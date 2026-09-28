--- The core's raw modules, as the running core registers them, held
--- to their declarations: core/declarations_test.tl's two tests that
--- read beyond their closure -- every declaration against the raw
--- module the store's searcher hands its wrapper, and every module of
--- every database of the store's -- apart so the rest stand while the
--- tree moves. The helpers that read a declaration and name where a raw
--- module disagrees with it are core/declarations_test.tl's, repeated.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local ast = require("build.ast")
local gen_syscalls = require("build.gen_syscalls")
local teal = require("build.teal")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")

--- Every declaration of the core's raw modules, and the process table's
--- header; and the whole projection, since it walks every database's
--- modules and searches by hand for wrappers outside its closure, which
--- the store of its closure would leave to the program's own database.
Test.needs{ reads = { "core/process.h", "cosmic/internal/" }, store = true }

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
  ["build.test_worker"] = "store",
  ["build.filesystem_observations"] = "observations",
  ["build.fuzz"] = "budget",
  ["cosmic.child"] = "process",
  ["cosmic.compress"] = "compress",
  ["cosmic.coverage"] = "debug",
  ["cosmic.hash"] = "hash",
  ["cosmic.http"] = "http",
  ["cosmic.json"] = "json",
  ["cosmic.proc"] = "process",
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
local function test_every_declaration_is_what_the_core_registers()
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
    local made: Made = maker ~= nil and maker(members(raw))
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
