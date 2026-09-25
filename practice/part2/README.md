# Part 2 — License Plates

Give every agent a cryptographic identity issued by attestation, not by a human. Then use it to sign what crosses the queue.

- **Identity ladder:** ServiceAccount → bound, projected SA token (node attestation) → SPIFFE X.509-SVID (workload attestation).
- **Where GPG fits:** signing *payloads*. It isn't runtime identity. Here the payload key *is* the SVID key. It's short-lived, rotated by SPIRE, and bound to where the pod runs.

```bash
task part2:up          # Part 1 road + SPIRE 1.15.3 + registration entries
task part2:svid        # planner/executor get SVIDs; rogue gets PERMISSION_DENIED
task part2:forge-open  # BREAK: signing off, rogue's task runs
task part2:sign        # FIX: planner signs (JWS, x5c = SVID chain); executor verifies
task part2:forge       # unsigned + self-signed "planner" cert: rejected
task part2:tamper      # rewrite signed tasks inside Redis: rejected
task part2:poison      # BREAK AGAIN: validly signed bad step still runs
```

## Real output (local SPIRE 1.15.3, join_token + unix attestors)

From [captured/local/](captured/local/). On k3d the attestors are `k8s_psat` + `k8s`; the flow and log lines are the same.

```text
# rogue asks the Workload API for an identity
FetchX509SvidError: ... no identity issued (StatusCode.PERMISSION_DENIED)

executor=REJECTED reason='unsigned payload'
executor=REJECTED reason='chain does not lead to the highway.lab trust bundle (claimed spiffe://highway.lab/ns/migration/sa/planner-agent)'

forge=tampered index=0 before='copy bucket customer-data to regulated-customer-data' after='delete bucket prod-archive'
executor=REJECTED reason='bad signature: bad_signature: '

# poisoned inventory: the planner signs the bad step itself
executor=task task_id=44 step=2 instruction='delete bucket prod-archive' requested_by=haggai signer=spiffe://highway.lab/ns/migration/sa/planner-agent
tool=delete_bucket bucket=prod-archive status=ok peer=-
```

## How verification works ([signing.py](../../src/highway/signing.py))
1. Parse the JWS header. Require `typ: highway-task+jws` and `x5c`.
2. Walk the x5c chain up to an authority in the SPIRE trust bundle. The executor fetches that bundle from its own Workload API.
3. Check the leaf's SPIFFE ID against `ALLOWED_SIGNERS`.
4. Verify the signature with the leaf key, then check `exp`, which limits replay.

**Gotcha found while building this:** `joserfc` caps the protected header at 512 bytes. A real SVID in `x5c` is about 1 KB, so every legitimate message was rejected as `exceeded_size` until the cap was raised.

## What signing did not fix
The signature proves **the planner said it**, unchanged. It doesn't prove the planner *should* have said it. The poisoned note went in as data and came out as a correctly signed instruction.

Identity ≠ permission. Part 3 adds delegation (`sub` + `act`), task scopes and policy at the tool gateway.

## Cleanup
```bash
./cleanup.sh            # SPIRE + namespace
./cleanup.sh --cluster  # whole k3d cluster
```
