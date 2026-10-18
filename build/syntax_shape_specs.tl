--- Resolves `Shape.record_of("Module.Record")` where a module is compiled: the call names a record, and this reads the
--- record's declaration off the checker's types and splices the [`cosmic.shape`] spec the declaration describes into the
--- call, with a witness of the record's type, so the compiled module holds exactly what a hand-written `Shape.record{...}`
--- would and the call's answer is typed as the record.
---
--- The build is where this runs, not the program: a record's declaration is source, and reading it is the compiler's
--- work, which a program built into an executable does not carry. A call is rewritten in the compile's input alone; the
--- source a module is stored and shown under is what its author wrote.
---
--- The name is one of
---
--- - `Record` or `Record.Inner`, a record declared above the call in a block the call is in, however the module ends
---   (a test or an example declares its own and returns no type), or
--- - `module.name.Record`, a record the module `module.name` declares inside the record it returns, which the calling
---   module must `require` at its top level (`local Fs = require("cosmic.fs")`), so the compile is keyed by it
---   ([`build.compilation`]'s `dependency_keys`).
---
--- What a record may hold is what [`cosmic.shape`] can check: strings, integers, numbers, booleans and `any`; arrays and
--- string-keyed maps of those; enums, as `one_of` in byte order; records of those; and `T?` for a field that may be
--- missing. Anything else (a function, a union of more than one type, a generic, an interface, a class, a record that
--- holds itself) is refused where the call is, naming the field.
--
-- TODO: splice a witness the new checker accepts: `return nil` in a function typed `T` is the nil it refuses. Once the
-- build compiles with the new checker, which waits on the wiring of [`build.compilation`] to [`build.driver`], write
-- the third argument of `record_of` as a function that does not return, and port the fork's test that `into` answers the
-- record's own type and refuses an annotation of another (build/shape_specs_test.tl), which compiles the module.
local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local Driver = require("build.driver")
local Match = require("build.syntax_match")
local Node = require("build.syntax_node")
local Scopes = require("lang.scopes")
local Types = require("lang.types")

local record ShapeSpecs
  --- `source` with each `Shape.record_of("name")` it holds given the call's spec and a function that answers the
  --- record's type ([`Shape.record_of`]'s `built` and `_witness`), spliced after the name on its own line: the lines a
  --- message names do not move, but columns after the call on that line do. `source` is the text `module` of `build`
  --- was read from. Nothing changes in a source that has no such call, which is every module but the few that use it.
  ---
  --- nil and the refusal, as the compiler words one (`file:line: ...`), when a call cannot be resolved: a name that is
  --- not a string literal, a record the module does not reach, a field with no shape. A source the compiler would
  --- refuse anyway comes back as it is, for the compile that follows to report.
  resolve: function(build: Driver.Build, module: string, file: string, source: string): string | nil, string

  --- One call's resolution: `text` goes after byte `at` of the source.
  record Splice
    at: integer
    text: string
  end

  --- What [`ShapeSpecs.splices`] found of a source.
  record Found
    --- Each call's splice, the last in the source first; none where a call was refused.
    splices: {Splice}
    --- What was refused, as the compiler words a refusal (`file:line: ...`); "" where nothing was.
    refusal: string
    --- The line of the call refused; 0 where none was.
    line: integer
  end

  --- What [`ShapeSpecs.resolve`] splices into `source`, each call's [`ShapeSpecs.Splice`], the last in the source first;
  --- none for a source that has no such call, or that the compiler would refuse anyway. Where a call cannot be
  --- resolved, none, and the refusal `resolve` makes and the call's line ([`ShapeSpecs.Found`]).
  splices: function(build: Driver.Build, module: string, file: string, source: string): Found

  --- `source` with each of `splices` put in, the last first as [`ShapeSpecs.splices`] answers them.
  spliced: function(source: string, splices: {Splice}): string
end

local type Type = Types.Type

--- Names in byte order, as [`Shape.record`] keeps them.
local function sorted(names: {string}): {string}
  local out: {string} = {}
  for _, name in ipairs(names) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

