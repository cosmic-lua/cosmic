local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local artifact = require("build.artifact")
local sys = require("cosmic.sys")

return function(argv: {string}): integer
  local function phase(name: string)
    Fs.put(Fs.stderr, "cosmic portable probe phase: " .. name .. "\n")
  end
  local expected_prefix = assert(argv[1])
  local expected_marker = assert(argv[2])
  -- This checkout has its own build/artifact.tl. The reserved binary module
  -- must win over that project row or it receives no retained-FD capability.
  phase("prefix entering")
  local prefix = assert(artifact.trusted_prefix())
  phase("prefix read")
  assert(Hash.hex(Hash.sha256(prefix)) == expected_prefix)
  phase("prefix hashed")
  assert(Store.meta("retained_fixture") == expected_marker)
  phase("fixture metadata read")
  local executable = assert(Store.meta("artifact"))
  phase("artifact metadata read")
  assert(Proc.executable() == executable)
  phase("Proc executable read")
  assert(sys.executable() == executable)
  phase("sys executable read")
  local private = {
    "COSMIC_PORTABLE_ARTIFACT_FD", "COSMIC_PORTABLE_CORE_FD",
    "COSMIC_PORTABLE_TARGET_ID", "COSMIC_PORTABLE_CONFIGURATION_ID",
    "COSMIC_PORTABLE_CORE_OFFSET", "COSMIC_PORTABLE_CORE_LENGTH",
    "COSMIC_PORTABLE_CORE_SHA256",
  }
  for _, name in ipairs(private) do
    assert(sys.getenv(name) == nil, name .. " escaped portable startup")
  end
  phase("private environment checked")
  Fs.put(Fs.stdout, expected_marker .. " " .. expected_prefix .. "\n")
  return 0
end
