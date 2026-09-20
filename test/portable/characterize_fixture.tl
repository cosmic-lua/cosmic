--- Reads the old packed prototype without depending on a host SQLite tool.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

return function(argv: {string}): integer
  local action, path = argv[1], argv[2]
  assert(action ~= nil and path ~= nil,
    "usage: characterize_fixture.tl runtime ARTIFACT TEMP_DATABASE | verdicts DATABASE")
  if action == "verdicts" then
    local db = assert(Sqlite.open(path, false))
    local rows = assert(Sqlite.text_rows(db, "SELECT key FROM verdicts"))
    assert(db:close())
    assert(#rows == 0,
      "portable characterization: missing runtime wrote a verdict")
    return 0
  end

  assert(action == "runtime" and argv[3] ~= nil,
    "usage: characterize_fixture.tl runtime ARTIFACT TEMP_DATABASE")
  local bytes = assert(Fs.read(path))
  local marker = "Start-Of-Cosmic--"
  local trailer = #marker + 8
  assert(#bytes >= trailer and bytes:sub(-trailer, -9) == marker,
    "portable characterization: prototype trailer is missing")
  local offset = string.unpack(">I8", bytes, #bytes - 7)
  assert(offset < #bytes - trailer,
    "portable characterization: prototype database range is invalid")
  local database = argv[3] as string
  assert(Fs.write(database, bytes:sub(offset + 1, #bytes - trailer)))
  local db = assert(Sqlite.open(database, false))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'runtime'"))
  assert(db:close())
  assert(Fs.remove(database))
  print(#rows == 0 and "<missing>" or rows[1][1])
  return 0
end
