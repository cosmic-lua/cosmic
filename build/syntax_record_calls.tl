--- What a resolver of a call that names a record needs, whichever call it completes: [`build.syntax_shape_specs`]
--- completes `Shape.record_of("Module.Record")` with a check written from the record's declaration, and each part here
--- is one it would otherwise hold alone. A resolver finds its calls, reads the record each names ([`resolve_name`]),
--- writes Teal that names the record's types as the calling module spells them ([`spelling`]), and puts that text into
--- the compile's input ([`spliced`]). What it writes is its own.
local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local Driver = require("build.driver")
local Scopes = require("lang.scopes")
local Types = require("lang.types")

local type Type = Types.Type

local record RecordCalls
  --- One call's resolution: `text` goes after byte `at` of the source.
  record Splice
    at: integer
    text: string
  end

  --- What a call's name stands for.
  record Target
    type: Type
    --- How the calling module spells the type: the name itself for a record it declares, through the alias it requires
    --- the module by otherwise.
    spelled: string
  end

  --- Where a call stands, for [`spelling`]: what the calling module can name there.
  record Namer
    program: Declarations.Program
    --- The module the call is in, and the modules it requires at its top level by the name each is bound to.
    module: string
    aliases: {string: string}
    --- The names in scope where the call is.
    visible: {string: boolean}
    --- The record the call names, and how the calling module spells it.
    target: Types.Decl
    spelled: string
  end

  --- The module `call` requires, when it is `require("name")`.
  required_name: function(call: Ast.Exp?): string?

  --- The modules the chunk requires at its top level, each by the name it binds (`local Fs = require("cosmic.fs")`,
  --- or `local type Fs = ...`). A module bound twice answers its first name.
  required: function(chunk: Ast.Chunk): {string: string}

  --- `name`, read as a record, or nil and why it is none. `at` is the token of the call, for the names in scope there,
  --- and `required_by` what [`required`] answers for the call's chunk.
  resolve_name: function(build: Driver.Build, outcome: Driver.Outcome, name: string, at: integer,
    required_by: {string: string}): Target?, string

  --- The names in scope at the token `at` of the module `outcome` holds.
  visible: function(outcome: Driver.Outcome, at: integer): {string: boolean}

  --- How the calling module spells the declaration `decl`, or nil: the record the call names, a type declared inside
  --- it, a type of the calling module that is in scope where the call is, or one inside the record a module it requires
  --- returns.
  spelling: function(n: Namer, t: Type, decl: Types.Decl): string?

  --- `source` with each of `splices` put in, the last in the source first.
  spliced: function(source: string, splices: {Splice}): string
end

local function required_name(call: Ast.Exp?): string?
  if call ~= nil and (call.kind == "Call") then
    local callee = call.callee
    local only = call.args[1]
    if (callee.kind == "Name") and callee.text == "require" and #call.args == 1 and only ~= nil and (only.kind == "String") then
      return only.value
    end
  end
  return nil
end

local function required(chunk: Ast.Chunk): {string: string}
  local out: mut {string: string} = {}
  for _, statement in ipairs(chunk.body.stats) do
    local name: string? = nil
    local alias: string? = nil
    if (statement.kind == "Local") then
      if #statement.bindings == 1 and #statement.values == 1 then
        alias = assert(statement.bindings[1]).name
        name = required_name(statement.values[1])
      end
    elseif (statement.kind == "Import") then
      alias, name = statement.name.name, statement.module
    end
    if name ~= nil and alias ~= nil and out[name] == nil then
      out[name] = alias
    end
  end
  return out
end

local type Target = RecordCalls.Target

--- The target for what `entry` stands for, a declaration or an alias, spelled `spelled`; nil and why where it is generic,
--- and a type of it needs arguments, or an alias is not lowered.
local function entry_target(store: Types.Store, entry: Declarations.Entry, spelled: string): Target?, string
  local decl = entry.decl
  if decl ~= nil then
    if (decl.arity or 0) > 0 then
      return nil, ("it is a generic %s, not a record"):format(decl.kind)
    end
    return { type = store:named(decl), spelled = spelled }, ""
  end
  local alias = entry.alias
  local aliased = if alias ~= nil then alias.type else nil end
  if aliased == nil then
    return nil, "an alias the checker did not resolve"
  end
  return { type = aliased, spelled = spelled }, ""
