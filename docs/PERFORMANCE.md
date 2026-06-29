# PERFORMANCE.md — Performance Goals & Optimization

> **Purpose:** Define performance budgets, the strategy to hit them, and how to measure.
> **Scope:** Throughput/memory/responsiveness targets, optimization techniques, benchmarking harness.
> **Dependencies:** `ARCHITECTURE.md`, `DATA_MODEL.md`, `TESTING.md`.

**Why it matters:** Doppel competes with fast deterministic tools. If it's slow or a battery hog, the cascade advantage is wasted. Speed is a feature.

---

## 1. Budgets (Apple Silicon, MVP documents)
| Scenario | Target |
|---|---|
| Enumerate 50k files | < 5 s |
| Full scan 50k docs (avg 200 KB) through Stage 2 | **< 5 min** |
| Incremental re-scan (no changes) | < 15 s |
| Peak memory (50k scan) | **< 1.5 GB** |
| UI frame time during scan | ≥ 60 fps, no main-thread stalls > 16 ms |
| Stage-2 throughput | ≥ 300 files/sec p50 |
| First results visible | < 3 s after scan start |
| Time-to-interactive (app launch) | < 1 s |

Stage 3 (embeddings) is opt-in and budgeted separately; throttle to keep the app responsive and battery sane.

---

## 2. Strategy
1. **Cascade ordering** is the #1 optimization: never embed what hashing/MinHash resolved.
2. **Stream, never accumulate.** Process in batches; flush to SQLite; release memory. Never hold all file contents/embeddings in RAM.
3. **Streamed hashing** (1 MB chunks) — never load whole files.
4. **Bounded parallelism** via `TaskGroup` sized to `activeProcessorCount`; separate throttle for IO-bound (extract/hash) vs NE/GPU-bound (embed).
5. **LSH banding** keeps near-dup comparison near-linear instead of O(n²).
6. **Size-bucketing** before hashing eliminates most hash work.
7. **Incremental scans** skip unchanged files via signature.
8. **Lazy embeddings** — Stage 3 only on survivors, persisted and reused (keyed by `modelID`).
9. **SQLite tuning:** WAL mode, batched transactions (e.g., 1k upserts/tx), prepared statements, indices on `size_bytes`/`sha256`/`status`.
10. **UI:** virtualized `List`, throttled progress (~10–20 Hz), diffing/extraction off-main, thumbnails generated lazily + cached.

## 3. Memory management
- Autorelease-pool-style batch boundaries; explicit `nil`-ing of large buffers after use.
- Cap in-flight content size (config `fileTooLarge`).
- Embeddings as `float32` BLOBs, loaded on demand for comparison, not all at once.
- Stream results to UI; ViewModels hold IDs + lightweight models, fetch details on selection.

## 4. Benchmarking harness
- `Tools/CorpusGen` produces deterministic synthetic corpora at sizes 1k/10k/50k/200k with known duplicate/near-dup ratios.
- A `PerfHarness` test runs the cascade on a fixed corpus, asserts wall-clock + peak memory against budgets, and records a CSV for trend tracking.
- `OSSignposter` intervals around each stage → Instruments (Time Profiler, Allocations) for deep dives.
- CI runs the 10k perf test on every PR (smaller for time); 50k nightly. Regressions > 15% fail.

## 5. Thermal/battery awareness
- Stage 3 checks `ProcessInfo.thermalState`; back off concurrency when `.serious`/`.critical`.
- Deep scan warns it uses more battery; never runs automatically.

## Open Questions
- Optimal MinHash permutation count vs. accuracy/perf (128 default; tune on corpus).
- Embed batch size for Neural Engine efficiency (pending model pin).

## Future Improvements
- Memory-map large files for hashing.
- Persisted thumbnail cache across launches.

## Related Documents
- `ARCHITECTURE.md`, `TESTING.md`, `DATA_MODEL.md`.
