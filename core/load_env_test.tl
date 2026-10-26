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
  -- The string metatable a chunk reads is a copy that reaches a copy of the string library alone.
  assert(run("return getmetatable('x').__index == string") == false)
  assert(run("return type(getmetatable('x').__index.rep)") == "function")
  assert(run("return getmetatable(print)") == nil)
end

--- The chunk walks its own environment and the tables in it, and answers the first name that reaches the globals, `require` or
--- `package` (given as its arguments), or nil.
local WALK <const> = [[
local globals, require_function, package_table, host = ...
local function reaches(value)
  if value == globals or value == require_function or value == package_table then return true end
  for _, held in ipairs(host) do
    if value == held then return true end
  end
  return false
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
  -- The host's libraries and the metatable of its strings, which a chunk must not be handed or write to.
  local host_chunk = assert(load("return { string, table, math, utf8, coroutine, getmetatable(''), " ..
    "getmetatable('').__index }", "=host_values", "t", globals))
  local host: any = host_chunk()
  local found: any = chunk(globals, globals["require"], globals["package"], host)
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

--- What the host reads of `name` in its own libraries, with the globals as the chunk's environment.
local function host_reads(source: string): any
  local chunk = assert(load(source, "=host", "t", Globals.table()))
  local value: any = chunk()
  return value
end

local function test_a_chunk_that_writes_into_a_library_changes_its_own_copy_and_not_the_hosts()
  run("string.rep = function() return 'POISON' end")
  assert(host_reads("return ('a'):rep(2)") == "aa", "string.rep reached the host")
  run("table.insert = function() error('POISON') end math.floor = function() return -1 end")
  run("utf8.char = function() return 'POISON' end coroutine.wrap = function() return 'POISON' end")
  assert(host_reads("local t = {} table.insert(t, 1) return #t") == 1, "table.insert reached the host")
  assert(host_reads("return math.floor(1.5)") == 1, "math.floor reached the host")
  assert(host_reads("return utf8.char(65)") == "A", "utf8.char reached the host")
  assert(host_reads("return type(coroutine.wrap(function() end))") == "function", "coroutine.wrap reached the host")
  -- The next chunk starts from the libraries as they were.
  assert(run("return string.rep('a', 2)") == "aa", "a chunk saw what another wrote")
end

local function test_a_chunk_that_writes_through_a_strings_metatable_changes_a_copy()
  run("getmetatable('').__index.rep = function() return 'POISON' end")
  run("getmetatable('').__index = {}")
  run("rawset(getmetatable(''), '__index', nil)")
  assert(host_reads("return ('a'):rep(2)") == "aa", "the string metatable reached the host")
  assert(host_reads("return getmetatable('').__index == string") == true, "the host's string metatable changed")
end
