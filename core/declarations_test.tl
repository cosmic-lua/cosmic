--- The hand-written declarations of the core's raw modules,
--- cosmic/internal/*.d.tl, hold to what the running core registers:
--- every member a declaration names is in the table its C builds, a
--- function where it declares a function, and every member that table
--- holds is declared. A userdata record is held to the metatable of one
--- value made of it: its methods to `__index`, its metamethods to the
--- rest. A test run holds each core it runs on to them, the checked one
--- included, so a member only one configuration registered would fail
--- the other's run; a checked-only instrument is registered by every
--- core instead, raising outside the checked one (core/testing.c).

-- TODO: hold each function's result count, the records the C builds
-- as tables (store.Core, debug.Function), and json.null's metatable to
-- their declarations too; this compares names and whether each is a
-- function, nothing of a function's signature, and never looks inside
-- a declared value such as json.null.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local ast = require("build.ast")
local teal = require("build.teal")
local testing = require("cosmic.internal.testing")

local built = assert(teal.load())

local type Searcher = function(string): any, any
local type Call = function(...: any): any...

--- A value of the core's, read by name.
local function members(value: any): {string: any}
  local t = type(value)
  assert(t == "table" or t == "userdata", "not a table: " .. t)
  return value as {string: any} -- cast: checked above to be indexable
end

--- Calls a function of the core's, whatever its declared signature.
local function call(f: any, ...: any): any...
  assert(type(f) == "function", "not a function: " .. type(f))
  return (f as Call)(...) -- cast: checked above to be callable
end

--- What one record declares: each value member by name, true for a
--- function; each metamethod the same way; and, for a userdata record
--- nested in it, the same again under its name.
local record Surface
  fields: {string: boolean}
  metamethods: {string: boolean}
  userdata: boolean
  nested: {string: Surface}
end

local function surface_of(def: ast.TypeNode): Surface
  local s: Surface = { fields = {}, metamethods = {}, userdata = def.is_userdata == true,
    nested = {} }
  for _, name in ipairs(def.field_order or {}) do
    local field = (def.fields or {})[name]
    if field.typename == "typedecl" then
      local inner = field.def
      if inner ~= nil and inner.typename == "record" then
        s.nested[name] = surface_of(inner)
      end
    else
      s.fields[name] = field.typename == "function"
    end
  end
  for _, name in ipairs(def.meta_field_order or {}) do
    s.metamethods[name] = (def.meta_fields or {})[name].typename == "function"
  end
  return s
end

--- The record a declaration's source returns.
local function declared(source: string, file: string): Surface
  local parsed = assert(ast.parse(built, source, file))
  local chunk = parsed.node
  local last = chunk[#chunk]
  assert(last.kind == "return" and last.exps ~= nil, file .. " returns no record")
  local returned = last.exps[1].tk
  for _, stmt in ipairs(chunk) do
    local value = stmt.value
    local typedecl = value ~= nil and value.kind == "newtype" and value.newtype or nil
    if stmt.kind == "local_type" and stmt.var ~= nil and stmt.var.tk == returned
        and typedecl ~= nil and typedecl.def ~= nil then
      return surface_of(typedecl.def)
    end
  end
  error(file .. " returns " .. tostring(returned) .. ", which is no record it declares")
end

--- Where each of `actual`'s members disagrees with `fields`, as lines
--- naming `where`.
local function compare(where: string, fields: {string: boolean}, actual: {string: any},
                       problems: {string})
  for name, is_function in pairs(fields) do
    local value = actual[name]
    if value == nil then
      problems[#problems + 1] = where .. name .. " is declared but not registered"
    elseif (type(value) == "function") ~= is_function then
      problems[#problems + 1] = where .. name .. " is declared as a " ..
        (is_function and "function" or "value") .. " but registered as a " .. type(value)
    end
  end
  for name in pairs(actual) do
    if fields[name] == nil then
      problems[#problems + 1] = where .. tostring(name) .. " is registered but not declared"
    end
  end
end

--- The metamethods a declaration has no way to say, or no reason to:
--- the lookup, the type's name and the collector's.
local undeclared_metamethods <const>: {string: boolean} = {
  __index = true, __name = true, __gc = true,
}

--- Where the raw module `raw`, and `instances`, one value of each
--- userdata record by the record's name, disagree with the declaration
--- `source`, named `module`.
local function disagreements(module: string, source: string, raw: any,
                             instances: {string: any}): {string}
  local surface = declared(source, module .. ".d.tl")
  local problems: {string} = {}
  compare(module .. ".", surface.fields, members(raw), problems)
  local names: {string} = {}
  for name, nested in pairs(surface.nested) do
    if nested.userdata then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local nested = surface.nested[name]
    local where = module .. "." .. name
    local instance = instances[name]
    if instance == nil then
      problems[#problems + 1] = where .. " is userdata this test makes none of"
    else
      local mt = members(getmetatable(instance))
      local index = mt.__index
      local methods: {string: any} = {}
      local metamethods: {string: any} = {}
      if index == mt then
        -- One table for both, as `mt.__index = mt` makes it: a name
        -- with a leading `__` is a metamethod, any other a method.
        for key, value in pairs(mt) do
          if key:sub(1, 2) ~= "__" then
            methods[key] = value
          elseif not undeclared_metamethods[key] then
            metamethods[key] = value
          end
        end
      else
        if type(index) == "function" then
          problems[#problems + 1] = where .. "'s __index is a function, whose methods " ..
            "this test cannot list"
        elseif index ~= nil then
          methods = members(index)
        end
        for key, value in pairs(mt) do
          if not undeclared_metamethods[key] then metamethods[key] = value end
        end
      end
      if type(index) ~= "function" then
        compare(where .. ":", nested.fields, methods, problems)
      end
      compare(where .. ".", nested.metamethods, metamethods, problems)
    end
  end
  table.sort(problems)
  return problems
end

--- The raw value the store's searcher hands `wrapper`'s loader, the
--- way `require` hands it, or nil when it hands none.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then
      return extra
    end
  end
  return nil
end

local function reply(): string
  return "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
end

--- One of each userdata a raw module makes, by record name, and what
--- releases them.
local record Made
  instances: {string: any}
  release: function()
end

local function nothing() end

local makers: {string: function(raw: {string: any}): Made} = {
  compress = function(raw: {string: any}): Made
    local stream = assert(call(raw.inflater, "raw"))
    return { instances = { Stream = stream }, release = nothing }
  end,
  hash = function(raw: {string: any}): Made
    local hasher = assert(call(raw.hasher, "sha256"))
    return { instances = { Hasher = hasher }, release = nothing }
  end,
  http = function(raw: {string: any}): Made
    local handle = assert(call(raw.open, "http://declarations.invalid/",
      { script = { reply() } }))
    return { instances = { Handle = handle },
      release = function() call(members(handle).close, handle) end }
  end,
  sqlite = function(raw: {string: any}): Made
    local handle = assert(call(raw.open, ":memory:", true))
    local statement = assert(call(members(handle).prepare, handle, "SELECT 1"))
    return { instances = { Handle = handle, Statement = statement },
      release = function()
        call(members(statement).finalize, statement)
        call(members(handle).close, handle)
      end }
  end,
}

--- Every wrapper the store hands a raw module to, and the name of the
--- raw module's declaration. The preloaded ones have no wrapper. Edit
--- it together with core/store.c's `raw_modules`, which it repeats:
--- `test_every_raw_module_has_a_declaration` fails when the two part.
local wrappers <const>: {string: string} = {
  ["build.artifact"] = "store",
  ["build.fuzz"] = "budget",
  ["cosmic.compress"] = "compress",
  ["cosmic.coverage"] = "debug",
  ["cosmic.hash"] = "hash",
  ["cosmic.http"] = "http",
  ["cosmic.json"] = "json",
  ["cosmic.sqlite"] = "sqlite",
  ["cosmic.store"] = "store",
}

local preloaded <const>: {string: boolean} = { errors = true, testing = true }

--- The raw module a declaration names, as the running core registers it.
local function raw_module(name: string): any
  if preloaded[name] then
    local open = package.preload["cosmic.internal." .. name]
    assert(open ~= nil, "cosmic.internal." .. name .. " is not preloaded")
    return open("cosmic.internal." .. name)
  end
  local wrapper: string = nil
  for candidate, declaration in pairs(wrappers) do
    if declaration == name and (wrapper == nil or candidate < wrapper) then
      wrapper = candidate
    end
  end
  assert(wrapper ~= nil, "cosmic/internal/" .. name .. ".d.tl declares a module " ..
    "this test does not know how to reach")
  return (assert(raw_behind(wrapper), wrapper .. " is handed no raw value"))
end

local function test_every_declaration_is_what_the_core_registers()
  local problems: {string} = {}
  local names: {string} = {}
  for _, entry in ipairs((assert(Fs.list("cosmic/internal")))) do
    local name = entry:match("^(.+)%.d%.tl$")
    if name ~= nil then names[#names + 1] = name end
  end
  table.sort(names)
  assert(#names > 0, "no declarations under cosmic/internal")
  for _, name in ipairs(names) do
    local raw = raw_module(name)
    local maker = makers[name]
    local made: Made = maker ~= nil and maker(members(raw))
      or { instances = {}, release = nothing }
    local source = assert(Fs.read("cosmic/internal/" .. name .. ".d.tl"))
    for _, problem in ipairs(disagreements(name, source, raw, made.instances)) do
      problems[#problems + 1] = problem
    end
    made.release()
  end
  assert(#problems == 0, "the core and its declarations disagree (" ..
    testing.configuration .. " core):\n  " .. table.concat(problems, "\n  "))
end

--- Every wrapper the store hands a raw value to is one this test holds
--- to a declaration, so a raw module no declaration names fails here.
local function test_every_raw_module_has_a_declaration()
  local known: {string: boolean} = {}
  for wrapper in pairs(wrappers) do known[wrapper] = true end
  local seen: {string: boolean} = {}
  for _, db in ipairs(Store.databases()) do
    for _, row in ipairs((assert(Sqlite.text_rows(db,
        "SELECT path FROM modules WHERE kind = 'module'")))) do
      local name = row[1]
      if not seen[name] then
        seen[name] = true
        if raw_behind(name) ~= nil then
          assert(known[name], name .. " is handed a raw value no declaration here names")
        end
      end
    end
  end
  for wrapper in pairs(known) do
    assert(seen[wrapper], wrapper .. " is no module of the store's")
  end
end

--- Every raw module the core preloads, but the syscall table, which
--- core/syscalls.h declares (build/gen_syscalls.tl), has a declaration
--- here, so a preloaded module cannot go undeclared.
local function test_every_preloaded_raw_module_has_a_declaration()
  local found = 0
  for key in pairs(package.preload) do
    local name = key:match("^cosmic%.internal%.(.+)$")
    if name ~= nil then
      found = found + 1
      assert(preloaded[name], key .. " is preloaded but this test does not reach it")
      assert(Fs.exists("cosmic/internal/" .. name .. ".d.tl"),
        key .. " is preloaded but cosmic/internal/" .. name .. ".d.tl does not declare it")
    end
  end
  for name in pairs(preloaded) do
    assert(package.preload["cosmic.internal." .. name] ~= nil,
      "cosmic.internal." .. name .. " is not preloaded")
  end
  assert(found > 0, "no cosmic.internal module is preloaded")
end

local declaration <const> = [[
local record m
  record Thing
    userdata
    poke: function(Thing): integer
    metamethod __close: function(Thing)
  end
  type Alias = {string: integer}
  open: function(): Thing
  version: string
end
return m
]]

--- Makes a thing whose metatable holds `methods` and `metamethods`.
local function thing(methods: {string: any}, metamethods: {string: any}): any
  local mt: {string: any} = { __index = methods, __name = "thing", __gc = nothing }
  for key, value in pairs(metamethods) do mt[key] = value end
  local stand_in: any = {}
  return setmetatable(stand_in, mt as metatable<any>) -- cast: a stand-in userdata
end

local function check(raw: {string: any}, methods: {string: any},
                     metamethods: {string: any}): {string}
  return disagreements("m", declaration, raw, { Thing = thing(methods, metamethods) })
end

local function test_a_module_that_matches_its_declaration_passes()
  local problems = check({ open = nothing, version = "1" }, { poke = nothing },
    { __close = nothing })
  assert(#problems == 0, table.concat(problems, "\n"))
end

local function test_a_declared_member_the_core_lacks_is_named()
  local problems = check({ open = nothing }, { poke = nothing }, { __close = nothing })
  assert(#problems == 1 and problems[1] == "m.version is declared but not registered",
    table.concat(problems, "\n"))
end

local function test_a_registered_member_nothing_declares_is_named()
  local problems = check({ open = nothing, version = "1", extra = nothing },
    { poke = nothing, prod = nothing }, { __close = nothing, __len = nothing })
  assert(#problems == 3, table.concat(problems, "\n"))
  assert(problems[1] == "m.Thing.__len is registered but not declared", problems[1])
  assert(problems[2] == "m.Thing:prod is registered but not declared", problems[2])
  assert(problems[3] == "m.extra is registered but not declared", problems[3])
end

local function test_a_function_declared_as_a_value_is_named()
  local problems = check({ open = "no", version = "1" }, { poke = nothing },
    { __close = nothing })
  assert(#problems == 1 and
    problems[1] == "m.open is declared as a function but registered as a string",
    table.concat(problems, "\n"))
end

local function test_a_missing_method_or_metamethod_is_named()
  local problems = check({ open = nothing, version = "1" }, {}, {})
  assert(#problems == 2, table.concat(problems, "\n"))
  assert(problems[1] == "m.Thing.__close is declared but not registered", problems[1])
  assert(problems[2] == "m.Thing:poke is declared but not registered", problems[2])
end

local function test_a_metatable_that_is_its_own_index_is_split_by_name()
  local mt: {string: any} = { __name = "thing", __close = nothing, poke = nothing }
  mt.__index = mt
  local stand_in: any = {}
  local problems = disagreements("m", declaration, { open = nothing, version = "1" },
    { Thing = setmetatable(stand_in, mt as metatable<any>) }) -- cast: a stand-in userdata
  assert(#problems == 0, table.concat(problems, "\n"))
  mt.poke = nil
  mt.prod = nothing
  problems = disagreements("m", declaration, { open = nothing, version = "1" },
    { Thing = setmetatable(stand_in, mt as metatable<any>) }) -- cast: a stand-in userdata
  assert(#problems == 2, table.concat(problems, "\n"))
  assert(problems[1] == "m.Thing:poke is declared but not registered", problems[1])
  assert(problems[2] == "m.Thing:prod is registered but not declared", problems[2])
end

local function test_a_function_index_is_named_rather_than_listed()
  local mt: {string: any} = { __index = function(): any return nil end, __close = nothing }
  local stand_in: any = {}
  local problems = disagreements("m", declaration, { open = nothing, version = "1" },
    { Thing = setmetatable(stand_in, mt as metatable<any>) }) -- cast: a stand-in userdata
  assert(#problems == 1 and problems[1] ==
    "m.Thing's __index is a function, whose methods this test cannot list",
    table.concat(problems, "\n"))
end

local function test_userdata_the_test_makes_none_of_is_named()
  local problems = disagreements("m", declaration, { open = nothing, version = "1" }, {})
  assert(#problems == 1 and problems[1] == "m.Thing is userdata this test makes none of",
    table.concat(problems, "\n"))
end
