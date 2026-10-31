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
  local centroids = assert(Vector.kmeans(corpus, CLUSTERS))
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
      local exact = assert(corpus:search(query, 10)).ids
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
  local a = assert(Vector.kmeans(corpus, 8, { seed = 5 }))
  local b = assert(Vector.kmeans(corpus, 8, { seed = 5 }))
  for i = 1, 8 do
    assert(a[i] == b[i], "centroid " .. tostring(i) .. " differs between runs")
  end
  -- Same iterations, so only the seed differs.
  local one = assert(Vector.kmeans(corpus, 8, { seed = 5, iterations = 1 }))
  local other = assert(Vector.kmeans(corpus, 8, { seed = 6, iterations = 1 }))
  local same = true
  for i = 1, 8 do
    if one[i] ~= other[i] then
      same = false
    end
  end
  assert(not same, "another seed should seed another run")
end

local function test_centroids_are_unit_length_and_cover_clusters()
  local corpus = corpus_of(dataset())
  local centroids = assert(Vector.kmeans(corpus, CLUSTERS))
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
  assert(#assert(Vector.kmeans(corpus, 1)) == 1)
  assert(#assert(Vector.kmeans(corpus, 3)) == 3)
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

-- How well the clusters k-means found match the true ones: of the true
-- clusters, how many have 90% of their points under one centroid, and
-- how many different centroids those are. Random rows as centroids
-- leave true clusters sharing one, so the second count falls short.
local function purity(centroids: {string}, points: {string}): integer, integer
  local well = 0
  local seen: mut {integer: boolean} = {}
  for cluster = 0, CLUSTERS - 1 do
    local tally: mut {integer: integer} = {}
    for i = 1, PER do
      local at = Vector.nearest(centroids, assert(points[cluster * PER + i]))
      tally[at] = (tally[at] or 0) + 1
    end
    local top, owner = 0, 0
    for at, n in pairs(tally) do
      if n > top then
        top, owner = n, at
      end
    end
    if top >= PER * 0.9 then
      well = well + 1
      seen[owner] = true
    end
  end
  local distinct = 0
  for _ in pairs(seen) do
    distinct = distinct + 1
  end
  return well, distinct
end

-- The mean inner product of each point with its nearest centroid.
local function fit(centroids: {string}, points: {string}): number
  local total = 0.0
  for _, p in ipairs(points) do
    local q = assert(Vector.unpack(p))
    local c = assert(Vector.unpack(assert(centroids[Vector.nearest(centroids, p)])))
    for d, x in ipairs(c) do
      total = total + x * assert(q[d])
    end
  end
  return total / #points
end

local function test_kmeans_recovers_the_true_clusters()
  local points = dataset()
  local centroids = assert(Vector.kmeans(corpus_of(points), CLUSTERS))
  -- Twenty rows of the data themselves, spread through it, as centroids:
  -- what k-means would answer if it did nothing.
  local rows: mut {string} = {}
  for i = 1, CLUSTERS do
    rows[#rows + 1] = assert(points[(i * 97) % #points + 1])
  end
  local gained = fit(centroids, points) - fit(rows, points)
  assert(gained > 0.05, "k-means should fit better than rows: " .. tostring(gained))
  local well, distinct = purity(centroids, points)
  assert(well >= CLUSTERS - 2, "pure clusters: " .. tostring(well))
  assert(distinct >= 15, "distinct owners: " .. tostring(distinct))
end

local function test_zero_vectors_are_no_cluster()
  local points = dataset()
  local corpus = corpus_of(points)
  local zero = Vector.pack((function(): {number}
    local z: mut {number} = {}
    for _ = 1, DIMS do
      z[#z + 1] = 0
    end
    return z
  end)())
  -- A tenth as many zero rows again, spread through the ids.
  for i = 1, #points // 10 do
    corpus:add(100000 + i, zero)
  end
  local centroids = assert(Vector.kmeans(corpus, CLUSTERS))
  for _, c in ipairs(centroids) do
    local n = 0.0
    for _, x in ipairs(Vector.unpack(c)) do
      n = n + x * x
    end
    assert(math.abs(n - 1) < 1e-4, "centroid length with zero rows present")
  end
  local well, distinct = purity(centroids, points)
  assert(well >= CLUSTERS - 2, "pure clusters: " .. tostring(well))
  assert(distinct >= 15, "distinct owners: " .. tostring(distinct))

  local only = Vector.corpus(2)
  only:add(1, Vector.pack({ 0, 0 }))
  only:add(2, Vector.pack({ 0, 0 }))
  assert(refusal(function() Vector.kmeans(only, 1) end):find("direction", 1, true))
end

local function test_a_vector_too_short_to_scale_has_no_direction()
  -- Its length is under 1/FLT_MAX, so the inverse would be infinite.
  local corpus = Vector.corpus(2)
  corpus:add(1, Vector.pack({ 1e-39, 1e-39 }))
  corpus:add(2, Vector.pack({ 1, 0 }))
  local c = Vector.unpack(assert(assert(Vector.kmeans(corpus, 1))[1]))
  assert(math.abs(assert(c[1]) - 1) < 1e-6 and math.abs(assert(c[2])) < 1e-6,
    "the centroid is the one vector with a direction")
end

local function test_k_equal_to_count_with_duplicates()
  local corpus = Vector.corpus(2)
  for i = 1, 4 do
    corpus:add(i, Vector.pack({ 1, 0 }))
  end
  local centroids = assert(Vector.kmeans(corpus, 4))
  assert(#centroids == 4)
  for _, c in ipairs(centroids) do
    assert(c == Vector.pack({ 1, 0 }))
  end
end

local function test_iterations_under_one_raise()
  local corpus = corpus_of(dataset())
  assert(refusal(function() Vector.kmeans(corpus, 3, { iterations = 0 }) end)
      :find("iterations is at least 1", 1, true))
end

local function test_nearest_refusals()
  local one = Vector.pack({ 1, 0 })
  assert(refusal(function() Vector.nearest({}, one) end):find("no centroids", 1, true))
  -- Tables the type checker would refuse, built by a chunk that is not
  -- checked: a number among the centroids, and a number whose text is
  -- 4 bytes long standing in for a one-dimension centroid.
  local build = assert(load("local nearest, v, w = ...; return nearest({ v, 5 }, v), nearest({ 1234 }, w)"))
  assert(refusal(function() build(Vector.nearest, one, Vector.pack({ 1 })) end)
      :find("centroid", 1, true))
  local alone = assert(load("local nearest, w = ...; return nearest({ 1234 }, w)"))
  assert(refusal(function() alone(Vector.nearest, Vector.pack({ 1 })) end)
      :find("centroid", 1, true))
  local infinite = string.pack("<f", math.huge)
  assert(refusal(function() Vector.nearest({ Vector.pack({ 1 }) }, infinite) end)
      :find("finite", 1, true))
  assert(refusal(function() Vector.nearest({ infinite }, Vector.pack({ 1 })) end)
      :find("finite", 1, true))
end

local function test_nearest_survives_scores_that_are_not_finite()
  local big = Vector.pack({ 3e38, 3e38 })
  -- Every product is -infinity.
  local low = Vector.pack({ -3e38, -3e38 })
  assert(Vector.nearest({ big, big }, low) == 1)
  local all = Vector.nearest_n({ big, big, big }, low, 3)
  assert(#all == 3 and all[1] == 1 and all[2] == 2 and all[3] == 3)
  -- Infinity minus infinity is not a number; it ranks last.
  local mixed = Vector.pack({ 3e38, -3e38 })
  local ranked = Vector.nearest_n({ big, Vector.pack({ 1, 1 }) }, mixed, 2)
  assert(ranked[1] == 2 and ranked[2] == 1)
end

local function test_nearest_is_the_best_inner_product_ties_to_the_lower()
  local points = dataset()
  local found = assert(Vector.kmeans(corpus_of(points), 6))
  local centroids: mut {string} = {}
  for _, c in ipairs(found) do
    centroids[#centroids + 1] = c
  end
  -- A repeated centroid, so a tie is certain.
  centroids[#centroids + 1] = assert(found[2])
  for i = 1, #points, 37 do
    local p = assert(points[i])
    local q = assert(Vector.unpack(p))
    local best, top = 0, -math.huge
    for j, c in ipairs(centroids) do
      local sum = 0.0
      for d, x in ipairs(assert(Vector.unpack(c))) do
        sum = sum + x * assert(q[d])
      end
      if sum > top + 1e-6 then
        best, top = j, sum
      end
    end
    assert(Vector.nearest(centroids, p) == best, "point " .. tostring(i))
    assert(assert(Vector.nearest_n(centroids, p, 7)[1]) == best)
  end
  assert(Vector.nearest({ assert(centroids[2]), assert(centroids[2]) }, assert(points[1])) ==
      1)
end
