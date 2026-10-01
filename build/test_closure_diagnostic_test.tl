--- The core's message for a removed global names what to write
--- instead from [`cosmic.removed`], which a worker refuses a test whose
--- closure does not hold it, as it refuses any other module of the tree
--- ([`build.test_worker`]'s `refusal`): what the catalog says is no
--- input of this test's key, so it is not told it. The global is
--- refused all the same, by name. This module requires nothing, so its
--- closure is itself alone; core/surface_test.tl, which requires the
--- catalog, is told what to write.

local function test_a_removed_global_outside_the_closure_says_only_that_it_is_gone()
  local ok, why = pcall(load("return os.getenv"))
  assert(not ok)
  assert(tostring(why):find(": os%.getenv is not available$"), tostring(why))
  assert(not tostring(why):find("Env.get", 1, true), tostring(why))
  assert(package.loaded["cosmic.removed"] == nil)
end
