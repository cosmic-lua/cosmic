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
local Ast = require("lang.ast")
local AnalysisSchema = require("build.analysis_schema")
local gen_syscalls = require("build.gen_syscalls")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")

-- Every module that opens a raw module, required so that it is of the closure
-- and has made the raw module ready, as cosmic.http loads the CA roots its
-- raw `open` needs. The store's searcher, asked by hand for a wrapper in
-- `wrappers` below, hands its raw value only for a module the closure holds.
local type _artifact = require("build.artifact")
local type _assertions = require("build.assertions")
local type _digest = require("build.digest")
local type _test_worker = require("build.test_worker")
local type _confine = require("build.confine")
local type _fuzz = require("build.fuzz")
local type _coverage_hits = require("build.coverage_hits")
local type _child = require("cosmic.child")
local type _connector = require("cosmic.internal.connector")
local type _compress = require("cosmic.compress")
local type _coverage = require("cosmic.coverage")
local type _hash = require("cosmic.hash")
local type _html = require("cosmic.html")
local type _http = require("cosmic.http")
local type _json = require("cosmic.json")
local type _net = require("cosmic.net")
local type _proc = require("cosmic.proc")
local type _sandbox = require("cosmic.sandbox")
local type _sqlite = require("cosmic.sqlite")
local type _store = require("cosmic.store")
local type _tar = require("cosmic.tar")
local type _vector = require("cosmic.vector")
local type _xml = require("cosmic.xml")
local type _zip = require("cosmic.zip")

--- Every declaration of the core's raw modules, the headers the process
--- and socket tables' are derived from, and core/store.c, whose `raw_modules` names
--- the wrapper each raw module is handed to.
Test.policy{
  cpu_features = true,
  grants = {
    { path = "cosmic/internal/", letters = "r" },
    { path = "core/process.h", letters = "r" },
    { path = "core/socket.h", letters = "r" },
    { path = "core/store.c", letters = "r" },
  },
  loopback = { "127.0.0.1" },
}

--- A value of the core's, read by name.
local function members(value: any): {string: any}
  local t = type(value)
  assert(t == "table" or t == "userdata", "not a table: " .. t)
  return value as {string: any} -- cast: checked above to be indexable
end

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
  fields: mut {string: boolean}
  metamethods: mut {string: boolean}
  userdata: boolean
  nested: mut {string: Surface}
end

--- Whether `members` hold the `userdata` marker of a record.
local function marks_userdata(items: {Ast.Member}): boolean
  for _, inner in ipairs(items) do
    if inner.kind == "Userdata" then
      return true
    end
  end
  return false
end

local function surface_of(items: {Ast.Member}, is_userdata: boolean): Surface
  local s: Surface = { fields = {}, metamethods = {}, userdata = is_userdata, nested = {} }
  for _, member in ipairs(items) do
    if member.kind == "FieldDecl" then
      local name = member.name.name
      local is_function = member.type.kind == "TypeFunction"
      if name:sub(1, 2) == "__" then
        s.metamethods[name] = is_function
      else
        s.fields[name] = is_function
      end
    elseif member.kind == "Record" then
      s.nested[member.name.name] = surface_of(member.members, marks_userdata(member.members))
    end
  end
  return s
end

