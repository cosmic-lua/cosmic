--- Adds hostile project metadata used to prove portable context wins.

local Sqlite = require("cosmic.sqlite")

return function(argv: {string}): integer
  local path = assert(argv[1], "usage: spoof_runtime_database.tl DATABASE")
  local db = assert(Sqlite.open(path, true))
  local values: {string:string} = {
    host = "spoofed",
    host_image = "spoofed",
    runtime = string.rep("f", 64),
    runtime_basis = "spoofed",
    artifact = "/spoofed",
    runtime_context = "legacy-spoof",
  }
  for key, value in pairs(values) do
    assert(Sqlite.run(db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
      { { text = key }, { text = value } }))
  end
  assert(db:close())
  return 0
end
