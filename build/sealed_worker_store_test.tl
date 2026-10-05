--- A module that declares `store` reads the whole program, which a worker
--- that does not is given a sealed database of its closure in place of
--- (build/sealed_worker_test.tl): its key holds the projection by its
--- contents.
local Store = require("cosmic.store")
local Test = require("cosmic.test")

-- Declared on purpose: this test asserts what `store` gives.
Test.needs{ store = true }

local function test_the_whole_program_is_read()
  assert(Store.source("cosmic.zip") ~= nil)
  assert(Store.bytecode("build.writer") ~= nil)
  assert(#assert(Store.requires("build.writer")) > 0)
end
