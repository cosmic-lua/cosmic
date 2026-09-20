--- Makes the portable database variants consumed by the runtime fixture.

local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")

local function text(value: string): Sqlite.Value
  return { text = value }
end

local function update(path: string, marker: string)
  local db = assert(Sqlite.open(path, true))
  assert(Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
    { text("retained_fixture"), text(marker) }))
  if marker == "basis" then
    assert(Sqlite.run(db, "UPDATE meta SET value = ?1 WHERE key = 'runtime_basis'",
      { text(Hash.hex_sha256("portable fixture basis variant")) }))
  elseif marker == "missing" then
    assert(Sqlite.run(db, "DELETE FROM meta WHERE key = 'runtime_basis'"))
  end
  assert(db:close())
end

return function(argv: {string}): integer
  assert(#argv == 4,
    "usage: prepare_runtime_databases.tl OLD NEW BASIS MISSING")
  local markers = { "old", "new", "basis", "missing" }
  for index, marker in ipairs(markers) do update(argv[index], marker) end

  local db = assert(Sqlite.open(argv[1], false))
  local rows = assert(Sqlite.text_rows(db, "SELECT key FROM meta"))
  local keys: {string:boolean} = {}
  for _, row in ipairs(rows) do keys[row[1]] = true end
  local images = assert(Sqlite.text_rows(db, "SELECT count(*) FROM images"))
  assert(db:close())
  for _, forbidden in ipairs({ "host", "host_image", "runtime" }) do
    assert(not keys[forbidden],
      "portable runtime build: per-host metadata survived: " .. forbidden)
  end
  assert(keys["runtime_basis"] and images[1][1] == "0",
    "portable runtime build: projection lacks basis or carries images")
  return 0
end
