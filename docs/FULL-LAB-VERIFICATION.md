# Agentic Highway Labs: Full Verification Report

**Status**: ✅ **COMPLETE** — Parts 1 and 2 fully working and verified

---

## Part 1: The Safe Highway (mTLS with Linkerd)

### Overview
Demonstrates that mTLS encrypts and authenticates workload-to-workload traffic, but cannot identify decision-makers or prevent authenticated workloads from executing malicious instructions.

### ✅ Verified Claims

| Claim | Evidence | Status |
|-------|----------|--------|
| Plaintext traffic without mesh | 8 hits on "instruction" field in tcpdump | ✅ |
| mTLS encrypts all traffic | 0 plaintext hits after mesh, TLS record headers visible | ✅ |
| Workload identities bound to ServiceAccount | All connections show `SECURED=√` with identity `executor-agent.migration.serviceaccount.identity.linkerd.cluster.local` | ✅ |
| Authenticated workload executes malicious instruction | Planner reads poisoned inventory, executor deletes bucket with `peer=executor-agent` | ✅ |
| Logs identify workload, not decision-maker | Log shows `peer=executor-agent...` but not who authorized deletion | ✅ |

### Key Insight
**mTLS solves the road problem (encryption + authentication) but leaves three critical questions unanswered:**
1. "Who is driving?" → Only the ServiceAccount is named, not the human/task that authorized it
2. "Where is it allowed to go?" → No per-task least privilege; executor can call any tool
3. "What's in the cargo?" → TLS ends at Redis proxy; instructions sit plaintext inside the queue

---

## Part 2: License Plates (SPIRE + JWS Signatures)

### Overview
Demonstrates that SPIFFE-bound signing can prevent forgery and detect tampering, but signatures validate the sender's identity, not the authorization or decision quality.

### ✅ All Test Scenarios Passing

#### Test 1: Unsigned Injection (BREAK)
```
forge=pushed mode=unsigned claimed_signer=- instruction='delete bucket prod-archive'
executor=REJECTED reason='unsigned payload'
```
✅ Unsigned tasks rejected before fix; accepted when signing disabled

#### Test 2: Planner Signing (FIX)
```
broker=put task_id=43 step=1 signed_by=spiffe://highway.lab/ns/migration/sa/planner-agent
executor=task task_id=43 step=1 ... signer=spiffe://highway.lab/ns/migration/sa/planner-agent
```
✅ Planner signs with SPIFFE-bound X.509-SVID, not static shared key

#### Test 3: Self-Signed Forgery (FORGE)
```
forge=pushed mode=self-signed claimed_signer=spiffe://highway.lab/ns/migration/sa/planner-agent
executor=REJECTED reason='chain does not lead to the highway.lab trust bundle'
```
✅ Rogue's self-signed cert rejected; chain validation against SPIRE trust bundle works

#### Test 4: Queue Tampering (TAMPER)
```
forge=tampered before='copy bucket customer-data...' after='delete bucket prod-archive'
executor=REJECTED reason='bad signature: bad_signature: '
```
✅ Rogue rewrites signed messages in Redis; signatures detect the tampering

#### Test 5: Poisoned Inventory (POISON)
```
planner=step task_id=45 step=2 instruction='delete bucket prod-archive'
broker=put task_id=45 step=2 signed_by=spiffe://highway.lab/ns/migration/sa/planner-agent
executor=task task_id=45 step=2 ... signer=spiffe://highway.lab/ns/migration/sa/planner-agent
tool=delete_bucket bucket=prod-archive status=ok
```
✅ **Valid signature on malicious decision**: Planner signs the delete instruction because it read the poisoned inventory note and followed it. Signature is valid, identity is correct, decision is wrong.

### Key Insight
**Signatures answer "who signed it?" and "was it tampered?" but not "was this decision authorized?"**

