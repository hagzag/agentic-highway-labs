"""Part 5: the black box. An append-only, hash-chained, signed audit log.

    python -m highway.audit serve                    # the collector (a Deployment)
    python -m highway.audit verify [--checkpoint -]  # is the tape intact?
    python -m highway.audit replay --ip 10.42.0.33   # who shipped the token?
    python -m highway.audit replay --bucket prod-archive
    python -m highway.audit replay --task-id 71
    python -m highway.audit dump                     # every record, decoded

Three layers, each catching what the one before can't:

1. Emitter signatures. Every event is a JWS signed by the workload that saw it
   (its X.509-SVID, see auditlog.py). The collector accepts an event only if the
   signature chains to the SPIRE bundle AND that SPIFFE ID may emit that kind
   (only mcp-gateway writes gateway.* events). Nobody, including whoever runs the
   collector, can later rewrite what the gateway said without breaking its
   signature.
2. A hash chain. Record n stores hash(n) = sha256(hash(n-1) | n | jws). Deleting or
   reordering a record breaks the chain... unless the editor recomputes it, which
   is why layer 1 exists.
3. Signed checkpoints. After appends, the collector signs {seq, head} with its own
   SVID and writes it to a ConfigMap (a stand-in for S3 Object Lock / a
   transparency log). Truncating the tail, or rechaining after an edit, no longer
   matches the anchored head.
"""
import argparse
import asyncio
import base64
import hashlib
import json
import os
import sys
import threading
import time

from . import signing, svid
from .log import log

GENESIS = "0" * 64
FILE = os.environ.get("AUDIT_FILE", "/var/lib/audit/audit.jsonl")
CHECKPOINT_CM = os.environ.get("AUDIT_CHECKPOINT_CM", "")      # empty = no anchoring
EVERY = int(os.environ.get("AUDIT_CHECKPOINT_EVERY", "1"))
PREFIX = os.environ.get("AUDIT_SPIFFE_PREFIX", "spiffe://highway.lab/ns/migration/sa/")
# Which workload may write which kind of event. The prefix of `kind` picks the row.
EMITTERS = {"sts": "sts", "planner": "planner-agent", "executor": "executor-agent",
            "gateway": "mcp-gateway", "tool": "mcp-tools", "runner": "sandbox-runner",
            # Part 6: the egress gateway's decisions, and the store API's own account
            "egress": "egress-gateway", "store": "mcp-tools"}
COLLECTOR = os.environ.get("AUDIT_COLLECTOR_ID", PREFIX + "audit")


def link(prev: str, seq: int, jws: str) -> str:
    return hashlib.sha256(f"{prev}|{seq}|{jws}".encode()).hexdigest()


def peek(jws: str) -> dict:
    """Decode a JWS payload WITHOUT verifying it (display only)."""
    try:
        p = jws.split(".")[1]
        return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
    except Exception:  # noqa: BLE001
        return {}


def claimed_signer(jws: str) -> str:
    """The SPIFFE ID the x5c leaf *claims* (unverified; display only)."""
    try:
        from cryptography import x509
        h = jws.split(".")[0]
        header = json.loads(base64.urlsafe_b64decode(h + "=" * (-len(h) % 4)))
        return signing._spiffe_id(x509.load_der_x509_certificate(base64.b64decode(header["x5c"][0])))
    except Exception:  # noqa: BLE001
        return "-"


def _kind(raw: str) -> str:
    try:
        return str(json.loads(raw).get("kind", "-"))
    except Exception:  # noqa: BLE001
        return "-"


def unauthorized(kind: str, signer: str) -> str | None:
    want = EMITTERS.get(kind.split(".", 1)[0])
    if want is None:
        return f"unknown event kind {kind!r}"
    if signer != PREFIX + want:
        return f"{svid.short(signer)} may not write {kind} (only {want})"
    return None


# --- the collector -------------------------------------------------------------

class Box:
    """The tape. One JSON line per record; seq and head survive restarts (it's a PVC)."""

    def __init__(self, path: str):
        self.path, self.lock = path, threading.Lock()
        self.seq, self.head = 0, GENESIS
        if os.path.exists(path):
            with open(path) as f:
                for line in f:
                    if line.strip():
                        r = json.loads(line)
                        self.seq, self.head = r["seq"], r["hash"]

    def append(self, jws: str) -> tuple[int, str]:
        with self.lock:
            seq, prev = self.seq + 1, self.head
            h = link(prev, seq, jws)
            rec = {"seq": seq, "received": round(time.time(), 3), "prev": prev, "hash": h, "jws": jws}
            os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
            with open(self.path, "a") as f:
                f.write(json.dumps(rec) + "\n")
                f.flush()
                os.fsync(f.fileno())
            self.seq, self.head = seq, h
            return seq, h

    def state(self) -> tuple[int, str]:
        with self.lock:
            return self.seq, self.head


