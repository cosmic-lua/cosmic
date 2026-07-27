-- A `.lua` test in a Lua-only project. The marker suffixes are
-- extension-agnostic, so this must RUN under `--make test` and must
-- NOT be embedded in the artifact -- it classified as a module and did
-- both wrongly.
--
-- It imports, deliberately: a `.lua` test's make-variable stem is the
-- path without its extension, and naming it `deps_main_test.lua`
-- instead left the closure empty -- no rebuild when greet.lua changes,
-- and no read grant for it under an enforcing fence.
local greet = require("greet")
assert(greet.hi("lua") == "hello, lua", "greet.hi should greet")
print("luaonly test ran")
