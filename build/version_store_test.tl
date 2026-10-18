--- The case of build/version_test.tl that reads the store beyond this
--- module's closure: `cosmic help` describes `cosmic --version` from
--- the docs (build/version_tool_test.tl reads the program's file).

local Test = require("cosmic.test")
local invoke = require("build.invoke")

-- The import closure, which holds every verb through build.verb_list, is
-- one grant a module, and a worker's start takes 255: build/lsp/ is given
-- as one directory, which shows the closure's modules beneath it.
-- TODO: drop the build/lsp/ grant once a worker's grants show a directory's
-- modules as one (build.test_sandbox's `plan`), which a closure past 255 needs.
--- `store`: `help version`, run in this process, reads every module's
--- docs through [`Store.databases()`].
Test.policy{ grants = { { path = "build/lsp/", letters = "r" }, { path = "o/cosmic.db", letters = "r" } } }

local function test_help_describes_version_by_either_spelling(tmp: string)
  for _, word in ipairs({ "version", "--version" }) do
    local result = invoke.run({ "help", word }, { cwd = tmp })
    assert(result.code == 0, result.stderr)
    assert(result.stdout:find("`cosmic --version`: prints `cosmic <hex>`", 1, true),
      result.stdout)
  end
end
