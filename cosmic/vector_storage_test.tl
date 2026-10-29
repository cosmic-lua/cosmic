--- Proves the storages of the corpus of [`cosmic.vector`], `"f16"` and
--- `"int8"` beside `"f32"`: what each refuses and rounds, that the numbers
--- a storage holds exactly score exactly as f32's, that the neighbors it
--- finds are f32's on a seeded corpus, and that every search option
--- (metrics, ties, `allow`, `candidates`), growth, k-means and
--- interruption behave alike in each.

local testing = require("cosmic.internal.testing")
local Signal = require("cosmic.signal")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local Vector = require("cosmic.vector")

local storages: {Vector.Storage} = { "f32", "f16", "int8" }
local metrics: {Vector.Metric} = { "inner_product", "cosine", "l2" }
local smaller: {Vector.Storage} = { "f16", "int8" }
local widened: {Vector.Storage} = { "f32", "int8" }

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

local function random_vector(next_number: function(): number, dims: integer): mut {number}
  local out: mut {number} = {}
  for _ = 1, dims do
    out[#out + 1] = next_number()
  end
  return out
end

local function unit(next_number: function(): number, dims: integer): string
  return Vector.normalize(Vector.pack(random_vector(next_number, dims)))
end

local function refusal(f: function()): string
  local ok, why = pcall(f)
  assert(not ok, "it should have raised")
  return tostring(why)
end

local function overlap(a: {integer}, b: {integer}): integer
  local seen: mut {integer: boolean} = {}
  for _, id in ipairs(a) do
    seen[id] = true
  end
  local both = 0
  for _, id in ipairs(b) do
    if seen[id] == true then both = both + 1 end
  end
  return both
end

local function sorted(ids: {integer}): string
  local copy: mut {integer} = {}
  for _, id in ipairs(ids) do
    copy[#copy + 1] = id
  end
  table.sort(copy)
  return table.concat(copy, ",")
end

local function test_a_corpus_is_f32_unless_told_and_refuses_another_storage()
  assert(Vector.corpus(4).storage == "f32")
  assert(Vector.corpus(4, {}).storage == "f32")
  for _, storage in ipairs(storages) do
    assert(Vector.corpus(4, { storage = storage }).storage == storage)
  end
  local chunk = assert(load([[
    local Vector, storage = ...
    return pcall(Vector.corpus, 4, { storage = storage })
  ]], "=storage_entry", "t"))
  for _, word in ipairs({ "bf16", "F16", "int4", "", "f32 " }) do
    local ok, why = chunk(Vector, word)
    assert(ok == false and tostring(why):find("storage", 1, true) ~= nil, word)
  end
  local ok, why = chunk(Vector, 16)
  assert(ok == false and tostring(why):find("storage", 1, true) ~= nil, tostring(why))
end

local function test_f16_refuses_numbers_it_cannot_hold_and_rounds_to_even()
  local corpus = Vector.corpus(2, { storage = "f16" })
  local x = Vector.pack({ 1, 0 })
  -- 65504 is the largest half; below 65520 rounds down to it.
  corpus:add(1, Vector.pack({ 65519.5, 1 }))
  assert(assert(corpus:search(x, 1)).scores[1] == 65504)
  for _, big in ipairs({ 65520, -65520, 1e10, 3e38, -3e38 }) do
    local why = refusal(function() corpus:add(2, Vector.pack({ 1, big })) end)
    assert(why:find("half", 1, true) ~= nil, why)
    assert(refusal(function() corpus:add(2, Vector.pack({ big, 1 })) end):find("half", 1, true) ~= nil)
  end
  assert(corpus:count() == 1)
  -- 2049 and 2051 are ties between neighbors of a step of 2.
  corpus:add(3, Vector.pack({ 2049, 0 }))
  corpus:add(4, Vector.pack({ 2051, 0 }))
  corpus:add(5, Vector.pack({ -2049, 0 }))
  local hits = assert(corpus:search(x, 5))
  local by_id: mut {integer: number} = {}
  for i, id in ipairs(hits.ids) do
    by_id[id] = assert(hits.scores[i])
  end
  assert(by_id[3] == 2048 and by_id[4] == 2052 and by_id[5] == -2048)
  -- A number under half of the smallest subnormal half, 2^-24, is zero.
  local small = Vector.corpus(1, { storage = "f16" })
  small:add(1, Vector.pack({ 1e-8 }))
  small:add(2, Vector.pack({ 6e-8 }))
  local tiny = assert(small:search(Vector.pack({ 1 }), 2))
  assert(tiny.ids[1] == 2 and tiny.scores[2] == 0)
  -- The other storages hold what f16 cannot, and a query may be any f32.
  for _, storage in ipairs(widened) do
    local wide = Vector.corpus(2, { storage = storage })
    wide:add(1, Vector.pack({ 3e38, -3e38 }))
    wide:add(2, Vector.pack({ 1, 1 }))
    assert(assert(wide:search(Vector.pack({ 3e38, -3e38 }), 1, { metric = "cosine" })).ids[1] == 1)
  end
  assert(assert(corpus:search(Vector.pack({ 1e30, 0 }), 1)).ids[1] == 1)
end

-- Numbers a half holds exactly, in sums a float holds exactly, so that the
-- f16 corpus must answer to the bit as the f32 corpus does.
local function quarters(next_number: function(): number, dims: integer): string
  local out: mut {number} = {}
  for _ = 1, dims do
    out[#out + 1] = math.floor(next_number() * 8) / 4
  end
  return Vector.pack(out)
end

local function test_f16_scores_as_f32_does_for_numbers_a_half_holds()
  local dims = 37 -- crosses the kernels' eight lanes and leaves a tail
  local next_number = stream(3)
  local f32 = Vector.corpus(dims)
  local f16 = Vector.corpus(dims, { storage = "f16" })
  for id = 1, 150 do
    local v = quarters(next_number, dims)
    f32:add(id, v)
    f16:add(id, v)
  end
  for _ = 1, 5 do
    local q = quarters(next_number, dims)
    for _, metric in ipairs(metrics) do
      local want = assert(f32:search(q, 12, { metric = metric }))
      local got = assert(f16:search(q, 12, { metric = metric }))
      assert(table.concat(got.ids, ",") == table.concat(want.ids, ","), metric)
      for i = 1, 12 do
        assert(got.scores[i] == want.scores[i], metric .. " " .. tostring(i))
      end
    end
  end
end

-- Whole numbers with a 127 in each vector have the scale 1, so their codes
-- are the numbers and the int8 corpus must answer as the f32 corpus does.
local function whole(next_number: function(): number, dims: integer, sign: integer): string
  local out: mut {number} = {}
  for _ = 1, dims do
    out[#out + 1] = math.floor(next_number() * 127)
  end
  out[1] = 127 * sign
  return Vector.pack(out)
end

local whole_sums: {Vector.Metric} = { "inner_product", "l2" }

local function test_int8_scores_as_f32_does_for_codes_that_are_the_numbers()
  local dims = 37
  local next_number = stream(5)
  local f32 = Vector.corpus(dims)
  local int8 = Vector.corpus(dims, { storage = "int8" })
  for id = 1, 150 do
    local v = whole(next_number, dims, if id % 2 == 0 then 1 else -1 end)
    f32:add(id, v)
    int8:add(id, v)
  end
  for _ = 1, 5 do
    local q = whole(next_number, dims, 1)
    for _, metric in ipairs(whole_sums) do
      local want = assert(f32:search(q, 12, { metric = metric }))
      local got = assert(int8:search(q, 12, { metric = metric }))
      assert(table.concat(got.ids, ",") == table.concat(want.ids, ","), metric)
      for i = 1, 12 do
        assert(got.scores[i] == want.scores[i], metric .. " " .. tostring(i))
      end
    end
    local want = assert(f32:search(q, 12, { metric = "cosine" }))
    local got = assert(int8:search(q, 12, { metric = "cosine" }))
    for i = 1, 12 do
      assert(math.abs(assert(got.scores[i]) - assert(want.scores[i])) < 1e-6)
    end
  end
end

local function test_int8_rounds_to_even_and_scales_each_vector_by_itself()
  -- 62.5 over the scale 1 is a tie: the even code 62 is stored, so the
  -- product with a query of codes (0, 127) is 62 * 127.
  local ties = Vector.corpus(2, { storage = "int8" })
  ties:add(1, Vector.pack({ 127, 62.5 }))
  ties:add(2, Vector.pack({ 127, 63.5 }))
  local hits = assert(ties:search(Vector.pack({ 0, 127 }), 2))
  assert(hits.ids[1] == 2 and hits.scores[1] == 64 * 127 and hits.scores[2] == 62 * 127)

  -- A vector and its multiples have the same codes: only the scale differs.
  local next_number = stream(8)
  local base = random_vector(next_number, 48)
  local corpus = Vector.corpus(48, { storage = "int8" })
  local function scaled(factor: number): string
    local out: mut {number} = {}
    for _, x in ipairs(base) do
      out[#out + 1] = x * factor
    end
    return Vector.pack(out)
  end
  corpus:add(1, scaled(1))
  corpus:add(2, scaled(1000))
  corpus:add(3, scaled(0.001))
  corpus:add(4, Vector.pack(random_vector(next_number, 48)))
  local cosine = assert(corpus:search(scaled(1), 3, { metric = "cosine" }))
  for i = 1, 3 do
    assert(math.abs(assert(cosine.scores[i]) - 1) < 1e-6, tostring(cosine.scores[i]))
  end
  local product = assert(corpus:search(scaled(1), 4, { metric = "inner_product" }))
  local score_of: mut {integer: number} = {}
  for i, id in ipairs(product.ids) do
    score_of[id] = assert(product.scores[i])
  end
  assert(math.abs(assert(score_of[2]) / assert(score_of[1]) - 1000) < 1e-2)
  assert(math.abs(assert(score_of[3]) / assert(score_of[1]) - 0.001) < 1e-8)

  -- A vector too small to scale has no direction, as a zero vector has not.
  local small = Vector.corpus(2, { storage = "int8" })
  small:add(1, Vector.pack({ 1e-37, 2e-37 }))
  small:add(2, Vector.pack({ 1, 2 }))
  local ranked = assert(small:search(Vector.pack({ 1, 2 }), 2, { metric = "cosine" }))
  assert(ranked.ids[1] == 2 and ranked.ids[2] == 1 and ranked.scores[2] == -math.huge)
  assert(assert(small:search(Vector.pack({ 1, 2 }), 2)).scores[2] == 0)
end

-- Embeddings in clusters, as a model's are: a vector is the center of its
-- cluster and noise of the same size, and a query is another of its
-- cluster. Uniform noise alone has no neighbors worth recalling.
local function embeddings(dims: integer, rows: integer, clusters: integer, queries: integer):
    {string}, {string}
  local next_number = stream(dims)
  local centers: mut {{number}} = {}
  for _ = 1, clusters do
    local center: mut {number} = {}
    for _ = 1, dims do
      center[#center + 1] = next_number() + next_number()
    end
    centers[#centers + 1] = center
  end
  local function around(center: {number}): string
    local t: mut {number} = {}
    for d = 1, dims do
      t[#t + 1] = assert(center[d]) + next_number() + next_number()
    end
    return Vector.normalize(Vector.pack(t))
  end
  local blobs: mut {string} = {}
  for i = 1, rows do
    blobs[#blobs + 1] = around(assert(centers[i % clusters + 1]))
  end
  local asked: mut {string} = {}
  for i = 1, queries do
    asked[#asked + 1] = around(assert(centers[i * 7 % clusters + 1]))
  end
  return blobs, asked
end

local function recall(dims: integer, storage: Vector.Storage, k: integer): number
  local blobs, asked = embeddings(dims, 1500, 30, 20)
  local want = Vector.corpus(dims)
  local got = Vector.corpus(dims, { storage = storage })
  for id, blob in ipairs(blobs) do
    want:add(id, blob)
    got:add(id, blob)
  end
  local same, total = 0, 0
  for _, q in ipairs(asked) do
    same = same + overlap(assert(want:search(q, k)).ids, assert(got:search(q, k)).ids)
    total = total + k
  end
  return same / total
end

local function test_smaller_storages_find_the_neighbors_f32_finds_at_384_dimensions()
  assert(recall(384, "f16", 10) >= 0.99)
  assert(recall(384, "int8", 10) >= 0.9)
end

local function test_smaller_storages_find_the_neighbors_f32_finds_at_768_dimensions()
  assert(recall(768, "f16", 10) >= 0.99)
  assert(recall(768, "int8", 10) >= 0.9)
end

local function test_a_normalized_vector_is_nearest_to_itself_in_every_storage()
  local dims = 64
  local next_number = stream(13)
  local blobs: mut {string} = {}
  for _ = 1, 300 do
    blobs[#blobs + 1] = unit(next_number, dims)
  end
  for _, storage in ipairs(storages) do
    local corpus = Vector.corpus(dims, { storage = storage })
    for id, blob in ipairs(blobs) do
      corpus:add(id, blob)
    end
    for id = 1, 300, 7 do
      for _, metric in ipairs(metrics) do
        local hit = assert(corpus:search(assert(blobs[id]), 1, { metric = metric }))
        assert(hit.ids[1] == id, storage .. " " .. metric .. " " .. tostring(id))
        if storage == "int8" and metric == "l2" then
          -- The same quantization of the same numbers: no distance at all.
          assert(hit.scores[1] == 0)
        end
        if metric == "cosine" then
          assert(math.abs(assert(hit.scores[1]) - 1) < 1e-6)
        end
      end
    end
  end
end

local function test_scores_are_f32s_to_the_rounding_of_the_storage()
  local dims = 384
  local next_number = stream(17)
  local blobs: mut {string} = {}
  for _ = 1, 200 do
    blobs[#blobs + 1] = unit(next_number, dims)
  end
  local q = unit(next_number, dims)
  local reference = Vector.corpus(dims)
  for id, blob in ipairs(blobs) do
    reference:add(id, blob)
  end
  local bound: mut {string: number} = { f16 = 2e-3, int8 = 2e-2 }
  for _, storage in ipairs(smaller) do
    local corpus = Vector.corpus(dims, { storage = storage })
    for id, blob in ipairs(blobs) do
      corpus:add(id, blob)
    end
    for _, metric in ipairs(metrics) do
      local want = assert(reference:search(q, 200, { metric = metric }))
      local got = assert(corpus:search(q, 200, { metric = metric }))
      local score_of: mut {integer: number} = {}
      for i, id in ipairs(got.ids) do
        score_of[id] = assert(got.scores[i])
      end
      for i = 1, 200 do
        local seen = assert(score_of[assert(want.ids[i])])
        assert(math.abs(seen - assert(want.scores[i])) < assert(bound[storage]),
          storage .. " " .. metric .. " row " .. tostring(want.ids[i]))
      end
    end
  end
end

local function test_ties_and_zero_vectors_rank_alike_in_every_storage()
  for _, storage in ipairs(storages) do
    local ties = Vector.corpus(2, { storage = storage })
    local same = Vector.pack({ 1, 0 })
    for _, id in ipairs({ 50, 7, 31, 12, 99 }) do
      ties:add(id, same)
    end
    ties:add(5, Vector.pack({ 0, 1 }))
    local hits = assert(ties:search(same, 3))
    assert(table.concat(hits.ids, ",") == "7,12,31", storage)
    assert(assert(ties:search(same, 100)).ids[6] == 5)

    local corpus = Vector.corpus(2, { storage = storage })
    corpus:add(1, Vector.pack({ 0, 0 }))
    corpus:add(2, Vector.pack({ -1, 0.5 }))
    corpus:add(3, Vector.pack({ 1, 0 }))
    local ranked = assert(corpus:search(Vector.pack({ 1, 0 }), 3, { metric = "cosine" }))
    assert(table.concat(ranked.ids, ",") == "3,2,1", storage)
    assert(ranked.scores[3] == -math.huge)
    local none = assert(corpus:search(Vector.pack({ 0, 0 }), 3, { metric = "cosine" }))
    assert(none.ids[1] == 1 and none.scores[1] == -math.huge)
    -- A zero vector is at no distance but its query's length.
    local near = assert(corpus:search(Vector.pack({ 0, 0 }), 1, { metric = "l2" }))
    assert(near.ids[1] == 1 and near.scores[1] == 0)
  end
end

local function test_allow_and_candidates_restrict_the_ids_in_every_storage()
  for _, storage in ipairs(storages) do
    local corpus = Vector.corpus(2, { storage = storage })
    for id = 1, 20 do
      corpus:add(id, Vector.pack({ id, 1 }))
    end
    local q = Vector.pack({ 1, 0 })
    local hits = assert(corpus:search(q, 3, { allow = { 4, 8, 15, 99 } }))
    assert(table.concat(hits.ids, ",") == "15,8,4", storage)
    assert(#assert(corpus:search(q, 3, { allow = {} })).ids == 0)
    -- Every sign matches the query's, so the first pass keeps the earliest
    -- rows of those the filter leaves.
    local first = assert(corpus:search(q, 2, { allow = { 10, 11, 12, 13, 14 }, candidates = 3 }))
    assert(table.concat(first.ids, ",") == "12,11", storage)
    -- Wide enough to keep every row, the pass is the exact search.
    local exact = assert(corpus:search(q, 5))
    local wide = assert(corpus:search(q, 5, { candidates = 20 }))
    assert(table.concat(wide.ids, ",") == table.concat(exact.ids, ","))
    assert(wide.scores[1] == exact.scores[1])
  end
end

-- The first pass keeps the rows whose signs are nearest the query's, and
-- the signs are the f32 vector's: a number a half or a code rounds to zero
-- still counts as positive. Asking for as many rows as it keeps answers the
-- rows it kept, whatever they score.
local function test_candidates_read_the_signs_of_the_f32_vector()
  local dims = 24
  local next_number = stream(23)
  local blobs: mut {string} = {}
  for _ = 1, 60 do
    local t: mut {number} = {}
    for d = 1, dims do
      if d <= 12 then
        local sign = 1
        if next_number() < 0 then sign = -1 end
        -- Under 2.9e-8, and under half a code of the vector, so zero when stored.
        t[#t + 1] = sign * 1e-9
      else
        t[#t + 1] = next_number()
      end
    end
    blobs[#blobs + 1] = Vector.pack(t)
  end
  local q: mut {number} = {}
  for _ = 1, dims do
    q[#q + 1] = 1
  end
  local query = Vector.pack(q)
  local want = ""
  for _, storage in ipairs(storages) do
    local corpus = Vector.corpus(dims, { storage = storage })
    for id, blob in ipairs(blobs) do
      corpus:add(id, blob)
    end
    local kept = sorted(assert(corpus:search(query, 20, { candidates = 20 })).ids)
    if storage == "f32" then
      want = kept
    else
      assert(kept == want, storage .. " kept " .. kept .. ", f32 kept " .. want)
    end
  end
end

local function test_a_corpus_grows_past_its_first_capacity_in_every_storage()
  local dims = 16
  for _, storage in ipairs(storages) do
    local next_number = stream(29)
    local corpus = Vector.corpus(dims, { storage = storage })
    local blobs: mut {string} = {}
    for id = 1, 200 do
      blobs[#blobs + 1] = unit(next_number, dims)
      corpus:add(id, assert(blobs[id]))
    end
    assert(corpus:count() == 200)
    for _, id in ipairs({ 1, 63, 64, 65, 128, 129, 200 }) do
      local own = assert(blobs[id])
      assert(assert(corpus:search(own, 1, { metric = "cosine" })).ids[1] == id, storage)
      -- The bit vectors and, for int8, the scales moved with the rows.
      local fast = assert(corpus:search(own, 3, { candidates = 5, metric = "l2" }))
      assert(fast.ids[1] == id, storage)
    end
  end
end

local function test_k_means_clusters_every_storage()
  local dims, clusters, per = 64, 8, 40
  local next_number = stream(31)
  local centers: mut {{number}} = {}
  for _ = 1, clusters do
    local center: mut {number} = {}
    for _ = 1, dims do
      center[#center + 1] = if next_number() > 0 then 1.0 else -1.0 end
    end
    centers[#centers + 1] = center
  end
  local blobs: mut {string} = {}
  for _, center in ipairs(centers) do
    for _ = 1, per do
      local v: mut {number} = {}
      for d = 1, dims do
        v[#v + 1] = assert(center[d]) + 0.3 * next_number()
      end
      blobs[#blobs + 1] = Vector.pack(v)
    end
  end
  for _, storage in ipairs(storages) do
    local corpus = Vector.corpus(dims, { storage = storage })
    for id, blob in ipairs(blobs) do
      corpus:add(id, blob)
    end
    local centroids = assert(Vector.kmeans(corpus, clusters, { seed = 3 }))
    assert(#centroids == clusters)
    local owner: mut {integer: boolean} = {}
    for c = 0, clusters - 1 do
      local first = Vector.nearest(centroids, assert(blobs[c * per + 1]))
      for i = 2, per do
        assert(Vector.nearest(centroids, assert(blobs[c * per + i])) == first, storage)
      end
      assert(owner[first] == nil, storage .. " put two clusters in one")
      owner[first] = true
    end
    -- The same seed on the same corpus answers the same centroids.
    local again = assert(Vector.kmeans(corpus, clusters, { seed = 3 }))
    assert(table.concat(again, "") == table.concat(centroids, ""))
  end
  local nothing = Vector.corpus(2, { storage = "int8" })
  nothing:add(1, Vector.pack({ 1e-37, 1e-37 }))
  assert(refusal(function() Vector.kmeans(nothing, 1) end):find("direction", 1, true) ~= nil)
end

--- A guard of cosmic.signal that has caught a signal ends a search or a
--- k-means with `nil, "interrupted"` in every storage, and neither changes
--- the corpus nor takes the signal.
local function test_a_caught_signal_interrupts_every_storage()
  for _, storage in ipairs(storages) do
    local next_number = stream(37)
    local corpus = Vector.corpus(8, { storage = storage })
    for i = 1, 600 do
      corpus:add(i, unit(next_number, 8))
    end
    local query = unit(next_number, 8)
    local exact = assert(corpus:search(query, 5))
    local guard = assert(Signal.guard())
    assert(sys.kill(sys.getpid(), sys.SIGTERM))
    local none, why = corpus:search(query, 5)
    assert(none == nil and why == "interrupted", tostring(why))
    none, why = corpus:search(query, 5, { candidates = 50 })
    assert(none == nil and why == "interrupted", tostring(why))
    local no_centroids: {string}?
    no_centroids, why = Vector.kmeans(corpus, 3, { seed = 4, iterations = 5 })
    assert(no_centroids == nil and why == "interrupted", tostring(why))
    corpus:add(601, query)
    assert(corpus:count() == 601)
    assert(guard:take() == sys.SIGTERM)
    assert(guard:release() == sys.SIGTERM)
    local again = assert(corpus:search(query, 5))
    assert(again.ids[1] == 601 and #again.ids == #exact.ids, storage)
    assert(#assert(corpus:search(query, 5, { candidates = 50 })).ids == 5)
  end
end

--- Every int8 kernel the CPU has answers what the portable one does, to the
--- bit, over dimension counts that leave each kernel's tail.
local function test_every_int8_kernel_answers_alike()
  local original = testing.vector_kernel()
  assert(refusal(function() testing.vector_kernel("avx1024") end):find("kernel", 1, true) ~= nil)
  assert(testing.vector_kernel() == original)
  local ran = 0
  local vectorized: {string} = { "avx512_vnni", "avx_vnni" }
  for _, dims in ipairs({ 1, 3, 31, 32, 37, 63, 64, 65, 100, 384, 768, 1001 }) do
    local next_number = stream(dims)
    local corpus = Vector.corpus(dims, { storage = "int8" })
    for id = 1, 40 do
      corpus:add(id, Vector.pack(random_vector(next_number, dims)))
    end
    -- Rows at the extremes of the codes: every product 127 * 127 or its negative.
    local high: mut {number} = {}
    local low: mut {number} = {}
    for d = 1, dims do
      high[#high + 1] = 1
      low[#low + 1] = if d % 2 == 0 then 1 else -1 end
    end
    corpus:add(41, Vector.pack(high))
    corpus:add(42, Vector.pack(low))
    local random_query = Vector.pack(random_vector(next_number, dims))
    local queries: {string} = { random_query, Vector.pack(high), Vector.pack(low) }
    for _, q in ipairs(queries) do
      for _, metric in ipairs(metrics) do
        testing.vector_kernel("generic")
        local want = assert(corpus:search(q, 42, { metric = metric }))
        for _, name in ipairs(vectorized) do
          local available, _ = pcall(testing.vector_kernel, name)
          if available then
            ran = ran + 1
            assert(testing.vector_kernel() == name)
            local got = assert(corpus:search(q, 42, { metric = metric }))
            assert(table.concat(got.ids, ",") == table.concat(want.ids, ","), name)
            for i = 1, 42 do
              assert(got.scores[i] == want.scores[i], name .. " dims " .. tostring(dims))
            end
          end
        end
      end
    end
    -- Every code of a row and of the query is 127, so the product is the
    -- dimension count, however a kernel gets to it.
    for _, name in ipairs({ "generic", "avx512_vnni", "avx_vnni" }) do
      local available, _ = pcall(testing.vector_kernel, name)
      if available then
        local top = assert(corpus:search(Vector.pack(high), 1))
        assert(top.ids[1] == 41 and math.abs(assert(top.scores[1]) - dims) < 1e-4 * dims,
          name .. " answered " .. tostring(top.scores[1]) .. " for " .. tostring(dims))
      end
    end
  end
  testing.vector_kernel(original)
  assert(testing.vector_kernel() == original)
  -- The widest kernel the CPU has is the one chosen at open, and a host
  -- with one compared it above. A host with none compares the portable
  -- kernel with itself and nothing more.
  local widest = "generic"
  for _, name in ipairs(vectorized) do
    local available, _ = pcall(testing.vector_kernel, name)
    if available and widest == "generic" then widest = name end
  end
  testing.vector_kernel(original)
  assert(original == widest, "the kernel chosen at open is " .. original .. ", the widest is " .. widest)
  assert(widest == "generic" or ran > 0)
end

--- The collector counts the bytes of a smaller corpus, and they are
--- fewer: about half for f16 and under a third for int8 (whose bit vectors,
--- made as each row is added, are a part).
local function test_a_smaller_storage_holds_fewer_bytes()
  local dims, rows = 256, 2000
  local function held(storage: Vector.Storage): number
    collectgarbage("collect")
    local before = collectgarbage("count")
    local next_number = stream(41)
    local corpus = Vector.corpus(dims, { storage = storage })
    for i = 1, rows do
      corpus:add(i, Vector.pack(random_vector(next_number, dims)))
    end
    assert(corpus:count() == rows)
    collectgarbage("collect")
    return collectgarbage("count") - before
  end
  local f32 = held("f32")
  local f16 = held("f16")
  local int8 = held("int8")
  assert(f32 >= rows * dims * 4 / 1024)
  assert(f16 < 0.6 * f32, "f16 held " .. tostring(f16) .. " KB of f32's " .. tostring(f32))
  assert(int8 < 0.35 * f32, "int8 held " .. tostring(int8) .. " KB of f32's " .. tostring(f32))
  assert(int8 >= rows * dims / 1024)
end

local function test_load_takes_the_storage()
  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE chunks (id INTEGER PRIMARY KEY, embedding BLOB);
    INSERT INTO chunks VALUES
      (10, l2_normalize('[1, 0]')), (20, l2_normalize('[0, 1]')), (30, l2_normalize('[1, 1]'));
  ]]))
  local sql = "SELECT id, embedding FROM chunks"
  for _, storage in ipairs(storages) do
    local corpus = assert(Vector.load(db, sql, nil, { storage = storage }))
    assert(corpus.storage == storage and corpus:count() == 3)
    local hits = assert(corpus:search(Vector.pack({ 1, 0 }), 3, { metric = "cosine" }))
    assert(table.concat(hits.ids, ",") == "10,30,20", storage)
  end
  assert(assert(Vector.load(db, sql)).storage == "f32")
  local huge, why = Vector.load(db, sql .. " UNION ALL SELECT 99, vector('[70000, 0]')", nil,
    { storage = "f16" })
  assert(huge == nil and why:find("row 99", 1, true) ~= nil and why:find("half", 1, true) ~= nil, tostring(why))
  assert(Vector.load(db, sql .. " UNION ALL SELECT 99, vector('[70000, 0]')", nil, { storage = "int8" }) ~= nil)
  assert(db:close())
end
