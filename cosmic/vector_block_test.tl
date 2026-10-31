--- Proves the packed blocks of core/vector.c: `vector_block`, the aggregate
--- that packs rows into one blob, `vector_block_search`, the table-valued
--- function that answers each block's nearest rows, and the corpus loaded
--- from blocks. A search over blocks gives the ids and order of the
--- per-row scan and of a corpus in the same storage, under every metric;
--- a malformed block is refused, never read past.

local Signal = require("cosmic.signal")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local Vector = require("cosmic.vector")
local Test = require("cosmic.test")

local storages: {Vector.Storage} = { "f32", "f16", "int8" }
local metrics: {Vector.Metric} = { "inner_product", "cosine", "l2" }

local record Seed
  mut state: integer
end

-- A deterministic stream of numbers in [-1, 1), so a failure replays.
local function stream(seed: integer): function(): number
  local held: Seed = { state = seed }
  return function(): number
    held.state = (held.state * 6364136223846793005 + 1442695040888963407)
    return ((held.state >> 11) % 2000001) / 1000000 - 1
  end
end

local function random_vector(next_number: function(): number, dims: integer): string
  local out: mut {number} = {}
  for _ = 1, dims do
    out[#out + 1] = next_number()
  end
  return Vector.pack(out)
end

-- What a query refuses with.
local function refusal(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): string
  local rows, trouble = Sqlite.rows(db, sql, values)
  assert(rows == nil, sql)
  return trouble
end

local function refused(db: Sqlite.Handle, sql: string, words: string, values?: {Sqlite.Value})
  local why = refusal(db, sql, values)
  assert(why:find(words, 1, true) ~= nil, sql .. " refused with " .. why)
end

local function count_of(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): integer
  local rows = assert(Sqlite.rows(db, sql, values))
  return assert(rows[1]):integer(1)
end

--- The corpus a lone block loads into, or nil and why it is not a block:
--- what its header says is the corpus's dimensions, storage and count.
local function read_block(db: Sqlite.Handle, block: string): Vector.Corpus?, string
  return Vector.load_blocks(db, "SELECT ?1", { { blob = block } })
end

local function storage_of(name: string): Vector.Storage
  if name == "f16" then
    return "f16"
  elseif name == "int8" then
    return "int8"
  end
  return "f32"
end

local record Hit
  id: integer
  distance: number
  nothing: boolean
end

local function hits_of(db: Sqlite.Handle, sql: string, values?: {Sqlite.Value}): {Hit}
  local rows = assert(Sqlite.rows(db, sql, values))
  local out: mut {Hit} = {}
  for _, row in ipairs(rows) do
    local none = row:kind(2) == "null"
    out[#out + 1] = { id = row:integer(1), distance = if none then 0 else row:number(2) end, nothing = none }
  end
  return out
end

--- A table `chunks (seq, id, tenant, embedding)` of `n` random vectors
--- with ids 7, 10, 13, ... -- not dense, so a block cannot be told by
--- `id / size` -- and a `blocks` table packing them `size` to a block.
local function dataset(db: Sqlite.Handle, n: integer, dims: integer, size: integer,
                       storage: Vector.Storage, seed: integer): {string}
  local next_number = stream(seed)
  assert(db:exec("CREATE TABLE chunks (seq INTEGER PRIMARY KEY, id INTEGER, tenant TEXT, embedding BLOB)"))
  local vectors: mut {string} = {}
  for i = 1, n do
    local v = random_vector(next_number, dims)
    vectors[#vectors + 1] = v
    assert(Sqlite.run(db, "INSERT INTO chunks VALUES (?1, ?2, ?3, ?4)",
      { { integer = i }, { integer = 4 + 3 * i }, { text = if i % 3 == 0 then "a" else "b" end }, { blob = v } }))
  end
  assert(db:exec(([[
    CREATE TABLE blocks AS
      SELECT tenant, (seq - 1) / %d AS n, min(id) AS lo, max(id) AS hi,
             vector_block(id, embedding, '%s') AS vectors
      FROM chunks GROUP BY tenant, (seq - 1) / %d
  ]]):format(size, storage, size)))
  return vectors
end

local SEARCH <const> = [[
  SELECT h.id, h.distance FROM blocks, vector_block_search(blocks.vectors, ?1, ?2, ?3) AS h
  %s ORDER BY h.distance NULLS LAST, h.id LIMIT ?2
]]

local function packed_hits(db: Sqlite.Handle, query: string, k: integer, metric: string,
                           where?: string): {Hit}
  return hits_of(db, SEARCH:format(where or ""),
    { { blob = query }, { integer = k }, { text = metric } })
end

--- The distance a corpus's score stands for.
local function distance_of(metric: Vector.Metric, score: number): number?
  if metric == "inner_product" then
    return 0.0 - score
  elseif metric == "l2" then
    return score
  end
  if score == -math.huge then
    return nil
  end
  return 1.0 - math.max(-1.0, math.min(1.0, score))
end

--- The rows of `vectors` in a corpus of `storage`, from `add`.
local function corpus_of(vectors: {string}, dims: integer, storage: Vector.Storage): Vector.Corpus
  local corpus = Vector.corpus(dims, { storage = storage })
  for i, v in ipairs(vectors) do
    corpus:add(4 + 3 * i, v)
  end
  return corpus
end

local function same_as_corpus(found: {Hit}, corpus: Vector.Corpus, query: string, k: integer,
                              metric: Vector.Metric, what: string)
  local hits = assert(corpus:search(query, k, { metric = metric }))
  assert(#found == #hits.ids, ("%s: %d hits, not %d"):format(what, #found, #hits.ids))
  for i, hit in ipairs(found) do
    local distance = distance_of(metric, assert(hits.scores[i]))
    assert(hit.id == hits.ids[i], ("%s: hit %d is %d, not %s"):format(what, i, hit.id, tostring(hits.ids[i])))
    if distance == nil then
      assert(hit.nothing, ("%s: hit %d should have no distance"):format(what, i))
    else
      assert(not hit.nothing and hit.distance == distance,
        ("%s: hit %d is %.17g, not %.17g"):format(what, i, hit.distance, distance))
    end
  end
end

--- Every metric and storage ranks the blocks' rows as a corpus of that
--- storage does, same ids, same distances, over block sizes that leave a
--- short last block, one row to a block and one block for all.
local function test_a_search_over_blocks_answers_what_a_corpus_does()
  local dims = 11
  for _, storage in ipairs(storages) do
    for _, size in ipairs({ 1, 7, 64, 500 }) do
      local db = assert(Sqlite.memory())
      local vectors = dataset(db, 150, dims, size, storage, 3)
      local corpus = corpus_of(vectors, dims, storage)
      local next_number = stream(99)
      for q = 1, 3 do
        local query = random_vector(next_number, dims)
        for _, metric in ipairs(metrics) do
          for _, k in ipairs({ 1, 5, 40 }) do
            same_as_corpus(packed_hits(db, query, k, metric), corpus, query, k, metric,
              ("%s size %d %s k=%d query %d"):format(storage, size, metric, k, q))
          end
        end
      end
      local _, _ = db:close()
    end
  end
end

--- The f32 blocks rank rows as the per-row functions do (same ids, the
--- distances to the rounding of a sum), including `inner_product`, whose
--- distance is its negation as pgvector's `<#>` is.
local function test_f32_blocks_answer_what_the_per_row_scan_does()
  local dims = 24
  local db = assert(Sqlite.memory())
  dataset(db, 300, dims, 16, "f32", 5)
  local next_number = stream(11)
  local functions: {string: string} = {
    inner_product = "0.0 - inner_product(embedding, ?1)",
    cosine = "cosine_distance(embedding, ?1)",
    l2 = "l2_distance(embedding, ?1)",
  }
  for _, metric in ipairs(metrics) do
    for _ = 1, 4 do
      local query = random_vector(next_number, dims)
      local per_row = hits_of(db, ("SELECT id, %s AS distance FROM chunks ORDER BY distance NULLS LAST, id LIMIT 20")
          :format(assert(functions[metric])), { { blob = query } })
      local packed = packed_hits(db, query, 20, metric)
      assert(#packed == 20 and #per_row == 20)
      for i, hit in ipairs(packed) do
        assert(hit.id == assert(per_row[i]).id, ("%s hit %d"):format(metric, i))
        assert(math.abs(hit.distance - assert(per_row[i]).distance) < 1e-5, ("%s distance %d"):format(metric, i))
      end
    end
  end
  local _, _ = db:close()
end

--- Equal distances order by the lower id whichever block holds them, and a
--- block's own answer, cut at k, keeps the lower ids too.
local function test_ties_go_to_the_lower_id_across_blocks()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (seq INTEGER PRIMARY KEY, id INTEGER, v BLOB)"))
  local same = Vector.pack({ 1, 2, 3 })
  for seq, id in ipairs({ 9, 5, 3, 1 }) do
    assert(Sqlite.run(db, "INSERT INTO r VALUES (?1, ?2, ?3)",
      { { integer = seq }, { integer = id }, { blob = same } }))
  end
  assert(db:exec([[
    CREATE TABLE blocks AS SELECT (seq - 1) / 2 AS n, vector_block(id, v) AS vectors
    FROM r GROUP BY (seq - 1) / 2
  ]]))
  for _, metric in ipairs(metrics) do
    local found = packed_hits(db, same, 2, metric)
    assert(#found == 2 and found[1].id == 1 and found[2].id == 3, metric)
    -- The first block holds ids 9 and 5; cut to one, it answers 5.
    local one = hits_of(db, "SELECT id, distance FROM blocks, vector_block_search(vectors, ?1, 1, ?2) WHERE n = 0",
      { { blob = same }, { text = metric } })
    assert(#one == 1 and one[1].id == 5, metric)
  end
  local _, _ = db:close()
end

--- A k beyond a block, beyond every row, and the largest integer.
local function test_k_may_outrun_a_block_and_the_table()
  local db = assert(Sqlite.memory())
  local dims = 4
  local vectors = dataset(db, 25, dims, 4, "f32", 8)
  local corpus = corpus_of(vectors, dims, "f32")
  local query = random_vector(stream(2), dims)
  for _, k in ipairs({ 3, 4, 5, 25, 26, 1000, math.maxinteger }) do
    local found = packed_hits(db, query, k, "l2")
    assert(#found == math.min(k, 25), k)
    same_as_corpus(found, corpus, query, k, "l2", "k " .. tostring(k))
  end
  local _, _ = db:close()
end

--- The blocks' table is filtered by SQL as any table is: a block that a
--- WHERE drops contributes no row, so a search over a tenant's blocks
--- finds the tenant's nearest.
local function test_a_where_on_the_block_table_filters()
  local dims = 9
  for _, storage in ipairs(storages) do
    local db = assert(Sqlite.memory())
    local vectors = dataset(db, 120, dims, 5, storage, 21)
    -- Corpus of the tenant's rows only.
    local mine = Vector.corpus(dims, { storage = storage })
    for i, v in ipairs(vectors) do
      if i % 3 == 0 then mine:add(4 + 3 * i, v) end
    end
    local query = random_vector(stream(5), dims)
    for _, metric in ipairs(metrics) do
      same_as_corpus(packed_hits(db, query, 10, metric, "WHERE blocks.tenant = 'a'"), mine, query, 10,
        metric, storage .. " " .. metric)
    end
    -- Ranges of ids prune whole blocks.
    local none = packed_hits(db, query, 10, "l2", "WHERE blocks.lo > 100000")
    assert(#none == 0)
    local some = packed_hits(db, query, 100, "l2", "WHERE blocks.hi < 40")
    for _, hit in ipairs(some) do assert(hit.id < 40) end
    assert(#some > 0 and #some < 100)
    local _, _ = db:close()
  end
end

--- NULL block, query or k answers no rows, as the functions answer NULL;
--- a NULL vector is left out of its block; an empty set packs to NULL; a
--- block of no rows searches to nothing.
local function test_nulls_and_empty_blocks()
  local db = assert(Sqlite.memory())
  local query = Vector.pack({ 1, 2 })
  local block = Vector.pack({ 1, 2 })
  assert(db:exec("CREATE TABLE r (id INTEGER, v BLOB)"))
  assert(Sqlite.run(db, "INSERT INTO r VALUES (1, ?1), (2, NULL), (3, ?1)",
    { { blob = block } }))
  assert(count_of(db, "SELECT vector_block(id, v) IS NULL FROM r WHERE id = 99") == 1)
  assert(count_of(db, "SELECT vector_block(id, v) IS NULL FROM r WHERE id = 2") == 1)
  local rows = assert(Sqlite.rows(db, "SELECT vector_block(id, v) FROM r"))
  local packed = assert(rows[1]):blob(1)
  local found = hits_of(db, "SELECT id, distance FROM vector_block_search(?1, ?2, 5, 'l2')",
    { { blob = packed }, { blob = query } })
  assert(#found == 2 and found[1].id == 1 and found[2].id == 3, "the NULL vector's row is left out")
  local nulls: {string} = { "nullif(?1, ?1), ?2, 5, 'l2'", "?1, nullif(?2, ?2), 5, 'l2'", "?1, ?2, nullif(5, 5), 'l2'" }
  for _, args in ipairs(nulls) do
    local none = hits_of(db, "SELECT id, distance FROM vector_block_search(" .. args .. ")",
      { { blob = packed }, { blob = query } })
    assert(#none == 0, args)
  end
  -- A block of no rows, as no aggregate makes but a program may write.
  local empty = "VBLK" .. string.pack("<I4I4I4", 0, 2, 0)
  assert(#hits_of(db, "SELECT id, distance FROM vector_block_search(?1, ?2, 5, 'l2')",
    { { blob = empty }, { blob = query } }) == 0)
  local corpus = Vector.corpus(2)
  corpus:add_block(empty)
  assert(corpus:count() == 0)
  local _, _ = db:close()
end

--- The text form of a vector packs and searches as the blob does.
local function test_text_vectors_pack_and_search()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (id INTEGER, v TEXT)"))
  assert(db:exec("INSERT INTO r VALUES (1, '[1, 0]'), (2, '[0, 1]'), (3, '[0.9, 0.1]')"))
  assert(db:exec("CREATE TABLE blocks AS SELECT vector_block(id, v, 'f16') AS vectors FROM r"))
  local found = hits_of(db,
    "SELECT id, distance FROM blocks, vector_block_search(vectors, '[1, 0]', 2, 'cosine')")
  assert(#found == 2 and found[1].id == 1 and found[2].id == 3)
  assert(found[1].distance == 0)
  local _, _ = db:close()
end

--- Every way a block can be wrong is refused by name, whichever storage
--- it claims.
local function test_malformed_blocks_are_refused()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (id INTEGER, v BLOB)"))
  assert(db:exec("INSERT INTO r VALUES (1, x'0000803f00000040'), (2, x'0000404000008040'), (3, x'0000a0400000c040')"))
  local query = Vector.pack({ 1, 2 })
  local function search(blob: string, k?: integer): string
    return refusal(db, "SELECT id FROM vector_block_search(?1, ?2, ?3, 'l2')",
      { { blob = blob }, { blob = query }, { integer = k or 2 } })
  end
  for _, storage in ipairs(storages) do
    local rows = assert(Sqlite.rows(db, ("SELECT vector_block(id, v, '%s') FROM r"):format(storage)))
    local good = assert(rows[1]):blob(1)
    local info = assert(read_block(db, good))
    assert(info.dims == 2 and info.storage == storage and info:count() == 3, storage)
    -- Offsets of the sections for three rows.
    local inverse_at = 16 + 3 * 8
    local codes_at = (inverse_at + 3 * 4 + 7) // 8 * 8
    local function with(at: integer, bytes: string): string
      return good:sub(1, at) .. bytes .. good:sub(at + #bytes + 1)
    end
    local cases: mut {string: string} = {
      [with(0, "XBLK")] = "not a vector block",
      [good:sub(1, 15)] = "not a vector block",
      [with(4, "\3")] = "header is malformed",
      [with(5, "\1")] = "header is malformed",
      [with(7, "\1")] = "header is malformed",
      [with(8, string.pack("<I4", 0))] = "1 to 16000 dimensions",
      [with(8, string.pack("<I4", 16001))] = "1 to 16000 dimensions",
      [with(8, string.pack("<I4", 3))] = "length does not match",
      [with(12, string.pack("<I4", 4))] = "length does not match",
      [with(12, string.pack("<I4", 2))] = "length does not match",
      [with(12, string.pack("<I4", 4294967295))] = "length does not match",
      [good:sub(1, #good - 1)] = "length does not match",
      [good .. "\0"] = "length does not match",
      [with(inverse_at + 4, string.pack("<f", -1))] = "length that is not a number",
      [with(inverse_at, string.pack("<f", 0 / 0))] = "length that is not a number",
      [with(inverse_at + 8, string.pack("<f", math.huge))] = "length that is not a number",
    }
    if storage == "int8" then
      cases[with(codes_at, string.pack("<f", 0 / 0))] = "scale out of range"
      cases[with(codes_at + 12, string.pack("<f", -2))] = "scale out of range"
      -- A code of 127 would stand for a number that is not finite.
      cases[with(codes_at + 24, string.pack("<f", 3e38))] = "scale out of range"
      cases[with(codes_at + 24, string.pack("<f", math.huge))] = "scale out of range"
    end
    for blob, words in pairs(cases) do
      local why = search(blob)
      assert(why:find(words, 1, true) ~= nil, storage .. ": " .. words .. " vs " .. why)
      local held = Vector.corpus(2, { storage = storage })
      local ok, err = pcall(held.add_block, held, blob)
      assert(not ok and tostring(err):find(words, 1, true) ~= nil, storage .. ": " .. tostring(err))
      assert(read_block(db, blob) == nil)
    end
    assert(search("", 2):find("not a vector block", 1, true) ~= nil)
    refused(db, "SELECT id FROM vector_block_search('a block', ?1, 1, 'l2')", "is a blob", { { blob = query } })
    refused(db, "SELECT id FROM vector_block_search(1, ?1, 1, 'l2')", "is a blob", { { blob = query } })
    -- The arguments besides the block.
    local function ask(args: string): string
      return refusal(db, "SELECT id FROM vector_block_search(" .. args ..
          ") WHERE ?1 IS NOT NULL AND ?2 IS NOT NULL AND ?3 IS NOT NULL",
        { { blob = good }, { blob = query }, { blob = Vector.pack({ 1, 2, 3 }) } })
    end
    assert(ask("?1, ?3, 2, 'l2'"):find("dimensions are not the block's", 1, true) ~= nil)
    assert(ask("?1, x'0000c07f0000803f', 2, 'l2'"):find("finite numbers", 1, true) ~= nil, ask("?1, x'0000c07f0000803f', 2, 'l2'"))
    assert(ask("?1, 'a', 2, 'l2'"):find("starts with [", 1, true) ~= nil)
    assert(ask("?1, ?2, 0, 'l2'"):find("k is at least 1", 1, true) ~= nil)
    assert(ask("?1, ?2, -4, 'l2'"):find("k is at least 1", 1, true) ~= nil)
    assert(ask("?1, ?2, 2.5, 'l2'"):find("k is an integer", 1, true) ~= nil)
    assert(ask("?1, ?2, '2', 'l2'"):find("k is an integer", 1, true) ~= nil)
    assert(ask("?1, ?2, 2, 'euclid'"):find("a metric is", 1, true) ~= nil)
    assert(ask("?1, ?2, 2, 'L2'"):find("a metric is", 1, true) ~= nil)
    assert(ask("?1, ?2, 2, NULL"):find("a metric is", 1, true) ~= nil)
    assert(ask("?1, ?2, 2, 5"):find("a metric is", 1, true) ~= nil)
    -- Without k, or without the arguments at all, there is no plan.
    assert(ask("?1, ?2"):find("no query solution", 1, true) ~= nil)
    assert(ask("?1"):find("no query solution", 1, true) ~= nil)
  end
  local _, _ = db:close()
end

--- What `vector_block` refuses, by name.
local function test_vector_block_refuses_what_a_corpus_would()
  local db = assert(Sqlite.memory())
  local inf = string.pack("<f", math.huge)
  local nan = string.pack("<f", 0 / 0)
  assert(db:exec("CREATE TABLE r (id, v, s)"))
  local function block_of(rows: string): string
    assert(db:exec("DELETE FROM r"))
    assert(db:exec("INSERT INTO r VALUES " .. rows))
    return refusal(db, "SELECT vector_block(id, v) FROM r")
  end
  assert(block_of("(1, '[1,2]', NULL), (2, '[1,2,3]', NULL)"):find("different dimensions", 1, true) ~= nil)
  assert(block_of("('a', '[1,2]', NULL)"):find("wants an integer id", 1, true) ~= nil)
  assert(block_of("(1.5, '[1,2]', NULL)"):find("wants an integer id", 1, true) ~= nil)
  assert(block_of("(NULL, '[1,2]', NULL)"):find("wants an integer id", 1, true) ~= nil)
  assert(block_of("(1, 5, NULL)"):find("blob of floats or a text", 1, true) ~= nil)
  assert(block_of("(1, '[1,', NULL)"):find("finite numbers", 1, true) ~= nil)
  refused(db, "SELECT vector_block(1, ?1)", "finite numbers", { { blob = inf .. inf } })
  refused(db, "SELECT vector_block(1, ?1)", "finite numbers", { { blob = nan .. inf } })
  refused(db, "SELECT vector_block(1, ?1, 'f16')", "finite numbers", { { blob = nan .. inf } })
  refused(db, "SELECT vector_block(1, ?1, 'int8')", "finite numbers", { { blob = nan .. inf } })
  refused(db, "SELECT vector_block(1, '[65520, 1]', 'f16')", "under 65520")
  refused(db, "SELECT vector_block(1, '[-65520, 1]', 'f16')", "under 65520")
  assert(count_of(db, "SELECT vector_block(1, '[65519, 1]', 'f16') IS NOT NULL") == 1)
  assert(count_of(db, "SELECT vector_block(1, '[65520, 1]', 'f32') IS NOT NULL") == 1)
  assert(count_of(db, "SELECT vector_block(1, '[65520, 1]', 'int8') IS NOT NULL") == 1)
  for _, storage in ipairs({ "'bf16'", "NULL", "5", "'F32'", "''" }) do
    refused(db, "SELECT vector_block(1, '[1]', " .. storage .. ")", "storage is f32, f16 or int8")
  end
  -- One storage to a block: it is an argument of each row.
  assert(db:exec("DELETE FROM r"))
  assert(db:exec("INSERT INTO r VALUES (1, '[1,2]', 'f32'), (2, '[1,2]', 'int8')"))
  refused(db, "SELECT vector_block(id, v, s) FROM r", "one storage")
  -- A window is not an aggregate that can be run over one.
  assert(refusal(db, "SELECT vector_block(id, v) OVER () FROM r"):find("window", 1, true) ~= nil)
  -- Groups are separate blocks.
  assert(db:exec("DELETE FROM r"))
  assert(db:exec("INSERT INTO r VALUES (1, '[1,2]', 'f32'), (2, '[1,2,3]', 'f32')"))
  assert(count_of(db, "SELECT count(*) FROM (SELECT vector_block(id, v) FROM r GROUP BY id)") == 2)
  local _, _ = db:close()
end

--- A block stays inside SQLite's limit on a value.
local function test_a_block_may_not_pass_sqlites_length_limit()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (id INTEGER, v BLOB)"))
  for i = 1, 30 do
    assert(Sqlite.run(db, "INSERT INTO r VALUES (?1, ?2)", { { integer = i }, { blob = Vector.pack({ i, 1, 2 }) } }))
  end
  assert(count_of(db, "SELECT length(vector_block(id, v)) FROM r") == 16 + 30 * 8 + 30 * 4 + 30 * 12)
  db:limit("length", 300)
  refused(db, "SELECT vector_block(id, v) FROM r", "longer than SQLite allows")
  db:limit("length", 1000000)
  assert(count_of(db, "SELECT count(*) FROM (SELECT vector_block(id, v) FROM r GROUP BY id / 5)") == 7)
  local _, _ = db:close()
end

--- The layout is fixed, so a block made by one build is read by another.
local function test_the_layout_is_the_documented_one()
  local db = assert(Sqlite.memory())
  local rows = assert(Sqlite.rows(db, [[
    SELECT vector_block(id, v) FROM (SELECT 7 AS id, vector('[3, 4]') AS v UNION ALL SELECT -1, vector('[0, 0]'))
  ]]))
  local block = assert(rows[1]):blob(1)
  assert(#block == 16 + 16 + 8 + 16, tostring(#block))
  assert(block:sub(1, 4) == "VBLK" and block:byte(5) == 0 and block:sub(6, 8) == "\0\0\0")
  local dimensions, held = string.unpack("<I4I4", block, 9)
  assert(dimensions == 2 and held == 2)
  local first_id, second_id = string.unpack("<i8i8", block, 17)
  assert(first_id == 7 and second_id == -1)
  local first_inverse, second_inverse = string.unpack("<ff", block, 33)
  assert(first_inverse == string.unpack("<f", string.pack("<f", 1 / 5)) and second_inverse == 0)
  local a, b, c, d = string.unpack("<ffff", block, 41)
  assert(a == 3 and b == 4 and c == 0 and d == 0)
  local info = assert(read_block(db, block))
  assert(info.dims == 2 and info.storage == "f32" and info:count() == 2)
  local _, _ = db:close()
end

--- A corpus loaded from blocks is the corpus `load` makes from the rows,
--- in each storage: the same hits for every metric. (A first pass reads
--- the bits of the numbers stored, so it can keep other rows than the
--- f32 numbers of `load` do in an int8 corpus; see the next test.)
local function test_load_blocks_makes_the_corpus_load_makes()
  local dims = 13
  for _, storage in ipairs(storages) do
    local db = assert(Sqlite.memory())
    dataset(db, 200, dims, 17, storage, 4)
    local from_rows = assert(Vector.load(db, "SELECT id, embedding FROM chunks ORDER BY seq", nil, { storage = storage }))
    -- The storage defaults to the blocks'.
    local from_blocks = assert(Vector.load_blocks(db, "SELECT vectors FROM blocks ORDER BY tenant, n"))
    assert(from_blocks.storage == storage and from_blocks.dims == dims)
    assert(from_blocks:count() == 200)
    local next_number = stream(8)
    for _ = 1, 4 do
      local query = random_vector(next_number, dims)
      for _, metric in ipairs(metrics) do
        local want = assert(from_rows:search(query, 12, { metric = metric }))
        local got = assert(from_blocks:search(query, 12, { metric = metric }))
        assert(table.concat(got.ids, ",") == table.concat(want.ids, ","), storage .. " " .. metric)
        for i, score in ipairs(got.scores) do assert(score == want.scores[i]) end
        local fast = assert(from_blocks:search(query, 12, { metric = metric, candidates = 30 }))
        assert(#fast.ids == 12)
      end
    end
    -- More blocks add to it, and its bits keep working for a first pass.
    local more = assert(Vector.load_blocks(db, "SELECT vectors FROM blocks WHERE tenant = 'a'"))
    assert(more:count() == 66)
    local extra = assert(assert(Sqlite.rows(db, "SELECT vectors FROM blocks WHERE tenant = 'b' LIMIT 1"))[1]):blob(1)
    local held = assert(read_block(db, extra)):count()
    more:add_block(extra)
    assert(more:count() == 66 + held)
    assert(#assert(more:search(random_vector(stream(2), dims), 5, { candidates = 20 })).ids == 5)
    local _, _ = db:close()
  end
end

--- A block loads into a corpus of another storage as `add` would convert
--- its numbers; the ids and the shape survive.
local function test_load_blocks_converts_between_storages()
  local dims = 10
  local db = assert(Sqlite.memory())
  local vectors = dataset(db, 90, dims, 9, "f32", 6)
  local next_number = stream(1)
  local query = random_vector(next_number, dims)
  for _, into in ipairs(storages) do
    local through = assert(Vector.load_blocks(db, "SELECT vectors FROM blocks ORDER BY tenant, n", nil, { storage = into }))
    assert(through.storage == into and through:count() == 90)
    -- f32 blocks hold the numbers `add` was given: the same corpus.
    local direct = Vector.corpus(dims, { storage = into })
    local order = assert(Sqlite.rows(db, "SELECT id, embedding FROM chunks ORDER BY tenant, seq"))
    for _, row in ipairs(order) do direct:add(row:integer(1), row:blob(2)) end
    for _, metric in ipairs(metrics) do
      local want = assert(direct:search(query, 15, { metric = metric }))
      local got = assert(through:search(query, 15, { metric = metric }))
      assert(table.concat(got.ids, ",") == table.concat(want.ids, ","), into .. " " .. metric)
      for i, score in ipairs(got.scores) do assert(score == want.scores[i]) end
    end
    local fast = assert(through:search(query, 5, { candidates = 20 }))
    assert(#fast.ids == 5)
  end
  assert(#vectors == 90)
  -- Blocks of a smaller storage into the others: the numbers they stored,
  -- widened. An f32 corpus from f16 blocks scores as the f16 corpus does.
  for _, from in ipairs({ "f16", "int8" }) do
    assert(db:exec("DROP TABLE blocks"))
    assert(db:exec(("CREATE TABLE blocks AS SELECT vector_block(id, embedding, '%s') AS vectors FROM chunks GROUP BY (seq - 1) / 30"):format(from)))
    local held = assert(Vector.load_blocks(db, "SELECT vectors FROM blocks"))
    assert(held.storage == storage_of(from))
    for _, into in ipairs(storages) do
      local converted = assert(Vector.load_blocks(db, "SELECT vectors FROM blocks", nil, { storage = into }))
      assert(converted:count() == 90)
      for _, metric in ipairs(metrics) do
        local want = assert(held:search(query, 8, { metric = metric }))
        local got = assert(converted:search(query, 8, { metric = metric }))
        if into == held.storage then
          assert(table.concat(got.ids, ",") == table.concat(want.ids, ","))
          for i, score in ipairs(got.scores) do assert(score == want.scores[i]) end
        else
          -- Another rounding of the same numbers: the nearest rows agree.
          assert(got.ids[1] == want.ids[1] or got.ids[2] == want.ids[1], from .. " into " .. into .. " " .. metric)
        end
      end
    end
  end
  local _, _ = db:close()
end

local function test_load_blocks_refuses_what_is_not_a_block()
  local db = assert(Sqlite.memory())
  local _, why = Vector.load_blocks(db, "SELECT x'00' WHERE 0")
  assert(why:find("no rows", 1, true) ~= nil, why)
  _, why = Vector.load_blocks(db, "SELEC")
  assert(why:find("syntax error", 1, true) ~= nil, why)
  _, why = Vector.load_blocks(db, "SELECT 1")
  assert(why:find("row 1", 1, true) ~= nil and why:find("vector block", 1, true) ~= nil, why)
  _, why = Vector.load_blocks(db, "SELECT x'00'")
  assert(why:find("row 1: not a vector block", 1, true) ~= nil, why)
  _, why = Vector.load_blocks(db, "SELECT 1", nil, { storage = "f16" })
  assert(why:find("row 1", 1, true) ~= nil, why)
  assert(db:exec([[
    CREATE TABLE r (id INTEGER, v BLOB);
    INSERT INTO r VALUES (1, vector('[1,2]')), (2, vector('[1,2,3]')), (3, vector('[70000, 1]'));
    CREATE TABLE blocks (n INTEGER, b BLOB);
    INSERT INTO blocks SELECT id, vector_block(id, v) FROM r GROUP BY id;
  ]]))
  _, why = Vector.load_blocks(db, "SELECT b FROM blocks WHERE n < 3 ORDER BY n")
  assert(why:find("row 2: ", 1, true) ~= nil and why:find("dimensions are not the corpus's", 1, true) ~= nil, why)
  _, why = Vector.load_blocks(db, "SELECT b FROM blocks WHERE n IN (1, 3) ORDER BY n", nil, { storage = "f16" })
  assert(why:find("row 2: ", 1, true) ~= nil and why:find("under 65520", 1, true) ~= nil, why)
  local f32 = assert(Vector.load_blocks(db, "SELECT b FROM blocks WHERE n IN (1, 3) ORDER BY n"))
  assert(f32:count() == 2)
  -- A refused block adds nothing to a corpus that already holds rows.
  local f16 = assert(Vector.load_blocks(db, "SELECT b FROM blocks WHERE n = 1", nil, { storage = "f16" }))
  local big = assert(assert(Sqlite.rows(db, "SELECT b FROM blocks WHERE n = 3"))[1]):blob(1)
  local raised, err = pcall(f16.add_block, f16, big)
  assert(not raised and tostring(err):find("under 65520", 1, true) ~= nil, tostring(err))
  assert(f16:count() == 1)
  local _, _ = db:close()
end

--- A caught signal ends a statement scanning blocks with "interrupted",
--- as it ends a corpus search, and the next statement runs.
local function test_a_caught_signal_interrupts_a_search_over_blocks()
  local db = assert(Sqlite.memory())
  dataset(db, 50, 6, 10, "int8", 2)
  local query = random_vector(stream(3), 6)
  local before = packed_hits(db, query, 3, "l2")
  local guard = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGTERM))
  refused(db, SEARCH:format(""), "interrupted", { { blob = query }, { integer = 3 }, { text = "l2" } })
  assert(guard:take() == sys.SIGTERM)
  assert(guard:release() == sys.SIGTERM)
  local after = packed_hits(db, query, 3, "l2")
  assert(#after == 3 and assert(after[1]).id == assert(before[1]).id)
  local _, _ = db:close()
end

--- The aggregate and the function are innocuous like the others: a view
--- in a file may use them with `trusted_schema` off.
local function test_a_view_may_search_blocks()
  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE r (id INTEGER PRIMARY KEY, v BLOB);
    INSERT INTO r VALUES (1, vector('[1,0]')), (2, vector('[0,1]')), (3, vector('[0.9,0.1]'));
    CREATE VIEW packed AS SELECT vector_block(id, v, 'int8') AS vectors FROM r;
    CREATE VIEW nearest AS
      SELECT h.id AS id, h.distance AS distance FROM packed, vector_block_search(packed.vectors, vector('[1,0]'), 2, 'cosine') AS h;
  ]]))
  assert(count_of(db, "PRAGMA trusted_schema") == 0)
  local rows = assert(Sqlite.rows(db, "SELECT id FROM nearest ORDER BY distance, id"))
  assert(#rows == 2 and assert(rows[1]):integer(1) == 1 and assert(rows[2]):integer(1) == 3)
  local _, _ = db:close()
end

--- Rows too wide for a block of one row still pack, and the widest vector
--- may be searched.
local function test_widest_vectors_pack()
  local db = assert(Sqlite.memory())
  local wide = random_vector(stream(4), 16000)
  assert(db:exec("CREATE TABLE r (id INTEGER, v BLOB)"))
  assert(Sqlite.run(db, "INSERT INTO r VALUES (1, ?1), (2, ?2)", { { blob = wide }, { blob = random_vector(stream(5), 16000) } }))
  for _, storage in ipairs(storages) do
    local rows = assert(Sqlite.rows(db, ("SELECT vector_block(id, v, '%s') FROM r"):format(storage)))
    local block = assert(rows[1]):blob(1)
    local found = hits_of(db, "SELECT id, distance FROM vector_block_search(?1, ?2, 2, 'cosine')",
      { { blob = block }, { blob = wide } })
    assert(#found == 2 and found[1].id == 1 and found[1].distance < 1e-3, storage)
  end
  local _, _ = db:close()
end

--- A block whose numbers a corpus would refuse still searches (the search
--- does not read the numbers again) but loads nowhere, and an int8 block
--- whose sums are not its codes' loads into no int8 corpus, which scores
--- by them. A block that lies is not undefined behavior in a kernel.
local function test_a_block_a_corpus_would_refuse_loads_nowhere()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (id INTEGER, v BLOB)"))
  assert(db:exec("INSERT INTO r VALUES (1, x'0000803f00000040'), (2, x'0000404000008040'), (3, x'0000a0400000c040')"))
  local query = Vector.pack({ 1, 2 })
  local data_at = 56
  for _, storage in ipairs(storages) do
    local rows = assert(Sqlite.rows(db, ("SELECT vector_block(id, v, '%s') FROM r"):format(storage)))
    local good = assert(rows[1]):blob(1)
    local function with(at: integer, bytes: string): string
      return good:sub(1, at) .. bytes .. good:sub(at + #bytes + 1)
    end
    local into = Vector.corpus(2, { storage = storage })
    into:add_block(good)
    assert(into:count() == 3)
    local cases: mut {string: string} = {}
    local words = "finite numbers"
    if storage == "f32" then
      cases[with(data_at, string.pack("<f", 0 / 0))] = words
      cases[with(data_at + 4, string.pack("<f", -math.huge))] = words
    elseif storage == "f16" then
      -- Half precision's infinity, and a NaN.
      cases[with(data_at, "\0\124")] = words
      cases[with(data_at + 2, "\1\126")] = words
    else
      -- The sums the row headers hold: the sum of the codes, the sum of
      -- their squares, and a code outside 127.
      local codes_at = 56
      local data = 96
      cases[with(codes_at + 8, string.pack("<i4", 1000))] = "code sums"
      cases[with(codes_at + 4, string.pack("<I4", 7))] = "code sums"
      cases[with(data, "\128")] = "code sums"
      -- A code of -128 with the sums that are its own: still outside 127.
      local minus = with(data, "\128\0")
      minus = minus:sub(1, codes_at + 4) .. string.pack("<I4i4", 16384, -128) .. minus:sub(codes_at + 12 + 1)
      cases[minus] = "code sums"
    end
    for blob, why in pairs(cases) do
      local _, trouble = read_block(db, blob)
      assert(trouble:find(why, 1, true) ~= nil, storage .. ": " .. why .. " vs " .. trouble)
      local fresh = Vector.corpus(2, { storage = storage })
      Test.raises(function() fresh:add_block(blob) end, why)
      assert(fresh:count() == 0)
      -- The search takes it: its numbers are not read again.
      local found = hits_of(db, "SELECT id, distance FROM vector_block_search(?1, ?2, 3, 'l2')",
        { { blob = blob }, { blob = query } })
      assert(#found <= 3)
    end
    -- An int8 block into another storage is widened, so its sums are
    -- not read; and the block is a block.
    if storage == "int8" then
      for blob, _ in pairs(cases) do
        local widened = Vector.corpus(2)
        widened:add_block(blob)
        assert(widened:count() == 3)
      end
    end
  end
  local _, _ = db:close()
end

--- A corpus loaded from blocks answers a search with `candidates` as one
--- made by `add` does: its bit vectors are the signs of the numbers
--- stored, which for numbers a storage holds exactly are `add`'s.
local function test_a_corpus_from_blocks_takes_a_first_pass()
  local dims = 16
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE chunks (seq INTEGER PRIMARY KEY, id INTEGER, embedding BLOB)"))
  local next_number = stream(17)
  local vectors: mut {string} = {}
  for i = 1, 120 do
    local numbers: mut {number} = {}
    for d = 1, dims do
      -- A number of 127 makes int8's scale 1, so every integer is a code.
      if d == 1 + i % dims then
        numbers[#numbers + 1] = if i % 2 == 0 then 127 else -127 end
      else
        numbers[#numbers + 1] = math.floor(next_number() * 8)
      end
    end
    local packed = Vector.pack(numbers)
    vectors[#vectors + 1] = packed
    assert(Sqlite.run(db, "INSERT INTO chunks VALUES (?1, ?2, ?3)",
      { { integer = i }, { integer = 1000 + i }, { blob = packed } }))
  end
  local queries: mut {string} = {}
  for _ = 1, 3 do
    queries[#queries + 1] = random_vector(next_number, dims)
  end
  for _, from in ipairs(storages) do
    assert(db:exec("DROP TABLE IF EXISTS blocks"))
    assert(db:exec(("CREATE TABLE blocks AS SELECT (seq - 1) / 16 AS n, vector_block(id, embedding, '%s') AS vectors FROM chunks GROUP BY n"):format(from)))
    for _, into in ipairs(storages) do
      local direct = Vector.corpus(dims, { storage = into })
      for i, v in ipairs(vectors) do direct:add(1000 + i, v) end
      local through = assert(Vector.load_blocks(db, "SELECT vectors FROM blocks ORDER BY n", nil, { storage = into }))
      for _, query in ipairs(queries) do
        for _, candidates in ipairs({ 10, 40 }) do
          for _, metric in ipairs(metrics) do
            local want = assert(direct:search(query, 8, { metric = metric, candidates = candidates }))
            local got = assert(through:search(query, 8, { metric = metric, candidates = candidates }))
            assert(table.concat(got.ids, ",") == table.concat(want.ids, ","),
              ("%s blocks into %s %s candidates %d"):format(from, into, metric, candidates))
          end
        end
      end
    end
  end
  local _, _ = db:close()
end

--- Rows whose cosine rounds just past 1 are all at distance 0, so they
--- rank by id: the nearest k of a block are the first k of every row a
--- block answers.
local function test_cosine_rows_that_round_past_one_rank_by_id()
  local dims = 8
  local query = random_vector(stream(6), dims)
  local base = Vector.unpack(query)
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (seq INTEGER PRIMARY KEY, id INTEGER, v BLOB)"))
  for i = 1, 400 do
    local numbers: mut {number} = {}
    local scale = 0.3 + i * 0.37
    for d = 1, dims do
      numbers[d] = assert(base[d]) * scale
    end
    assert(Sqlite.run(db, "INSERT INTO r VALUES (?1, ?2, ?3)",
      { { integer = i }, { integer = 1000 - i }, { blob = Vector.pack(numbers) } }))
  end
  assert(db:exec("CREATE TABLE blocks AS SELECT vector_block(id, v) AS vectors FROM r GROUP BY (seq - 1) / 25"))
  local all = packed_hits(db, query, 400, "cosine")
  assert(#all == 400)
  for _, hit in ipairs(all) do
    assert(hit.distance >= 0 and hit.distance <= 2, "a cosine distance is from 0 to 2")
  end
  for i = 2, #all do
    local before, now = assert(all[i - 1]), assert(all[i])
    assert(before.distance < now.distance or (before.distance == now.distance and before.id < now.id))
  end
  for _, k in ipairs({ 1, 3, 10, 100 }) do
    local some = packed_hits(db, query, k, "cosine")
    for i, hit in ipairs(some) do
      assert(hit.id == assert(all[i]).id and hit.distance == assert(all[i]).distance, "k " .. tostring(k))
    end
  end
  local _, _ = db:close()
end

--- The limit on a value is met exactly: a block of its length is made, a
--- byte over is refused.
local function test_a_block_of_exactly_the_length_limit_is_made()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (id INTEGER, v BLOB)"))
  for i = 1, 30 do
    assert(Sqlite.run(db, "INSERT INTO r VALUES (?1, ?2)", { { integer = i }, { blob = Vector.pack({ i, 1, 2 }) } }))
  end
  local exact = 16 + 30 * 8 + 30 * 4 + 30 * 12
  db:limit("length", exact)
  assert(count_of(db, "SELECT length(vector_block(id, v)) FROM r") == exact)
  db:limit("length", exact - 1)
  refused(db, "SELECT vector_block(id, v) FROM r", "longer than SQLite allows")
  local _, _ = db:close()
end

--- The arguments read back, so a WHERE on one that the planner did not
--- take as the argument still holds.
local function test_the_arguments_read_back()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (id INTEGER, v BLOB)"))
  assert(db:exec("INSERT INTO r VALUES (1, x'0000803f00000040'), (2, x'0000404000008040'), (3, x'0000a0400000c040')"))
  local rows = assert(Sqlite.rows(db, "SELECT vector_block(id, v) FROM r"))
  local block = assert(rows[1]):blob(1)
  local function count(where: string): integer
    return #assert(Sqlite.rows(db,
      "SELECT id FROM vector_block_search(?1, ?2, 3, 'l2') " .. where,
      { { blob = block }, { blob = Vector.pack({ 1, 2 }) } }))
  end
  assert(count("") == 3)
  assert(count("WHERE k = 3 AND metric = 'l2'") == 3)
  assert(count("WHERE k > 2") == 3)
  assert(count("WHERE k > 3") == 0)
  assert(count("WHERE metric = 'cosine'") == 0)
  local _, _ = db:close()
end

--- Distances that round to the same double are ties, ranked by id: a
--- cosine so near 0 that 1 less it is exactly 1 is at the distance of one
--- twice as near, and the lower id wins in the block as it does outside.
local function test_cosine_distances_that_round_alike_rank_by_id()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (id INTEGER, v BLOB)"))
  assert(db:exec("INSERT INTO r VALUES (1, vector('[1e-30, 1]')), (2, vector('[2e-30, 1]')), (3, vector('[3e-30, 1]'))"))
  assert(db:exec("CREATE TABLE blocks AS SELECT vector_block(id, v) AS vectors FROM r"))
  local query = Vector.pack({ 1, 0 })
  for _, k in ipairs({ 1, 2, 3 }) do
    local found = packed_hits(db, query, k, "cosine")
    assert(#found == k and assert(found[1]).id == 1, "k " .. tostring(k))
    assert(assert(found[1]).distance == 1.0)
  end
  local per_row = hits_of(db, "SELECT id, cosine_distance(v, ?1) FROM r ORDER BY 2, 1 LIMIT 1", { { blob = query } })
  assert(#per_row == 1 and assert(per_row[1]).id == 1)
  local _, _ = db:close()
end

--- A second vector shorter than the first is refused as a longer one is,
--- not read past its end.
local function test_vector_block_refuses_a_shorter_vector()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (id INTEGER, v BLOB)"))
  assert(db:exec("INSERT INTO r VALUES (1, vector('[1,2,3,4]')), (2, vector('[1,2]'))"))
  refused(db, "SELECT vector_block(id, v) FROM r", "different dimensions")
  refused(db, "SELECT vector_block(id, v, 'int8') FROM r", "different dimensions")
  local _, _ = db:close()
end

--- The row numbers of the answer count from 0, and the tables that supply
--- the arguments come first: a CROSS JOIN the other way round has no plan
--- for the block, and answers nothing for a metric.
local function test_the_function_joins_after_the_tables_that_supply_it()
  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE r (id INTEGER, v BLOB);
    INSERT INTO r VALUES (1, vector('[1,0]')), (2, vector('[0,1]')), (3, vector('[0.9,0.1]'));
    CREATE TABLE b AS SELECT vector_block(id, v) AS vectors FROM r;
    CREATE TABLE m (name TEXT);
    INSERT INTO m VALUES ('l2');
  ]]))
  local rows = assert(Sqlite.rows(db,
    "SELECT h.rowid, h.id FROM b, vector_block_search(b.vectors, vector('[1,0]'), 3, 'l2') AS h ORDER BY 1"))
  assert(#rows == 3 and assert(rows[1]):integer(1) == 0 and assert(rows[3]):integer(1) == 2)
  assert(assert(rows[1]):integer(2) == 1 and assert(rows[2]):integer(2) == 3)
  refused(db, "SELECT h.id FROM vector_block_search(b.vectors, vector('[1,0]'), 3, 'l2') AS h CROSS JOIN b",
    "no query solution")
  local none = assert(Sqlite.rows(db, [[
    SELECT h.id FROM b CROSS JOIN vector_block_search(b.vectors, vector('[1,0]'), 3, m.name) AS h CROSS JOIN m
  ]]))
  assert(#none == 0)
  local some = assert(Sqlite.rows(db, [[
    SELECT h.id FROM b, m, vector_block_search(b.vectors, vector('[1,0]'), 3, m.name) AS h
  ]]))
  assert(#some == 3)
  local _, _ = db:close()
end

--- A corpus computes its lengths from the numbers it loads, not from the
--- block's: a block that lies about them loads into a corpus that ranks
--- by cosine as the honest block's does.
local function test_load_blocks_computes_the_lengths_itself()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE r (id INTEGER, v BLOB)"))
  assert(db:exec("INSERT INTO r VALUES (1, x'0000803f00000040'), (2, x'0000404000008040'), (3, x'0000a0400000c040')"))
  local query = Vector.pack({ 1, 2 })
  for _, storage in ipairs(storages) do
    local rows = assert(Sqlite.rows(db, ("SELECT vector_block(id, v, '%s') FROM r"):format(storage)))
    local good = assert(rows[1]):blob(1)
    -- The inverse lengths start after the header and the three ids.
    local lie = good:sub(1, 40) .. string.pack("<fff", 100, 0.5, 7) .. good:sub(53)
    local honest = assert(read_block(db, good))
    local lied = assert(read_block(db, lie))
    for _, metric in ipairs(metrics) do
      local want = assert(honest:search(query, 3, { metric = metric }))
      local got = assert(lied:search(query, 3, { metric = metric }))
      assert(table.concat(got.ids, ",") == table.concat(want.ids, ","), storage .. " " .. metric)
      for i, score in ipairs(got.scores) do assert(score == want.scores[i]) end
    end
  end
  local _, _ = db:close()
end
