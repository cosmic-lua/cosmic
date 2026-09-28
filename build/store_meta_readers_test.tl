--- A test worker whose test's closure holds what a `meta` row digests
--- reads that row through `Store.meta` under the store's hold
--- (`build.test_worker`'s `compiler_meta` and `writer_meta`): the
--- compiler's identity, since this module is named in
--- `build.declared_key`'s `compiler_readers` and its key holds the
--- tool's, and the writer's, since its closure holds build.writer, whose
--- sources its key holds. Every other row no key holds is held as ever.

local Store = require("cosmic.store")
-- Erased, so nothing loads: it only puts build.writer's closure in this
-- module's, and so in its key.
local type _ = require("build.writer")

local function test_a_row_is_read_by_a_closure_that_holds_what_it_digests()
  assert(Store.meta("compiler") ~= nil, "the tool names its compiler")
  assert(Store.meta("compiled_by") ~= nil, "the tool names what compiled it")
  assert(Store.meta("writer") ~= nil, "the tool names its writer")
  local ok, why = pcall(Store.meta, "projected")
  assert(not ok and tostring(why):find("store = true", 1, true), tostring(why))
end