end

--- The entry for the declaration or alias at `names` below `module`, then `rest` (a dotted path inside it, or "").
local function entry_at(program: Declarations.Program, module: string, names: {string}, rest: string):
    Declarations.Entry?
  local path = table.concat(names, ".")
  if rest ~= "" then
    path = path .. "." .. rest
  end
  return program.entries[module .. "\0" .. path]
end

local function resolve_name(build: Driver.Build, outcome: Driver.Outcome, name: string, at: integer,
                            required_by: {string: string}): Target?, string
  local program = build.program
  local first = name:match("^[^.]+")
  if first == nil then
    return nil, "the name must start with a module or record name"
  end
  local rest = name:sub(#first + 2)
  local lowered = outcome.lowered
  local here = Scopes.in_scope(outcome.scoped, at)[first]
  local entry: Declarations.Entry? = nil
  if here ~= nil and lowered ~= nil then entry = lowered.entries[here.id] end
  if entry ~= nil then
    local found: Declarations.Entry? = entry
    if rest ~= "" then
      found = entry_at(program, entry.module, entry.names, rest)
    end
    if found == nil then
      return nil, ("%q has no field %q"):format(first, rest)
    end
    return entry_target(program.store, found, name)
  end
  local longest = ""
  for module in pairs(required_by) do
    if name:sub(1, #module + 1) == module .. "." and #module > #longest then
      longest = module
    end
  end
  if longest == "" then
    return nil, "it names no record declared above it, and no module it requires at its top level " ..
      "(`local X = require(\"the.module\")`)"
  end
  local inside = name:sub(#longest + 2)
  local held = program.modules[longest]
  local export = if held ~= nil then held.export else nil end
  local found: Declarations.Entry? = nil
  if export ~= nil then found = entry_at(program, export.module, export.names, inside) end
  if found == nil then
    return nil, ("module %q declares no record %q"):format(longest, inside)
  end
  local module_name = assert(required_by[longest], "the module found is one the file requires")
  return entry_target(program.store, found, module_name .. "." .. inside)
end

function RecordCalls.spelling(n: RecordCalls.Namer, t: Type, decl: Types.Decl): string?
  if decl == n.target then return n.spelled end
  local names = decl.names
  local path = table.concat(names, ".")
  local mine = n.target.names
  if decl.module == n.target.module and #names > #mine then
    local inside = true
    for i, name in ipairs(mine) do
      if names[i] ~= name then inside = false end
    end
    if inside then return n.spelled .. "." .. table.concat(names, ".", #mine + 1) end
  end
  local first = names[1]
  if decl.module == n.module and first ~= nil and n.visible[first] == true then return path end
  local alias = n.aliases[decl.module]
  local held = n.program.modules[decl.module]
  local export = if held ~= nil then held.export else nil end
  if alias ~= nil and export ~= nil then
    local inside = table.concat(export.names, ".")
    if path:sub(1, #inside + 1) == inside .. "." then
      return alias .. "." .. path:sub(#inside + 2)
    end
  end
  -- A type a module required at the top level spells by an alias of its own (`type Grant = rules.Grant`).
  for _, entry in pairs(n.program.entries) do
    local aliased = entry.alias
    local home = n.aliases[entry.module]
    local owner = n.program.modules[entry.module]
    local exported = if owner ~= nil then owner.export else nil end
    if aliased ~= nil and aliased.type == t and home ~= nil and exported ~= nil then
      local inside = table.concat(exported.names, ".")
      local there = table.concat(entry.names, ".")
      if there:sub(1, #inside + 1) == inside .. "." then
        return home .. "." .. there:sub(#inside + 2)
      end
    end
  end
  return nil
end

RecordCalls.required_name = required_name
RecordCalls.required = required
RecordCalls.resolve_name = resolve_name

function RecordCalls.visible(outcome: Driver.Outcome, at: integer): {string: boolean}
  local visible: mut {string: boolean} = {}
  for name in pairs(Scopes.in_scope(outcome.scoped, at)) do
    visible[name] = true
  end
  return visible
end

function RecordCalls.spliced(source: string, splices: {RecordCalls.Splice}): string
  local out = source
  for _, splice in ipairs(splices) do
    out = out:sub(1, splice.at) .. splice.text .. out:sub(splice.at + 1)
  end
  return out
end

return RecordCalls
