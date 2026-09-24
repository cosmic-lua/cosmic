--- Worked examples for `cosmic.coverage`, shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Coverage = require("cosmic.coverage")

local Example = {}

--- The lines hit so far, looked in on without ending the collection:
--- empty when none is open, as outside `cosmic test`.
function Example.snapshot()
  local modules = 0
  for _ in pairs(Coverage.snapshot()) do
    modules = modules + 1
  end
  print(modules)
  assert(modules >= 0)
end

--- The core's own C functions a run entered: a function's first line,
--- among `native_entries`, is hit when it was entered. Both are empty
--- in a core built without native coverage.
function Example.native_entries()
  local entries = Coverage.native_entries()
  local hits = Coverage.snapshot()
  local entered = 0
  for _, fn in ipairs(Coverage.native_functions()) do
    local first = entries[fn.path]
    assert(first ~= nil and first[fn.line], fn.path .. ":" .. fn.name)
    local hit = hits[fn.path]
    if hit ~= nil and hit[fn.line] then
      entered = entered + 1
    end
  end
  print(entered)
end

return Example