local LEAVES <const>: {string: boolean} = {
  string = true, integer = true, number = true, boolean = true, any = true,
}

local spec_of: function(t: Type, path: string, shape: string, holding: {Types.Decl: boolean}, store: Types.Store):
  string | nil, string

--- `T?` as `Shape.optional(T)`: the one union a spec has a word for.
local function optional_of(t: Types.Union, path: string, shape: string, holding: {Types.Decl: boolean},
                           store: Types.Store): string | nil, string
  local present = t.members[1]
  if #t.members > 1 then
    return nil, path .. ": a union of more than one type has no shape; " ..
      "`T?` is the one it has, and `Shape.one_of` an enumeration"
  end
  local inner, why = spec_of(present, path, shape, holding, store)
  if inner == nil then
    return nil, why
  end
  return shape .. ".optional(" .. inner .. ")", ""
end

local function record_spec(decl: Types.Decl, path: string, shape: string, holding: {Types.Decl: boolean},
                           store: Types.Store): string | nil, string
  local body = decl.body
  if body == nil then
    return nil, path .. ": a declaration the checker did not resolve"
  end
  if body.array ~= nil then
    return nil, path .. ": a record that is also an array has no shape"
  end
  -- TODO: read the fields a record inherits (`supers`, expanded by the checker) and drop this refusal, once a caller
  -- gives a record that implements an interface a shape; the tree has none.
  if #body.supers > 0 then
    return nil, path .. ": a record that implements an interface has no shape; its inherited fields are not read"
  end
  if holding[decl] then
    return nil, path .. ": a record that holds itself has no finite shape"
  end
  holding[decl] = true
  local by_name: {string: Types.Field} = {}
  local names: {string} = {}
  for _, field in ipairs(body.fields) do
    by_name[field.name] = field
    names[#names + 1] = field.name
  end
  local parts: {string} = {}
  for _, name in ipairs(sorted(names)) do
    local inner, why = spec_of(by_name[name].type, path .. "." .. name, shape, holding, store)
    if inner == nil then
      holding[decl] = nil
      return nil, why
    end
    parts[#parts + 1] = ("[%q] = %s"):format(name, inner)
  end
  holding[decl] = nil
  return shape .. ".record({ " .. table.concat(parts, ", ") .. " })", ""
end

--- The Teal expression, over the `shape` alias, that builds the spec of `t`, or nil and why it has none. `path` names
--- where `t` is, for the message, and `holding` the records being read, which none may hold.
spec_of = function(t: Type, path: string, shape: string, holding: {Types.Decl: boolean}, store: Types.Store):
    string | nil, string
  if t is Types.Atom then
    if LEAVES[t.tag] then
      return shape .. "." .. t.tag, ""
    elseif t.tag == "invalid" then
      return nil, path .. ": a type the checker did not resolve"
    end
    return nil, ("%s: a %s type has no shape"):format(path, t.tag)
  elseif t is Types.Array then
    local inner, why = spec_of(t.element, path .. "[]", shape, holding, store)
    if inner == nil then
      return nil, why
    end
    return shape .. ".list(" .. inner .. ")", ""
  elseif t is Types.Map then
    local key = t.key
    if not (key is Types.Atom and key.tag == "string") then
      return nil, path .. ": a map keyed by anything but a string has no shape"
    end
    local inner, why = spec_of(t.value, path .. "{}", shape, holding, store)
    if inner == nil then
      return nil, why
    end
    return shape .. ".map(" .. inner .. ")", ""
  elseif t is Types.Union then
    return optional_of(t, path, shape, holding, store)
  elseif t is Types.Named then
    local decl = t.decl
    local body = decl.body
    if #t.args > 0 or (body ~= nil and #body.tparams > 0) then
      return nil, path .. ": a generic type has no shape"
    elseif decl.kind == "enum" then
      local values: {string} = {}
      if body ~= nil then
        for _, value in ipairs(sorted(body.values)) do
          values[#values + 1] = ("%q"):format(value)
        end
      end
      if #values == 0 then
        return nil, path .. ": an enum with no values has no shape"
      end
      return shape .. ".one_of(" .. table.concat(values, ", ") .. ")", ""
    elseif decl.kind == "record" then
      return record_spec(decl, path, shape, holding, store)
    elseif decl.kind == "userdata" then
      return nil, path .. ": a userdata record has no shape"
    end
    return nil, ("%s: %s has no shape"):format(path, decl.kind == "interface" and "an interface" or "a class")
  elseif t is Types.Fn then
    return nil, path .. ": a function has no shape"
  end
  return nil, path .. ": a generic type has no shape"
end

--- The module `call` requires, when it is `require("name")`.
local function required_name(call: Ast.Exp | nil): string | nil
  if call ~= nil and call is Ast.Call then
    local callee = call.callee
    local only = call.args[1]
    if callee is Ast.Name and callee.text == "require" and #call.args == 1 and only ~= nil and only is Ast.String then
      return only.value
    end
  end
  return nil
end

--- The modules the chunk requires at its top level, each by the name it binds (`local Fs = require("cosmic.fs")`,
--- or `local type Fs = ...`). A module bound twice answers its first name.
local function required(chunk: Ast.Chunk): {string: string}
  local out: {string: string} = {}
  for _, statement in ipairs(chunk.body.stats) do
    local name: string | nil = nil
    local alias: string | nil = nil
    if statement is Ast.Local then
      if #statement.bindings == 1 and #statement.values == 1 then
        alias = statement.bindings[1].name
        name = required_name(statement.values[1])
      end
    elseif statement is Ast.Import then
      alias, name = statement.name.name, statement.module
    end
    if name ~= nil and alias ~= nil and out[name] == nil then
      out[name] = alias
    end
  end
  return out
end

--- What a call's name stands for.
local record Target
  type: Type
  --- How the calling module spells the type: the name itself for a record it declares, through the alias it requires
  --- the module by otherwise.
  spelled: string
end

--- The target for what `entry` stands for, a declaration or an alias, spelled `spelled`; nil and why where it is generic,
--- and a type of it needs arguments, or an alias is not lowered.
local function entry_target(store: Types.Store, entry: Declarations.Entry, spelled: string): Target | nil, string
  local decl = entry.decl
  if decl ~= nil then
    if (decl.arity or 0) > 0 then
      return nil, ("it is a generic %s, not a record"):format(decl.kind)
    end
    return { type = store:named(decl), spelled = spelled }, ""
  end
  local alias = entry.alias
  local aliased = alias ~= nil and alias.type or nil
  if aliased == nil then
    return nil, "an alias the checker did not resolve"
  end
  return { type = aliased, spelled = spelled }, ""
end

--- The entry for the declaration or alias at `names` below `module`, then `rest` (a dotted path inside it, or "").
local function entry_at(program: Declarations.Program, module: string, names: {string}, rest: string):
    Declarations.Entry | nil
  local path = table.concat(names, ".")
  if rest ~= "" then
    path = path .. "." .. rest
  end
  return program.entries[module .. "\0" .. path]
end

--- `name`, read as a record, or nil and why it is none. `at` is the token of the call, for the names in scope there.
local function resolve_name(build: Driver.Build, outcome: Driver.Outcome, name: string, at: integer,
                            required_by: {string: string}): Target | nil, string
  local program = build.program
  local first = name:match("^[^.]+")
  local rest = name:sub(#first + 2)
  local lowered = outcome.lowered
  local here = Scopes.in_scope(outcome.scoped, at)[first]
  local entry = here ~= nil and lowered ~= nil and lowered.entries[here.id] or nil
  if entry ~= nil then
    local found = entry
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
  local export = held ~= nil and held.export or nil
  local found = export ~= nil and entry_at(program, export.module, export.names, inside) or nil
  if found == nil then
    return nil, ("module %q declares no record %q"):format(longest, inside)
  end
  return entry_target(program.store, found, required_by[longest] .. "." .. inside)
end

local type Splice = ShapeSpecs.Splice

function ShapeSpecs.splices(build: Driver.Build, module: string, file: string, source: string): ShapeSpecs.Found
  local none: {Splice} = {}
  if not source:find("record_of", 1, true) then
    return { splices = none, refusal = "", line = 0 }
  end
  build:lower({ module })
  local outcome = build:result(module, false)
  if outcome == nil or outcome.broken then
    return { splices = none, refusal = "", line = 0 }
  end
  local chunk = outcome.chunk
  local aliases = required(chunk)
  local shape = aliases["cosmic.shape"]
  if shape == nil then
    return { splices = none, refusal = "", line = 0 }
  end
  local pattern, pattern_trouble = Match.compile("$S.record_of($N)")
  if pattern == nil then
    return { splices = none, refusal = pattern_trouble, line = 0 }
  end
  local calls: {Match.Hit} = {}
  for _, hit in ipairs(Match.find_all(pattern, chunk, chunk)) do
    local on = hit.caps["_S"]
    local head = on ~= nil and on.nodes[1] or nil
    if head ~= nil and head is Ast.Name and head.text == shape then
      calls[#calls + 1] = hit
    end
  end
  local splices: {Splice} = {}
  for _, hit in ipairs(calls) do
    local span = Node.span(chunk, hit.node)
    local where = ("%s:%d: %s.record_of"):format(file, span.y, shape)
    local named = hit.caps["_N"]
    local literal = named ~= nil and named.nodes[1] or nil
    if literal == nil or not (literal is Ast.String) then
      return { splices = none, line = span.y,
        refusal = where .. ": the name must be a string literal, which the build reads" }
    end
    local token = chunk.tokens[named.first]
    local quote = token.text:sub(1, 1)
    if literal.long or (quote ~= '"' and quote ~= "'") or token.text:find("\\", 1, true) ~= nil then
      return { splices = none, line = span.y,
        refusal = where .. ": the name must be a plain quoted string with no escape in it" }
    end
    local target, unresolved = resolve_name(build, outcome, literal.value, Node.base(hit.node).first, aliases)
    if target == nil then
      return { splices = none, line = span.y,
        refusal = ("%s(%q): %s"):format(where, literal.value, unresolved) }
    end
    local at = target.type
    if not (at is Types.Named) or at.decl.kind ~= "record" then
      local what = "a type, not a record"
      if at is Types.Named then
        what = at.decl.kind == "enum" and "an enum, which " .. shape .. ".one_of checks" or
          "a " .. at.decl.kind .. ", not a record"
      end
      return { splices = none, line = span.y,
        refusal = ("%s(%q): it is %s"):format(where, literal.value, what) }
    end
    local spec, refusal = spec_of(at, literal.value, shape, {}, build.program.store)
    if spec == nil then
      return { splices = none, line = span.y,
        refusal = ("%s(%q): %s"):format(where, literal.value, refusal) }
    end
    splices[#splices + 1] = {
      at = token.offset + token.length - 1, text = (", %s, function(): %s return nil end"):format(spec, target.spelled),
    }
  end
  table.sort(splices, function(a: Splice, b: Splice): boolean
    return a.at > b.at
  end)
  return { splices = splices, refusal = "", line = 0 }
end

function ShapeSpecs.spliced(source: string, splices: {Splice}): string
  local out = source
  for _, splice in ipairs(splices) do
    out = out:sub(1, splice.at) .. splice.text .. out:sub(splice.at + 1)
  end
  return out
end

function ShapeSpecs.resolve(build: Driver.Build, module: string, file: string, source: string):
    string | nil, string
  local found = ShapeSpecs.splices(build, module, file, source)
  if found.refusal ~= "" then
    return nil, found.refusal
  end
  return ShapeSpecs.spliced(source, found.splices), ""
end

return ShapeSpecs
