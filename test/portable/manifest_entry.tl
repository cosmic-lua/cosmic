--- Prints one portable manifest entry for shell fixture setup.

local Hash = require("cosmic.hash")
local fixture = require("test.portable.artifact_fixture")

return function(argv: {string}): integer
  local target = math.tointeger(tonumber(argv[2]))
  local configuration = math.tointeger(tonumber(argv[3]))
  assert(argv[1] ~= nil and target ~= nil and configuration ~= nil,
    "usage: manifest_entry.tl ARTIFACT TARGET CONFIGURATION")
  local artifact = assert(fixture.read(argv[1]))
  local entry = assert(fixture.entry(artifact, target, configuration),
    "identity fixture: selected manifest entry is missing")
  print(entry.offset, entry.length, Hash.hex(entry.digest))
  return 0
end
