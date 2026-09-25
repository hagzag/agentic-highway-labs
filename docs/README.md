# Lab Documentation & Verification

This directory contains comprehensive verification and findings documents for the agentic-highway lab series.

## Files

### `FULL-LAB-VERIFICATION.md` (Start here)
Complete verification report for both Part 1 and Part 2. Includes:
- Part 1 claims validation against blog post
- Part 2 test scenarios (forge, tamper, poison)
- SPIRE configuration fix explanation
- Blog post validation summary
- Lab structure and testing methodology

### `part1-verification.md`
Detailed claim-by-claim validation for Part 1: The Safe Highway (mTLS)
- 5 verified claims with evidence
- Plaintext vs encrypted traffic comparisons
- Workload identity verification
- Decision-maker attribution gap

### `parts-1-2-verification.md`
Side-by-side comparison of Part 1 and Part 2 results and status

### `LAB-FINDINGS.md`
Initial findings and recommendations from lab execution
- Evidence artifacts
- SPIRE attestation issue diagnosis
- Recommendations for publishing

## How to Use

**For blog post validation**: Start with `FULL-LAB-VERIFICATION.md` → "Blog Post Validation" section

**For understanding mTLS limits**: See `part1-verification.md`

**For SPIRE setup**: See `FULL-LAB-VERIFICATION.md` → "SPIRE Configuration Fix"

**For test results**: See `FULL-LAB-VERIFICATION.md` → "Part 2: All Test Scenarios Passing"

## Key Findings

**Part 1**: mTLS encrypts and authenticates workload-to-workload traffic, but cannot identify decision-makers or prevent authenticated workloads from executing malicious instructions.

**Part 2**: JWS signatures prevent forgery and detect tampering, but valid signatures on bad decisions (from poisoned inventory) still execute.

**Both**: Lab fully demonstrates the blog post claims with real k3d execution and captured output.

## Running the Labs

```bash
# Part 1
task part1:all        # Run everything
task part1:capture    # Run and save output to practice/part1/captured/k3d

# Part 2  
task part2:up         # Set up Part 2 (Part 1 + SPIRE)
task part2:capture    # Run all tests and save output

# Cleanup
task part1:cleanup
task part2:cleanup
```

See `practice/part1/README.md` and `practice/part2/README.md` for detailed task descriptions.
