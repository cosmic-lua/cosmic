--- The core's message for a removed global names what to write
--- instead, from [`cosmic.removed`], which the worker lets any test
--- `require` beyond its closure ([`build.test_worker`]'s `diagnostics`).
--- This module requires nothing, so its closure is itself alone.

local function test_a_removed_global_still_says_what_to_write()
  local ok, why = pcall(load("return os.getenv"))
  assert(not ok)
  assert(tostring(why):find("Env.get", 1, true), tostring(why))
end
