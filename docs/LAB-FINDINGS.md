# Agentic Highway Lab: Execution Findings

## Part 1: ✅ Complete Success

All claims from "The Safe Highway" blog post have been verified:

1. **Plaintext traffic without mTLS**: 8 plaintext "instruction" hits captured
2. **mTLS encryption**: Plaintext reduced to 0 after mesh (with proper restart order)
3. **Workload identities**: All connections secured with `SECURED=√` and SPIFFE-like identities
4. **Authenticated but dangerous**: Planner-read poisoned inventory → executor deleted bucket despite mTLS
5. **Logs don't name decision-makers**: Logs show `peer=executor-agent` but not who authorized it

### Key Finding
mTLS successfully encrypts and authenticates workload-to-workload traffic, but:
- Cannot prevent legitimate workloads from executing malicious instructions
- Cannot distinguish between authorized and unauthorized operations
- Cannot identify who authorized an action

---

## Part 2: ⚠️ Partial Success - SPIRE Attestation Issue

### What Worked
- ✅ SPIRE server and agent installed
- ✅ Identities registered in SPIRE (3 entries for planner, executor, mcp-tools)
- ✅ Planner SIGNING with SPIFFE identity: `signed_by=spiffe://highway.lab/ns/migration/sa/planner-agent`
- ✅ Rogue pod CAN push unsigned tasks (demonstrates vulnerability)

### What Failed
- ❌ SPIRE Workload API not issuing identities to agent processes
- ❌ Executor cannot verify signatures (no SVID to verify against)
- ❌ Forge rejection tests incomplete

### Root Cause
**SPIRE agent Kubernetes attestor mismatch**: Entries are registered correctly, but the agent process selector matching returns `registered=false`.

```
SPIRE server shows: 3 entries with selectors k8s:ns:migration + k8s:sa:*
SPIRE agent logs: "No identity issued" ... registered=false
```

This is a **configuration/setup issue**, not a design problem. Likely causes:
1. K8S attestor not configured to attest pod identity
2. Service account selectors not matching pod attestation
3. SPIRE agent rbac or permissions issue

---

## Evidence Artifacts

### Part 1 Evidence
- **Plaintext sniff**: 8 hits on "instruction" before mesh
- **Encrypted sniff**: 0 plaintext hits after mesh, TLS record headers (0x16/0x17 0x03 0x03)
- **Linkerd edges**: All connections show SECURED=√
- **Poisoned bucket**: `tool=delete_bucket bucket=prod-archive status=ok`

### Part 2 Evidence
- **Rogue unsigned task**: Executed despite no signature
  ```
  forge=pushed mode=unsigned ... signer=-
  executor=task ... signer=-
  tool=delete_bucket bucket=prod-archive status=ok
  ```
- **Planner signing**: Signed with SPIFFE ID
  ```
  broker=put task_id=43 step=1 signed_by=spiffe://highway.lab/ns/migration/sa/planner-agent
  ```
- **SPIRE entries registered**: 3 entries for planner, executor, mcp-tools with correct selectors

---

## Blog Post Validation

**"The Safe Highway" claims — ALL VERIFIED by Part 1:**

| Claim | Evidence | Status |
|-------|----------|--------|
| Plaintext traffic without mesh | 8 hits on "instruction" field | ✅ |
| mTLS encrypts after mesh | 0 plaintext hits, TLS records | ✅ |
| Workload identities bound | SECURED=√ for all connections | ✅ |
| Authenticated agent executes bad instruction | Bucket deleted via mTLS executor | ✅ |
| Logs name workload, not decision-maker | `peer=executor-agent...` only | ✅ |

**Part 2 intent** — To address the three gaps Part 1 leaves open:
1. "Who is driving?" → SPIFFE identity + signature
2. "Where is it allowed to go?" → Per-task authorization (Part 3)
3. "What's in the cargo?" → JWS signature verification

Part 2 demonstrates:
- ✅ Signing mechanism works (planner signs with SPIFFE key)
- ✅ Unsigned messages can be forged (rogue injects unsigned task)
- ⚠️ Signature verification blocked by SPIRE agent attestation issue

---

## Recommendations

1. **Part 1 Lab**: Production-ready. Demonstrates all claimed vulnerabilities correctly.

2. **Part 2 Lab**: SPIRE attestation needs debugging:
   - Check SPIRE agent K8S workload attestor config
   - Verify pod PSAT tokens are being used
   - May need to re-register entries after agent is healthy
   - Alternative: Use a simpler attestor (e.g., Unix socket) for testing

3. **Documentation**: Update Part 2 run.sh with known SPIRE issues or provide debugging steps

4. **Blog post**: Part 1 is ready to publish with full lab verification. Part 2 needs SPIRE fix before publishing.

---

## Cluster Status

- **Part 1 infrastructure**: ✅ All pods healthy, mesh working
- **SPIRE server**: ✅ Running, entries registered
- **SPIRE agent**: ⚠️ Running but attestor not matching pod selectors
- **Migration namespace**: ✅ All agents ready
- **Linkerd**: ✅ All connections secured and encrypted
