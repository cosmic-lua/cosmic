--- Worked examples for [`cosmic.coverage`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Coverage = require("cosmic.coverage")

local Example = {}

--- The lines hit between `start` and `stop`, by module path. A window
--- already open, as under `cosmic test`, refuses a second `start`.
function Example.stop()
  local session, trouble = Coverage.start()
  if session == nil then
    print(trouble)
    return
  end
  local hits = assert(Coverage.stop(session))
  local modules = 0
  for _ in pairs(hits) do
    modules = modules + 1
  end
  print(modules)
  assert(modules >= 0)
end

--- The core's own C functions: each begins on a line among
--- [`Coverage.native_lines`], which a hit names when the function was entered.
--- Both are empty in a core built without native coverage.
function Example.native_functions()
  local lines = Coverage.native_lines()
  local functions = Coverage.native_functions()
  for _, fn in ipairs(functions) do
    local here = lines[fn.path]
    assert(here ~= nil and here[fn.line], fn.path .. ":" .. fn.name)
  end
  print(#functions)
end

return Example
