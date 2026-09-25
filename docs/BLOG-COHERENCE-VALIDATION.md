# Blog Post Coherence Validation

**Validation date**: 2026-09-25  
**Blog posts validated**: 
- `2026-09-24-the-safe-highway-agentic-mtls.md` (Part 1)
- `2026-09-25-license-plates-agent-identity-spiffe.md` (Part 2)

**Docs validated**:
- FULL-LAB-VERIFICATION.md
- part1-verification.md
- parts-1-2-verification.md
- LAB-FINDINGS.md

---

## Part 1: The Safe Highway (2026-09-24)

### TL;DR Claims
✅ "mTLS gives them that road: encrypted, authenticated, attributable traffic"  
→ **VERIFIED in docs**: FULL-LAB-VERIFICATION.md § Part 1 / Verified Claims (encryption, workload auth)

✅ "mTLS answers only one question: which workload is this?"  
→ **VERIFIED in docs**: FULL-LAB-VERIFICATION.md § "What Works in Each Part" (encryption & workload auth ✅, identity & signing ❌)

✅ "logs can't tell you who asked"  
→ **VERIFIED in docs**: part1-verification.md § Claim 5, FULL-LAB-VERIFICATION.md § Key Insight (logs show peer=executor-agent but not decision-maker)

### Three Gaps from Article
| Gap | Claim | Evidence in Docs |
|-----|-------|------------------|
| "Who is driving?" | Only ServiceAccount named, not who authorized | FULL-LAB-VERIFICATION.md, part1-verification.md §Claim 5 |
| "Where allowed?" | No per-task least privilege | FULL-LAB-VERIFICATION.md § Key Insight, part1-verification.md |
| "What's in cargo?" | TLS ends at Redis, instructions plaintext | FULL-LAB-VERIFICATION.md § Key Insight, parts-1-2-verification.md |

### Specific Evidence
✅ "8 hits on plaintext instruction"  
→ FULL-LAB-VERIFICATION.md § Part 1 § Table, part1-verification.md § Claim 1

✅ "plaintext_instruction_hits=0 after mesh"  
→ part1-verification.md § Claim 2, FULL-LAB-VERIFICATION.md § Plaintext sniff

✅ "Linkerd edges: SECURED=√"  
→ part1-verification.md § Claim 3, FULL-LAB-VERIFICATION.md § Workload Identities

✅ "Planner reads poisoned inventory, executor deletes bucket"  
→ part1-verification.md § Claim 4, FULL-LAB-VERIFICATION.md § Authenticated but dangerous

✅ "peer=executor-agent.migration.serviceaccount.identity.linkerd.cluster.local"  
→ part1-verification.md § Claim 3, parts-1-2-verification.md

---

## Part 2: License Plates (2026-09-25)

### TL;DR Claims
✅ "identity should be issued by attestation, not handed as a key"  
→ **VERIFIED in docs**: FULL-LAB-VERIFICATION.md § Part 2 Overview, FULL-LAB-VERIFICATION.md § SPIRE Working

✅ "SPIRE issues X.509-SVID"  
→ **VERIFIED in docs**: FULL-LAB-VERIFICATION.md § Test 1: Planner Signing, excerpt shows signed_by=spiffe://highway.lab/...

✅ "Forged, self-signed, tampered tasks rejected"  
→ **VERIFIED in docs**: FULL-LAB-VERIFICATION.md § Test 3 & 4 with actual rejection messages

✅ "Valid signature on bad decision still executes"  
→ **VERIFIED in docs**: FULL-LAB-VERIFICATION.md § Test 5: Poisoned Inventory

### Specific Evidence From Article

#### SVID Fetching
✅ "planner-agent spiffe://highway.lab/ns/migration/sa/planner-agent | expires..."  
→ FULL-LAB-VERIFICATION.md § Part 2 § Verification After Fix

✅ "executor-agent spiffe://highway.lab/ns/migration/sa/executor-agent | expires..."  
→ FULL-LAB-VERIFICATION.md § Part 2 § Verification After Fix

✅ "rogue FetchX509SvidError: no identity issued"  
→ FULL-LAB-VERIFICATION.md § Part 2 § Verification After Fix

#### Break: Unsigned Injection
✅ "forge=pushed mode=unsigned claimed_signer=- instruction='delete bucket prod-archive'"  
→ FULL-LAB-VERIFICATION.md § Test 1: Unsigned Injection

✅ "executor=task ... signer=- ... tool=delete_bucket ... status=ok"  
→ FULL-LAB-VERIFICATION.md § Test 1: Unsigned Injection

#### Fix: Signing
✅ "broker=put task_id=43 step=1 signed_by=spiffe://highway.lab/ns/migration/sa/planner-agent"  
→ FULL-LAB-VERIFICATION.md § Test 2: Planner Signing

✅ "executor=task ... signer=spiffe://highway.lab/ns/migration/sa/planner-agent"  
→ FULL-LAB-VERIFICATION.md § Test 2: Planner Signing

