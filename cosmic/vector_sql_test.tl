--- Proves the vector functions core/vector.c registers on every SQLite
--- handle: each distance against a hand-computed answer, the text and
--- blob forms agreeing, the refusals, and a whole search -- store,
--- filter, rank, rerank and blend with full-text search -- in SQL alone.

local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")

local function close_to(a: number, b: number): boolean
  return math.abs(a - b) < 1e-6
end

-- The one number a query answers.
local function number_of(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): number
  local rows = assert(Sqlite.rows(db, sql, values))
  return assert(rows[1]):number(1)
end

local function text_of(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): string
  local rows = assert(Sqlite.rows(db, sql, values))
  return assert(rows[1]):text(1)
end

-- What a query refuses with.
local function refusal(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): string
  local rows, trouble = Sqlite.rows(db, sql, values)
  assert(rows == nil, sql)
  return trouble
end

-- A vector as the blob an embedding API's base64 float32 decodes to.
local function blob_of(values: {number}): string
  local parts: mut {string} = {}
  for _, v in ipairs(values) do
    parts[#parts + 1] = string.pack("<f", v)
  end
  return table.concat(parts)
end

local function test_distances_match_hand_computed_answers()
  local db = assert(Sqlite.memory())
  local a, b = "'[1, 2, 3]'", "'[4, 6, 3]'"
  assert(close_to(number_of(db, "SELECT l2_distance(" .. a .. ", " .. b .. ")"), 5))
  assert(close_to(number_of(db, "SELECT inner_product(" .. a .. ", " .. b .. ")"), 25))
  assert(close_to(number_of(db, "SELECT l1_distance(" .. a .. ", " .. b .. ")"), 7))
  assert(close_to(number_of(db, "SELECT cosine_distance(" .. a .. ", " .. b .. ")"),
    1 - 25 / (math.sqrt(14) * math.sqrt(61))))
  assert(close_to(number_of(db, "SELECT cosine_distance('[1,0]', '[-1,0]')"), 2))
  assert(close_to(number_of(db, "SELECT cosine_distance('[1,1]', '[2,2]')"), 0))
  -- Long enough to cross the kernels' eight lanes and leave a tail.
  local long: mut {number} = {}
  local ones: mut {number} = {}
  for i = 1, 21 do
    long[#long + 1] = i
    ones[#ones + 1] = 1
  end
  assert(close_to(number_of(db, "SELECT inner_product(?1, ?2)",
    { { blob = blob_of(long) }, { blob = blob_of(ones) } }), 231))
  db:close()
end

local function test_text_and_blob_forms_agree()
  local db = assert(Sqlite.memory())
  local packed = blob_of({ 1, 2.5, -3 })
  local rows = assert(Sqlite.rows(db, "SELECT vector('[1, 2.5, -3]')"))
  assert(assert(rows[1]):blob(1) == packed)
  assert(text_of(db, "SELECT vector_text(?1)", { { blob = packed } }) == "[1,2.5,-3]")
  assert(text_of(db, "SELECT vector_text(vector(' [ 0.1 ] '))") == "[0.100000001]")
  assert(number_of(db, "SELECT vector_dims(?1)", { { blob = packed } }) == 3)
  assert(number_of(db, "SELECT vector_dims('[]')") == 0)
  assert(close_to(number_of(db, "SELECT l2_distance(?1, '[1, 2.5, -3]')",
    { { blob = packed } }), 0))
  db:close()
end

local function test_normalize_and_subvector()
  local db = assert(Sqlite.memory())
  assert(text_of(db, "SELECT vector_text(l2_normalize('[3, 4]'))") == "[0.600000024,0.800000012]")
  assert(text_of(db, "SELECT vector_text(l2_normalize('[0, 0]'))") == "[0,0]")
  assert(close_to(number_of(db,
    "SELECT inner_product(l2_normalize('[1,2,3]'), l2_normalize('[4,6,3]'))"),
    1 - number_of(db, "SELECT cosine_distance('[1,2,3]', '[4,6,3]')")))
  assert(text_of(db, "SELECT vector_text(subvector('[1,2,3,4,5]', 2, 3))") == "[2,3,4]")
  assert(refusal(db, "SELECT subvector('[1,2,3]', 3, 2)"):find("outside the vector", 1, true) ~= nil)
  assert(refusal(db, "SELECT subvector('[1,2,3]', 0, 1)"):find("outside the vector", 1, true) ~= nil)
  db:close()
end

local function test_binary_quantize_and_bit_distances()
  local db = assert(Sqlite.memory())
  -- Bits above zero set, the first dimension in the high bit.
  assert(text_of(db, "SELECT hex(binary_quantize('[1,-1,0,2,-2,3,0,0,5]'))") == "9480")
  assert(number_of(db,
    "SELECT hamming_distance(binary_quantize('[1,1,-1,-1]'), binary_quantize('[1,-1,1,-1]'))") == 2)
  assert(close_to(number_of(db,
    "SELECT jaccard_distance(binary_quantize('[1,1,-1,-1]'), binary_quantize('[1,-1,1,-1]'))"),
    1 - 1 / 3))
  assert(number_of(db, "SELECT jaccard_distance(x'00', x'00')") == 0)
  -- Past one 64-bit word, so both the word and byte paths count.
  assert(number_of(db, "SELECT hamming_distance(zeroblob(9), x'ffffffffffffffffff')") == 72)
  assert(refusal(db, "SELECT hamming_distance(x'00', x'0000')"):find("different lengths", 1, true) ~= nil)
  assert(refusal(db, "SELECT hamming_distance('a', 'b')"):find("is a blob", 1, true) ~= nil)
  db:close()
end

local function test_refuses_what_is_not_a_vector()
  local db = assert(Sqlite.memory())
  assert(refusal(db, "SELECT l2_distance('[1,2]', '[1,2,3]')"):find("different dimensions", 1, true) ~= nil)
  assert(refusal(db, "SELECT vector('1,2')"):find("starts with [", 1, true) ~= nil)
  assert(refusal(db, "SELECT vector('[1,,2]')"):find("finite numbers", 1, true) ~= nil)
  assert(refusal(db, "SELECT vector('[1 2]')"):find("separated by commas", 1, true) ~= nil)
  assert(refusal(db, "SELECT vector('[1] x')"):find("nothing may follow", 1, true) ~= nil)
  assert(refusal(db, "SELECT vector(x'000000')"):find("4-byte floats", 1, true) ~= nil)
  assert(refusal(db, "SELECT vector(42)"):find("blob of floats or a text", 1, true) ~= nil)
  assert(refusal(db, "SELECT vector(zeroblob(64004))"):find("16000 dimensions", 1, true) ~= nil)
  local rows = assert(Sqlite.rows(db,
    "SELECT l2_distance(NULL, '[1]') IS NULL, cosine_distance('[0,0]', '[1,1]') IS NULL"))
  assert(assert(rows[1]):integer(1) == 1 and assert(rows[1]):integer(2) == 1)
  db:close()
end

-- A toy embedding, so a search runs with no model: each word lands on
-- one of 64 dimensions by its digest, with a sign by its digest too.
-- Texts that share words point the same way. A real program stores what
-- an embedding API answers instead.
local function embed(text: string): string
  local sums: mut {integer: number} = {}
  for word in text:lower():gmatch("%a+") do
    local digest = Hash.digest("sha256", word)
    local slot = assert(digest:byte(1)) % 64 + 1
    local sign = if assert(digest:byte(2)) % 2 == 0 then 1 else -1 end
    sums[slot] = (sums[slot] or 0) + sign
  end
  local dims: mut {number} = {}
  for slot = 1, 64 do
    dims[#dims + 1] = sums[slot] or 0
  end
  return blob_of(dims)
end

local record Doc
  body: string
  topic: string
end

local docs: {Doc} = {
  { body = "Cats purr and sleep in the sun", topic = "pets" },
  { body = "Dogs bark and fetch the ball", topic = "pets" },
  { body = "The sun is a star at the centre of the solar system", topic = "space" },
  { body = "Mars is a cold planet in the solar system", topic = "space" },
  { body = "Bake bread with flour water and yeast", topic = "food" },
  { body = "Cats and dogs can live together as pets", topic = "pets" },
}

local function corpus(): Sqlite.Handle
  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE chunks (id INTEGER PRIMARY KEY, body TEXT, topic TEXT, embedding BLOB);
    CREATE VIRTUAL TABLE chunks_fts USING fts5(body, content='chunks', content_rowid='id');
  ]]))
  for i, d in ipairs(docs) do
    assert(Sqlite.run(db,
      "INSERT INTO chunks VALUES (?1, ?2, ?3, l2_normalize(?4))",
      { { integer = i }, { text = d.body }, { text = d.topic }, { blob = embed(d.body) } }))
  end
  assert(db:exec("INSERT INTO chunks_fts(chunks_fts) VALUES ('rebuild')"))
  return db
