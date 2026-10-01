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
local ast = require("build.ast")
local gen_syscalls = require("build.gen_syscalls")
local teal = require("build.teal")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")

-- Every wrapper core/store.c hands a raw module to (`wrappers`, below),
-- required so it is of the closure: the store's searcher, asked by hand
-- ([`raw_behind`]), hands its raw value only for a module the closure
-- holds.
local type _artifact = require("build.artifact")
local type _digest = require("build.digest")
local type _test_worker = require("build.test_worker")
local type _confine = require("build.confine")
local type _fuzz = require("build.fuzz")
local type _coverage_hits = require("build.coverage_hits")
local type _child = require("cosmic.child")
local type _compress = require("cosmic.compress")
local type _coverage = require("cosmic.coverage")
local type _hash = require("cosmic.hash")
local type _http = require("cosmic.http")
local type _json = require("cosmic.json")
local type _net = require("cosmic.net")
local type _proc = require("cosmic.proc")
local type _sqlite = require("cosmic.sqlite")
local type _store = require("cosmic.store")

--- Every declaration of the core's raw modules, the headers the process
--- and socket tables' are derived from, and core/store.c, whose `raw_modules` names
--- the wrapper each raw module is handed to.
Test.needs{ reads = { "cosmic/internal/", "core/process.h", "core/socket.h", "core/store.c" } }

local built = assert(teal.load())

--- A value of the core's, read by name.
local function members(value: any): {string: any}
  local t = type(value)
  assert(t == "table" or t == "userdata", "not a table: " .. t)
  return value as {string: any} -- cast: checked above to be indexable
end

local type Searcher = function(string): any, any
local type Call = function(...: any): any...

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

local function nothing() end

local preloaded <const>: {string: boolean} = { errors = true, testing = true }

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
--- releases them, made in `tmp` where a file is made.
local record Made
  instances: {string: any}
  release: function()
end

