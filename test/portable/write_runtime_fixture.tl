--- Writes a new-format Cosmic fixture from the generated target records, the
--- three real raw cores, and a supplied application database.

local Fs = require("cosmic.fs")
local artifact = require("build.artifact")

return function(argv: {string}): integer
  local records_path, cores_root, database_path, output =
    argv[1], argv[2], argv[3], argv[4]
  assert(records_path ~= nil and cores_root ~= nil and
    database_path ~= nil and output ~= nil,
    "usage: write_runtime_fixture.tl TARGETS CORES DATABASE OUTPUT")
  local records = assert(Fs.read(records_path))
  local cores: {string:string} = {}
  for line in records:gmatch("[^\n]+") do
    local target = line:match("^%d+\t%d+\t[^\t]+\t([^\t]+)\t")
    assert(target ~= nil, "invalid generated target record")
    cores[target] = assert(Fs.read(cores_root .. "/" .. target ..
      "/cosmic-core"))
  end
  local prefix = argv[5] == "test" and
    assert(artifact.test_prefix(records, cores)) or
    assert(artifact.prefix(records, cores))
  local database = assert(Fs.read(database_path))
  local program = assert(artifact.program(prefix, database))
  assert(Fs.write(output, program))
  return 0
end
