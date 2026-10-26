--- Proves IVF search end to end: k-means centroids over clustered data,
--- rows stored under their nearest centroid in an indexed column, and a
--- query that scores only the rows of its nearest few clusters, measured
--- for recall against exact search.

local Rand = require("cosmic.rand")
local Sqlite = require("cosmic.sqlite")
local Vector = require("cosmic.vector")

local DIMS = 64
local CLUSTERS = 20
local PER = 100

local function noisy(source: Rand.Source, center: {number}, spread: number): string
  local out: mut {number} = {}
  for d = 1, #center do
    out[#out + 1] = assert(center[d]) + (source:float() * 2 - 1) * spread
  end
  return Vector.normalize(Vector.pack(out))
end

local function centers(source: Rand.Source): {{number}}
  local out: mut {{number}} = {}
  for _ = 1, CLUSTERS do
    local c: mut {number} = {}
    for _ = 1, DIMS do
      c[#c + 1] = source:float() * 2 - 1
    end
    out[#out + 1] = c
  end
  return out
end

local function dataset(): {string}
  local source = Rand.new(7)
  local points: mut {string} = {}
  for _, c in ipairs(centers(source)) do
    for _ = 1, PER do
      points[#points + 1] = noisy(source, c, 0.6)
    end
  end
  return points
end

local function corpus_of(points: {string}): Vector.Corpus
  local corpus = Vector.corpus(DIMS)
  for i, p in ipairs(points) do
    corpus:add(i, p)
  end
  return corpus
end

local function refusal(f: function()): string
  local ok, why = pcall(f)
  assert(not ok, "it should have raised")
  return tostring(why)
end

local function test_ivf_recall_against_exact_search()
  local points = dataset()
  local corpus = corpus_of(points)
  local centroids = Vector.kmeans(corpus, CLUSTERS)
  assert(#centroids == CLUSTERS)

  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE chunks (id INTEGER PRIMARY KEY, cluster INTEGER, embedding BLOB);
    CREATE INDEX chunks_cluster ON chunks (cluster);
  ]]))
  assert(db:exec("BEGIN"))
  for i, p in ipairs(points) do
    assert(Sqlite.run(db, "INSERT INTO chunks VALUES (?1, ?2, ?3)",
      { { integer = i }, { integer = Vector.nearest(centroids, p) }, { blob = p } }))
  end
  assert(db:exec("COMMIT"))

  local source = Rand.new(99)
  local probe_counts = { 1, 3 }
  local recalls: mut {integer: number} = {}
  local queries = 40
  for _, probes_n in ipairs(probe_counts) do
    local hit = 0
    for q = 1, queries do
      -- A query drawn from the data's own distribution: a stored point
      -- with fresh noise.
      local base = assert(Vector.unpack(assert(points[(q * 47) % #points + 1])))
      local query = noisy(source, base, 0.2)
      local exact = corpus:search(query, 10).ids
      local probes = Vector.nearest_n(centroids, query, probes_n)
      local v: Sqlite.Value = { integers = probes }
      local found = assert(Sqlite.map(db, [[
        SELECT id FROM chunks WHERE cluster IN carray(?2)
        ORDER BY inner_product(embedding, ?1) DESC, id LIMIT 10
      ]], { { blob = query }, v }, function(r: Sqlite.Row): integer
        return r:integer(1)
      end))
      local in_exact: mut {integer: boolean} = {}
      for _, id in ipairs(exact) do
        in_exact[id] = true
      end
      for _, id in ipairs(found) do
        if in_exact[id] == true then
          hit = hit + 1
        end
      end
    end
    recalls[probes_n] = hit / (queries * 10)
  end
  print("recall@10 with 1 probe", recalls[1], "with 3 probes", recalls[3])
  assert(assert(recalls[1]) >= 0.9, "1 probe recall " .. tostring(recalls[1]))
  assert(assert(recalls[3]) >= 0.99, "3 probe recall " .. tostring(recalls[3]))
  assert(db:close())
end

local function test_same_seed_same_centroids()
  local corpus = corpus_of(dataset())
  local a = Vector.kmeans(corpus, 8, { seed = 5 })
  local b = Vector.kmeans(corpus, 8, { seed = 5 })
  for i = 1, 8 do
    assert(a[i] == b[i], "centroid " .. tostring(i) .. " differs between runs")
  end
  local c = Vector.kmeans(corpus, 8, { seed = 6, iterations = 1 })
  local same = true
  for i = 1, 8 do
    if a[i] ~= c[i] then
      same = false
    end
  end
  assert(not same, "another seed should seed another run")
end

local function test_centroids_are_unit_length_and_cover_clusters()
  local corpus = corpus_of(dataset())
  local centroids = Vector.kmeans(corpus, CLUSTERS)
  local used: mut {integer: boolean} = {}
  for _, c in ipairs(centroids) do
    local n = 0.0
    for _, x in ipairs(Vector.unpack(c)) do
      n = n + x * x
    end
    assert(math.abs(n - 1) < 1e-4, "centroid length")
  end
  -- Well-separated clusters: the points of one true cluster agree.
  local points = dataset()
  for cluster = 0, CLUSTERS - 1 do
    used[Vector.nearest(centroids, assert(points[cluster * PER + 1]))] = true
  end
  local distinct = 0
  for _ in pairs(used) do
    distinct = distinct + 1
  end
  assert(distinct >= CLUSTERS - 2, "clusters found: " .. tostring(distinct))
end

local function test_k_bounds()
  local corpus = Vector.corpus(2)
  corpus:add(1, Vector.pack({ 1, 0 }))
  corpus:add(2, Vector.pack({ 0, 1 }))
  corpus:add(3, Vector.pack({ -1, 0 }))
  assert(#Vector.kmeans(corpus, 1) == 1)
  assert(#Vector.kmeans(corpus, 3) == 3)
  assert(refusal(function() Vector.kmeans(corpus, 0) end):find("k is from 1", 1, true))
  assert(refusal(function() Vector.kmeans(corpus, 4) end):find("k is from 1", 1, true))
end

local function test_nearest_and_nearest_n()
  local centroids = {
    Vector.pack({ 1, 0 }), Vector.pack({ 0, 1 }), Vector.pack({ -1, 0 }),
  }
  assert(Vector.nearest(centroids, Vector.pack({ 0.9, 0.1 })) == 1)
  assert(Vector.nearest(centroids, Vector.pack({ -0.2, 0.8 })) == 2)
  local two = Vector.nearest_n(centroids, Vector.pack({ 0.2, 0.9 }), 2)
  assert(#two == 2 and two[1] == 2 and two[2] == 1)
  assert(#Vector.nearest_n(centroids, Vector.pack({ 0.2, 0.9 }), 10) == 3)
  assert(refusal(function() Vector.nearest_n(centroids, Vector.pack({ 1, 0, 0 }), 1) end)
    :find("centroid", 1, true))
  assert(refusal(function() Vector.nearest_n(centroids, Vector.pack({ 1, 0 }), 0) end)
    :find("at least 1", 1, true))
end
