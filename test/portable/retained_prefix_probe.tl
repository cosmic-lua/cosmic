local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Store = require("cosmic.store")
local artifact = require("build.artifact")
local sys = require("cosmic.sys")

return function(argv: {string}): integer
  local expected_prefix = assert(argv[1])
  local expected_marker = assert(argv[2])
  -- This checkout has its own build/artifact.tl. The reserved binary module
  -- must win over that project row or it receives no retained-FD capability.
  local prefix = assert(artifact.trusted_prefix())
  assert(Hash.hex(Hash.sha256(prefix)) == expected_prefix)
  assert(Store.meta("retained_fixture") == expected_marker)
  local private = {
    "COSMIC_PORTABLE_ARTIFACT_FD", "COSMIC_PORTABLE_CORE_FD",
    "COSMIC_PORTABLE_TARGET_ID", "COSMIC_PORTABLE_CONFIGURATION_ID",
    "COSMIC_PORTABLE_CORE_OFFSET", "COSMIC_PORTABLE_CORE_LENGTH",
    "COSMIC_PORTABLE_CORE_SHA256",
  }
  for _, name in ipairs(private) do
    assert(sys.getenv(name) == nil, name .. " escaped portable startup")
  end
  Fs.put(Fs.stdout, expected_marker .. " " .. expected_prefix .. "\n")
  return 0
end
