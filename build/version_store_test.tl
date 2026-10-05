--- The case of build/version_test.tl that reads the store beyond this
--- module's closure: `cosmic help` describes `cosmic --version` from
--- the docs (build/version_tool_test.tl reads the program's file).

local Test = require("cosmic.test")
local invoke = require("build.invoke")

--- `store`: `help version`, run in this process, reads every module's
--- docs through [`Store.databases()`].
-- TODO: declare this with [`Test.policy`] once a policy field says `store` (the TODO
-- above [`Test.needs_of`] in cosmic/test.tl).
Test.needs{ store = true }

local function test_help_describes_version_by_either_spelling(tmp: string)
  for _, word in ipairs({ "version", "--version" }) do
    local result = invoke.run({ "help", word }, { cwd = tmp })
    assert(result.code == 0, result.stderr)
    assert(result.stdout:find("`cosmic --version`: prints `cosmic <hex>`", 1, true),
      result.stdout)
  end
end
