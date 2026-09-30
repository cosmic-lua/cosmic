--- `cosmic --version`'s command line, run in this process
--- ([`build.invoke`]): it takes nothing after it. build/version_tool_test.tl
--- holds what it prints, the digest of this program's own file.

local invoke = require("build.invoke")

local function test_version_refuses_a_word_after_it(tmp: string)
  local result = invoke.run({ "--version", "--short" }, { cwd = tmp })
  assert(result.code == 2 and result.stdout == "", result.stdout)
  assert(result.stderr == "cosmic: --version takes nothing after it, not --short\n",
    result.stderr)
end
