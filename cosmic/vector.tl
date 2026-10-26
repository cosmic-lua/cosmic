--- Vectors in memory: packing them for the SQL functions of
--- [`cosmic.sqlite`], and a corpus searched for the nearest of many.
---
--- A vector is a string of little-endian 32-bit floats, which is what the
--- SQL vector functions store and read. A [`Vector.Corpus`] holds many in
--- one buffer, each with an integer id (a rowid), and answers the k
--- nearest to a query without a SQLite row in the way.
---
---     local corpus = Vector.corpus(3)
---     corpus:add(1, Vector.pack({ 1, 0, 0 }))
---     corpus:add(2, Vector.pack({ 0, 1, 0 }))
---     local hits = corpus:search(Vector.pack({ 0.9, 0.1, 0 }), 1)
---     -- hits.ids[1] == 1

local Sqlite = require("cosmic.sqlite")

-- The raw module behind every function here lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why this
-- indirection exists.
local type raw_vector = require("cosmic.internal.vector")

local extra: any = select(2, ...)
local raw: raw_vector
if type(extra) == "table" then
  raw = extra as raw_vector
else
  raw = require("cosmic.internal.vector")
end

local record Vector
  --- The k nearest, best first: ids and scores side by side. A score is
  --- the inner product or cosine similarity (higher is nearer) or, for
  --- `l2`, the distance (lower is nearer).
  record Hits
    --- The ids of the rows, best first.
    ids: {integer}
    --- The score of each id, in the same order.
    scores: {number}
  end

  --- How a row is scored against the query.
  enum Metric
    "inner_product"
    "cosine"
    "l2"
  end

  record SearchOptions
    --- The score to rank by; `inner_product` by default. On vectors
    --- normalized to length 1, `inner_product` and `cosine` rank alike
    --- and the first is cheaper. Under `cosine` a zero vector, in the
    --- corpus or as the query, has no direction (SQL's `cosine_distance`
    --- of one is NULL): such rows rank after every other row, with the
    --- score `-math.huge`, and come back only when `k` outruns the rest.
    metric?: Vector.Metric
    --- A binary first pass: keep this many rows nearest to the query by
    --- the sign bits of their dimensions, then score only those exactly.
    --- Faster, and approximate: it can miss a true neighbor. The corpus
    --- builds its bit vectors on the first search that asks.
    candidates?: integer
    --- Only these ids, such as the answer of `SELECT id FROM chunks WHERE
    --- ...`.
    allow?: {integer}
  end

  --- n vectors of one dimension count, each with an id.
  record Corpus
    --- The dimension count of every vector in the corpus.
    dims: integer
    --- The core's buffer behind the corpus; not for callers.
    handle: raw_vector.Corpus
    --- `corpus:add(id, v)`: see [`Vector.corpus`].
    add: function(Corpus, id: integer, v: string)
    --- `corpus:count()`: how many vectors the corpus holds.
    count: function(Corpus): integer
    --- `corpus:search(query, k, opts)`: the `k` nearest, as [`Vector.Hits`].
    search: function(Corpus, query: string, k: integer, opts?: SearchOptions): Hits
  end

  record KmeansOptions
    --- Seeds the choice of the first centroids; the same seed on the same
    --- corpus answers the same centroids. 1 by default.
    seed?: integer
    --- The most Lloyd iterations; it stops sooner when no vector changes
    --- cluster. 20 by default.
    iterations?: integer
  end
end

--- A vector from its numbers, as the SQL functions store one. Raises on
--- an entry that is not a finite number or is too large for a 32-bit
--- float, and on none or more than 16000 of them.
function Vector.pack(numbers: {number}): string
  return raw.pack(numbers)
end

--- The numbers of a vector, as floats widened to Lua numbers.
function Vector.unpack(v: string): {number}
  return raw.unpack(v)
end

--- The vector a JSON array of numbers spells, `[0.1, 0.2]`, or `nil` and
--- why it is not one.
function Vector.from_json(text: string): string?, string
  return raw.from_json(text)
end

