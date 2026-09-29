--- The cases of build/version_test.tl that read this program: `cosmic
--- --version` names the build by the digest its release records, the
--- SHA-256 of the file the binary runs from; and `cosmic help` describes
--- it from the docs, which it reads through the store beyond this
--- module's closure. They declare `tool` because they read this
--- program, its file and its store.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local invoke = require("build.invoke")

--- The tool itself, whose digest the version is, and whose store
--- holds the docs help reads.
Test.needs{ tool = true }

local function test_version_is_the_digest_of_the_binarys_own_file(tmp: string)
  local path = assert(Proc.executable())
  local expected = "cosmic " .. Hash.hex_sha256((assert(Fs.read(path)))) .. "\n"
  local result = invoke.run({ "--version" }, { cwd = tmp })
  assert(result.code == 0, result.stderr)
  assert(result.stdout == expected, result.stdout)
  assert(result.stderr == "", result.stderr)
end

local function test_help_describes_version_by_either_spelling(tmp: string)
  for _, word in ipairs({ "version", "--version" }) do
    local result = invoke.run({ "help", word }, { cwd = tmp })
    assert(result.code == 0, result.stderr)
    assert(result.stdout:find("`cosmic --version`: prints `cosmic <hex>`", 1, true),
      result.stdout)
  end
end