_anchor_lock = threading.Lock()


def checkpoint(box: Box) -> str:
    seq, head = box.state()
    tok, _ = signing.sign({"seq": seq, "head": head}, typ=signing.CHECKPOINT_TYP)
    return tok


def anchor(box: Box) -> None:
    """Write the signed head somewhere the file's editor can't: a ConfigMap only this SA may patch."""
    import httpx
    sa = "/var/run/secrets/kubernetes.io/serviceaccount"
    with _anchor_lock:
        try:
            tok = checkpoint(box)
            ns = open(f"{sa}/namespace").read().strip()
            r = httpx.patch(
                f"https://kubernetes.default.svc/api/v1/namespaces/{ns}/configmaps/{CHECKPOINT_CM}",
                content=json.dumps({"data": {"latest": tok}}),
                headers={"Authorization": "Bearer " + open(f"{sa}/token").read().strip(),
                         "Content-Type": "application/merge-patch+json"},
                verify=f"{sa}/ca.crt", timeout=5)
            r.raise_for_status()
            c = peek(tok)
            log("audit=checkpoint", seq=c["seq"], head=c["head"][:12], to=f"configmap/{CHECKPOINT_CM}")
        except Exception as e:  # noqa: BLE001
            log("audit=checkpoint_error", error=f"{type(e).__name__}: {e}")


def make_app(box: Box):
    from starlette.applications import Starlette
    from starlette.requests import Request
    from starlette.responses import JSONResponse
    from starlette.routing import Route

    async def events(request: Request) -> JSONResponse:
        tok = (await request.body()).decode("utf-8", "replace").strip()
        if tok.startswith("{"):
            log("audit=REJECTED", claimed="-", kind=_kind(tok), reason="unsigned event")
            return JSONResponse({"rejected": "unsigned event"}, status_code=403)
        try:
            event, signer = await asyncio.to_thread(signing.verify, tok, signing.AUDIT_TYP, [])
        except signing.Rejected as e:
            log("audit=REJECTED", claimed=svid.short(claimed_signer(tok)), kind=peek(tok).get("kind", "-"),
                reason=str(e))
            return JSONResponse({"rejected": str(e)}, status_code=403)
        why = unauthorized(str(event.get("kind", "")), signer)
        if why:
            log("audit=REJECTED", claimed=svid.short(signer), kind=event.get("kind", "-"), reason=why)
            return JSONResponse({"rejected": why}, status_code=403)
        seq, head = box.append(tok)
        log("audit=appended", seq=seq, kind=event["kind"], signer=svid.short(signer),
            task_id=event.get("task_id", "-"))
        if CHECKPOINT_CM and seq % EVERY == 0:
            threading.Thread(target=anchor, args=(box,), daemon=True).start()
        return JSONResponse({"seq": seq, "hash": head})

    async def get_checkpoint(_: Request) -> JSONResponse:
        return JSONResponse({"checkpoint": await asyncio.to_thread(checkpoint, box)})

    async def healthz(_: Request) -> JSONResponse:
        return JSONResponse({"ok": True})

    return Starlette(routes=[Route("/events", events, methods=["POST"]),
                             Route("/checkpoint", get_checkpoint), Route("/healthz", healthz)])


def serve() -> None:
    import uvicorn
    box = Box(FILE)
    port = int(os.environ.get("PORT", "8080"))
    log("audit starting", port=port, file=FILE, records=box.seq, checkpoint=CHECKPOINT_CM or "-")
    uvicorn.run(make_app(box), host="0.0.0.0", port=port, log_level="warning")


# --- verify ---------------------------------------------------------------------

class Rec:
    def __init__(self, raw: dict, prev: str):
        self.seq, self.jws, self.hash = raw["seq"], raw["jws"], raw["hash"]
        self.chain_ok = raw["prev"] == prev and raw["hash"] == link(raw["prev"], raw["seq"], raw["jws"])
        try:
            self.event, self.signer = signing.verify(self.jws, signing.AUDIT_TYP, [], historic=True)
            self.sig_ok, self.why = True, unauthorized(str(self.event.get("kind", "")), self.signer) or ""
            self.sig_ok = not self.why
        except signing.Rejected as e:
            why = str(e).rstrip(": ")
            if why.startswith("bad signature"):
                why = "bad signature: payload changed after it was signed"
            self.event, self.signer, self.sig_ok, self.why = peek(self.jws), claimed_signer(self.jws), False, why

    @property
    def ok(self) -> bool:
        return self.chain_ok and self.sig_ok

    def get(self, k: str, default=None):
        return self.event.get(k, default)


