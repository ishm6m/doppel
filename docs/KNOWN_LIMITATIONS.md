# KNOWN_LIMITATIONS.md

Tracked engine limitations with known upgrade paths. Each entry: what, why, fix.

## Stage 2 — MinHash estimate false-negatives on short docs near the gate

The 128-perm MinHash *estimate* of Jaccard can dip below `nearDupTextThreshold`
(0.85) for genuinely near-identical but **short** documents. A single changed
token can become the minimum for many permutations, dragging the estimate under
the gate even when true Jaccard is ~0.9. (Observed: a ~120-word contract with one
date changed estimated 0.836.) This is estimator variance, not a logic bug — it
shrinks as docs lengthen or permutation count rises.

**Mitigation today:** none in code; fixtures use longer docs. **Upgrade path:**
exact-Jaccard verify on near-gate candidates (cheap — they already share an LSH
bucket), or adaptive permutation count for short inputs. Site: `NearTextStage.group`.
