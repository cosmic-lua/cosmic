--- The environment `load` gives a chunk it is handed none for: the base functions that reach nothing else and the pure
--- libraries, and no path to `require`, `package` or the globals. A program that needs more passes an environment.
local Globals = require("cosmic.internal.globals")
local Test = require("cosmic.test")

Test.policy{}

--- Runs `source` as a chunk with the default environment and answers what it returns.
local function run(source: string): any
  local chunk, why = load(source, "=load_env", "t")
  assert(chunk ~= nil, tostring(why))
  local value: any = chunk()
  return value
end

local function test_a_chunk_with_no_environment_reads_neither_require_nor_package_nor_the_globals()
  assert(run("return require") == nil, "require")
  assert(run("return package") == nil, "package")
  assert(run("return _G") == nil, "_G")
  assert(run("return rawget(_ENV, 'require')") == nil, "rawget of require")
  assert(run("return rawget(_ENV, '_G')") == nil, "rawget of _G")
  assert(run("return os") == nil and run("return io") == nil and run("return debug") == nil, "os, io, debug")
end

local function test_the_environment_has_no_metatable_that_leads_back_to_the_globals()
  assert(run("return getmetatable(_ENV)") == nil, "the environment has a metatable")
  assert(run("return select('#', getmetatable('x'))") == 1)
  -- The string metatable reaches the string library alone.
  assert(run("return getmetatable('x').__index == string") == true)
  assert(run("return getmetatable(print)") == nil)
end

--- The chunk walks its own environment and the tables in it, and answers the first name that reaches the globals, `require` or
--- `package` (given as its arguments), or nil.
local WALK <const> = [[
local globals, require_function, package_table = ...
local function reaches(value)
  return value == globals or value == require_function or value == package_table
end
local count = 0
for name, value in pairs(_ENV) do
  count = count + 1
  if reaches(value) then return name end
  if type(value) == 'table' and value ~= _ENV then
    for inner_name, inner in pairs(value) do
      if reaches(inner) then return name .. '.' .. tostring(inner_name) end
    end
  end
end
if count < 20 then return 'nearly empty: ' .. count end
return nil
]]

local function test_nothing_the_environment_holds_is_the_globals_or_require_or_package_or_a_table_holding_them()
  local globals = Globals.table()
  assert(globals["require"] ~= nil and globals["package"] ~= nil and globals["_G"] ~= nil)
  local chunk = assert(load(WALK, "=walk", "t"))
  local found: any = chunk(globals, globals["require"], globals["package"])
  assert(found == nil, tostring(found))
end

local function test_a_load_the_chunk_makes_is_held_to_the_same_environment()
  assert(run("return load('return require')()") == nil, "a nested load reads require")
  assert(run("return load('return package')()") == nil, "a nested load reads package")
  assert(run("return load('return load')() ~= nil") == true, "load is in the environment")
end

local function test_a_chunk_given_an_environment_reads_what_it_names()
  assert(run("return 1 + 1") == 2)
  local globals = Globals.table()
  local chunk = assert(load("return require, package, _G", "=whole", "t", globals))
  local first: any = chunk()
  assert(first == globals["require"], "the globals give require")
  local bare = assert(load("return require", "=bare", "t", {}))
  local none: any = bare()
  assert(none == nil, "an environment that names nothing gives nothing")
end
