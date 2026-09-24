--- vec1, the SQLite project's vector search extension, as the core
--- carries it: every handle `cosmic.sqlite` opens has the `vec1` virtual
--- table and its distance functions, and a nearest-neighbour query over
--- it answers in order of distance.

local Sqlite = require("cosmic.sqlite")

--- A vector as vec1 stores one: 32-bit floats in the machine's order.
local function vector(...: number): string
  local n = select("#", ...)
  return string.pack("=" .. string.rep("f", n), ...)
end

local function memory(): Sqlite.Handle
  local handle, trouble = Sqlite.memory()
  assert(handle ~= nil, trouble)
  return handle
end

--- The rowids a query answers, in the order it answers them.
local function ids(handle: Sqlite.Handle, sql: string, values: {Sqlite.Value}): {integer}
  local rows, trouble = Sqlite.rows(handle, sql, values)
  assert(rows ~= nil, trouble)
  local out: {integer} = {}
  for i, row in ipairs(rows) do
    out[i] = row[1].integer
  end
  return out
end

--- A cosine-distance table over four notes in two collections.
local function notes(): Sqlite.Handle
  local handle = memory()
  assert(handle:exec("CREATE VIRTUAL TABLE notes USING vec1(embedding, collection)"))
  assert(handle:exec([[INSERT INTO notes(cmd, arg)
    VALUES ('rebuild', '{index: "flat", distance: "cos"}')]]))
  local rows: {{integer, string, string}} = {
    { 1, "work", vector(1, 0, 0) },
    { 2, "work", vector(0.9, 0.1, 0) },
    { 3, "home", vector(0, 1, 0) },
    { 4, "home", vector(0.8, 0, 0.2) },
  }
  for _, row in ipairs(rows) do
    assert(Sqlite.run(handle,
      "INSERT INTO notes(rowid, collection, embedding) VALUES (?1, ?2, ?3)",
      { { integer = row[1] }, { text = row[2] }, { blob = row[3] } }))
  end
  return handle
end

local function test_nearest_neighbours_come_back_in_order_of_distance()
  local handle = notes()
  local found = ids(handle, "SELECT rowid FROM notes(?1, 3)", { { blob = vector(1, 0, 0) } })
  assert(#found == 3 and found[1] == 1 and found[2] == 2 and found[3] == 4,
    "nearest to x: " .. table.concat(found, ","))
  local rows = assert(Sqlite.rows(handle,
    "SELECT distance FROM notes(?1, 1)", { { blob = vector(1, 0, 0) } }))
  assert(rows[1][1].kind == "number" and math.abs(rows[1][1].number) < 1e-6,
    "a vector's distance to itself is zero")
  handle:close()
end

local function test_a_metadata_column_narrows_the_search()
  local handle = notes()
  local found = ids(handle,
    "SELECT rowid FROM notes(?1, 2) WHERE collection = 'home'",
    { { blob = vector(1, 0, 0) } })
  assert(#found == 2 and found[1] == 4 and found[2] == 3,
    "nearest home note to x: " .. table.concat(found, ","))
  handle:close()
end

local function test_an_update_and_a_delete_are_seen_by_the_next_query()
  local handle = notes()
  assert(Sqlite.run(handle, "UPDATE notes SET embedding = ?1 WHERE rowid = 3",
    { { blob = vector(1, 0, 0) } }))
  assert(handle:exec("DELETE FROM notes WHERE rowid = 1"))
  local found = ids(handle, "SELECT rowid FROM notes(?1, 1)", { { blob = vector(1, 0, 0) } })
  assert(#found == 1 and found[1] == 3, "the updated row is now nearest")
  handle:close()
end

local function test_a_vector_of_another_size_is_refused()
  local handle = notes()
  local ok, why = Sqlite.run(handle, "INSERT INTO notes(embedding) VALUES (?1)",
    { { blob = vector(1, 0) } })
  assert(not ok and why ~= "", "a two-element vector in a three-element table")
  handle:close()
end

local function test_distance_functions_compare_two_vectors()
  local handle = memory()
  local rows = assert(Sqlite.rows(handle,
    "SELECT vec1_l2_distance(?1, ?2), vec1_cos_distance(?1, ?1)",
    { { blob = vector(1, 2, 3) }, { blob = vector(1, 2, 5) } }))
  assert(math.abs(rows[1][1].number - 4) < 1e-6, "squared euclidean distance")
  assert(math.abs(rows[1][2].number) < 1e-6, "cosine distance to itself")
  handle:close()
end

local function test_a_scan_reads_the_distance_column_without_a_model()
  local handle = notes()
  local rows = assert(Sqlite.rows(handle, "SELECT distance FROM notes WHERE rowid = 1"))
  assert(rows[1][1].kind == "text", "a scan's distance is its statistics")
  -- A zero norm's errors are zero, not SQLite's printf of 0/0, "NaN".
  assert(rows[1][1].text:find("coarse_error:0.000000,", 1, true), rows[1][1].text)
  handle:close()
end
