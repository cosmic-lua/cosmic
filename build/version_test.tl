--- `cosmic --version`'s command line, run in this process
--- ([`build.invoke`]): it takes nothing after it. build/version_tool_test.tl
--- holds what it prints, the digest of this program's own file.

local Test = require("cosmic.test")
local invoke = require("build.invoke")

-- The import closure, which holds every verb through build.verb_list, is
-- one grant a module, and a worker's start takes 255: build/lsp/ is given
-- as one directory, which shows the closure's modules beneath it.
-- TODO: drop the build/lsp/ grant once a worker's grants show a directory's
-- modules as one (build.test_sandbox's `plan`), which a closure past 255 needs.
Test.policy{ grants = { { path = "build/lsp/", letters = "r" } } }

local function test_version_refuses_a_word_after_it(tmp: string)
  local result = invoke.run({ "--version", "--short" }, { cwd = tmp })
  assert(result.code == 2 and result.stdout == "", result.stdout)
  assert(result.stderr == "cosmic: --version takes nothing after it, not --short\n",
    result.stderr)
end