end

local function ids(db: Sqlite.Handle, sql: string, values: {Sqlite.Value}): {integer}
  local found = assert(Sqlite.map(db, sql, values, function(r: Sqlite.Row): integer
    return r:integer(1)
  end))
  return found
end

local function test_searches_by_meaning_with_a_filter()
  local db = corpus()
  local query: Sqlite.Value = { blob = embed("where do cats sleep") }
  local nearest = ids(db,
    "SELECT id FROM chunks ORDER BY cosine_distance(embedding, ?1) LIMIT 2", { query })
  assert(nearest[1] == 1, "the cat that sleeps is nearest")
  -- A filter is a WHERE clause: every row it keeps is scored, none other.
  local in_space = ids(db,
    "SELECT id FROM chunks WHERE topic = 'space' ORDER BY cosine_distance(embedding, ?1) LIMIT 1",
    { { blob = embed("the solar system") } })
  assert(#in_space == 1 and (in_space[1] == 3 or in_space[1] == 4))
  -- Normalized at insert, so the inner product ranks as cosine does.
  local by_dot = ids(db,
    "SELECT id FROM chunks ORDER BY inner_product(embedding, l2_normalize(?1)) DESC LIMIT 2", { query })
  assert(by_dot[1] == nearest[1] and by_dot[2] == nearest[2])
  db:close()
end

local function test_binary_first_pass_then_rerank()
  local db = corpus()
  -- A stored bit vector per chunk, 32 times smaller than its floats, in
  -- a table of its own so the first pass never reads the floats.
  assert(db:exec([[
    CREATE TABLE chunk_bits (id INTEGER PRIMARY KEY, bits BLOB);
    INSERT INTO chunk_bits SELECT id, binary_quantize(embedding) FROM chunks;
  ]]))
  local query: Sqlite.Value = { blob = embed("cats and dogs as pets") }
  local reranked = ids(db, [[
    SELECT c.id FROM (
      SELECT id FROM chunk_bits ORDER BY hamming_distance(bits, binary_quantize(?1)) LIMIT 4
    ) b JOIN chunks c ON c.id = b.id
    ORDER BY cosine_distance(c.embedding, ?1) LIMIT 1
  ]], { query })
  assert(reranked[1] == 6, "the chunk with all three words wins the rerank")
  db:close()
end

local function test_hybrid_search_blends_keywords_and_meaning()
  local db = corpus()
  -- Reciprocal rank fusion: each list adds 1 / (60 + rank) to a chunk.
  local blended = ids(db, [[
    WITH
      semantic AS (
        SELECT id, row_number() OVER (ORDER BY cosine_distance(embedding, ?1)) AS rank
        FROM chunks LIMIT 5),
      keyword AS (
        SELECT rowid AS id, row_number() OVER (ORDER BY rank) AS rank
        FROM chunks_fts WHERE chunks_fts MATCH ?2 LIMIT 5)
    SELECT id FROM (
      SELECT id, 1.0 / (60 + rank) AS score FROM semantic
      UNION ALL
      SELECT id, 1.0 / (60 + rank) AS score FROM keyword)
    GROUP BY id ORDER BY sum(score) DESC LIMIT 1
  ]], { { blob = embed("a planet in the solar system") }, { text = "Mars" } })
  assert(blended[1] == 4, "Mars matches both by word and by meaning")
  db:close()
end

local function test_a_view_in_an_untrusted_file_may_use_them()
  -- Innocuous, unlike cosmic's digest functions: a schema may call them
  -- though cosmic turns trusted_schema off.
  local db = corpus()
  assert(db:exec([[
    CREATE VIEW near_sun AS
      SELECT id FROM chunks ORDER BY l2_distance(embedding, embedding) + id LIMIT 1;
    CREATE INDEX chunks_bits ON chunks (binary_quantize(embedding));
  ]]))
  assert(number_of(db, "SELECT id FROM near_sun") == 1)
  db:close()
end
