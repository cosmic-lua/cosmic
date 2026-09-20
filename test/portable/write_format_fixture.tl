--- Writes transitional format fixtures from build.zig's generated target TSV
--- and real raw cores. This is test support, not a product build path.

local Fs = require("cosmic.fs")
local artifact = require("build.artifact")

return function(argv: {string}): integer
  local records_path, core_root, output = argv[1], argv[2], argv[3]
  assert(records_path ~= nil and core_root ~= nil and output ~= nil,
    "usage: write_format_fixture.tl TARGETS CORE_ROOT OUTPUT")
  local records = assert(Fs.read(records_path))
  local cores: {string:string} = {}
  for line in records:gmatch("[^\n]+") do
    local target = line:match("^%d+\t%d+\t[^\t]+\t([^\t]+)\t")
    assert(target ~= nil, "invalid generated target record")
    cores[target] = assert(Fs.read(core_root .. "/" .. target .. "/cosmic-core"))
  end
  local prefix = assert(artifact.prefix(records, cores))
  local database_a = "SQLite format 3\0fixture database A"
  local database_b = "SQLite format 3\0fixture database B"
  local program_a = assert(artifact.program(prefix, database_a))
  local program_b = assert(artifact.program(prefix, database_b))
  assert(Fs.write(output .. ".prefix", prefix))
  assert(Fs.write(output .. ".a", program_a))
  assert(Fs.write(output .. ".b", program_b))
  return 0
end
