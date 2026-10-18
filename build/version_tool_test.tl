--- The case of build/version_test.tl that reads this program: `cosmic
--- --version` names the build by the digest its release records, the
--- SHA-256 of the file the binary runs from. It declares `tool` because
--- it reads this program's file. `cosmic help`'s description of it,
--- which reads the store, is in build/version_store_test.tl.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local invoke = require("build.invoke")

-- The import closure, which holds every verb through build.verb_list, is
-- one grant a module, and a worker's start takes 255: build/lsp/ is given
-- as one directory, which shows the closure's modules beneath it.
-- TODO: drop the build/lsp/ grant once a worker's grants show a directory's
-- modules as one (build.test_sandbox's `plan`), which a closure past 255 needs.
--- The tool itself, whose digest the version is.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "build/lsp/", letters = "r" }, { path = "o/bin", letters = "rx" } } }

local function test_version_is_the_digest_of_the_binarys_own_file(tmp: string)
  local path = assert(Proc.executable())
  local expected = "cosmic " .. Hash.hex_sha256((assert(Fs.read(path)))) .. "\n"
  local result = invoke.run({ "--version" }, { cwd = tmp })
  assert(result.code == 0, result.stderr)
  assert(result.stdout == expected, result.stdout)
  assert(result.stderr == "", result.stderr)
end