--- The record a declaration's source returns.
local function declared(source: string, file: string): Surface
  local parsed = Parser.parse(Lexer.lex(source, file), file, "decl")
  local first_error = parsed.errors[1]
  assert(#parsed.errors == 0, file .. ": " .. (if first_error ~= nil then first_error.msg else "" end))
  local body = parsed.chunk.body.stats
  local last = body[#body]
  assert(last ~= nil and last.kind == "Return", file .. " returns no record")
  local first = last.values[1]
  assert(first ~= nil and first.kind == "Name", file .. " returns no record")
  local returned = first.text
  for _, stmt in ipairs(body) do
    if stmt.kind == "Record" and stmt.name.name == returned then
      return surface_of(stmt.members, marks_userdata(stmt.members))
    end
  end
  error(file .. " returns " .. returned .. ", which is no record it declares")
end

--- Where each of `actual`'s members disagrees with `fields`, as lines
--- naming `where`.
local function compare(where: string, fields: {string: boolean}, actual: {string: any},
                       problems: mut {string})
  for name, is_function in pairs(fields) do
    local value = actual[name]
    if value == nil then
      problems[#problems + 1] = where .. name .. " is declared but not registered"
    elseif (type(value) == "function") ~= is_function then
      table.insert(problems, where .. name .. " is declared as a " ..
          (if is_function then "function" else "value" end) .. " but registered as a " .. type(value))
    end
  end
  for name in pairs(actual) do
    if fields[name] == nil then
      table.insert(problems, where .. tostring(name) .. " is registered but not declared")
    end
  end
end

--- The metamethods a declaration has no way to say, or no reason to:
--- the lookup, the type's name and the collector's.
local undeclared_metamethods <const>: {string: boolean} = {
  __index = true, __name = true, __gc = true, __metatable = true,
}

--- What `getmetatable` answers for `value`: `false` for a type that
--- hides its metatable.
local function metatable_of(value: any): any
  return getmetatable(value)
end

--- Where the raw module `raw`, and `instances`, one value of each
--- userdata record by the record's name, disagree with the declaration
--- `source`, named `module`.
local function disagreements(module: string, source: string, raw: any,
                             instances: {string: any}): {string}
  local surface = declared(source, module .. ".d.tl")
  local problems: mut {string} = {}
  compare(module .. ".", surface.fields, members(raw), problems)
  local names: mut {string} = {}
  for name, nested in pairs(surface.nested) do
    if nested.userdata then names[#names + 1] = name end
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local nested = assert(surface.nested[name], "the names are those of surface.nested")
    local where = module .. "." .. name
    local instance = instances[name]
    if instance == nil then
      problems[#problems + 1] = where .. " is userdata this test makes none of"
    elseif metatable_of(instance) == false then
      -- A type that hides its metatable (`__metatable = false`) has no
      -- members to list, so a declaration that names one is refused.
      -- TODO: read a hidden metatable once cosmic has a debug.getmetatable
      -- replacement, to hold its own fields to the declaration too.
      if next(nested.fields) ~= nil or next(nested.metamethods) ~= nil then
        problems[#problems + 1] = where .. " is declared with members but hides its metatable"
      end
    else
      local mt = members(getmetatable(instance))
      local index = mt.__index
      local methods: mut {string: any} = {}
      local metamethods: mut {string: any} = {}
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

local preloaded <const>: {string: boolean} = { errors = true, globals = true, testing = true }

local function reply(): string
  return "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
end

--- One of each userdata a raw module makes, by record name, and what
--- releases them.
local record Made
  instances: {string: any}
  release: function()
end

local makers: {string: function(raw: {string: any}): Made} = {
  compress = function(raw: {string: any}): Made
    local stream = assert(call(raw.inflater, "raw"))
    return { instances = { Stream = stream }, release = nothing }
  end,
  hash = function(raw: {string: any}): Made
    local hasher = assert(call(raw.hasher, "sha256"))
    return { instances = { Hasher = hasher }, release = nothing }
  end,
  html = function(raw: {string: any}): Made
    return { instances = { SafeHtml = call(raw.escape, "<"), SafeAttr = call(raw.escape_attr, "<"),
      SafeUrl = call(raw.href, "/"), SafeUrlPart = call(raw.url_part, "x"), SafeJson = call(raw.trust_json, "1") },
      release = nothing }
  end,
  http = function(raw: {string: any}): Made
    local handle = assert(call(raw.open, "http://declarations.invalid/",
      { script = { reply() } }))
    return { instances = { Handle = handle },
      release = function() call(members(handle).close, handle) end }
  end,
  json = function(raw: {string: any}): Made
    return { instances = { Null = raw["null"] }, release = nothing }
  end,
  socket = function(raw: {string: any}): Made
    -- A TCP listener on the worker's own loopback: a unix one needs a `u`
    -- grant the policy path cannot give below Landlock ABI 9.
    local socket = assert(call(raw.listen, { kind = "tcp", host = "127.0.0.1", port = 0 }, 1))
    -- A numeric address answers itself, so the lookup opens nothing.
    local lookup = assert(call(raw.lookup, "127.0.0.1", -1))
    return { instances = { Socket = socket, Lookup = lookup },
      release = function()
        call(members(socket).close, socket)
        call(members(lookup).close, lookup)
      end }
  end,
  xml = function(raw: {string: any}): Made
    local parser = assert(call(raw["parser"]))
    return { instances = { Parser = parser }, release = nothing }
  end,
  vector = function(raw: {string: any}): Made
    return { instances = { Corpus = call(raw["corpus"], 4) }, release = nothing }
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
--- raw module's declaration: the four values that steer the process, which
--- `require` never answers by name. The others, and the preloaded ones,
--- have no wrapper. Edit it together with core/store.c's `raw_modules`,
--- which it repeats: [`test_every_raw_module_has_a_declaration`] fails when
--- the two part.
local wrappers <const>: {string: string} = {
  ["build.artifact"] = "store",
  ["build.test_worker"] = "store",
  ["build.assertions"] = "assertions",
  ["build.fuzz"] = "budget",
  ["build.coverage_hits"] = "debug",
  ["cosmic.coverage"] = "debug",
  ["cosmic.store"] = "store",
}

local type Loader = function(arg1?: string, arg2?: any): any

--- What the store's searchers answer for `asked`: the loader of a module and the value beside it, or nil.
local function searched(asked: string): Loader?, any
  for _, searcher in ipairs(package.searchers) do
    local loader, extra = searcher(asked)
    if type(loader) == "function" then return loader, extra end
  end
  return nil, nil
end

--- The raw module a declaration names, as the running core registers it:
--- a plain one is what `require` answers by its name, and the others are
--- what the store hands the first wrapper that takes them.
local function raw_module(name: string): any
  if preloaded[name] then
    local open = package.preload["cosmic.internal." .. name]
    assert(open ~= nil, "cosmic.internal." .. name .. " is not preloaded")
    return open("cosmic.internal." .. name)
  end
  local wrapper: string? = nil
  for candidate, declaration in pairs(wrappers) do
    if declaration == name and (wrapper == nil or candidate < wrapper) then
      wrapper = candidate
    end
  end
  if wrapper == nil then
    local loader, extra = searched("cosmic.internal." .. name)
    assert(loader ~= nil, "cosmic.internal." .. name .. " is no module the store answers by its name")
    return loader("cosmic.internal." .. name, extra)
  end
  local _, extra = searched(wrapper)
  assert(type(extra) == "table", wrapper .. " is handed no raw table")
  return extra
end

--- The raw modules whose declaration the build derives from a header
--- (build/gen_syscalls.tl) rather than a cosmic/internal/*.d.tl, by
--- name, and the target that derives it.
local derived <const>: mut {string: gen_syscalls.Target} = {}
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

--- A declaration file: its path below the root and its text.
local record Declaration
  path: string
  text: string
end

--- The raw modules among `declarations`, by the kind `binding` the build
--- gives a declaration ([`build.analysis_schema`]'s `kind_of`, which the
--- `inputs` view of the build's database also answers), and a line for each
--- declaration that is none. Such a declaration is no raw module for this
--- test to skip: it is named, with the line that makes it one.
local function split_bindings(declarations: {Declaration}): {string}, {string}
  local names: mut {string} = {}
  local refused: mut {string} = {}
  for _, each in ipairs(declarations) do
    if AnalysisSchema.kind_of(each.path, each.text) == "binding" then
      names[#names + 1] = assert(each.path:match("([^/]+)%.d%.tl$"), each.path .. " is no declaration file")
    else
      refused[#refused + 1] = each.path .. " is no binding: if it declares a module implemented in C, add the line `" ..
        AnalysisSchema.binding_tag() .. "` to its leading comment block"
    end
  end
  table.sort(names)
  table.sort(refused)
  return names, refused
end

--- Every declaration of a raw module: each under cosmic/internal, and each
--- the build derives from a header.
local function declarations_of_the_core(): {Declaration}
  local out: mut {Declaration} = {}
  for _, entry in ipairs((assert(Fs.list("cosmic/internal")))) do
    if entry:match("%.d%.tl$") ~= nil then
      local path = "cosmic/internal/" .. entry
      out[#out + 1] = { path = path, text = assert(Fs.read(path)) }
    end
  end
  for name in pairs(derived) do
    out[#out + 1] = { path = "cosmic/internal/" .. name .. ".d.tl", text = declaration_of(name) }
  end
  return out
end

--- Every binding of C -- each declaration under cosmic/internal, and each
--- the build derives from a header -- is what the running core registers.
local function test_every_declaration_is_what_the_core_registers()
  local problems: mut {string} = {}
  local names, refused = split_bindings(declarations_of_the_core())
  assert(#refused == 0, table.concat(refused, "\n"))
  assert(#names > 0, "no bindings under cosmic/internal")
  for _, name in ipairs(names) do
    local raw = raw_module(name)
    local maker = makers[name]
    local made: Made = maker ~= nil and maker(members(raw)) or
      { instances = {}, release = nothing }
    local source = declaration_of(name)
    for _, problem in ipairs(disagreements(name, source, raw, made.instances)) do
      problems[#problems + 1] = problem
    end
    made.release()
  end
  assert(#problems == 0, "the core and its declarations disagree (" ..
      testing.configuration .. " core):\n  " .. table.concat(problems, "\n  "))
end

--- The entries of the table `table_name` of core/store.c's `source`, each as
--- its pattern `entry` reads them (two captures); or nil and why when the
--- table is not all entries of that shape -- a macro, a comment, an entry
--- spelled otherwise -- rather than answer part of it.
local function table_in(source: string, table_name: string, entry: string, least: integer): {{string}}?, string
  local body = source:match("%} " .. table_name .. "%[%] = {\n(.-)\n};")
  if body == nil then
    return nil, "core/store.c declares no " .. table_name .. " table this test can read"
  end
  local out: mut {{string}} = {}
  for first, second in body:gmatch(entry) do
    out[#out + 1] = { assert(first), assert(second) }
  end
  local rest = body:gsub(entry, ""):gsub("%s", "")
  if rest ~= "" then
    return nil, "core/store.c's " .. table_name .. " holds what this test cannot read as an entry: " .. rest
  end
  if #out < least then
    return nil, "read only " .. tostring(#out) .. " " .. table_name .. " entries of core/store.c"
  end
  return out, ""
end

--- The `raw_modules` table of core/store.c's `source`: the raw module each
--- wrapper is handed, by the wrapper's name, less the `cosmic.internal.`
--- prefix; or nil and why.
local function raw_modules_in(source: string): {string: string}?, string
  local rows, why = table_in(source, "raw_modules", '{"([%w_.]+)",%s*"cosmic%.internal%.([%w_]+)"},', 5)
  if rows == nil then return nil, why end
  local out: mut {string: string} = {}
  for _, row in ipairs(rows) do
    local wrapper, raw = row[1], row[2]
    if wrapper ~= nil and raw ~= nil then out[wrapper] = raw end
  end
  return out, ""
end

--- The `raw_values` table of core/store.c's `source`: each raw value by its name, less the `cosmic.internal.` prefix,
--- and whether `require` answers it by that name.
local function raw_values_in(source: string): {string: boolean}?, string
  local rows, why = table_in(source, "raw_values", '{"cosmic%.internal%.([%w_]+)",%s*[%w_]+,%s*(%d)},', 5)
  if rows == nil then return nil, why end
  local out: mut {string: boolean} = {}
  for _, row in ipairs(rows) do
    local name, plain = row[1], row[2]
    if name ~= nil then out[name] = plain == "1" end
  end
  return out, ""
end

--- Every wrapper core/store.c hands a raw value to is one this test holds to
--- a declaration, by the raw module it is handed, and the running core hands
--- each one its raw value; every raw value it opens has a declaration, and
--- is either handed to a wrapper or answered by `require` by its name.
local function test_every_raw_module_has_a_declaration()
  local source = assert(Fs.read("core/store.c"))
  local in_c = assert(raw_modules_in(source))
  for wrapper, raw in pairs(in_c) do
    local wrapped = assert(wrappers[wrapper], wrapper .. " is a wrapper")
    assert(raw == wrapped, wrapper .. " is handed cosmic.internal." .. raw .. ", which `wrappers` here names as " ..
        wrapped)
  end
  for wrapper in pairs(wrappers) do
    assert(in_c[wrapper] ~= nil, wrapper .. " is no wrapper of core/store.c's raw_modules")
    local _, extra = searched(wrapper)
    assert(type(extra) == "table", wrapper .. " is handed no raw table")
  end
  local handed: mut {string: boolean} = {}
  for _, raw in pairs(in_c) do handed[raw] = true end
  local values = assert(raw_values_in(source))
  for name, plain in pairs(values) do
    assert(Fs.exists("cosmic/internal/" .. name .. ".d.tl") == true or derived[name] ~= nil,
      "cosmic.internal." .. name .. " is a raw value of core/store.c with no declaration")
    if plain then
      assert(handed[name] == nil, "cosmic.internal." .. name .. " is handed to a wrapper and answered by its name")
      local loader, extra = searched("cosmic.internal." .. name)
      assert(loader ~= nil and type(loader("cosmic.internal." .. name, extra)) == "table",
        "cosmic.internal." .. name .. " is not answered by its name")
    else
      assert(handed[name] == true, "cosmic.internal." .. name .. " is neither handed to a wrapper nor plain")
      assert(searched("cosmic.internal." .. name) == nil, "cosmic.internal." .. name .. " is answered by its name")
    end
  end
  for _, name in pairs(wrappers) do
    assert(values[name] == false, "cosmic.internal." .. name .. " is handed to a wrapper but plain in raw_values")
  end
end

--- A declaration without the binding line is named, not left out of the
--- comparison with the core.
local function test_an_untagged_declaration_is_named_rather_than_skipped()
  local names, refused = split_bindings({
    { path = "cosmic/internal/tagged.d.tl", text = "--- A raw module.\n--- @kind binding\n\nlocal record tagged\nend\nreturn tagged\n" },
    { path = "cosmic/internal/bare.d.tl", text = "--- A raw module.\n\nlocal record bare\nend\nreturn bare\n" },
  })
  assert(#names == 1 and names[1] == "tagged", table.concat(names, ","))
  assert(#refused == 1 and refused[1]:find("cosmic/internal/bare.d.tl is no binding", 1, true) ~= nil and
      refused[1]:find("--- @kind binding", 1, true) ~= nil, table.concat(refused, "\n"))
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
    local values_found, values_why = raw_values_in((source:gsub("(%} raw_values%[%] = {\n)", "%1" .. planted)))
    assert(values_found == nil and values_why:find("cannot read", 1, true) ~= nil, values_why)
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
    __close: function(Thing)
  end
  type Alias = {string: integer}
  open: function(): Thing
  version: string
end
return m
]]

--- Makes a thing whose metatable holds `methods` and `metamethods`.
local function thing(methods: {string: any}, metamethods: {string: any}): any
  local mt: mut {string: any} = { __index = methods, __name = "thing", __gc = nothing }
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