local makers: {string: function(raw: {string: any}, tmp: string): Made} = {
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
  socket = function(raw: {string: any}, tmp: string): Made
    local socket = assert(call(raw.listen, { kind = "unix", path = tmp .. "/s.sock" }, 1))
    return { instances = { Socket = socket },
      release = function() call(members(socket).close, socket) end }
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
--- [`test_every_raw_module_has_a_declaration`] fails when the two part.
local wrappers <const>: {string: string} = {
  ["build.artifact"] = "store",
  ["build.digest"] = "hash",
  ["build.test_worker"] = "store",
  ["build.confine"] = "process",
  ["build.fuzz"] = "budget",
  ["build.coverage_hits"] = "debug",
  ["cosmic.child"] = "process",
  ["cosmic.compress"] = "compress",
  ["cosmic.coverage"] = "debug",
  ["cosmic.hash"] = "hash",
  ["cosmic.http"] = "http",
  ["cosmic.json"] = "json",
  ["cosmic.net"] = "socket",
  ["cosmic.proc"] = "process",
  ["cosmic.sqlite"] = "sqlite",
  ["cosmic.store"] = "store",
}

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
  return (assert(raw_behind(wrapper), wrapper .. " is handed no raw value " ..
    "(require it with `local type` at the top so it is in the closure)"))
end

--- The raw modules whose declaration the build derives from a header
--- (build/gen_syscalls.tl) rather than a cosmic/internal/*.d.tl, by
--- name, and the target that derives it.
local derived <const>: {string: gen_syscalls.Target} = {}
for _, derivation in ipairs(gen_syscalls.targets) do
  local name = derivation.path:match("^cosmic%.internal%.(.+)$")
  if name ~= nil then derived[name] = derivation.target end
end

--- A raw module's declaration: its cosmic/internal/*.d.tl, or the one
--- the build derives from its header.
local function declaration_of(name: string): string
  local target = derived[name]
  if target ~= nil then
    return (assert(gen_syscalls.declaration(assert(Fs.read(target.header)), target)))
  end
  return (assert(Fs.read("cosmic/internal/" .. name .. ".d.tl")))
end

--- Every declaration under cosmic/internal, and each the build derives
--- from a header, is what the running core registers.
local function test_every_declaration_is_what_the_core_registers(tmp: string)
  local problems: {string} = {}
  local names: {string} = {}
  for _, entry in ipairs((assert(Fs.list("cosmic/internal")))) do
    local name = entry:match("^(.+)%.d%.tl$")
    if name ~= nil then names[#names + 1] = name end
  end
  assert(#names > 0, "no declarations under cosmic/internal")
  for name in pairs(derived) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local raw = raw_module(name)
    local maker = makers[name]
    local made: Made = maker ~= nil and maker(members(raw), tmp)
      or { instances = {}, release = nothing }
    local source = declaration_of(name)
    for _, problem in ipairs(disagreements(name, source, raw, made.instances)) do
      problems[#problems + 1] = problem
    end
    made.release()
  end
  assert(#problems == 0, "the core and its declarations disagree (" ..
    testing.configuration .. " core):\n  " .. table.concat(problems, "\n  "))
end

--- The `raw_modules` table of core/store.c's `source`: the raw module
--- each wrapper is handed, by the wrapper's name, less the
--- `cosmic.internal.` prefix; or nil and why when the table is not all
--- entries of the shape this reads -- a macro, a comment, an entry
--- spelled otherwise -- rather than answer part of it.
local function raw_modules_in(source: string): {string: string} | nil, string
  local body = source:match("%} raw_modules%[%] = {\n(.-)\n};")
  if body == nil then
    return nil, "core/store.c declares no raw_modules table this test can read"
  end
  local out: {string: string} = {}
  local read = 0
  local entry = '{"([%w_.]+)",%s*"cosmic%.internal%.([%w_]+)",%s*[%w_]+%s*},'
  for wrapper, raw in body:gmatch(entry) do
    out[wrapper] = raw
    read = read + 1
  end
  local rest = body:gsub(entry, ""):gsub("%s", "")
  if rest ~= "" then
    return nil, "core/store.c's raw_modules holds what this test cannot read as an " ..
      "entry: " .. rest
  end
  if read < 10 then
    return nil, "read only " .. read .. " raw_modules entries of core/store.c"
  end
  return out, ""
end

--- Every wrapper core/store.c hands a raw value to is one this test
--- holds to a declaration, by the raw module it is handed, so a raw
--- module no declaration names fails here; and the running core hands
--- each one its raw value.
local function test_every_raw_module_has_a_declaration()
  local in_c = assert(raw_modules_in((assert(Fs.read("core/store.c")))))
  for wrapper, raw in pairs(in_c) do
    assert(wrappers[wrapper] == raw, wrapper .. " is handed cosmic.internal." .. raw ..
      ", which `wrappers` here names as " .. tostring(wrappers[wrapper]))
  end
  for wrapper in pairs(wrappers) do
    assert(in_c[wrapper] ~= nil, wrapper .. " is no wrapper of core/store.c's raw_modules")
    assert(raw_behind(wrapper) ~= nil, wrapper .. " is handed no raw value " ..
      "(require it with `local type` at the top so it is in the closure)")
  end
end

--- An entry of `raw_modules` this test cannot read -- a macro standing
--- for one, a comment -- fails the read rather than go uncounted.
local function test_an_unreadable_raw_modules_entry_is_refused()
  local source = assert(Fs.read("core/store.c"))
  assert(raw_modules_in(source) ~= nil)
  for _, planted in ipairs({ "  RAW_ENTRY(cosmic.planted),\n", "  /* planted */\n" }) do
    local with = source:gsub("(%} raw_modules%[%] = {\n)", "%1" .. planted)
    assert(with ~= source, "the table was not found to plant in")
    local found, why = raw_modules_in(with)
    assert(found == nil and why:find("cannot read", 1, true) ~= nil, why)
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