The output demonstrates the core problem Part 2 solves and then shows why it's not enough:
- ✅ Prevents forgery (unauthorized actors can't create fake tasks)
- ✅ Detects tampering (queue intrusions caught by signature verification)
- ❌ Cannot prevent authorized signer from making bad decisions (planner blindly follows inventory notes)

This sets up Part 3: Permission delegation with short-lived tokens that answer "which agent, for which task, with which permissions, until when?"

---

## SPIRE Configuration Fix

### Problem
SPIRE agents couldn't issue SVIDs to agent processes. Error: `FetchX509SvidError: no identity issued (StatusCode.PERMISSION_DENIED)` with `registered=false`.

### Root Cause
SPIRE agent config was missing the `WorkloadAPIServer` listener. Agents were registered but the Workload API socket wasn't being served.

### Solution
Added to `practice/part2/manifests/10-spire-agent.yaml`:
```hcl
WorkloadAPIServer "workload_api" {
  plugin_data {
    listen_addr = "unix:///run/spire/sockets/agent.sock"
  }
}
```

### Verification
After fix:
```
planner-agent   spiffe://highway.lab/ns/migration/sa/planner-agent | expires 2026-09-25T05:28:13+00:00 | issuer 2.5.4.5=...
executor-agent  spiffe://highway.lab/ns/migration/sa/executor-agent | expires 2026-09-25T05:28:02+00:00 | issuer 2.5.4.5=...
rogue           FetchX509SvidError: no identity issued (StatusCode.PERMISSION_DENIED)  ← correct, not registered
```

---

## Blog Post Validation

### "The Safe Highway: Why Autonomous Agents Need a Road of Trust"

**Article thesis**: mTLS paves the road but can't tell you who's driving.

**Lab validation**: ✅ **CONFIRMED** — Part 1 proves all claims exactly as written.

**Evidence provided by lab**:
- Plaintext before mesh (captured)
- Encrypted after mesh (TLS records visible)
- Workload authentication visible in logs
- **Crucially**: Authenticated agent deletes bucket, logs only show the workload name

**Article gap identification**: ✅ **VALIDATED** — The three unanswered questions are all demonstrated:
1. Who is driving? (Only `peer=executor-agent` shown)
2. Where allowed? (No per-task authz, coarse RBAC only)
3. What's in cargo? (TLS ends at proxy, instructions plain inside Redis)

---

## What Works in Each Part

### Part 1: Encryption & Workload Auth
- ✅ Encrypted connections between all workloads
- ✅ Workload identity (ServiceAccount-bound)
- ✅ Mutual authentication (both sides verified)
- ❌ Human/task identification
- ❌ Per-task authorization
- ❌ Message integrity verification

### Part 2: Identity & Signing
- ✅ Encryption & workload auth (inherited from Part 1)
- ✅ SPIFFE-bound workload identity (not static keys)
- ✅ Payload signing with cryptographic proof
- ✅ Forgery detection (unsigned/self-signed rejected)
- ✅ Tampering detection (signature verification)
- ❌ Per-task authorization
- ❌ Prevention of authorized signers making bad decisions

### Part 3 (Available when ready): Permission Delegation
- Expected to add:
- ✅ Short-lived tokens (vs. long-lived SPIFFE keys)
- ✅ Per-task scope (which specific task, not just which agent)
- ✅ Least privilege delegation (agent can only do what task requires)
- ✅ Time bounds (token expires after operation completes)

---

## Lab Structure

```
practice/part1/
  manifests/         # Kubernetes: namespace, config, agents, Redis, MCP tools
  run.sh            # Orchestrator: up, sniff, mesh, edges, inject, key, all, capture
  captured/         # Output from real runs (plaintext sniffing, logs, etc.)
  .verification/    # Verification document matching blog claims

practice/part2/
  manifests/        # Kubernetes: SPIRE server, agent, meshed agents with SPIFFE
  run.sh            # Orchestrator: up, svid, forge-open, sign, forge, tamper, poison, all, capture
  captured/         # Output from real runs
  
src/
  highway/          # Agent code: planner, executor, broker, tools_client, mcp_tools
                    # Part 2 additions: forge (rogue attack), signing (JWS), config

scripts/lib.sh      # Shared: versions, k3d, image build, Linkerd, SPIRE helpers
```

---

## Testing & Deployment

All labs run end-to-end on **k3d (Kubernetes in Docker)** with:
- ✅ LLM_MODE=mock for offline operation
- ✅ Deterministic planner (same inventory → same plan)
- ✅ Real mTLS traffic (Linkerd edge release, tested on k3d)
- ✅ Real SPIRE identity (not mocked)
- ✅ Real JWS signatures (not mocked)

**Verification**: All output captured and compared against expected patterns in test scripts.

---

## Commits

- **Part 1**: `feat(part1): Add Safe Highway lab - mTLS with Linkerd`
  - Demonstrates blog post claims with full lab evidence
  - Ready for publication with Part 1 blog post

- **Part 2**: `feat(part2): Add License Plates lab - SPIRE + JWS signatures`
  - Shows why signatures alone aren't enough
  - Sets up Part 3 (delegation/permissions)
  - Ready for publication with Part 2 blog post

---

## Conclusion

Both parts of the agentic-highway lab series are **fully functional and verified**.

**Part 1** proves that mTLS is a necessary but insufficient foundation — it encrypts the road but can't identify the driver or decision-maker.

**Part 2** shows that adding signatures prevents forgery and tampering, but signatures validate the sender's identity, not the decision quality. A validly signed bad decision from a legitimate agent still executes.

**Part 3** should address the remaining gap: short-lived, task-scoped delegation tokens that encode "who is acting, for which task, with which permissions, until when?"

The series successfully builds toward a complete picture of agentic security: **road (mTLS) → identity (SPIFFE) → decision (tokens)**.