def load(path: str) -> list[Rec]:
    recs, prev = [], GENESIS
    with open(path) as f:
        for line in f:
            if line.strip():
                raw = json.loads(line)
                recs.append(Rec(raw, prev))
                prev = raw["hash"]
    return recs


def check_anchor(recs: list[Rec], tok: str | None) -> str:
    if not tok:
        return "NONE (no checkpoint given)"
    try:
        c, _ = signing.verify(tok.strip(), signing.CHECKPOINT_TYP, [COLLECTOR], historic=True)
    except signing.Rejected as e:
        return f"BAD ({e})"
    seq, head = int(c["seq"]), c["head"]
    if seq > len(recs):
        return f"TRUNCATED (anchored seq={seq}, file has {len(recs)} records)"
    have = recs[seq - 1].hash if seq else GENESIS
    if have != head:
        return f"MISMATCH (seq={seq} anchored head={head[:12]} file has {have[:12]})"
    return f"OK (seq={seq} head={head[:12]})"


def verify(path: str, tok: str | None) -> bool:
    recs = load(path)
    for r in recs:
        if not r.ok:
            log("verify", seq=r.seq, chain="OK" if r.chain_ok else "BROKEN", sig="OK" if r.sig_ok else "BAD",
                kind=r.get("kind", "-"), claimed=svid.short(r.signer), reason=r.why or "-")
    anchored = check_anchor(recs, tok)
    chain = "OK" if all(r.chain_ok for r in recs) else "BROKEN"
    sigs = sum(r.sig_ok for r in recs)
    intact = chain == "OK" and sigs == len(recs) and anchored.startswith(("OK", "NONE"))
    log("verify", records=len(recs), chain=chain, signatures=f"{sigs}/{len(recs)}", checkpoint=anchored,
        verdict="INTACT" if intact else "TAMPERED")
    return intact


# --- replay ---------------------------------------------------------------------

def _t(e: dict) -> str:
    return time.strftime("%H:%M:%S", time.gmtime(e.get("iat", 0)))


def _j(v) -> str:
    return str(v)[:8] if v else "-"


def _peer(p: str | None) -> str:
    """rogue.migration.serviceaccount.identity.linkerd.cluster.local -> rogue"""
    return p.split(".", 1)[0] if p and ".serviceaccount." in p else (p or "-")


def describe(e: dict) -> str:
    k = e.get("kind", "?")
    if k == "sts.issued":
        s = f"permit {_j(e.get('jti'))} sub={e.get('sub')} act='{e.get('act')}' scope='{e.get('scope')}'"
        if e.get("parent_jti"):
            return s + f" (exchanged from {_j(e['parent_jti'])})"
        idp = e.get("idp") or {}
        s += f" dropped={e.get('dropped', '-')}"
        return s + f"\n{'':27}human: {e.get('sub')} logged in at Keycloak (client={idp.get('azp', '-')}, " \
                   f"session={_j(idp.get('sid'))}, auth_time={_t({'iat': idp.get('auth_time', 0)})})"
    if k == "sts.deny":
        return f"permit DENIED {e.get('error')}: {e.get('reason')}"
    if k == "planner.plan":
        steps = "".join(f"\n{'':27}{i}) {s}" for i, s in enumerate(e.get("steps", []), 1))
        notes = "".join(f"\n{'':27}note on {b}: {n!r}" for b, n in (e.get("notes") or {}).items())
        return f"planned task {e.get('task_id')} from inventory {e.get('inventory')} with permit " \
               f"{_j(e.get('jti'))}:{steps}{notes}"
    if k == "executor.task":
        return f"took step {e.get('step')} '{e.get('instruction')}' (queued task signed by " \
               f"{svid.short(e.get('signer'))}), permit {_j(e.get('jti'))}"
    if k == "executor.tool_call":
        return f"called {e.get('tool')} args={e.get('args')}"
    if k == "gateway.decision":
        why = f" reasons='{'; '.join(e.get('reasons', []))}'" if e.get("reasons") else ""
        return f"{e.get('decision')} {e.get('tool')} caller={svid.short(e.get('caller'))} (JWT-SVID) " \
               f"sub={e.get('sub')} act='{e.get('act')}' permit={_j(e.get('jti'))}{why}"
    if k == "tool.exec":
        return f"{e.get('tool')} {e.get('bucket', '')} status={e.get('status')} sub={e.get('sub', '-')} " \
               f"(header) peer={_peer(e.get('peer'))} (mTLS) permit={_j(e.get('jti'))}"
    if k == "runner.exec":
        out = str(e.get("out", "")).replace("\n", " ")
        return f"ran {e.get('language')} code={e.get('code')} sub={e.get('sub', '-')} (header) " \
               f"peer={_peer(e.get('peer'))} (mTLS) pod_ip={e.get('pod_ip')} permit={_j(e.get('jti'))}" \
               f"\n{'':27}output: {out}"
    if k == "egress.decision":
        why = f" reasons='{'; '.join(e.get('reasons', []))}'" if e.get("reasons") else ""
        return f"{e.get('decision')} {e.get('method')} {e.get('host')}{e.get('path')} " \
               f"credential={e.get('credential', '-')} caller={_peer(e.get('caller'))} (mTLS) " \
               f"sub={e.get('sub', '-')} act='{e.get('act', '-')}' permit={_j(e.get('jti'))}{why}"
    if k == "store.exec":
        return f"store {e.get('op')} {e.get('bucket')} status={e.get('status')} sub={e.get('sub', '-')} " \
               f"(header) peer={_peer(e.get('peer'))} (mTLS) permit={_j(e.get('jti'))}"
    return json.dumps(e)


