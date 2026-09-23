--- Every C function the core hands a program, by the name a test run
--- reports it under: each binding in the syscall table, each method of
--- a SQLite handle and statement, `print`, and `errors.trace`. A test
--- worker watches them all, so a call of one is recorded among the
--- test's hits (see `Coverage.called_path`), and a whole test run fails
--- for any that no test calls: the C has no line coverage, so being
--- reached by a test is the bar it is held to.

local Coverage = require("cosmic.coverage")
local Sqlite = require("cosmic.sqlite")
local errors = require("cosmic.internal.errors")
local sys = require("cosmic.sys")

local record entry_points
  --- The entry points no test can call from inside the process it
  --- runs in, and why.
  exempt: {string: string}

  --- How a run's hits measure up against every entry point.
  record Tally
    --- The entry points no test called and none exempts, sorted.
    unreached: {string}
    --- How many were called.
    reached: integer
    --- How many are exempt and were not called.
    exempted: integer
    --- How many entry points there are.
    total: integer
  end
end

entry_points.exempt = {
  ["sys.exit"] = "ends the process the test runs in",
}

--- Every entry point, by function. The SQLite methods are read off a
--- live handle's and statement's metatables, the only place they are
--- reachable from.
function entry_points.all(): {any: string}
  local points: {any: string} = {}
  for name, value in pairs(sys as {string: any}) do
    if type(value) == "function" then
      points[value] = "sys." .. name
    end
  end
  local handle = Sqlite.memory()
  if handle ~= nil then
    local statement = handle:prepare("SELECT 1")
    for kind, value in pairs({ handle = handle as any, statement = statement as any }) do
      local mt = getmetatable(value as {any: any}) as {string: {string: any}}
      if mt ~= nil and mt.__index ~= nil then
        for name, method in pairs(mt.__index) do
          points[method] = "sqlite." .. kind .. "." .. name
        end
      end
    end
    if statement ~= nil then
      statement:finalize()
    end
    handle:close()
  end
  points[print] = "print"
  points[errors.trace] = "errors.trace"
  return points
end

--- Measures `hits`, a run's hits with every call recorded in them,
--- against `points`, every entry point by function.
function entry_points.tally(points: {any: string}, hits: Coverage.Hits): entry_points.Tally
  local names: {string} = {}
  for _, name in pairs(points) do
    names[#names + 1] = name
  end
  table.sort(names)
  local tally: entry_points.Tally = { unreached = {}, reached = 0, exempted = 0,
                                      total = #names }
  for _, name in ipairs(names) do
    if hits[Coverage.called_path(name)] ~= nil then
      tally.reached = tally.reached + 1
    elseif entry_points.exempt[name] ~= nil then
      tally.exempted = tally.exempted + 1
    else
      tally.unreached[#tally.unreached + 1] = name
    end
  end
  return tally
end

return entry_points
