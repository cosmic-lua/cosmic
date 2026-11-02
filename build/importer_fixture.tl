--- What build/importer_test.tl and build/importer_store_test.tl share: the importer's compile of a staged fixture
--- tree. Test support.

local importer = require("build.importer")
local work = require("build.work")

local record importer_fixture
end

--- Stages and compiles one fixture run. Reopening the same root keeps its
--- working database, which lets a test exercise the real warm cache.
--- @param root the fixture tree
--- @return the importer's result, or nil and why it did not compile
function importer_fixture.compile_fixture(root: string): importer.Result?, string
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, { own = false })
  if staged == nil then
    local _, _ = work.close(handle)
    return nil, stage_trouble
  end
  local result, compile_trouble = importer.compile(handle,
    "declaration-cache-test")
  local _, _ = work.close(handle)
  -- The new checker goes on past a module it refuses and says so in `refused`: that is no compile, as the tests ask.
  if result ~= nil and #result.refused > 0 then
    return nil, table.concat(result.refused, "\n")
  end
  if result == nil then
    return nil, compile_trouble
  end
  return result, ""
end

return importer_fixture