def show(r: Rec) -> None:
    mark = "ok " if r.ok else "BAD"
    print(f"{_t(r.event)} {svid.short(r.signer):<15} {mark} #{r.seq:<3} {describe(r.event)}")
    if not r.ok:
        print(f"{'':27}^ {'chain broken; ' if not r.chain_ok else ''}{r.why}")


def lineage(recs: list[Rec], jti: str) -> list[Rec]:
    """The permits behind `jti`, newest first: executor hop -> planner hop (-> the human)."""
    by_jti = {r.get("jti"): r for r in recs if r.get("kind") == "sts.issued"}
    out, cur = [], by_jti.get(jti)
    while cur is not None and cur not in out:
        out.append(cur)
        cur = by_jti.get(cur.get("parent_jti"))
    return out


def verdict(recs: list[Rec], a: Rec, shown: list[Rec]) -> None:
    what = f"{a.get('tool', 'run_script')} {a.get('bucket', '')}".strip()
    if a.get("kind") == "runner.exec":
        what = f"run_script on {a.get('pod_ip')}"
    if a.get("kind") == "store.exec":
        what = f"store {a.get('op')} {a.get('bucket')}"
    jti = a.get("jti")
    gates = [r for r in recs if r.get("kind") == "gateway.decision" and r.get("decision") == "ALLOW"
             and jti and r.get("jti") == jti and r.get("tool") == a.get("tool", "run_script")]
    gate = next((g for g in gates if g.ok), None)
    chain = [c for c in lineage(recs, jti) if c.ok] if jti else []
    root = chain[-1] if chain else None
    print(f"\nVERDICT for #{a.seq} ({what})")
    egress = next((r for r in shown if r.get("kind") == "egress.decision" and r.get("decision") == "ALLOW"), None)
    if not jti and egress:
        print("  human   : NONE. The egress gateway spent the store credential without a permit")
        print(f"  agent   : none proven. Caller {_peer(egress.get('caller'))} (mTLS) asked; "
              f"credential={egress.get('credential')} was injected for it")
        print("  task    : none. The sandbox never held the key, and it didn't need to")
    elif not jti:
        print(f"  human   : UNPROVEN. sub={a.get('sub', '-')} is a request header anyone can set; "
              "no permit, no Keycloak login behind it")
        print("  agent   : none proven. No JWT-SVID, no gateway decision: this call never went through the gateway")
        print(f"  caller  : {_peer(a.get('peer'))} (the only proven identity: the mesh's mTLS peer)")
        print("  task    : none")
    else:
        idp = (root.get("idp") or {}) if root else {}
        print(f"  human   : {root.get('sub') if idp else 'UNPROVEN'}"
              + (f" (Keycloak session {_j(idp.get('sid'))}; every signed permit in the chain says "
                 f"sub={root.get('sub')})" if idp else " (no verified permit chain back to a login)"))
        step = next((r for r in recs if r.ok and r.get("kind") == "executor.task" and r.get("jti") == jti), None)
        if gate:
            agent = f"{gate.get('act')} (caller {svid.short(gate.get('caller'))} proved by JWT-SVID at the gateway)"
        elif step and chain:
            agent = (f"{chain[0].get('act')} (from the permit chain and {svid.short(step.signer)}'s own signed "
                     "record; the gateway's record did not verify)")
        else:
            agent = "UNPROVEN (no verified gateway ALLOW for this call)"
        print("  agent   : " + agent)
        print(f"  task    : {a.get('task_id')}, permit {_j(jti)}"
              + "".join(f" <- {_j(c.get('jti'))}" for c in chain[1:])
              + (f", scope '{chain[0].get('scope')}'" if chain else ""))
        plan = next((r for r in recs if r.ok and r.get("kind") == "planner.plan" and root
                     and r.get("jti") == root.get("jti")), None)
        if step:
            print(f"  why     : step '{step.get('instruction')}' of the plan"
                  + (f", written by {svid.short(plan.signer)} from inventory {plan.get('inventory')}" if plan else ""))
    if a.get("kind") == "runner.exec":
        print(f"  did     : {str(a.get('out', '')).replace(chr(10), ' ')}")
    bad = [r for r in shown if not r.ok]
    print(f"  evidence: {len(shown)} linked record{'s' * (len(shown) != 1)}, "
          + ("all signatures valid" if not bad else f"{len(bad)} FAILED verification and {'was' if len(bad) == 1 else 'were'} ignored"))
    for r in bad:
        print(f"  tampered: #{r.seq} {r.get('kind')} now says sub={r.get('sub', '-')}; "
              f"{svid.short(r.signer)}'s signature no longer matches it")


