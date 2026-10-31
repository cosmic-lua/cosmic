# Vector search

Embedding search in cosmic: store a model's vectors, find the nearest
to a query under any filter, and blend that with keyword search, in one
binary with nothing else running. This plan is the outcome of a design
discussion ([#3218]) and the record of what is decided, what is built,
and what comes next. All five phases are in the tree; the guide that
ends them is [`doc/guides/semantic-search.md`]. Phase 6 adds packed rows.

## Goal and scope

A program can:

1. turn text into embeddings with a provider's API, through
   [`cosmic.http`];
2. store them in SQLite beside the rows they describe;
3. rank rows by distance to a query embedding, with a `WHERE` as the
   filter;
4. blend that ranking with FTS5's (hybrid search);
5. search a corpus of up to about a million vectors in milliseconds.

Out of scope here: a general array or matrix library (see
[scientific computing](#later-scientific-computing)), running an
embedding model inside cosmic, and approximate indexes until a real
corpus outgrows brute force.

## Decisions

- **pgvector's vocabulary.** The SQL functions take [pgvector]'s names
  (`cosine_distance`, `inner_product`, `binary_quantize`, ...) and its
  text form `'[1,2,3]'`, which is also a JSON array. It is the de facto
  standard for vector search in SQL, so tutorials and users already know
  it. SQLite has no custom operators, so there are functions only.
- **Storage types: f32 and bits in SQL; f16 and int8 in the corpus.** A
  vector is a blob of little-endian 32-bit floats, which is what an
  embedding API's base64 `float32` decodes to; a bit vector is a blob,
  one bit per dimension. The in-memory corpus can also hold f16 and int8
  ([phase 5](#phase-5-f16-and-int8-storage-built)); the SQL functions
  read f32 blobs alone.
- **Brute force with SQL filtering is the design** up to about a million
  vectors. A scan scores every row the `WHERE` keeps, so a filter never
  loses a match. That is the problem Redis vector sets' `FILTER-EF` and
  pgvector's iterative scans exist to work around in an approximate
  index. There is no index to maintain: inserts, deletes and
  transactions are SQLite's own.
- **Binary quantization with a rerank is the fast path:** a first pass
  over bit vectors in a table of their own, then the floats of the best
  few hundred.
- **The functions are innocuous.** They are pure arithmetic on their
  arguments, so a database file's views, generated columns and
  expression indexes may call them. cosmic's other functions are
  direct-only. A hostile file's worst use of them is bounded: memory is
  at most the 16000-dimension limit and SQLite's length limit on a
  value, and the CPU they spend is no new risk, since plain SQL in the
  same file (a recursive CTE, a cross join) can already burn CPU
  without end. Pure functions are what `SQLITE_INNOCUOUS` is for;
  direct-only is for functions with effects.
- **Identical results across targets are not required** for floating
  point. A kernel may sum in whatever order its target's vectors make
  fastest. The same core gives the same answer on every run: no threads.
  The one runtime choice is the int8 dot product, which uses VNNI where
  the CPU has it: its sums are exact integers, so no choice changes an
  answer.
- **No C++ and nothing copyleft in the core.** That rules out USearch,
  hnswlib and FAISS (C++), Redis 8's vector sets (RSALv2, SSPLv1 or
  AGPLv3) and GSL (GPL).

## Measurements

Phase 1's functions, over 100k rows of 768 dimensions in memory, on a
4-core Xeon at 2.1 GHz, best of five runs:

- exact `inner_product` over every row: 91 ms (`cosine_distance`:
  120 ms);
- the same with a 10% `WHERE tenant = ?`: 28 ms;
- a scan that calls no function at all: 77 ms;
- `hamming_distance` over bits stored in the same row as the floats:
  44 ms;
- bits in a table of their own, a first pass of 200 and a rerank by the
  floats: 10 ms.

Reading the rows costs more than the arithmetic. A 768-dimension vector
is 3 KB, about a whole 4096-byte page, so a scan reads a page per row,
and reading any other column of that row, bits stored beside the floats
included, costs the same. Bits in a table of their own pack about 40
rows to a page. Two things follow:

- the guide puts bit vectors in a table of their own;
- phase 2's in-memory corpus, which holds the floats contiguously and
  reads them once, is where the next tenfold comes from;
- [phase 6](#phase-6-packed-rows-built) packs many vectors to a row, so
  the scan itself reads a row for dozens.

## Phase 1: SQL functions (built)

[`core/vector.c`] registers on every SQLite handle:

- conversions: `vector(X)`, `vector_text(X)`, `vector_dims(X)`;
- distances: `l2_distance(A, B)`, `inner_product(A, B)`,
  `cosine_distance(A, B)` (NULL for a vector of zeros, so a search
  orders `NULLS LAST`) and `l1_distance(A, B)`;
- transforms: `l2_normalize(X)`, and `subvector(X, S, N)` for the head
  of a Matryoshka embedding;
- bit vectors: `binary_quantize(X)`, `hamming_distance(A, B)` and
  `jaccard_distance(A, B)`.

They are documented in [`doc/guides/sql.md`], with
`Example.vector_search` in [`cosmic/sqlite_example.tl`], and tested in
[`cosmic/vector_sql_test.tl`]. That test includes a filtered search, a
binary first pass with a rerank, and hybrid ranking by reciprocal rank
fusion over toy word-hash embeddings. [`cosmic/vector_fuzz_test.tl`]
holds the text a vector is read from, and every function over arbitrary
arguments, to references written in Teal.

## Phase 2: `cosmic.vector`, an in-memory corpus (built)

For a corpus searched many times: load the vectors once, contiguously,
and search them with no per-row SQLite overhead.

The module is [`cosmic/vector.tl`] over a raw module,
[`cosmic.internal.vector`] (declared in
[`cosmic/internal/vector.d.tl`], implemented in C beside the SQL
functions in [`core/vector.c`]). It follows the pattern of
[`cosmic.hash`] over [`cosmic.internal.hash`].

```text
local Vector = require("cosmic.vector")

-- A vector is a string of little-endian f32: what the SQL functions
-- store and read.
Vector.pack(numbers: {number}): string
Vector.unpack(v: string): {number}
Vector.from_json(text: string): string?, string   -- "[0.1, 0.2]" to packed
Vector.normalize(v: string): string

-- A corpus: n vectors of d dimensions in one buffer, each with an
-- integer id (a rowid). Built from (id, blob) pairs, or a query
-- answering them.
Vector.corpus(dims: integer): Vector.Corpus
corpus:add(id: integer, v: string)                -- raises on a wrong length
Vector.load(db: Sqlite.Handle, sql: string, values?): Vector.Corpus?, string
corpus:count(): integer

-- The k nearest: a record, never a tuple.
record Vector.Hits
  ids: {integer}
  scores: {number}   -- cosine similarity or inner product, best first
end
corpus:search(query: string, k: integer, opts?: Vector.SearchOptions): Vector.Hits?, string
record Vector.SearchOptions
  metric?: "inner_product" | "cosine" | "l2"      -- inner_product by default
  candidates?: integer   -- a binary first pass of this many, then a rerank
  allow?: {integer}      -- only these ids (a filter computed in SQL)
end
```

Details:

- **The corpus holds its own bit vectors** once one search asks for
  `candidates`, built once and kept.
- **`search` keeps a bounded heap of the best k.** It never sorts the
  whole corpus, and a tie goes to the lower id, so results are stable.
- **`allow` is a filter from SQL:** `SELECT id FROM chunks WHERE ...`.
  It is a set of ids to test against, not a second scan of the table.
- **Shape errors raise,** such as a wrong vector length or `k < 1`, as
  argument-shape errors do across the tree. `load` answers `nil, why`
  for a failed query or a row whose blob is not a vector.
- **Memory** is allocated through Lua, so the garbage collector sees
  its size: each buffer is a userdata held in a user value of the
  corpus (see the status below).
- **Long calls can be cancelled.** `search` and `kmeans` ask
  [`cosmic_signal_caught`] every few hundred rows (and `kmeans` once per
  centroid and iteration), as core/http.c and core/socket.c do in their
  waits. Inside a [`Signal.guard`], a pending SIGINT or
  SIGTERM answers `nil, "interrupted"` and leaves the corpus as it was;
  the signal is not taken. That is the tree's convention for an
  interrupted operation, which core/http.c and core/socket.c follow,
  and honest returns (doc/design.md) make the result `Vector.Hits?,
  string` and `{string}?, string`. An earlier draft raised instead,
  because a search has no partial answer; the user decided on the
  convention over that. Out of memory and argument-shape errors still
  raise.
- **Tests:**
  - agreement with the SQL functions on the same data;
  - the top-k order on ties;
  - `candidates` recalling the exact top-k on clustered data;
  - `allow`;
  - the refusals;
  - an example in [`cosmic/vector_example.tl`].
- **Target:** under 15 ms for 100k × 768 exact, and under 3 ms with a
  binary first pass. Measure both and state the numbers in the PR.

**Status:** built. The corpus's buffers (vectors, inverse lengths, ids
and bit vectors) are Lua userdata held in the corpus's user values, so
the garbage collector counts every byte, the checked core refuses them
like any Lua allocation ([`core/allocation_test.tl`] walks creation,
growth past the first capacity, a search with `candidates` and
`allow`, `kmeans` and `nearest_n`, and that a refused allocation leaves the corpus as it was), and
nothing is left on the C heap. The price is that growing allocates the
larger buffer beside the old one, which lingers until collected, where
`realloc` could extend in place: a corpus can need up to three times
what it holds while it grows. A pending signal in a [`Signal.guard`]
makes `search` and `kmeans` answer `nil, "interrupted"` (see the decision above;
tested in [`cosmic/vector_test.tl`]). [`cosmic/vector_fuzz_test.tl`]
holds `pack`, `unpack`, `normalize`, `from_json` and the corpus's
`search` and refusals to references written in Teal. Measured on
100k × 768 on the development VM: exact inner product 52 ms, with
`candidates = 200` 2.6 ms; recall@10 was 10/10 on clustered synthetic
data. Earlier measurements: cosine 66 ms, L2 61 ms, 2.5 ms cosine with
candidates. The 15 ms exact target is missed: the scan is
bandwidth-bound, at about 5.4 GB/s on the test VM.

## Phase 3: IVF over a cluster column (built)

The approximate step for when brute force runs out, with no new storage.

**Status:** built, in [`core/vector.c`] and [`cosmic/vector.tl`]. `Vector.kmeans(corpus, k, { seed?, iterations? })`
is spherical k-means in C over the corpus buffer (vectors are scaled to
length 1, centroids renormalized each step, so similarity is the inner
product; k-means++ seeding from a splitmix64 stream of `seed`, default 1,
so a run replays; up to `iterations`, default 20, stopping when no
assignment changes; an empty cluster is refilled with the worst-served
vector). It raises on k under 1 or over the corpus count, on iterations
under 1, and on a corpus of zero vectors alone; a zero vector is never
a seed and counts toward no cluster. `nearest` refuses a query or
centroid holding a non-finite number. Also
`Vector.nearest(centroids, v)` (1-based index) and
`Vector.nearest_n(centroids, v, n)` (the probes, nearest first), and
[`cosmic/vector_ivf_test.tl`] and `Example.ivf` in
[`cosmic/vector_example.tl`] show the SQL pattern with
`cluster IN carray(?2)`. No port of pgvector's code was made. Measured:
on 20 well-separated clusters of 100 points in 64 dimensions, recall@10
against exact search is 0.96 with 1 probe and 1.0 with 3 probes;
`kmeans` of 100k x 768 with k = 100 takes about 4 s per iteration on
the development host. A `kmeans` of that size can be cancelled within
one block of rows (or one centroid pass while seeding), not only at
the end of an iteration: under a [`Signal.guard`] that has caught a
signal, `kmeans` answers `nil, "interrupted"` and leaves the corpus as it
was (tested in [`cosmic/vector_test.tl`]; [`cosmic/vector_fuzz_test.tl`]
holds `nearest_n` to a reference and the `kmeans` refusals).

The scheme: k-means picks centroids; each row stores the id of its
nearest centroid in an integer column with an ordinary index; a query
scores only the rows of the few centroids nearest to it.

```text
-- Lloyd's k-means with k-means++ seeding, from an inline splitmix64
-- stream of opts.seed so a run replays. Answers k packed centroids.
-- opts is { seed?: integer, iterations?: integer }.
Vector.kmeans(corpus: Vector.Corpus, k: integer, opts?): {string}?, string
Vector.nearest(centroids: {string}, v: string): integer  -- 1-based
Vector.nearest_n(centroids: {string}, v: string, n: integer): {integer}
```

```text
CREATE TABLE chunks (id INTEGER PRIMARY KEY, cluster INTEGER, embedding BLOB);
CREATE INDEX chunks_cluster ON chunks (cluster);

SELECT id FROM chunks
WHERE cluster IN (SELECT value FROM carray(?2)) AND tenant = ?3
ORDER BY inner_product(embedding, ?1) DESC LIMIT 10;
```

Inserts assign the nearest centroid, deletes are plain deletes, and
filters still apply. Recall drifts as the data does, so k-means is rerun
now and then; the guide says how to measure when.

pgvector's `ivfkmeans.c` is a clean reference: its k-means is separable
from the Postgres code around it. It is under the PostgreSQL License, a
permissive one, so a port carries its notice in a bill-of-materials
record.

## Phase 4: the guide, `doc/guides/semantic-search.md` (built)

End to end, every example run by `cosmic test` or saying why not (one
that calls a provider needs a key and the network):

- **Embeddings from an API:** an OpenAI-compatible `/v1/embeddings` call
  with [`cosmic.http`] and [`cosmic.json`]. `encoding_format: "base64"`
  is decoded with [`cosmic.codec`] straight into a stored blob. Record
  the model name and dimensions, so vectors from two models are never
  compared.
- **Chunking** text into passages, with their offsets kept.
- **The schema:** chunks, their FTS5 table, and the bits table.
- **A filtered search, the binary first pass, hybrid search** with
  reciprocal rank fusion, and "more like this" via a subquery for a
  stored row's embedding.
- **The in-memory corpus** for a hot path, and IVF for a large corpus.
- **Measuring recall** of a fast path against exact search on the
  caller's own data.

**Status:** built, as [`doc/guides/semantic-search.md`]. Every example
is compiled and, but for the provider call, run offline by `cosmic test`
over a toy word-hash embedding.

## Phase 5: f16 and int8 storage (built)

`Vector.corpus(dims, { storage = "f16" | "int8" })` (and a fourth
argument to [`Vector.load`]) holds the corpus in half the memory or a
quarter, and scans faster. `add` still takes a packed f32 vector and
converts it; a query stays f32; every search option behaves as for f32.

- **f16** rounds to nearest, ties to even. A number of 65520 or more in
  magnitude would round to infinity: `add` raises rather than saturate,
  as pgvector's `halfvec` raises "out of range for type halfvec" on input.
  Scores sum the widened halves against the f32 query in the f32 kernels'
  eight lanes (`vcvtph2ps` on x86-64-v3, `fcvtl` on Armv8.2-A).
- **int8** is Redis vector sets' Q8: `scale = max|x| / 127`,
  `q = round(x / scale)` (ties to even), the scale stored beside the
  codes (with their sum and the sum of their squares). The query is
  quantized once per search. A score is the exact int32 dot product of
  the codes times both scales. `cosine` multiplies by the stored inverse
  lengths of the dequantized vectors, so it is the cosine of what is
  stored. `l2` uses `|a|^2 + |b|^2 - 2 a.b` over the dequantized vectors,
  summed in double and clamped at zero, so a vector's distance to itself
  is exactly 0. A vector, or a query, under 1.4e-36 in magnitude has no
  direction and is held as zeros.
- **Bit vectors** for `candidates` are made from the f32 vector in `add`
  for f16 and int8, since the f32 numbers are gone later: the first pass
  keeps the rows it would keep in an f32 corpus. They cost `dims / 8`
  bytes a row from the start. An f32 corpus still makes them on the
  first search that asks.
- **[`Vector.kmeans`]** works on every storage by widening each row into a
  scratch buffer; [`Vector.nearest`] takes f32 centroids and is unchanged.
- **Kernels** are plain loops in [`core/vector.c`], with the f16 lanes
  written as vector types (the compiler shuffles the array form). On
  x86-64-v3 the int8 sum is `vpmovsxbw` and `vpmaddwd`; on Armv8.2-A it
  is `sdot`.
- **VNNI.** Where the CPU has AVX-512 VNNI (with the 256-bit forms of
  AVX-512 VL) or AVX-VNNI, a runtime-selected kernel (found with `cpuid`
  and `xgetbv`; `__builtin_cpu_supports` does not link in the static
  musl cores) multiplies 32 unsigned by 32 signed bytes per
  instruction. A signed product is `sum(row * (query + 128)) - 128 *
  sum(row)`, so each int8 row keeps the sum of its codes. A 512-bit form
  measured no faster than the 256-bit one: the scan is bound by memory.
  On 100,000 x 768 the exact int8 inner product takes 12 to 18 ms
  portable and 4 to 8 ms with either VNNI kernel (a shared VM: repeated
  rounds, and the order of the kernels, move each by a few ms; the
  256-bit AVX-512 VNNI form was never slower than AVX-VNNI). A 512-bit
  form took 7 to 8 ms and was dropped. Tests select each kernel through
  [`testing.vector_kernel`] ([`cosmic.internal.testing`]) and compare
  them to the bit.

**Status:** built. Measured on 100,000 x 768 clustered vectors on the
development VM (L3 cache 260 MB, so the smaller corpora fit it), best
of five, 20 queries: f32 71 ms exact, 1.6 ms with `candidates = 200`;
f16 20 ms, 1.4 ms, top-10 overlap with f32 0.99 to 1.0; int8 4 to 8 ms
(12 to 18 ms portable), 1.4 ms, overlap 0.975 to 0.98. Held per vector: 4,138,
2,155 and 1,159 bytes. [`cosmic/vector_storage_test.tl`] holds the
behavior; [`cosmic/vector_fuzz_test.tl`] holds the search to a reference
over each storage's stored numbers; [`core/allocation_test.tl`] walks
the new allocations.

## Phase 6: packed rows (built)

Many vectors to a SQLite row, so a search straight from the database has
no load step and costs a few times the in-memory scan instead of a
dozen, and a corpus fills from the rows in a fraction of [`Vector.load`]'s
time. It attacks the problem the measurements above state: a scan pays
SQLite's per-row cost, and for a 3 KB vector that is a page a row.

- **`vector_block(id, vector [, storage])`** is an aggregate: the rows
  of a `GROUP BY` as one blob, a block, in `'f32'`, `'f16'` or `'int8'`.
  A block is a corpus serialized (the ids, the inverse lengths, the int8
  scales, the vectors, each section 8-aligned, behind a 16-byte header
  that holds the storage, dimensions and count), so the corpus's own
  buffers, quantizer and kernels are reused and nothing is written twice.
  No pgvector function does this, so the names are `vector_`-prefixed
  after the module they belong to. The layout is in
  [`doc/guides/sql.md`] and is checked exactly: a length that does not
  follow from the header, a header the writer does not write, and a
  length or scale that is not a number are each refused by name.
- **`vector_block_search(block, query, k [, metric])`** is a
  table-valued function joined to the table of blocks. It answers each
  block's k nearest as `(id, distance)`, so `ORDER BY distance LIMIT k`
  is the global answer, and a `WHERE` on the block table drops whole
  blocks. The distance is lower for nearer rows (pgvector's `<#>` for the
  inner product), and the scores are the corpus's, so the answers agree
  with a corpus in the same storage to the bit, but for a cosine that
  rounds past 1, which the distance clamps and the ranking follows. Like the other vector
  functions it is innocuous. A statement it scans ends with the error
  `interrupted` once a [`Signal.guard`] has caught a signal, within a few
  hundred vectors; the other SQL functions do not look, since one row's
  arithmetic is short, but a block's is not.
- **`Vector.load_blocks(db, sql, values?, opts?)`** and
  **`corpus:add_block(block)`** copy a block into a corpus: the buffers
  whole when the storage agrees, converted row by row when not. The bit
  vectors of a quantized corpus are made from its stored numbers, since a
  block has no f32.
- **Maintenance** is the guide's: the blocks are a copy that can be made
  again from the table of record, an update or a delete remakes the one
  block of the changed id range, and the rows not yet packed are searched
  with the per-row functions in a `UNION ALL`. There is no incremental
  index.
- **Not done**, each a `TODO:` in [`core/vector.c`]: `candidates` has
  no packed form (a block scan reads every vector it holds), and the
  query is read and, for int8, quantized again for every block (keeping
  the prepared query between blocks measured about 5%, within the noise
  of the VM).

**Status:** built, with the measurements below from 100,000 x 768
clustered vectors on the development VM, in memory (a warm page cache),
best of five. The step that decided to build it measured first. A block
a read of which SQLite copies out of an overflow chain costs most of a
scan: the copy of 300 MB of f32 alone takes 45 ms, so f32 blocks cannot
beat the per-row scan, and f16 and int8 are what packing is for.

| storage | block, 4 KB / 64 KB pages | per-row SQL | packed SQL | corpus | `load` | `load_blocks` |
| ------- | ------------------------- | ----------- | ---------- | ------ | ------ | ------------- |
| f32     | 8 / 16 vectors            | 87 ms       | 93 / 75 ms | 72 ms  | 3.3 s  | 0.75 s        |
| f16     | 16 / 32 vectors           | -           | 46 / 34 ms | 21 ms  | 1.4 s  | 0.32 s        |
| int8    | 32 / 64 vectors           | -           | 26 / 19 ms | 9 ms   | 1.2 s  | 0.17 s        |

Per-row SQL is `ORDER BY inner_product(...) DESC LIMIT 10` (77 ms on
64 KB pages; `cosine_distance` 122 ms). A block over about 30 KB in 4 KB
pages scanned two to three times slower than one of 12 to 25 KB: SQLite
allocates a fresh buffer for each value on overflow pages, while a value
that fits its page is copied into a buffer the statement reuses, which
is why 64 KB pages suit blocks of 50 KB. The packed scan is 3.3 to 4
times the per-row scan for int8, 1.9 to 2.3 for f16 and 1 for f32.
[`cosmic/vector_block_test.tl`] holds the behavior,
[`cosmic/vector_fuzz_test.tl`] holds the search over blocks to a corpus
built row by row and hostile blocks to a read inside bounds, and
[`core/allocation_test.tl`] walks the allocations of the aggregate, the
function and `add_block`.

## Later

Each waits on a caller who needs it:

- **pgvector's `avg(vector)` and `sum(vector)` aggregates** (a TODO in
  [`core/vector.c`]).
- **HNSW in C**, if IVF's recall is not enough on a real corpus.
  pgvector's `hnswutils.c` and `hnswvacuum.c` are the reference for the
  algorithm and for repairing the graph after deletes.
- **sqlite-vec**, revisited at its 1.0. It is MIT or Apache-2.0, pure C,
  with DiskANN and IVF indexes, but alpha and still breaking its format.
- **Memory-mapped corpora** for ones larger than RAM.
- **Random projection** to fewer dimensions; truncation already works
  through `subvector`.
- **An embedding model inside cosmic,** such as MiniLM from safetensors,
  with a tokenizer and about ten kernels. It is the largest item here:
  search with no API at all.

## Later: scientific computing

A separate track, pulled by its own callers. From the same discussion:

- **`cosmic.array` would be vectors and matrices in f64,** not an
  N-dimensional array of many dtypes: much simpler broadcasting, and
  types the checker can tell apart.
- **Vendored C:**
  - pocketfft's C version (BSD-3, one file) for FFT;
  - the f2c-translated LAPACK that OpenBLAS ships under
    `lapack-netlib/SRC/` (BSD-3), trimmed by PIN globs to the routines
    used, with our own BLAS kernels under it;
  - in a later phase, a Cephes subset (scipy's BSD-3 copy) for
    distribution functions, cminpack and liblbfgs for optimization.
- **Platform libm,** since identical results across targets are not
  required.
- **Raising the x86_64 core's baseline to x86-64-v3** (AVX2, FMA) is its
  own change: [`build.zig`]'s target list and its baseline check, and a
  CPU check in the launcher.
- **Rejected:**
  - SLEEF (not bit-exact by default, and a build that generates headers);
  - SimSIMD (it picks kernels per CPU at runtime);
  - OpenBLAS's and BLIS's own kernels (size, and a configure step);
  - NLopt as a whole (LGPL).

[#3218]: https://github.com/cosmic-lua/cosmic/pull/3218
[pgvector]: https://github.com/pgvector/pgvector
[`build.zig`]: ../../build.zig
[`core/vector.c`]: ../../core/vector.c
[`cosmic_signal_caught`]: ../../core/process.h
[`cosmic.codec`]: ../../cosmic/codec.tl
[`cosmic.hash`]: ../../cosmic/hash.tl
[`cosmic.http`]: ../../cosmic/http/init.tl
[`cosmic.json`]: ../../cosmic/json.tl
[`cosmic/sqlite_example.tl`]: ../../cosmic/sqlite_example.tl
[`cosmic/vector_fuzz_test.tl`]: ../../cosmic/vector_fuzz_test.tl
[`cosmic/vector_block_test.tl`]: ../../cosmic/vector_block_test.tl
[`cosmic/vector_ivf_test.tl`]: ../../cosmic/vector_ivf_test.tl
[`cosmic/vector_sql_test.tl`]: ../../cosmic/vector_sql_test.tl
[`cosmic/vector_test.tl`]: ../../cosmic/vector_test.tl
[`cosmic/vector_storage_test.tl`]: ../../cosmic/vector_storage_test.tl
[`cosmic/vector_example.tl`]: ../../cosmic/vector_example.tl
[`cosmic/vector.tl`]: ../../cosmic/vector.tl
[`cosmic/internal/vector.d.tl`]: ../../cosmic/internal/vector.d.tl
[`core/allocation_test.tl`]: ../../core/allocation_test.tl
[`doc/guides/sql.md`]: ../guides/sql.md
[`doc/guides/semantic-search.md`]: ../guides/semantic-search.md

[`cosmic.internal.hash`]: ../../cosmic/internal/hash.d.tl
[`cosmic.internal.testing`]: ../../cosmic/internal/testing.d.tl
[`cosmic.internal.vector`]: ../../cosmic/internal/vector.d.tl
[`Signal.guard`]: ../../cosmic/signal.tl
[`testing.vector_kernel`]: ../../cosmic/internal/testing.d.tl
[`Vector.kmeans`]: ../../cosmic/vector.tl
[`Vector.load`]: ../../cosmic/vector.tl
[`Vector.nearest`]: ../../cosmic/vector.tl
