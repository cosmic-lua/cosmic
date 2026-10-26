--- Proves the in-memory corpus of [`cosmic.vector`]: packing, agreement
--- with the SQL vector functions on the same data, the order of ties,
--- the binary first pass finding the true neighbors of clustered data,
--- the `allow` filter, and the refusals.

local Sqlite = require("cosmic.sqlite")
local Vector = require("cosmic.vector")

local function close_to(a: number, b: number): boolean
  return math.abs(a - b) < 1e-4
end

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

local function random_vector(next_number: function(): number, dims: integer): {number}
  local out: mut {number} = {}
  for _ = 1, dims do
    out[#out + 1] = next_number()
  end
  return out
end

local function refusal(f: function()): string
  local ok, why = pcall(f)
  assert(not ok, "it should have raised")
  return tostring(why)
end

local function test_pack_unpack_and_json_round_trip()
  local packed = Vector.pack({ 1, 2.5, -3 })
  assert(#packed == 12 and packed == string.pack("<fff", 1, 2.5, -3))
  local back = Vector.unpack(packed)
  assert(#back == 3 and back[1] == 1 and back[2] == 2.5 and back[3] == -3)
  assert(Vector.from_json(" [1, 2.5, -3] ") == packed)
  local none, why = Vector.from_json("[1, oops]")
  assert(none == nil and why:find("finite numbers", 1, true) ~= nil, why)
  local unit = Vector.unpack(Vector.normalize(Vector.pack({ 3, 4 })))
  assert(close_to(assert(unit[1]), 0.6) and close_to(assert(unit[2]), 0.8))
  assert(Vector.normalize(Vector.pack({ 0, 0 })) == Vector.pack({ 0, 0 }))
end

-- The seven nearest by the SQL function `order` and by the corpus agree in
-- id and, once `score` turns the SQL value into the corpus's, in score.
local function agree(db: Sqlite.Handle, corpus: Vector.Corpus, q: string, metric: Vector.Metric,
    order: string, score: function(number): number)
  local param: Sqlite.Value = { blob = q }
  local expected = assert(Sqlite.map(db,
    "SELECT id, " .. order .. " FROM chunks ORDER BY 2, id LIMIT 7", { param },
    function(r: Sqlite.Row): {number}
      return { r:integer(1), r:number(2) }
    end))
  local hits = corpus:search(q, 7, { metric = metric })
  assert(#hits.ids == 7 and #hits.scores == 7)
  for i = 1, 7 do
    local want = assert(expected[i])
    assert(hits.ids[i] == want[1], metric .. " rank " .. tostring(i))
    assert(close_to(assert(hits.scores[i]), score(assert(want[2]))), metric .. " score " .. tostring(i))
  end
end

local function test_search_agrees_with_the_sql_functions()
  local dims = 37 -- crosses the kernels' eight lanes and leaves a tail
  local next_number = stream(7)
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE chunks (id INTEGER PRIMARY KEY, embedding BLOB)"))
  local corpus = Vector.corpus(dims)
  for id = 1, 300 do
    local v = Vector.pack(random_vector(next_number, dims))
    corpus:add(id, v)
    assert(Sqlite.run(db, "INSERT INTO chunks VALUES (?1, ?2)", { { integer = id }, { blob = v } }))
  end
  assert(corpus:count() == 300)
  local q = Vector.pack(random_vector(next_number, dims))
  agree(db, corpus, q, "inner_product", "-inner_product(embedding, ?1)", function(x: number): number
    return -x
  end)
  agree(db, corpus, q, "cosine", "cosine_distance(embedding, ?1)", function(x: number): number
    return 1 - x
  end)
  agree(db, corpus, q, "l2", "l2_distance(embedding, ?1)", function(x: number): number
    return x
  end)
  assert(db:close())
end

local function test_load_reads_a_query()
  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE chunks (id INTEGER PRIMARY KEY, tenant TEXT, embedding BLOB);
    INSERT INTO chunks VALUES
      (10, 'a', l2_normalize('[1, 0]')), (20, 'b', l2_normalize('[0, 1]')),
      (30, 'a', l2_normalize('[1, 1]'));
  ]]))
  local corpus = assert(Vector.load(db, "SELECT id, embedding FROM chunks WHERE tenant = ?1",
    { { text = "a" } }))
  assert(corpus:count() == 2 and corpus.dims == 2)
  local hits = corpus:search(Vector.pack({ 1, 0 }), 5)
  assert(#hits.ids == 2 and hits.ids[1] == 10 and hits.ids[2] == 30)
  local bad, why = Vector.load(db, "SELECT id, tenant FROM chunks")
  assert(bad == nil and why:find("vector blob", 1, true) ~= nil, why)
  local missing, trouble = Vector.load(db, "SELECT id, embedding FROM nowhere")
  assert(missing == nil and trouble:find("nowhere", 1, true) ~= nil, trouble)
  local ragged, rwhy = Vector.load(db,
    "SELECT id, embedding FROM chunks UNION ALL SELECT 99, x'00000000'")
  assert(ragged == nil and rwhy:find("row 99", 1, true) ~= nil, rwhy)
  assert(db:close())
end

local function test_ties_go_to_the_lower_id()
  local corpus = Vector.corpus(2)
  local same = Vector.pack({ 1, 0 })
  for _, id in ipairs({ 50, 7, 31, 12, 99 }) do
    corpus:add(id, same)
  end
  corpus:add(5, Vector.pack({ 0, 1 }))
  local hits = corpus:search(same, 3)
  assert(#hits.ids == 3 and hits.ids[1] == 7 and hits.ids[2] == 12 and hits.ids[3] == 31)
  local all = corpus:search(same, 100)
  assert(#all.ids == 6 and all.ids[6] == 5)
end

local function clustered(dims: integer, clusters: integer, per: integer): Vector.Corpus, {{number}}
  local next_number = stream(11)
  local corpus = Vector.corpus(dims)
  local centers: mut {{number}} = {}
  for _ = 1, clusters do
    local center: mut {number} = {}
    for _ = 1, dims do
      center[#center + 1] = if next_number() > 0 then 1.0 else -1.0 end
    end
    centers[#centers + 1] = center
  end
  local id = 0
  for _, center in ipairs(centers) do
    for _ = 1, per do
      local v: mut {number} = {}
      for d = 1, dims do
        v[#v + 1] = assert(center[d]) + 0.3 * next_number()
      end
      id = id + 1
      corpus:add(id, Vector.normalize(Vector.pack(v)))
    end
  end
  return corpus, centers
end

local function test_candidates_recall_the_exact_neighbors_of_clustered_data()
  local corpus, centers = clustered(64, 8, 50)
  for c = 1, 8 do
    local q = Vector.normalize(Vector.pack(assert(centers[c])))
    local exact = corpus:search(q, 10)
    local fast = corpus:search(q, 10, { candidates = 100 })
    assert(#fast.ids == 10)
    for i = 1, 10 do
      assert(fast.ids[i] == exact.ids[i], "cluster " .. tostring(c) .. " rank " .. tostring(i))
    end
    -- A pass as wide as the corpus is the exact search.
    local wide = corpus:search(q, 10, { candidates = 400 })
    assert(wide.ids[1] == exact.ids[1])
  end
end

local function test_allow_restricts_the_ids()
  local corpus = Vector.corpus(2)
  for id = 1, 20 do
    corpus:add(id, Vector.pack({ id, 1 }))
  end
  local q = Vector.pack({ 1, 0 })
  local hits = corpus:search(q, 3, { allow = { 4, 8, 15, 99 } })
  assert(#hits.ids == 3 and hits.ids[1] == 15 and hits.ids[2] == 8 and hits.ids[3] == 4)
  local few = corpus:search(q, 3, { allow = { 2 } })
  assert(#few.ids == 1 and few.ids[1] == 2)
  assert(#corpus:search(q, 3, { allow = {} }).ids == 0)
  -- With a binary first pass the filter applies before the pass.
  local both = corpus:search(q, 2, { allow = { 1, 2, 3, 4, 5 }, candidates = 3 })
  assert(#both.ids == 2 and assert(both.ids[1]) <= 5 and assert(both.ids[2]) <= 5)
end

local function test_shape_errors_raise()
  local corpus = Vector.corpus(3)
  corpus:add(1, Vector.pack({ 1, 2, 3 }))
  local short = Vector.pack({ 1, 2 })
  assert(refusal(function() corpus:add(2, short) end):find("dimensions", 1, true) ~= nil)
  assert(refusal(function() corpus:search(short, 1) end):find("dimensions", 1, true) ~= nil)
  local q = Vector.pack({ 1, 2, 3 })
  assert(refusal(function() corpus:search(q, 0) end):find("k is at least 1", 1, true) ~= nil)
  assert(refusal(function() corpus:search(q, 1, { candidates = 0 }) end):find("candidates", 1, true) ~= nil)
  assert(refusal(function() Vector.corpus(0) end):find("dimensions", 1, true) ~= nil)
  assert(refusal(function() Vector.pack({ 1 / 0 }) end):find("finite", 1, true) ~= nil)
  assert(refusal(function() Vector.unpack("abc") end):find("floats", 1, true) ~= nil)
  assert(corpus:count() == 1)
end
