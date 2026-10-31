# semantic search

Search a pile of text by meaning: embed each passage with a model, store
the vectors in SQLite beside the text, and rank passages by distance to
the embedding of the question. This guide builds that end to end with
[`cosmic.sqlite`] and [`cosmic.vector`], from the provider's API call
to a measured fast path. The SQL functions it uses are listed in the
[SQL functions guide](sql.md#vector-search).

The examples run offline. A provider needs a key and the network, so a
toy embedding stands in for it: each word gets one of 64 dimensions and
a sign, both from its digest. Texts that share words point the same way. It knows
nothing about meaning, but everything after the call is the real thing.

## embeddings from an API

An OpenAI-compatible `/v1/embeddings` endpoint takes a model name and a
list of texts, and answers one embedding per text. Ask for
`encoding_format: "base64"`: the embedding then arrives as the base64 of
its little-endian 32-bit floats, which is the blob [`cosmic.vector`]
and the SQL functions store. [`cosmic.http`] sends the request,
[`cosmic.json`] writes and reads its JSON, and [`cosmic.codec`] decodes
the embedding straight into one, with no list of numbers in between.

A provider caps the number of texts in one request, so `embed_all` sends
them in batches. A server that ignores `encoding_format` answers float
arrays; the shape check then fails with its message instead of storing
garbage.

This example is compiled but not run, since it calls a provider, so the
request has not been tried against a live one. Check the field names
against the provider's documentation.

```teal
local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Shape = require("cosmic.shape")

local record Item
  index: integer
  embedding: string
end

local record Reply
  model: string
  data: {Item}
end

local REPLY <const>: Shape.Typed<Reply> = Shape.record_of("Reply")

local record Embedded
  --- One packed vector per input text, in input order.
  vectors: {string}
  --- The model that made them, as the provider reports it.
  model: string
  dims: integer
end

local function embed_texts(texts: {string}, model: string, key: string): Embedded?, string
  if #texts == 0 then
    return nil, "embeddings: no texts"
  end
  local body = assert(Json.encode({ model = model, input = texts, encoding_format = "base64" }))
  local reply, why = Http.request("POST", "https://api.openai.com/v1/embeddings", {
    headers = { ["Authorization"] = "Bearer " .. key, ["Content-Type"] = "application/json" },
    body = body,
  })
  if reply == nil then
    return nil, why
  end
  if reply.status ~= 200 then
    return nil, "embeddings: status " .. tostring(reply.status) .. ": " .. reply.body
  end
  local decoded, bad = Json.decode(reply.body)
  if decoded == nil then
    return nil, bad
  end
  local parsed, mismatch = Shape.into(decoded, REPLY.spec)
  if parsed == nil then
    return nil, "embeddings: " .. mismatch
  end
  if #parsed.data ~= #texts then
    return nil, "embeddings: asked for " .. tostring(#texts) .. " vectors, got " .. tostring(#parsed.data)
  end
  -- Each item carries the index of its text; the API may answer out of order.
  local vectors: mut {integer: string} = {}
  for _, item in ipairs(parsed.data) do
    local blob, trouble = Codec.unbase64(item.embedding)
    if blob == nil then
      return nil, trouble
    end
    vectors[item.index + 1] = blob
  end
  local ordered: mut {string} = {}
  for i = 1, #texts do
    local blob = vectors[i]
    if blob == nil then
      return nil, "embeddings: no vector for text " .. tostring(i)
    end
    ordered[#ordered + 1] = blob
  end
  return { vectors = ordered, model = parsed.model, dims = #assert(ordered[1]) // 4 }, ""
end

-- Sends the texts `batch` at a time, and joins the answers.
local function embed_all(texts: {string}, model: string, key: string, batch: integer): Embedded?, string
  if #texts == 0 then
    return nil, "embeddings: no texts"
  end
  local vectors: mut {string} = {}
  local reported, dims = "", 0
  for from = 1, #texts, batch do
    local part: mut {string} = {}
    for i = from, math.min(from + batch - 1, #texts) do
      part[#part + 1] = assert(texts[i])
    end
    local made, why = embed_texts(part, model, key)
    if made == nil then
      return nil, why
    end
    for _, blob in ipairs(made.vectors) do
      vectors[#vectors + 1] = blob
    end
    reported, dims = made.model, made.dims
  end
  return { vectors = vectors, model = reported, dims = dims }, ""
end

local key = Env.get("OPENAI_API_KEY")
if key ~= nil then
  local made = assert(embed_all({ "cats purr", "dogs bark" }, "text-embedding-3-small", key, 100))
  print(made.model, made.dims)
end
```

Keep the model name and the dimension count with the vectors. Two
models' embeddings are unrelated even when they have the same length, so
a distance between them is a number with no meaning. Distances between
vectors of different lengths are refused, but only the model column
stops the silent mistake. The schema below has one, and every search
filters on it.

Some models, such as OpenAI's `text-embedding-3` family, are trained so
that the first dimensions of an embedding stand alone. A shorter vector
for a smaller table comes from the client, `subvector(embedding, 1, 256)`
re-normalized, or from the server: the request's `dimensions` parameter
asks it to truncate. Either way, record the shortened length as that
model's dimensions.

## chunking

Embed passages, not whole files: a model sees a limited input, and an
embedding of a long text blurs its parts. This chunker joins paragraphs
(split at blank lines) up to a size limit. A passage keeps its
byte offsets into the source, so a hit can be shown in place. A single
paragraph longer than the limit stays whole; a program with such
paragraphs splits them at sentences.

```teal
local record Span
  --- 1-based byte offsets into the text, `stop` included.
  mut start: integer
  mut stop: integer
end

local function chunk(text: string, limit: integer): {Span}
  local paragraphs: mut {Span} = {}
  local pos = 1
  while pos <= #text do
    local gap_from, gap_to = text:find("\n%s*\n", pos)
    local stop = (gap_from or #text + 1) - 1
    if stop >= pos then
      paragraphs[#paragraphs + 1] = { start = pos, stop = stop }
    end
    pos = (gap_to or #text) + 1
  end
  local passages: mut {Span} = {}
  for _, paragraph in ipairs(paragraphs) do
    local last = passages[#passages]
    if last ~= nil and paragraph.stop - last.start + 1 <= limit then
      last.stop = paragraph.stop
    else
      passages[#passages + 1] = { start = paragraph.start, stop = paragraph.stop }
    end
  end
  return passages
end
```

Text with blank lines between paragraphs, cut at 40 bytes, comes out
as passages of one or two paragraphs:

```teal continue
local sample = "Cats purr.\n\nThey sleep in the sun.\n\nMars is a cold planet.\n\n\nThe sun is a star."
for _, p in ipairs(chunk(sample, 40)) do
  print(p.start, p.stop, (sample:sub(p.start, p.stop):gsub("\n", "/")))
end
```

## the schema

Four tables hold a corpus.

- `embedding_models` names each model once, with its dimensions.
- `chunks` holds a passage, where it came from (`doc`, `start`,
  `stop`), the model that embedded it and the embedding. A `NULL`
  embedding is a passage not yet embedded.
- `chunks_fts` is an FTS5 index of the text, for keyword search. It
  keeps no second copy of the text: `content='chunks'` reads it from
  the table.
- `chunk_bits` holds a bit vector of every embedding, in a table of
  its own. A 768-dimension embedding is 3 KB, about a whole page of the
  file, so a scan of `chunks` reads a page per row whichever column it
  asks for. A bit vector is 96 bytes, which packs about 40 rows to a
  page, so the first pass of a binary search never touches the floats.

Triggers keep the last two in step with `chunks`, so inserting a chunk
is one statement, and so is embedding a passage later or editing one.
The embedding is normalized as it is stored, which makes the
inner product the cosine, so either ranks the rows.

The toy embedding comes first, then the schema and a first corpus of
three documents.

```teal continue
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Vector = require("cosmic.vector")

local DIMS = 64

-- Stands in for embed_texts above. Each word lands on one dimension by
-- its digest, with a sign by its digest too.
local function embed(text: string): string
  local sums: mut {integer: number} = {}
  for word in text:lower():gmatch("%a+") do
    local digest = Hash.digest("sha256", word)
    local slot = assert(digest:byte(1)) % DIMS + 1
    local sign = if assert(digest:byte(2)) % 2 == 0 then 1 else -1 end
    sums[slot] = (sums[slot] or 0) + sign
  end
  local dims: mut {number} = {}
  for slot = 1, DIMS do
    dims[#dims + 1] = sums[slot] or 0
  end
  return Vector.pack(dims)
end

-- A database with the schema and one model registered; answers the model's id.
local function open_corpus(): Sqlite.Handle, integer
  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE embedding_models (
      id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, dims INTEGER NOT NULL);
    CREATE TABLE chunks (
      id INTEGER PRIMARY KEY,
      doc TEXT NOT NULL,
      start INTEGER NOT NULL,
      stop INTEGER NOT NULL,
      body TEXT NOT NULL,
      model INTEGER NOT NULL REFERENCES embedding_models,
      embedding BLOB);
    CREATE VIRTUAL TABLE chunks_fts USING fts5(body, content='chunks', content_rowid='id');
    CREATE TABLE chunk_bits (id INTEGER PRIMARY KEY, model INTEGER NOT NULL, bits BLOB NOT NULL);

    CREATE TRIGGER chunks_insert AFTER INSERT ON chunks BEGIN
      INSERT INTO chunks_fts (rowid, body) VALUES (new.id, new.body);
      INSERT INTO chunk_bits SELECT new.id, new.model, binary_quantize(new.embedding)
        WHERE new.embedding IS NOT NULL;
    END;
    CREATE TRIGGER chunks_update AFTER UPDATE ON chunks BEGIN
      INSERT INTO chunks_fts (chunks_fts, rowid, body) VALUES ('delete', old.id, old.body);
      INSERT INTO chunks_fts (rowid, body) VALUES (new.id, new.body);
      DELETE FROM chunk_bits WHERE id = old.id;
      INSERT INTO chunk_bits SELECT new.id, new.model, binary_quantize(new.embedding)
        WHERE new.embedding IS NOT NULL;
    END;
    CREATE TRIGGER chunks_delete AFTER DELETE ON chunks BEGIN
      INSERT INTO chunks_fts (chunks_fts, rowid, body) VALUES ('delete', old.id, old.body);
      DELETE FROM chunk_bits WHERE id = old.id;
    END;
  ]]))
  assert(Sqlite.run(db, "INSERT INTO embedding_models (name, dims) VALUES (?1, ?2)",
    { { text = "toy-hash-64" }, { integer = DIMS } }))
  return db, db:last_insert_rowid()
end

local function add_chunk(db: Sqlite.Handle, model: integer, doc: string, span: Span, body: string)
  assert(Sqlite.run(db, [[
    INSERT INTO chunks (doc, start, stop, body, model, embedding)
    VALUES (?1, ?2, ?3, ?4, ?5, l2_normalize(?6))
  ]], { { text = doc }, { integer = span.start }, { integer = span.stop }, { text = body },
        { integer = model }, { blob = embed(body) } }))
end

local function ids(db: Sqlite.Handle, sql: string, values: {Sqlite.Value}): {integer}
  local found = assert(Sqlite.map(db, sql, values, function(r: Sqlite.Row): integer
    return r:integer(1)
  end))
  return found
end

local db, model = open_corpus()
local record Document
  name: string
  text: string
end
local documents: {Document} = {
  { name = "pets", text = "Cats purr and sleep in the sun.\n\nDogs bark and fetch the ball.\n\n"
    .. "Cats and dogs can live together as pets." },
  { name = "space", text = "The sun is a star at the centre of the solar system.\n\n"
    .. "Mars is a cold planet in the solar system." },
  { name = "food", text = "Bake bread with flour water and yeast.\n\nSoup is hot water with vegetables." },
}
for _, d in ipairs(documents) do
  for _, span in ipairs(chunk(d.text, 60)) do
    add_chunk(db, model, d.name, span, d.text:sub(span.start, span.stop))
  end
end
print("chunks", ids(db, "SELECT count(*) FROM chunks", {})[1])
```

SQLite does not check the dimensions `embedding_models` records. Give
each search its model's id, as the queries below do. A program that
keeps vectors of two models in one table indexes `model`; one that
keeps many may use a table for each.

## queries

A search is an `ORDER BY` over the rows a `WHERE` keeps. Every row the
filter keeps is scored, so a filter never loses a match. Write
`NULLS LAST` after `cosine_distance`: SQLite sorts NULL first, and the
distance is NULL for a vector of zeros and for a chunk that has no
embedding yet.

```teal continue
local question: Sqlite.Value = { blob = embed("where do cats sleep") }

-- The nearest passages, optionally within one document.
local nearest = ids(db, [[
  SELECT id FROM chunks WHERE model = ?2
  ORDER BY cosine_distance(embedding, ?1) NULLS LAST LIMIT 2
]], { question, { integer = model } })
local in_space = ids(db, [[
  SELECT id FROM chunks WHERE model = ?2 AND doc = 'space'
  ORDER BY cosine_distance(embedding, ?1) NULLS LAST LIMIT 1
]], { { blob = embed("the solar system") }, { integer = model } })
print("nearest", table.concat(nearest, " "), "in space", table.concat(in_space, " "))
```

The binary first pass keeps the 200 chunks whose bit vectors are
nearest in Hamming distance, then ranks only those by their floats. The
stored vectors are normalized, so the inner product of a normalized
query ranks them as the cosine does. The pass is approximate: measure
its recall, as the last section shows. Measured once on a
4-core 2.1 GHz Xeon, with a synthetic corpus of 100,000 chunks of 768
dimensions (no benchmark in the tree repeats it), it took 10 ms, where ranking all the floats by inner product took 91 ms, and by
cosine 120 ms.

```teal continue
local by_bits = ids(db, [[
  SELECT c.id FROM (
    SELECT id FROM chunk_bits WHERE model = ?2
    ORDER BY hamming_distance(bits, binary_quantize(?1)) LIMIT 200
  ) b JOIN chunks c ON c.id = b.id
  ORDER BY inner_product(c.embedding, l2_normalize(?1)) DESC, c.id LIMIT 2
]], { question, { integer = model } })
print("by bits", table.concat(by_bits, " "))
```

The `chunks_update` trigger keeps `chunk_bits` right when a passage is
embedded after it was stored. This chunk starts with a `NULL` embedding,
so it has no bit vector, and the first pass cannot find it. One `UPDATE`
embeds it, and the trigger adds the bits:

```teal continue
local late: Sqlite.Value = { blob = embed("kittens purr in the sun") }
assert(Sqlite.run(db, "INSERT INTO chunks (doc, start, stop, body, model) VALUES (?1, 1, 23, ?2, ?3)",
  { { text = "late" }, { text = "Kittens purr in the sun" }, { integer = model } }))
local late_id = db:last_insert_rowid()
local function nearest_bits(): integer
  return ids(db, [[
    SELECT id FROM chunk_bits WHERE model = ?2
    ORDER BY hamming_distance(bits, binary_quantize(?1)) LIMIT 1
  ]], { late, { integer = model } })[1] or 0
end
local before = nearest_bits() == late_id
assert(Sqlite.run(db, "UPDATE chunks SET embedding = l2_normalize(?1) WHERE id = ?2",
  { late, { integer = late_id } }))
print("late", before, nearest_bits() == late_id)
```

Hybrid search blends meaning with keywords: a rare word or a name is
what keywords find, and an embedding blurs. Reciprocal rank fusion
needs no common scale. Each list gives a chunk `1 / (60 + rank)`, and
the chunk with the most in total wins, so one that is high in both lists
beats one that leads a single list. FTS5's `rank` orders its matches by
`bm25`, and the full-text index knows no models, so the keyword list
keeps only the rows of this one. A `LIMIT` over a window function keeps
rows in no guaranteed order, so each list sorts by its position before
it cuts.

```teal continue
local hybrid = ids(db, [[
  WITH
    semantic AS (
      SELECT id, row_number() OVER w AS pos FROM chunks
      WHERE model = ?3
      WINDOW w AS (ORDER BY cosine_distance(embedding, ?1) NULLS LAST)
      ORDER BY pos LIMIT 20),
    keyword AS (
      SELECT rowid AS id, row_number() OVER w AS pos FROM chunks_fts
      WHERE chunks_fts MATCH ?2
        AND rowid IN (SELECT id FROM chunks WHERE model = ?3)
      WINDOW w AS (ORDER BY rank)
      ORDER BY pos LIMIT 20)
  SELECT id FROM (
    SELECT id, 1.0 / (60 + pos) AS score FROM semantic
    UNION ALL
    SELECT id, 1.0 / (60 + pos) AS score FROM keyword)
  GROUP BY id ORDER BY sum(score) DESC LIMIT 3
]], { { blob = embed("the sun in the solar system") }, { text = "bread OR mars" }, { integer = model } })
print("hybrid", table.concat(hybrid, " "))
```

"More like this" needs no query embedding: a stored chunk's own
embedding is the query. The subquery runs once, not per row.

```teal continue
local like = ids(db, [[
  SELECT id FROM chunks
  WHERE id <> ?1 AND model = (SELECT model FROM chunks WHERE id = ?1)
  ORDER BY cosine_distance(embedding, (SELECT embedding FROM chunks WHERE id = ?1)) NULLS LAST
  LIMIT 2
]], { { integer = 1 } })
print("like 1", table.concat(like, " "))
```

## the corpus in memory

Scanning a table reads a page per row. For a corpus that is searched
many times, load it once with [`Vector.load`], which keeps every embedding
in one buffer, and search that. A search then scores contiguous floats
and keeps the best `k` in a small heap, with no SQLite in the loop. A tie
goes to the lower id, so an answer is stable.

[`Vector.load`] runs the query and reads each row as an id and a vector
blob. When the query answers no rows, `load` returns nil with a message,
because a corpus takes its dimensions from its first vector. The query
keeps `embedding IS NOT NULL` because a passage not yet embedded has no
blob, and `load` refuses a row without one rather than skip it.

On 100,000 chunks of 768 dimensions (a 300 MB buffer), on a 4-core
Xeon at 2.1 GHz, best of five:

- an exact search by inner product takes 57 ms, by cosine 66 ms. The
  same search in SQL took 91 ms and 120 ms. The scan is bound by memory
  bandwidth;
- with `candidates = 200` the corpus first picks that many by their
  sign bits, which it builds once and keeps, then scores only those:
  4.1 ms by inner product and 2.5 ms by cosine.

`search` ranks by inner product unless `metric` says `"cosine"` or
`"l2"`, so store normalized vectors, as above. `allow` takes the ids a
SQL `WHERE` chose, for the filters SQL is good at. The corpus is a
snapshot: it does not see later inserts or deletes, so add new chunks
with `corpus:add` and reload after deletes, or filter a stale one with
`allow`.

```teal continue
local corpus = assert(Vector.load(db,
  "SELECT id, embedding FROM chunks WHERE model = ?1 AND embedding IS NOT NULL",
  { { integer = model } }))
local in_pets = ids(db, "SELECT id FROM chunks WHERE doc = 'pets'", {})
local asked = Vector.normalize(embed("where do cats sleep"))
local exact = assert(corpus:search(asked, 2, { allow = in_pets }))
local quick = assert(corpus:search(asked, 2, { allow = in_pets, candidates = 5 }))
print("corpus", table.concat(exact.ids, " "), "candidates", table.concat(quick.ids, " "))
```

## smaller storage

A corpus holds its vectors as 32-bit floats unless `storage` says
otherwise, to [`Vector.load`] or [`Vector.corpus`]. `"f16"` keeps 16-bit
floats and `"int8"` keeps one signed byte per dimension with a scale per
vector. `corpus:add` converts the f32 vector it is given, and
the query stays f32. Every option of `search` works as before. A scan
reads fewer bytes, so it is faster.

On 100,000 chunks of 768 dimensions on the Xeon above, with clustered
synthetic vectors and 20 queries, best of five (the buffers double as a
corpus grows, so a corpus built by many adds holds up to twice its
rows' size, and these held 100,000 of 131,072):

| storage | held per vector | exact search, inner product | top-10 shared with f32 |
| ------- | --------------- | --------------------------- | ---------------------- |
| `"f32"` | 4,138 bytes     | 71 ms                       | all                    |
| `"f16"` | 2,155 bytes     | 20 ms                       | 99.5% to 100%          |
| `"int8"`| 1,159 bytes     | 4 to 8 ms (12 to 18 without VNNI) | 97.5% to 98%     |

The f16 and int8 corpora fit this processor's 260 MB cache and the f32
one does not, so part of their lead is the machine's.

Choose by what the corpus costs and what a missed neighbour costs:

- **`"f32"`** is exact. Keep it when the corpus is small, when the
  program ranks by a score it shows to the digit, or when its numbers
  are large (see f16).
- **`"f16"`** halves the memory and finds the same neighbours. A half
  has 11 significant bits, which an embedding rarely needs. It holds magnitudes up to 65504, and `add` raises on a
  number of 65520 or more instead of storing infinity, as pgvector's
  `halfvec` refuses it. Numbers under 2.9e-8 become zero. It is the usual
  choice for a corpus that is too big for f32.
- **`"int8"`** is a quarter of the memory and the fastest scan, and
  loses a few of the top 10. Each vector is stored as `round(x / scale)`
  with `scale = max|x| / 127`, so its error is under half a scale in each
  number, and the query is quantized the same way. Scores are then close
  to f32's but not equal (the cosine of a vector with itself is 1 to
  about six digits). Use it for a corpus that must fit in memory or for
  speed, and measure the recall on real queries (next sections). When a
  missed neighbour matters, ask it for several times the `k` and rank
  those rows again in SQL with `inner_product(embedding, ?1)` on the
  f32 blobs, which `WHERE id IN (...)` limits to a few rows.

A corpus of `"f16"` or `"int8"` makes the bit vectors of `candidates`
when a row is added, from the f32 vector, because it keeps no f32 vector
to make them from later. They take one bit per dimension (96 bytes at 768
dimensions) in every row, where an f32 corpus builds them on the first
search that asks. [`Vector.kmeans`] clusters a corpus of any storage.

```teal continue
local small = assert(Vector.load(db,
  "SELECT id, embedding FROM chunks WHERE model = ?1 AND embedding IS NOT NULL",
  { { integer = model } }, { storage = "int8" }))
local approx = assert(small:search(asked, 2, { allow = in_pets }))
print("int8", table.concat(approx.ids, " "), small.storage)
```

## packed rows

A scan of `chunks` reads a page per row, and [`Vector.load`] reads rows one
at a time, so a program pays seconds of load before its first search.
A packed row holds many vectors: `vector_block` packs the rows of a
group into one blob, a block, and `vector_block_search` answers the
nearest rows of each block, so a search straight from the database reads
a row for a few dozen vectors and the arithmetic is nearly all that is
left. [`Vector.load_blocks`] fills a corpus from the blocks, without
reading the vectors one by one. The [SQL functions guide](sql.md#packed-rows)
documents both and the layout of a block.

On 100,000 chunks of 768 dimensions on the Xeon above, in memory with a
warm page cache, best of five. Every packed number is for the block size
the next paragraphs recommend:

| storage | block size, 4 KB pages / 64 KB pages | per-row SQL scan | packed SQL scan | corpus search | [`Vector.load`] | [`Vector.load_blocks`] |
| ------- | ------------------------------------ | ---------------- | --------------- | ------------- | ------------- | -------------------- |
| `"f32"` | 8 / 16 vectors                       | 87 ms            | 93 ms / 75 ms   | 72 ms         | 3.3 s         | 0.75 s               |
| `"f16"` | 16 / 32 vectors                      | (f32 only)       | 46 ms / 34 ms   | 21 ms         | 1.4 s         | 0.32 s               |
| `"int8"`| 32 / 64 vectors                      | (f32 only)       | 26 ms / 19 ms   | 9 ms          | 1.2 s         | 0.17 s               |

The per-row scan is `ORDER BY inner_product(embedding, ?1) DESC LIMIT 10` on
4 KB pages (77 ms on 64 KB pages); `cosine_distance` takes 122 ms, and
`vector_block_search` the same time for either metric. [`Vector.load`] is from
the same f32 rows into a corpus of the storage in the row.

- The per-row SQL scan can only hold f32, so it is the baseline of every
  row. The SQL scan of packed `int8` is about 3.3 to 4 times faster
  than it, `f16` 1.9 to 2.3 times, and `f32` no faster: the scan
  is then bound by copying 300 MB out of the page cache, which packing
  does not shrink. Pack f16 or int8 for a search in SQL; pack f32 only
  to load it faster.
- The corpus is still the fastest search. Packed rows cost a copy of
  the blocks out of the page cache on top of the same arithmetic, and
  the corpus keeps its vectors where it can reach them.
- `load_blocks` is 4 to 7 times faster than `load` in every storage: it copies a block's buffers into the
  corpus whole where `load` converts and appends a vector at a time. A
  corpus from blocks makes the bit vectors of `candidates` from the
  numbers the blocks hold, so in an `int8` corpus its first pass can keep
  other rows than one `load` makes from the f32 vectors: a small positive
  number that its code rounds to 0 has a 0 bit.

A block is read into a buffer of its own before it is searched, and how
SQLite does that decides the size to pack:

- A value that fits in the page it is stored on is copied into a buffer
  the statement keeps and reuses, so an `int8` block of 64 vectors of 768
  dimensions (50 KB) in a database of 64 KB pages scans fastest.
  `PRAGMA page_size = 65536` before the first table, or in a database of
  its own, `ATTACH 'blocks.db' AS packed` then `PRAGMA packed.page_size =
  65536`, which leaves `chunks` in 4 KB pages.
- In 4 KB pages a block spans overflow pages and each read allocates a
  fresh buffer. Blocks of 12 to 25 KB scanned fastest there (16 to 32 `int8`
  vectors of 768 dimensions, 8 to 16 `f16`); at 50 KB a scan took twice
  as long.

Measured sizes are in the table. Use the largest block that stays within
the limit of its page size. A bigger block is not slower to search, but
a rebuild after a change writes it all again, and a smaller block lets
a `WHERE` on the block table drop more of the corpus.

```teal continue
-- Four passages to a block by id range, so a change to one passage
-- touches one block, held as int8 in a table beside chunks.
assert(db:exec([[
  CREATE TABLE chunk_blocks (
    model INTEGER NOT NULL, n INTEGER NOT NULL, lo INTEGER NOT NULL, hi INTEGER NOT NULL,
    vectors BLOB NOT NULL, PRIMARY KEY (model, n));
]]))
local PACK <const> = [[
  INSERT INTO chunk_blocks
    SELECT model, id / 4, min(id), max(id), vector_block(id, embedding, 'int8')
    FROM chunks WHERE embedding IS NOT NULL %s GROUP BY model, id / 4
]]
assert(db:exec(PACK:format("")))

-- The packed blocks, and beside them the passages no block holds yet:
-- those past the last block's highest id.
local NEAREST <const> = [[
  SELECT id FROM (
    SELECT h.id AS id, h.distance AS distance
    FROM chunk_blocks b, vector_block_search(b.vectors, ?1, 3, 'cosine') AS h
    WHERE b.model = ?2
    UNION ALL
    SELECT id, cosine_distance(embedding, ?1) FROM chunks
    WHERE model = ?2 AND embedding IS NOT NULL
      AND id > (SELECT coalesce(max(hi), 0) FROM chunk_blocks WHERE model = ?2)
  ) ORDER BY distance NULLS LAST, id LIMIT 3
]]
local function nearest_packed(): {integer}
  return ids(db, NEAREST, { { blob = asked }, { integer = model } })
end
print("packed", table.concat(nearest_packed(), " "))

-- A new passage is found at once, from the unpacked rows...
add_chunk(db, model, "pets", { start = 1, stop = 25 }, "Where do cats sleep in the sun")
local newest = assert(ids(db, "SELECT max(id) FROM chunks", {})[1])
assert(nearest_packed()[1] == newest)
-- ...and packed with the block it belongs to when there is time: only
-- that block is made again. An update or a delete does the same, because
-- a block holds the vector it was made from.
local function repack(id: integer)
  assert(Sqlite.run(db, "DELETE FROM chunk_blocks WHERE model = ?1 AND n = ?2 / 4",
    { { integer = model }, { integer = id } }))
  assert(Sqlite.run(db, PACK:format("AND id / 4 = ?1 / 4"), { { integer = id } }))
end
repack(newest)
assert(nearest_packed()[1] == newest)
print("repacked", ids(db, "SELECT count(*) FROM chunk_blocks", {})[1], "blocks")

-- A corpus from the blocks, for the searches that need the options of search.
local loaded = assert(Vector.load_blocks(db,
  "SELECT vectors FROM chunk_blocks WHERE model = ?1", { { integer = model } }))
print("loaded", loaded:count(), loaded.storage, assert(loaded:search(asked, 1)).ids[1] == newest)
```

The blocks are a copy: `chunks` stays the table of record, and a block
can be thrown away and made again from it at about a second per 100,000
vectors of `int8`. A program that never changes a corpus packs it once.
One that does keeps the unpacked rows in the query above and packs
them in the background; the query is exact over both. A filter on a
column of `chunks` that is not in the block table (a `doc`) cannot be
applied to a block: put the column into the block table and group by it
(`GROUP BY model, doc, id / 4`), as the SQL guide's example does with a
tenant. The first-pass `candidates` of a corpus has no packed form: the
blocks scan every vector they hold, which at these sizes costs less than
the first pass saved.

## a large corpus

Past about 100,000 chunks the in-memory scan costs tens to hundreds
of milliseconds, and the rest of this section trades some recall for far
less work. IVF ("inverted file") splits the corpus into
clusters. A query scores only the chunks in the few clusters nearest to
it. No new storage is needed: an integer column holds each chunk's
cluster, and an ordinary index finds a cluster's rows.

[`Vector.kmeans`] finds the centers. It is spherical k-means on the
corpus's normalized vectors, seeded, so a run with the same `seed`
replays. A starting point for `k` is the square root of the number of
chunks. At 100,000 chunks of 768 dimensions with `k = 100` an iteration
takes about 4 s, so train on a sample of 20,000.

The next example builds a corpus of 2,000 synthetic passages drawn from
four topics, then clusters it. Keep the centers in a table: a program
that starts later needs them to place a new chunk.

```teal continue
local Rand = require("cosmic.rand")

local TOPICS: {{string}} = {
  { "cat", "purr", "fur", "whisker", "kitten", "mouse", "nap", "paw", "tail", "claw", "sofa", "milk" },
  { "star", "orbit", "comet", "moon", "planet", "galaxy", "rocket", "solar", "lunar", "probe", "dust", "void" },
  { "bread", "flour", "yeast", "oven", "soup", "salt", "butter", "dough", "spice", "stew", "crust", "sugar" },
  { "wave", "tide", "reef", "whale", "salt", "boat", "anchor", "shore", "storm", "fish", "sail", "harbor" },
}

-- Twelve words: usually from one topic, sometimes from another.
local function passage(source: Rand.Source): string
  local topic = source:int(1, #TOPICS)
  local words: mut {string} = {}
  for _ = 1, 12 do
    local from = if source:int(1, 6) == 1 then source:int(1, #TOPICS) else topic end
    local list = assert(TOPICS[from])
    words[#words + 1] = assert(list[source:int(1, #list)])
  end
  return table.concat(words, " ")
end

local source = Rand.new(11)
local big, big_model = open_corpus()
assert(big:exec("BEGIN"))
for _ = 1, 2000 do
  local body = passage(source)
  add_chunk(big, big_model, "synthetic", { start = 1, stop = #body }, body)
end
assert(big:exec("COMMIT"))

local everything = assert(Vector.load(big,
  "SELECT id, embedding FROM chunks WHERE model = ?1 AND embedding IS NOT NULL",
  { { integer = big_model } }))
local centroids = assert(Vector.kmeans(everything, 8))

assert(big:exec([[
  CREATE TABLE centroids (id INTEGER PRIMARY KEY, vector BLOB NOT NULL);
  ALTER TABLE chunks ADD COLUMN cluster INTEGER;
  CREATE INDEX chunks_cluster ON chunks (cluster);
]]))
assert(big:exec("BEGIN"))
for i, c in ipairs(centroids) do
  assert(Sqlite.run(big, "INSERT INTO centroids VALUES (?1, ?2)", { { integer = i }, { blob = c } }))
end
local record Placed
  id: integer
  cluster: integer
end
local placed = assert(Sqlite.map(big, "SELECT id, embedding FROM chunks", nil, function(r: Sqlite.Row): Placed
  return { id = r:integer(1), cluster = Vector.nearest(centroids, r:blob(2)) }
end))
for _, p in ipairs(placed) do
  assert(Sqlite.run(big, "UPDATE chunks SET cluster = ?2 WHERE id = ?1", { { integer = p.id }, { integer = p.cluster } }))
end
assert(big:exec("COMMIT"))
```

A new chunk takes the cluster of its nearest center, `Vector.nearest(centroids,
embedding)`, in the same insert. A delete is a plain delete. A filter is
more `WHERE`, because the cluster test is only one of its conditions.
A query takes the `probes` nearest clusters with [`Vector.nearest_n`], and
binds them as one array for `carray`:

```teal continue
local function by_cluster(query: string, probes: integer, k: integer): {integer}
  return ids(big, [[
    SELECT id FROM chunks WHERE model = ?4 AND cluster IN carray(?2)
    ORDER BY inner_product(embedding, ?1) DESC, id LIMIT ?3
  ]], { { blob = query }, { integers = Vector.nearest_n(centroids, query, probes) },
        { integer = k }, { integer = big_model } })
end
```

A program that starts later reloads the centers from their table, in
`id` order, since a center's position is its cluster number:

```teal continue
local reloaded = assert(Sqlite.map(big, "SELECT vector FROM centroids ORDER BY id", nil,
  function(r: Sqlite.Row): string
    return r:blob(1)
  end))
assert(#reloaded == #centroids and reloaded[1] == centroids[1])
```

More probes find more of the true neighbours and scan more rows. When
the data changes, so do the best centers. Inserts keep placing chunks
by the old ones, and recall slowly falls. Retrain when a measurement of
recall (next) drops below what the program needs, or, for example, when
the corpus has grown by half or its subject has changed. Retraining
rewrites the `centroids` table and every `cluster`, in one transaction,
so a reader never sees centers that do not match the clusters. Run it
from a job, not from a request.

## measuring recall

A fast path is approximate, and only the caller's own data says how
approximate. Use the exact search as the answer: for a sample of real
queries, count how many of the exact top `k` the fast path also returns.

```teal continue
-- The share of the exact top k that the fast path also answers.
local function recall(queries: {string}, k: integer, fast: function(string): {integer}): number
  local found, total = 0, 0
  for _, q in ipairs(queries) do
    local exact_ids: mut {integer: boolean} = {}
    for _, id in ipairs(assert(everything:search(q, k)).ids) do
      exact_ids[id] = true
    end
    for _, id in ipairs(fast(q)) do
      if exact_ids[id] == true then
        found = found + 1
      end
    end
    total = total + k
  end
  return found / total
end

local queries: mut {string} = {}
for _ = 1, 100 do
  queries[#queries + 1] = Vector.normalize(embed(passage(source)))
end

for _, probes in ipairs({ 1, 2, 4 }) do
  print(string.format("ivf, %d probes: %.2f", probes, recall(queries, 10, function(q: string): {integer}
    return by_cluster(q, probes, 10)
  end)))
end
for _, candidates in ipairs({ 100, 200, 400 }) do
  print(string.format("sign bits, %d candidates: %.2f", candidates, recall(queries, 10, function(q: string): {integer}
    return assert(everything:search(q, 10, { candidates = candidates })).ids
  end)))
end
```

Use queries the program will see, not rows of the corpus: a stored row
is its own nearest neighbour, and flatters the result. The toy
embedding's 64 sparse dimensions leave the sign bits little to go on,
which is why `candidates` must be so large above, and its scores tie
heavily, so a neighbour that ties the cut-off may fall either side of it
and counts as a miss. The recall on a real model's embeddings is for
the caller to measure. A recall of 0.95 for the top 10 means about one
in twenty true neighbours is missed, and the missed ones tend to be the
lower-ranked. Raise `candidates` or the probes until the recall meets
the program's target, and time the search at that setting.

Running the examples above, in order, prints:

```output
1	34	Cats purr.//They sleep in the sun.
37	58	Mars is a cold planet.
62	79	The sun is a star.
chunks	7
nearest	1 3	in space	4
by bits	1 3
late	false	true
hybrid	5 6 4
like 1	8 2
corpus	1 3	candidates	1 3
int8	1 3	int8
packed	1 3 2
repacked	3	blocks
loaded	9	int8	true
ivf, 1 probes: 0.85
ivf, 2 probes: 0.97
ivf, 4 probes: 1.00
sign bits, 100 candidates: 0.54
sign bits, 200 candidates: 0.74
sign bits, 400 candidates: 0.91
```

[`cosmic.codec`]: ../../cosmic/codec.tl
[`cosmic.http`]: ../../cosmic/http/init.tl
[`cosmic.json`]: ../../cosmic/json.tl
[`cosmic.sqlite`]: ../../cosmic/sqlite.tl
[`cosmic.vector`]: ../../cosmic/vector.tl
[`Vector.corpus`]: ../../cosmic/vector.tl
[`Vector.kmeans`]: ../../cosmic/vector.tl
[`Vector.load_blocks`]: ../../cosmic/vector.tl
[`Vector.load`]: ../../cosmic/vector.tl
[`Vector.nearest_n`]: ../../cosmic/vector.tl