def story(recs: list[Rec], a: Rec) -> None:
    """Every record linked to the anchor, in time order, then a verdict."""
    jti, keep = a.get("jti"), [a]
    chain = lineage(recs, jti) if jti else []
    if chain:
        ids, root = {c.get("jti") for c in chain}, chain[-1].get("jti")
        for r in recs:
            k = r.get("kind", "")
            if r is a:
                continue
            if (r in chain
                    or (k in ("gateway.decision", "tool.exec", "runner.exec", "egress.decision")
                        and r.get("jti") in ids)
                    or (k.startswith("executor.") and r.get("jti") == jti)
                    or (k == "planner.plan" and r.get("jti") == root)):
                keep.append(r)
    if a.get("kind") == "store.exec":  # Part 6: the egress decision that spent the credential
        keep += [r for r in recs if r.get("kind") == "egress.decision" and r not in keep
                 and str(r.get("path", "")).endswith("/" + str(a.get("bucket")))
                 and (r.get("jti") == jti if jti else not r.get("jti"))]
    keep.sort(key=lambda r: (r.get("iat", 0), r.seq))
    for r in keep:
        show(r)
    verdict(recs, a, keep)


def replay(path: str, task_id: str | None, ip: str | None, bucket: str | None) -> None:
    recs = load(path)
    if task_id:
        for r in sorted((r for r in recs if str(r.get("task_id")) == task_id), key=lambda r: (r.get("iat", 0), r.seq)):
            show(r)
        return
    if ip:
        anchors = [r for r in recs if r.get("kind") == "runner.exec" and r.get("pod_ip") == ip]
    else:
        anchors = [r for r in recs if r.get("kind") in ("tool.exec", "store.exec") and r.get("bucket") == bucket
                   and r.get("status") == "ok" and r.get("tool") != "read_inventory"]
    if not anchors:
        print(f"no record matches {'pod_ip=' + ip if ip else 'bucket=' + str(bucket)}")
        return
    for a in anchors:
        print(f"--- #{a.seq} {a.get('kind')} ---")
        story(recs, a)


def dump(path: str) -> None:
    for r in load(path):
        print(json.dumps({"seq": r.seq, "ok": r.ok, "signer": r.signer, **r.event}))


def main() -> None:
    p = argparse.ArgumentParser(prog="highway.audit")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve")
    v = sub.add_parser("verify")
    v.add_argument("--checkpoint", help="signed checkpoint JWS, a file, or - for stdin")
    r = sub.add_parser("replay")
    g = r.add_mutually_exclusive_group(required=True)
    g.add_argument("--task-id")
    g.add_argument("--ip", help="a source IP from an incident (e.g. the sink's src=)")
    g.add_argument("--bucket", help="a resource that was changed")
    sub.add_parser("dump")
    for s in (v, r, sub.choices["dump"]):
        s.add_argument("--file", default=FILE)
    a = p.parse_args()
    if a.cmd == "serve":
        return serve()
    if a.cmd == "verify":
        tok = a.checkpoint
        if tok == "-":
            tok = sys.stdin.read()
        elif tok and os.path.exists(tok):
            tok = open(tok).read()
        sys.exit(0 if verify(a.file, tok) else 1)
    if a.cmd == "replay":
        return replay(a.file, a.task_id, a.ip, a.bucket)
    return dump(a.file)


if __name__ == "__main__":
    main()
