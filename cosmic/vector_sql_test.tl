--- Proves the vector functions core/vector.c registers on every SQLite
--- handle: each distance against a hand-computed answer, the text and
--- blob forms agreeing, the refusals, and a whole search -- store,
--- filter, rank, rerank and blend with full-text search -- in SQL alone.

local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local VectorFixture = require("build.vector_fixture")

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
  assert(VectorFixture.refusal(db, "SELECT vector_dims('[]')"):find("at least 1 dimension", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector(x'')"):find("at least 1 dimension", 1, true) ~= nil)
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
  -- Clipped as substr clips: a count past the end stops at the end, a
  -- start below 1 starts at 1 but spends count on the dimensions before it.
  assert(text_of(db, "SELECT vector_text(subvector('[1,2,3]', 3, 2))") == "[3]")
  assert(text_of(db, "SELECT vector_text(subvector('[1,2,3]', 0, 2))") == "[1]")
  assert(text_of(db, "SELECT vector_text(subvector('[1,2,3]', -5, 100))") == "[1,2,3]")
  assert(text_of(db, "SELECT vector_text(subvector('[1,2,3]', 2, 9223372036854775807))") == "[2,3]")
  -- Only a range with no dimension left is refused.
  assert(VectorFixture.refusal(db, "SELECT subvector('[1,2,3]', 4, 2)"):find("at least 1 dimension", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT subvector('[1,2,3]', 0, 1)"):find("at least 1 dimension", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT subvector('[1,2,3]', 1, 0)"):find("at least 1 dimension", 1, true) ~= nil)
  db:close()
end

local function test_normalize_does_not_underflow_or_overflow_in_float()
  local db = assert(Sqlite.memory())
  -- The squares of 1e-30 and 1e30 are outside a float's range.
  assert(close_to(number_of(db,
    "SELECT l2_distance(l2_normalize('[3e-30, 4e-30]'), '[0.6, 0.8]')"), 0))
  assert(close_to(number_of(db,
    "SELECT l2_distance(l2_normalize('[3e30, 4e30]'), '[0.6, 0.8]')"), 0))
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
  -- Bit vectors compare by byte length alone: 9 bits and 16 are the same.
  assert(number_of(db, "SELECT hamming_distance(binary_quantize('[1,1,1,1,1,1,1,1,1]'), x'ffff')") == 7)
  assert(VectorFixture.refusal(db, "SELECT hamming_distance(x'00', x'0000')"):find("different lengths", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT hamming_distance('a', 'b')"):find("is a blob", 1, true) ~= nil)
  db:close()
end

local function test_refuses_what_is_not_a_vector()
  local db = assert(Sqlite.memory())
  assert(VectorFixture.refusal(db, "SELECT l2_distance('[1,2]', '[1,2,3]')"):find("different dimensions", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector('1,2')"):find("starts with [", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector('[1,,2]')"):find("finite numbers", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector('[1 2]')"):find("separated by commas", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector('[1] x')"):find("nothing may follow", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector(x'000000')"):find("4-byte floats", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector(42)"):find("blob of floats or a text", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector(zeroblob(64004))"):find("16000 dimensions", 1, true) ~= nil)
  -- A number a float cannot hold is refused, not stored as infinity.
  assert(VectorFixture.refusal(db, "SELECT vector('[1e39]')"):find("finite numbers", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector('[1, nan]')"):find("finite numbers", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector('[]')"):find("at least 1 dimension", 1, true) ~= nil)
  -- vector() also refuses a blob that holds a NaN or an infinity.
  local inf = string.pack("<f", math.huge)
  local nan = string.pack("<f", 0 / 0)
  assert(VectorFixture.refusal(db, "SELECT vector(?1)", { { blob = blob_of({ 1 }) .. inf } }):find("finite numbers", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector(?1)", { { blob = nan } }):find("finite numbers", 1, true) ~= nil)
  -- A zeroblob is a vector of zeros, read without being held in memory.
  assert(number_of(db, "SELECT vector_dims(zeroblob(12))") == 3)
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
  -- No words, so an embedding of zeros: it has no direction.
  { body = "", topic = "blank" },
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
    "SELECT id FROM chunks ORDER BY cosine_distance(embedding, ?1) NULLS LAST LIMIT 2", { query })
  assert(nearest[1] == 1, "the cat that sleeps is nearest")
  -- A filter is a WHERE clause: every row it keeps is scored, none other.
  local in_space = ids(db,
    "SELECT id FROM chunks WHERE topic = 'space' ORDER BY cosine_distance(embedding, ?1) NULLS LAST LIMIT 1",
    { { blob = embed("the solar system") } })
  assert(#in_space == 1 and in_space[1] == 3, "the sun and solar system chunk beats Mars")
  -- The chunk of zeros has no cosine, so it is NULL: without NULLS LAST
  -- SQLite would rank it before every real match.
  local everything = ids(db,
    "SELECT id FROM chunks ORDER BY cosine_distance(embedding, ?1) NULLS LAST", { query })
  assert(everything[1] == 1 and everything[#everything] == 7, "the zeros rank last")
  local unguarded = ids(db,
    "SELECT id FROM chunks ORDER BY cosine_distance(embedding, ?1) LIMIT 1", { query })
  assert(unguarded[1] == 7, "NULL sorts first unless told otherwise")
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
    ORDER BY cosine_distance(c.embedding, ?1) NULLS LAST LIMIT 1
  ]], { query })
  assert(reranked[1] == 6, "the chunk with all three words wins the rerank")
  db:close()
end

local function test_hybrid_search_blends_keywords_and_meaning()
  local db = corpus()
  -- Reciprocal rank fusion: each list adds 1 / (60 + rank) to a chunk.
  -- Neither list alone picks the winner: by meaning the sun chunk (3)
  -- leads, by keyword the bread chunk (5) does, and Mars (4), second in
  -- both, beats them. A constant distance would hand the semantic side
  -- to the first rows by id, and chunk 5 would win.
  local meaning: Sqlite.Value = { blob = embed("the sun in the solar system") }
  local keywords: Sqlite.Value = { text = "bread OR mars" }
  local by_meaning = ids(db,
    "SELECT id FROM chunks ORDER BY cosine_distance(embedding, ?1) NULLS LAST LIMIT 5", { meaning })
  local by_keyword = ids(db,
    "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ?1 ORDER BY rank LIMIT 5", { keywords })
  assert(by_meaning[1] == 3 and by_meaning[2] == 4, "meaning alone: sun, then Mars")
  assert(by_keyword[1] == 5 and by_keyword[2] == 4, "keywords alone: bread, then Mars")
  local blended = ids(db, [[
    WITH
      semantic AS (
        SELECT id, row_number() OVER w AS pos FROM chunks
        WINDOW w AS (ORDER BY cosine_distance(embedding, ?1) NULLS LAST)
        ORDER BY pos LIMIT 5),
      keyword AS (
        SELECT rowid AS id, row_number() OVER w AS pos FROM chunks_fts
        WHERE chunks_fts MATCH ?2
        WINDOW w AS (ORDER BY rank)
        ORDER BY pos LIMIT 5)
    SELECT id FROM (
      SELECT id, 1.0 / (60 + pos) AS score FROM semantic
      UNION ALL
      SELECT id, 1.0 / (60 + pos) AS score FROM keyword)
    GROUP BY id ORDER BY sum(score) DESC LIMIT 1
  ]], { meaning, keywords })
  assert(blended[1] == 4, "Mars is second in both lists, ahead of each list's first")
  db:close()
end

-- A blob sits at a different offset in its page as the columns before it
-- grow. read_vector copies a blob that is misaligned for a float, but
-- checked against the pinned SQLite, no SQL reaches that branch: OP_Column
-- copies a column's blob out of the page into a malloc'd value, so it is
-- always aligned. This pins that every offset reads the same.
local function test_a_blob_at_any_offset_in_a_row_reads_the_same()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE odd (id INTEGER PRIMARY KEY, pad BLOB, v BLOB)"))
  local packed = blob_of({ 1, 2.5, -3, 4, 5, 6, 7, 8, 9, 10 })
  for pad = 0, 3 do
    assert(Sqlite.run(db, "INSERT INTO odd VALUES (?1, ?2, ?3)",
      { { integer = pad }, { blob = string.rep("x", pad) }, { blob = packed } }))
  end
  local rows = assert(Sqlite.map(db,
    "SELECT l2_distance(v, ?1), vector_text(v), vector(v) = ?1 FROM odd ORDER BY id",
    { { blob = packed } }, function(r: Sqlite.Row): string
      return string.format("%g %s %d", r:number(1), r:text(2), r:integer(3))
    end))
  assert(#rows == 4)
  for _, row in ipairs(rows) do
    assert(row == "0 [1,2.5,-3,4,5,6,7,8,9,10] 1", row)
  end
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

local function test_a_text_with_a_nul_is_no_vector()
  local db = assert(Sqlite.memory())
  -- The parser reads to the first NUL, which must not make `[1]` of this.
  local text: Sqlite.Value = { text = "[1]\0junk" }
  assert(VectorFixture.refusal(db, "SELECT vector(?1)", { text }):find("NUL", 1, true) ~= nil)
  assert(VectorFixture.refusal(db, "SELECT vector_dims(?1)", { text }):find("NUL", 1, true) ~= nil)
  db:close()
end

local function test_the_sign_of_zero_survives_vector_text()
  local db = assert(Sqlite.memory())
  local blob: Sqlite.Value = { blob = blob_of({ -0.0, 1 }) }
  local written = text_of(db, "SELECT vector_text(?1)", { blob })
  assert(written == "[-0,1]", written)
  assert(text_of(db, "SELECT hex(vector(vector_text(?1)))", { blob }) == "000000800000803F")
  db:close()
end

local function test_distances_of_huge_or_tiny_vectors_stay_finite()
  local db = assert(Sqlite.memory())
  local big: Sqlite.Value = { blob = blob_of({ 3e38, 1e20 }) }
  local opposite: Sqlite.Value = { blob = blob_of({ -3e38, 0 }) }
  -- Past a float's range these sums are infinite (or not a number) in
  -- float, and ordinary doubles.
  assert(number_of(db, "SELECT l2_distance(?1, ?2)", { big, opposite }) > 6e38)
  assert(number_of(db, "SELECT l1_distance(?1, ?2)", { big, opposite }) > 6e38)
  assert(number_of(db, "SELECT inner_product(?1, ?2)", { big, opposite }) < -8e76)
  -- A vector of 1e20s has a direction though its square has none in float,
  -- and so has one of 1e-30s, whose square is zero in float.
  for _, x in ipairs({ 1e20, 1e-30 }) do
    local v: Sqlite.Value = { blob = blob_of({ x, 0 }) }
    assert(close_to(number_of(db, "SELECT cosine_distance(?1, ?1)", { v }), 0), tostring(x))
    local w: Sqlite.Value = { blob = blob_of({ 0, x }) }
    assert(close_to(number_of(db, "SELECT cosine_distance(?1, ?2)", { v, w }), 1), tostring(x))
  end
  local zeros: Sqlite.Value = { blob = blob_of({ 0, 0 }) }
  local v: Sqlite.Value = { blob = blob_of({ 1e-30, 0 }) }
  assert(text_of(db, "SELECT typeof(cosine_distance(?1, ?2))", { v, zeros }) == "null")
  db:close()
end

local function test_distances_do_not_underflow_to_zero_in_float()
  local db = assert(Sqlite.memory())
  local function near(got: number, want: number): boolean
    return math.abs(got - want) <= 1e-5 * math.abs(want)
  end
  local tiny: Sqlite.Value = { blob = blob_of({ 1e-30, 0 }) }
  local zeros: Sqlite.Value = { blob = blob_of({ 0, 0 }) }
  -- The squares of 1e-30 are 1e-60: zero in float, an ordinary double.
  local l2 = number_of(db, "SELECT l2_distance(?1, ?2)", { tiny, zeros })
  assert(near(l2, 1e-30), tostring(l2))
  local product = number_of(db, "SELECT inner_product(?1, ?1)", { tiny })
  assert(near(product, 1e-60), tostring(product))
  -- A sum that falls in the subnormals has lost most of its digits.
  local small: Sqlite.Value = { blob = blob_of({ 1e-20, 1e-20 }) }
  local axis: Sqlite.Value = { blob = blob_of({ 1e-20, 0 }) }
  local cosine = number_of(db, "SELECT cosine_distance(?1, ?2)", { small, axis })
  assert(near(cosine, 1 - math.sqrt(0.5)), tostring(cosine))
  -- Equal vectors are still at distance zero, and orthogonal ones at zero
  -- product.
  assert(number_of(db, "SELECT l2_distance(?1, ?1)", { tiny }) == 0)
  assert(number_of(db, "SELECT l2_distance(?1, ?1)", { zeros }) == 0)
  local other: Sqlite.Value = { blob = blob_of({ 0, 1e-30 }) }
  assert(number_of(db, "SELECT inner_product(?1, ?2)", { tiny, other }) == 0)
  db:close()
end
