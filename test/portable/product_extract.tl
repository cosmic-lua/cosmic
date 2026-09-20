--- Extracts the exact reusable prefix and manifest from a built product.

local Fs = require("cosmic.fs")
local fixture = require("test.portable.artifact_fixture")

return function(argv: {string}): integer
  local program, prefix_path, manifest_path = argv[1], argv[2], argv[3]
  assert(program ~= nil and prefix_path ~= nil and manifest_path ~= nil,
    "usage: product_extract.tl PROGRAM PREFIX MANIFEST APPLICATION...")
  local artifact = assert(fixture.read(program))
  local prefix = fixture.prefix(artifact)
  for at = 4, #argv do
    local application = assert(fixture.read(argv[at]))
    assert(fixture.prefix(application) == prefix,
      argv[at] .. ": application prefix differs from Cosmic")
  end
  assert(Fs.write(prefix_path, prefix, 0x1a4))
  assert(Fs.write(manifest_path,
    artifact.bytes:sub(artifact.manifest_offset + 1,
      artifact.manifest_offset + 4096), 0x1a4))
  return 0
end
