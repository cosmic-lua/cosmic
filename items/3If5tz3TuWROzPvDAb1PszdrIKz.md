## Capture

Vector search for cosmic: research recorded, decision deferred. No work is planned
from this item as written; refine it when vectors become wanted.

### The constraint that rules out most of the field

The Lua binary is pure C — `tool/lua/BUILD.mk` names no C++ package. Faiss (behind
the deprecated `sqlite-vss`), hnswlib (behind `vectorlite`) and usearch (behind
`sqlite-vector-rs`) are all C++ or Rust, and adopting one pulls `libcxx` (11 MB),
`libcxxabi` (6.3 MB) and `libunwind` (684 KB) into the shipped closure, plus
exception handling. That is against the standing decision to keep the fork's diff
against upstream small.

Both viable candidates are single-file portable C, and both install through the
`zipfile` precedent (`extensions.h` + an init call).

### sqlite-vec

Alex Garcia; Apache-2.0 / MIT; ~3.5–4k lines, self-contained (C stdlib plus
`sqlite3ext.h`); conditional AVX/NEON with scalar fallbacks, which suits a fat
binary built per architecture.

- float, int8 and **binary** vectors; metadata constraints applied *during* the KNN
  scan, so partitioned corpora search only their partition.
- **Brute force only in practice.** v0.1.9 (2026-03); IVF is "experimental, not
  enabled"; DiskANN is alpha, with a data-leak fix as recent as v0.1.10-alpha.4.
- Binary quantization is the practical scale lever: 1 bit per dimension is a **32×**
  storage reduction, and the documented pattern is a coarse KNN over the quantized
  column at ~20× the target k, then rescoring the shortlist against full float
  vectors.

### Vec1

Dan Kennedy (SQLite core developer), hosted on sqlite.org, announced 2026-02-26.
Single C file `vec1.c`, portable C, no external dependencies.

- **Real ANN**: IVFADC over OPQ, plus a newer RabitQ quantizer needing no training.
- L2 and cosine; **float32 only** (int8/float16 are roadmap).
- Requires a training step; a no-training mode with slower online writes is roadmap.
- v0.7. The project states no further features are required before 1.0, but that
  "testing is insufficient"; the February announcement said "not ready for real use
  yet".
- Distributed as a loadable extension. **Static linking is undocumented** — a single
  C file with an init function should link with `SQLITE_CORE` defined, exactly like
  `zipfile`, but that is an inference to verify.
- **License unconfirmed.** SQLite core is public domain; vec1's terms were not
  established. This is a hard gate before vendoring.

### What must be true before either is adopted

Extension loading is compiled out — `SQLITE_OMIT_LOAD_EXTENSION` is in the shared
flags, `load_extension` is not a function on the shipped binary, and `lsqlite3` does
not bind it. So any vector extension must be statically compiled and registered in
C; there is no runtime-loading path to fall back on.

### Open questions for whoever refines this

- Which workload: brute force is correct to roughly 10^5 vectors, and binary
  quantization plus metadata partitioning pushes that further; ANN is the answer
  only above that.
- One or both? They are strong in opposite places — sqlite-vec has the types,
  quantization, filtering and incremental writes; Vec1 has the ANN index and
  core-team provenance.
- Vec1's license and static-link story, both of which are gates rather than
  preferences.

### Also seen, and rejected for now

`sqlite-vector` (SQLite AI): C, quantized brute force, FLOAT32/16/BFLOAT16/INT8/UINT8,
benchmarks well ahead of sqlite-vec — but licensed "free for open-source projects",
a bespoke license, which is a problem for a distribution that ships other people's
code inside a fat binary.
