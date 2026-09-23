--- Every C function the core hands a program, by the name a test run
--- reports it under: each binding in the syscall table, each method of
--- a SQLite handle and statement, each function of the raw http, hash
--- and compress modules and each method of the objects they make,
--- `print`, and `errors.trace`. A test
--- worker watches them all, so a call of one is recorded among the
--- test's hits (see `Coverage.called_path`), and a whole test run fails
--- for any that no test calls. Every core now sees its own C lines too
--- (core/coverage.c), so a stricter bar -- every C function entered --
--- can replace this one once processes a test starts report theirs.

local Coverage = require("cosmic.coverage")
local Sqlite = require("cosmic.sqlite")
local errors = require("cosmic.internal.errors")
local sys = require("cosmic.sys")

local type raw_modules = require("cosmic.internal.modules")

--- The raw modules core C opens. Like each wrapper's own
--- raw module, the table arrives as the second argument `require`
--- passes this chunk's loader, present because this module was loaded
--- trusted from the binary's own tree (see core/store.c); boot mode
--- falls back to requiring it by name, which only boot's preload
--- answers.
local extra: any = select(2, ...)
local raw: raw_modules
if type(extra) == "table" then
  raw = extra as raw_modules
else
  raw = require("cosmic.internal.modules")
end

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

--- Names each function in `functions` `prefix.name` among `points`.
local function name_functions(points: {any: string}, prefix: string, functions: {string: any})
  for name, value in pairs(functions) do
    if type(value) == "function" then
      points[value] = prefix .. "." .. name
    end
  end
end

--- Names each method of `object`, read off its metatable, the only
--- place a userdata's methods are reachable from.
local function name_methods(points: {any: string}, prefix: string, object: any)
  local mt = getmetatable(object as {any: any}) as {string: {string: any}}
  if mt ~= nil and mt.__index ~= nil then
    name_functions(points, prefix, mt.__index)
  end
end

--- Every entry point, by function. The methods are read off live
--- objects: a SQLite handle and statement, a hasher, a compression
--- stream, and an HTTP response over the scripted transport, which
--- never touches the network.
function entry_points.all(): {any: string}
  local points: {any: string} = {}
  name_functions(points, "sys", sys as {string: any})
  local handle = Sqlite.memory()
  if handle ~= nil then
    local statement = handle:prepare("SELECT 1")
    name_methods(points, "sqlite.handle", handle)
    name_methods(points, "sqlite.statement", statement)
    if statement ~= nil then
      statement:finalize()
    end
    handle:close()
  end

  name_functions(points, "http", raw.http as {string: any})
  local response = raw.http.open("http://entry.points/",
    { script = { "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" } })
  if response ~= nil then
    name_methods(points, "http.handle", response)
    response:close()
  end
  name_functions(points, "hash", raw.hash as {string: any})
  name_methods(points, "hash.hasher", (raw.hash.hasher("sha256")))
  name_functions(points, "compress", raw.compress as {string: any})
  name_methods(points, "compress.stream", (raw.compress.inflater("raw")))

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