--- The vector scaled to length 1; all zeros stays all zeros. Normalize
--- once, where a vector is stored, and the inner product is the cosine.
function Vector.normalize(v: string): string
  return raw.normalize(v)
end

--- Adds a vector under an id. Raises on a vector of another length
--- than the corpus's dimensions, or with a value that is not finite.
--- A second add of an id makes a second row: ids are not unique to the
--- corpus.
local function corpus_add(self: Vector.Corpus, id: integer, v: string)
  self.handle:add(id, v)
end

--- How many vectors the corpus holds.
local function corpus_count(self: Vector.Corpus): integer
  return self.handle:count()
end

--- The `k` nearest vectors to `query`, best first. Rows of equal score
--- are ordered by the lower id, so an answer is stable. Raises on a query
--- of the wrong length, or `k` under 1; a corpus with fewer than `k`
--- rows answers them all.
local function corpus_search(self: Vector.Corpus, query: string, k: integer,
    opts?: Vector.SearchOptions): Vector.Hits
  local o = opts or {}
  local metric: string = o.metric or "inner_product"
  local ids, scores = self.handle:search(query, k, metric, o.candidates, o.allow)
  return { ids = ids, scores = scores }
end

--- `k` centroids for IVF search: spherical k-means (k-means++ seeding,
--- then Lloyd iterations on vectors scaled to length 1, centroids
--- renormalized each step, so similarity is the inner product). Answers
--- k packed centroids. Raises on `k` under 1 or over the corpus's count.
--- Cost is count x k x dims per iteration, in C.
function Vector.kmeans(corpus: Vector.Corpus, k: integer, opts?: Vector.KmeansOptions): {string}
  local o = opts or {}
  return corpus.handle:kmeans(k, o.seed or 1, o.iterations or 20)
end

--- The 1-based index of the centroid nearest `v` by inner product (the
--- cluster to store a row under). Ties go to the lower index.
function Vector.nearest(centroids: {string}, v: string): integer
  return assert(raw.nearest(centroids, v, 1)[1])
end

--- The indexes of the `n` nearest centroids, nearest first: the probes of
--- a query. Fewer when there are fewer centroids.
function Vector.nearest_n(centroids: {string}, v: string, n: integer): {integer}
  return raw.nearest(centroids, v, n)
end

--- An empty corpus of vectors with `dims` dimensions, from 1 to 16000.
function Vector.corpus(dims: integer): Vector.Corpus
  return { dims = dims, handle = raw.corpus(dims), add = corpus_add, count = corpus_count,
    search = corpus_search }
end

local function add_row(held: Vector.Corpus?, id: integer, blob: string): Vector.Corpus?, string
  local at = "row " .. tostring(id) .. ": "
  local target: Vector.Corpus
  if held == nil then
    if #blob == 0 or #blob % 4 ~= 0 or #blob // 4 > 16000 then
      return nil, at .. "not a vector blob"
    end
    target = Vector.corpus(#blob // 4)
  else
    target = held
  end
  local added, err = pcall(corpus_add, target, id, blob)
  if not added then
    return nil, at .. tostring(err)
  end
  return target, ""
end

--- A corpus from the rows a query answers, each an integer id and a
--- vector blob, in that order: `Vector.load(db, "SELECT id, embedding
--- FROM chunks")`. Answers `nil` and why when the query fails or a row
--- holds something else than a vector of the first row's length.
function Vector.load(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): Vector.Corpus?, string
  local q, why = Sqlite.query(db, sql, values)
  if not q then
    return nil, why
  end
  local corpus: Vector.Corpus? = nil
  local failure = ""
  for row in q:each() do
    if row:kind(1) ~= "integer" or row:kind(2) ~= "blob" then
      failure = "load wants an integer id and a vector blob in each row"
      break
    end
    local grown, trouble = add_row(corpus, row:integer(1), row:blob(2))
    if grown == nil then
      failure = trouble
      break
    end
    corpus = grown
  end
  if failure == "" then
    failure = q:failure()
  end
  q:close()
  if failure ~= "" then
    return nil, failure
  end
  if corpus == nil then
    return nil, "the query answered no rows, so there are no dimensions to read"
  end
  return corpus, ""
end

return Vector
