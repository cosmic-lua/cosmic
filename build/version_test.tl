--- `cosmic --version` names the build by the digest its release
--- records: the SHA-256 of the file the binary runs from.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local invoke = require("build.invoke")
local type Declared = require("build.inputs").Declared

--- The tool itself, whose digest the version is.
local _inputs: Declared = { tool = true }

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

local function test_version_refuses_a_word_after_it(tmp: string)
  local result = invoke.run({ "--version", "--short" }, { cwd = tmp })
  assert(result.code == 2 and result.stdout == "", result.stdout)
  assert(result.stderr == "cosmic: --version takes nothing after it, not --short\n",
    result.stderr)
end
