--- The declarations of build.importer tell the truth about nil: a compile
--- that is handed no shared cache, no judgement to skip and no choice of
--- compiler says so, and does not pass a nil where a type admits none. A
--- checked run (`cosmic test --check-types`) says whether a value crossed
--- a typed boundary under build/ as a kind its type does not admit; in
--- any other run the test skips.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local TypeWatch = require("build.type_watch")
local importer = require("build.importer")
local work = require("build.work")

--- The core's own tree, which a compile of a fixture reads beside it.
Test.policy{ grants = { { path = "core", letters = "r" } } }


local function test_a_compile_with_no_cache_and_no_choice_is_as_declared(tmp: string)
  assert(Fs.write(tmp .. "/a.tl", "return { answer = 42 }\n"))
  local found = TypeWatch.during(function()
    local handle = assert(work.open(tmp))
    assert(work.stage(handle, false))
    local result, trouble = importer.compile(handle, "declared-types-test")
    assert(work.close(handle))
    assert(result ~= nil, trouble)
  end, "build/")
  assert(#found == 0, #found .. " violations:\n" .. table.concat(found, "\n"))
end
