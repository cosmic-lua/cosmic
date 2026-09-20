--- Builds executable launcher fixtures around small native contract payloads.
--- The test form adds synchronization hooks to the production artifact layout.

local Fs = require("cosmic.fs")
local artifact = require("build.artifact")

return function(argv: {string}): integer
  local records_path, payload_root, output = argv[1], argv[2], argv[3]
  assert(records_path ~= nil and payload_root ~= nil and output ~= nil,
    "usage: write_launcher_fixture.tl TARGETS PAYLOAD_ROOT OUTPUT")
  local records = assert(Fs.read(records_path))
  local payloads: {string:string} = {}
  for line in records:gmatch("[^\n]+") do
    local target = line:match("^%d+\t%d+\t[^\t]+\t([^\t]+)\t")
    assert(target ~= nil, "invalid generated target record")
    payloads[target] = assert(Fs.read(payload_root .. "/payload-" .. target))
  end
  local release = assert(artifact.prefix(records, payloads))
  local testing = assert(artifact.test_prefix(records, payloads))
  local database = "SQLite format 3\0launcher contract fixture"
  local release_program = assert(artifact.program(release, database))
  local test_program = assert(artifact.program(testing, database))
  assert(Fs.write(output .. ".release", release_program))
  assert(Fs.write(output .. ".test", test_program))
  return 0
end