#### Forge Attack
✅ "executor=REJECTED reason='unsigned payload'"  
→ FULL-LAB-VERIFICATION.md § Test 3: Self-Signed Forgery

✅ "executor=REJECTED reason='chain does not lead to the highway.lab trust bundle'"  
→ FULL-LAB-VERIFICATION.md § Test 3: Self-Signed Forgery

#### Tamper Attack
✅ "forge=tampered before='copy bucket...' after='delete bucket prod-archive'"  
→ FULL-LAB-VERIFICATION.md § Test 4: Queue Tampering

✅ "executor=REJECTED reason='bad signature: bad_signature: '"  
→ FULL-LAB-VERIFICATION.md § Test 4: Queue Tampering

#### Poison: Valid Bad Decision
✅ "planner=step task_id=45 step=2 instruction='delete bucket prod-archive'"  
→ FULL-LAB-VERIFICATION.md § Test 5: Poisoned Inventory

✅ "broker=put task_id=45 step=2 signed_by=spiffe://highway.lab/ns/migration/sa/planner-agent"  
→ FULL-LAB-VERIFICATION.md § Test 5: Poisoned Inventory

✅ "executor=task ... signer=spiffe://highway.lab/ns/migration/sa/planner-agent"  
→ FULL-LAB-VERIFICATION.md § Test 5: Poisoned Inventory

✅ "tool=delete_bucket bucket=prod-archive status=ok"  
→ FULL-LAB-VERIFICATION.md § Test 5: Poisoned Inventory

### Key Insight
✅ Article: "Valid signature. Right signer. Untampered payload. Wrong decision."  
→ **VERIFIED in docs**: FULL-LAB-VERIFICATION.md § Key Insight for Part 2

✅ Article: "Identity is not permission"  
→ **VERIFIED in docs**: FULL-LAB-VERIFICATION.md § Key Insight, conclusion states "Signatures validate sender identity, not authorization"

---

## Cross-Document Coherence

### FULL-LAB-VERIFICATION.md (primary validation document)
- ✅ Covers all Part 1 blog claims with evidence
- ✅ Covers all Part 2 blog claims with evidence
- ✅ Explains SPIRE WorkloadAPI fix (root cause + solution)
- ✅ Shows test results for all 5 scenarios
- ✅ Includes blog post validation section
- ✅ Lists what works in each part clearly
- **Status**: UP-TO-DATE, coherent with both blog posts

### part1-verification.md
- ✅ All 5 claims from blog post mapped to evidence
- ✅ Shows plaintext before/after mesh
- ✅ Names specific identity strings from Linkerd
- ✅ Demonstrates the 3 gaps from blog post
- **Status**: UP-TO-DATE, coherent with Part 1 blog post

### parts-1-2-verification.md
- ✅ Side-by-side comparison of both parts
- ✅ Shows Part 2 test scenarios
- ✅ Notes SPIRE configuration issue (pre-fix)
- **Status**: NEEDS UPDATE - written before Part 2 fix completed

### LAB-FINDINGS.md
- ✅ Documents initial findings and SPIRE issue diagnosis
- ✅ Provides root cause analysis
- ✅ Lists verification artifacts
- **Status**: HISTORICAL - superseded by FULL-LAB-VERIFICATION.md

### docs/README.md
- ✅ Correctly directs to appropriate files for each query
- ✅ Summarizes key findings
- ✅ Links to task commands
- **Status**: UP-TO-DATE and helpful

---

## Updates Needed

### parts-1-2-verification.md
**Issue**: Written during Part 2 debugging, before SPIRE fix  
**Fix needed**: Update to show Part 2 fully working with:
- All SVID fetching succeeding
- Forge rejection working
- Tamper rejection working
- Poison test showing valid signature on bad decision

**Impact**: Moderate - this file is supplementary; FULL-LAB-VERIFICATION.md is the primary source

---

## Validation Results

### ✅ ALL PRIMARY CLAIMS FROM BOTH BLOG POSTS ARE VERIFIED IN THE DOCS

**Coverage**: 100%
- Part 1: All 5 main claims + 3 gaps ✅
- Part 2: All 5 test scenarios + key insight ✅
- SPIRE fix: Explanation and verification ✅

**Coherence**: High
- Docs match blog post claims with actual lab evidence
- Evidence includes actual log output with timestamps
- Test results align with article narratives

**Completeness**: 
- Part 1: Complete and final
- Part 2: Complete with working SPIRE
- Technical explanations: Present and accurate

---

## Recommendation

**READY FOR PUBLICATION** with one optional enhancement:

1. ✅ Publish Part 1 blog post with FULL-LAB-VERIFICATION.md as reference
2. ✅ Publish Part 2 blog post with FULL-LAB-VERIFICATION.md as reference
3. 📝 (Optional) Update parts-1-2-verification.md with final Part 2 results

The core validation work is complete and comprehensive.
