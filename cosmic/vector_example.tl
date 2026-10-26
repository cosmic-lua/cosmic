--- Worked examples for [`cosmic.vector`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Sqlite = require("cosmic.sqlite")
local Vector = require("cosmic.vector")

local record Example end

--- A corpus holds many vectors in one buffer. Pack the numbers, add each
--- under an id, and ask for the nearest to a query: the ids come back
--- best first, with their scores.
function Example.nearest()
  local corpus = Vector.corpus(3)
  corpus:add(1, Vector.normalize(Vector.pack({ 0.9, 0.1, 0.0 })))
  corpus:add(2, Vector.normalize(Vector.pack({ 0.7, 0.6, 0.1 })))
  corpus:add(3, Vector.normalize(Vector.pack({ 0.0, 0.2, 0.9 })))
  local hits = assert(corpus:search(Vector.normalize(Vector.pack({ 0.85, 0.15, 0.05 })), 2))
  print(hits.ids[1], hits.ids[2]) -- 1  2
  assert(hits.ids[1] == 1 and hits.ids[2] == 2)
  assert(assert(hits.scores[1]) > assert(hits.scores[2]))
  -- A packed vector reads back as the numbers it holds, in 32-bit floats.
  local numbers = Vector.unpack(Vector.pack({ 0.5, 2 }))
  assert(numbers[1] == 0.5 and numbers[2] == 2)
end

--- Load a corpus once from the table that stores it, search it many times,
--- and let SQL decide which rows may answer: `allow` takes the ids of a
--- `SELECT id ... WHERE` filter.
function Example.load_and_filter()
  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE chunks (id INTEGER PRIMARY KEY, tenant TEXT, embedding BLOB);
    INSERT INTO chunks VALUES
      (1, 'a', l2_normalize('[0.9, 0.1, 0.0]')),
      (2, 'a', l2_normalize('[0.7, 0.6, 0.1]')),
      (3, 'a', l2_normalize('[0.0, 0.2, 0.9]')),
      (4, 'b', l2_normalize('[0.8, 0.2, 0.1]'));
  ]]))
  local corpus = assert(Vector.load(db, "SELECT id, embedding FROM chunks"))
  local tenant_a = assert(Sqlite.map(db, "SELECT id FROM chunks WHERE tenant = 'a'", nil,
    function(r: Sqlite.Row): integer
      return r:integer(1)
    end))
  local q = assert(Vector.from_json("[0.85, 0.15, 0.05]"))
  local hits = assert(corpus:search(Vector.normalize(q), 2, { allow = tenant_a }))
  print(hits.ids[1], hits.ids[2]) -- 1  2
  assert(hits.ids[1] == 1 and hits.ids[2] == 2)
  assert(db:close())
end

--- A large corpus is searched in two passes with `candidates`: the sign
--- bits of each dimension pick that many rows cheaply, and only those are
--- scored exactly. It is approximate, so measure its recall on your data.
function Example.binary_first_pass()
  local corpus = Vector.corpus(4)
  for id = 1, 100 do
    corpus:add(id, Vector.pack({ id % 7 - 3, id % 5 - 2, id % 3 - 1, 1 }))
  end
  local exact = assert(corpus:search(Vector.pack({ 3, 2, 1, 1 }), 3))
  local fast = assert(corpus:search(Vector.pack({ 3, 2, 1, 1 }), 3, { candidates = 20 }))
  print(exact.ids[1], fast.ids[1])
  assert(exact.ids[1] == fast.ids[1])
end

--- IVF search: k-means picks centroids, each row stores the cluster of its
--- nearest centroid in an indexed column, and a query scores only the
--- rows of the few clusters nearest to it. Approximate: measure recall
--- against `corpus:search` on your data before trusting a probe count.
function Example.ivf()
  local points = {
    { 1, 0.1 }, { 0.9, 0.0 }, { 1, -0.1 },
    { 0.1, 1 }, { 0.0, 0.9 }, { -0.1, 1 },
    { -1, 0.1 }, { -0.9, 0.0 }, { -1, -0.1 },
  }
  local corpus = Vector.corpus(2)
  for i, p in ipairs(points) do
    corpus:add(i, Vector.normalize(Vector.pack(p)))
  end
  local centroids = assert(Vector.kmeans(corpus, 3))

  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE chunks (id INTEGER PRIMARY KEY, cluster INTEGER, embedding BLOB);
    CREATE INDEX chunks_cluster ON chunks (cluster);
  ]]))
  for i, p in ipairs(points) do
    local blob = Vector.normalize(Vector.pack(p))
    assert(Sqlite.run(db, "INSERT INTO chunks VALUES (?1, ?2, ?3)",
      { { integer = i }, { integer = Vector.nearest(centroids, blob) }, { blob = blob } }))
  end

  local query = Vector.normalize(Vector.pack({ 0.2, 1 }))
  local probes: Sqlite.Value = { integers = Vector.nearest_n(centroids, query, 1) }
  local ids = assert(Sqlite.map(db, [[
    SELECT id FROM chunks WHERE cluster IN carray(?2)
    ORDER BY inner_product(embedding, ?1) DESC LIMIT 2
  ]], { { blob = query }, probes }, function(r: Sqlite.Row): integer
    return r:integer(1)
  end))
  print(ids[1], ids[2]) -- 4  5
  assert(ids[1] == 4 and ids[2] == 5)
  assert(db:close())
end

return Example
