--- Resolves `Shape.record_of("Module.Record")` where a module is compiled:
--- the call names a Teal record, and this reads the record's declaration
--- off the checker's own types and splices the [`cosmic.shape`] spec the
--- declaration describes into the call, with a witness of the record's
--- type, so the compiled module holds exactly what a hand-written
--- `Shape.record{...}` would and the call's answer is typed as the record.
---
--- The build is where this runs, not the program: a record's declaration
--- is Teal source, and reading it is the compiler's work, which a
--- program built into an executable does not carry. A call is rewritten
--- in the compile's input alone; the source a module is stored and shown
--- under is what its author wrote.
---
--- The name is one of
---
--- - `Record` or `Record.Inner`, a record declared above the call in a block
---   the call is in, however the module ends (a test or an example declares
---   its own and returns no type), or
--- - `module.name.Record`, a record the module `module.name` reaches the
---   checker through, which the calling module must `require` at its top
---   level (`local Fs = require("cosmic.fs")`), so the compile is keyed by
---   it ([`build.compilation`]'s `dependency_keys`).
---
--- What a record may hold is what [`cosmic.shape`] can check: strings,
--- integers, numbers, booleans and `any`; arrays and string-keyed maps of
--- those; enums with no escape in a value, as `one_of` in byte order;
--- records of those; and `T | nil` for a field that may be missing.
--- Anything else (a function, a union of more than one type, a generic, an
--- interface, a record that holds itself) is refused where the call is,
--- naming the field.
local ast = require("build.ast")
local type compiler = require("build.compiler")
local receivers = require("build.receivers")

local record shape_specs
end

local type Node = ast.Node

--- The part of a tl type object read here: [`receivers.Type`]'s and
--- [`ast.TypeNode`]'s are two declarations of the checker's one, and
--- neither names the array, map and enum members a spec is built from.
local record Ty
  typename: string
  typeid: integer | nil
  --- A nominal's type declaration, once resolved, and its definition
  --- when it has none.
  found: Ty | nil
  resolved: Ty | nil
  --- A nominal's type arguments: set only when it instantiates a generic.
  typevals: {Ty} | nil
  --- A typedecl's definition.
  def: Ty | nil
  fields: {string: Ty} | nil
  --- The array part a record declares (`record R is {T}`), or an
  --- array's element.
  elements: Ty | nil
  keys: Ty | nil
  values: Ty | nil
  types: {Ty} | nil
  enumset: {string: boolean} | nil
  interface_list: {Ty} | nil
  is_userdata: boolean | nil
end

--- A checked type object of tl's, as [`Ty`] reads it.
local function view_of_node(t: ast.TypeNode): Ty
  return t as Ty -- cast: the checker's type object, which build.ast.node's TypeNode and Ty both declare in part
end

--- A checked type object of the checker's environment, as [`Ty`] reads it.
local function view_of_type(t: receivers.Type): Ty
  return t as Ty -- cast: the checker's type object, which build.receivers' Type and Ty both declare in part
end

--- The type under a nominal and a declaration, nil and why when there is
--- none to read: an alias is followed, a generic is not.
local function unwrapped(t: Ty): Ty | nil, string
  local at = t
  for _ = 1, 16 do
    local name = at.typename
    if name == "nominal" then
      local typevals = at.typevals
      if typevals ~= nil and #typevals > 0 then
        return nil, "a generic type has no shape"
      end
      local found = at.found or at.resolved
      if found == nil then
        return nil, "a type the checker did not resolve"
      end
      at = found
    elseif name == "typedecl" then
      local def = at.def
      if def == nil then
        return nil, "a declaration the checker did not resolve"
      end
      at = def
    else
      return at, ""
    end
  end
  return nil, "an alias nested too deep to follow"
end

local LEAVES <const>: {string: boolean} = {
  string = true, integer = true, number = true, boolean = true, any = true,
}

--- Names in byte order, as [`Shape.record`] keeps them.
local function sorted(set: {string: any}): {string}
  local names: {string} = {}
  for name in pairs(set) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local spec_of: function(t: Ty, path: string, shape: string, holding: {integer: boolean}): string | nil, string

--- `T | nil` as `Shape.optional(T)`: the one union a spec has a word for.
local function optional_of(at: Ty, path: string, shape: string,
                           holding: {integer: boolean}): string | nil, string
  local present: Ty | nil = nil
  local missing = false
  for _, member in ipairs(at.types or {}) do
    if member.typename == "nil" then
      missing = true
    elseif present == nil then
      present = member
    else
      return nil, path .. ": a union of more than one type has no shape; " ..
        "`T | nil` is the one it has, and `Shape.one_of` an enumeration"
    end
  end
  if present == nil or not missing then
    return nil, path .. ": a union without `nil` has no shape; `T | nil` is the one it has"
  end
  local inner, why = spec_of(present, path, shape, holding)
  if inner == nil then return nil, why end
  return shape .. ".optional(" .. inner .. ")", ""
end

local function record_spec(at: Ty, path: string, shape: string,
                           holding: {integer: boolean}): string | nil, string
  if at.is_userdata then
    return nil, path .. ": a userdata record has no shape"
  end
  if at.elements ~= nil then
    return nil, path .. ": a record that is also an array has no shape"
  end
  -- TODO: read the fields a record inherits (`interface_list`, expanded by
  -- the checker) once a record that implements an interface needs a shape;
  -- until then its inherited fields would silently be left out.
  local bases = at.interface_list
  if bases ~= nil and #bases > 0 then
    return nil, path .. ": a record that implements an interface has no shape; " ..
      "its inherited fields are not read"
  end
  local id = at.typeid
  if id ~= nil then
    if holding[id] then
      return nil, path .. ": a record that holds itself has no finite shape"
    end
    holding[id] = true
  end
  local parts: {string} = {}
  local fields = at.fields or {}
  for _, name in ipairs(sorted(fields)) do
    local member = fields[name]
    -- A type the record declares inside itself is no field of its values.
    if member.typename ~= "typedecl" then
      local inner, why = spec_of(member, path .. "." .. name, shape, holding)
      if inner == nil then
        if id ~= nil then holding[id] = nil end
        return nil, why
      end
      parts[#parts + 1] = ("[%q] = %s"):format(name, inner)
    end
  end
  if id ~= nil then holding[id] = nil end
  return shape .. ".record({ " .. table.concat(parts, ", ") .. " })", ""
end

--- The Teal expression, over the `shape` alias, that builds the spec of
--- `t`, or nil and why it has none. `path` names where `t` is, for the
--- message, and `holding` the records being read, which none may hold.
spec_of = function(t: Ty, path: string, shape: string,
                   holding: {integer: boolean}): string | nil, string
  local at, why = unwrapped(t)
  if at == nil then
    return nil, path .. ": " .. why
  end
  local kind = at.typename
  if LEAVES[kind] then
    return shape .. "." .. kind, ""
  elseif kind == "array" then
    local element = at.elements
    if element == nil then
      return nil, path .. ": an array the checker gave no element type"
    end
    local inner, trouble = spec_of(element, path .. "[]", shape, holding)
    if inner == nil then return nil, trouble end
    return shape .. ".list(" .. inner .. ")", ""
  elseif kind == "map" then
    local key, key_why = unwrapped(at.keys)
    if key == nil or key.typename ~= "string" then
      return nil, path .. ": a map keyed by anything but a string has no shape" ..
        (key_why ~= "" and " (" .. key_why .. ")" or "")
    end
    local inner, trouble = spec_of(at.values, path .. "{}", shape, holding)
    if inner == nil then return nil, trouble end
    return shape .. ".map(" .. inner .. ")", ""
  elseif kind == "enum" then
    -- The checker keeps an enum as a set, so its declaration order is not
    -- there to read: the values go in byte order, as [`Shape.record`] keeps
    -- its fields, and a message that lists them is in that order.
    local values: {string} = {}
    for _, name in ipairs(sorted(at.enumset or {})) do
      -- The checker keeps a value's source text, escapes unread, so a
      -- backslash would build a value the data never holds.
      if name:find("\\", 1, true) then
        return nil, path .. ": an enum value with an escape (" .. ("%q"):format(name) ..
          ") has no shape; the checker keeps its source text, not its value"
      end
      values[#values + 1] = ("%q"):format(name)
    end
    if #values == 0 then
      return nil, path .. ": an enum with no values has no shape"
    end
    return shape .. ".one_of(" .. table.concat(values, ", ") .. ")", ""
  elseif kind == "union" then
    return optional_of(at, path, shape, holding)
  elseif kind == "record" then
    return record_spec(at, path, shape, holding)
  elseif kind == "function" or kind == "poly" then
    return nil, path .. ": a function has no shape"
  elseif kind == "interface" then
    return nil, path .. ": an interface has no shape"
  elseif kind == "generic" or kind == "typearg" then
    return nil, path .. ": a generic type has no shape"
  end
  return nil, ("%s: a %s type has no shape"):format(path, kind)
end

--- The type `path` names inside `at`, a record: `Inner` or `Inner.More`.
local function nested(at: Ty, path: string): Ty | nil
  local here: Ty | nil = at
  for name in path:gmatch("[^.]+") do
    if here == nil then return nil end
    local owner, _ = unwrapped(here)
    local fields = owner ~= nil and owner.fields or nil
    if fields == nil then return nil end
    here = fields[name]
  end
  return here
end

--- A record declared in a block, and where that block ends.
local record Declaration
  type: Ty
  y: integer
  x: integer
  --- Where the enclosing block ends: 0 for the chunk's own, which ends
  --- with the file.
  end_y: integer
  end_x: integer
end

--- Every `local record`, enum or alias `name` that `root`'s tree
--- declares, each with the block it is in.
local function declarations(root: Node, name: string): {Declaration}
  local out: {Declaration} = {}
  ast.walk(root, function(block: Node)
    if block.kind ~= "statements" then return end
    for _, statement in ipairs(block) do
      local var, value = statement.var, statement.value
      if statement.kind == "local_type" and var ~= nil and var.tk == name and
          value ~= nil and value.kind == "newtype" and value.newtype ~= nil then
        out[#out + 1] = {
          type = view_of_node(value.newtype), y = statement.y, x = statement.x,
          end_y = block.yend or 0, end_x = block.xend or 0,
        }
      end
    end
  end)
  return out
end

--- The record the call at `y`, `x` reads as `name`: the nearest declaration
--- of that name above it whose block it is in, in the checked tree `root`.
local function declared(root: Node, name: string, y: integer, x: integer): Ty | nil
  local best: Declaration | nil = nil
  for _, candidate in ipairs(declarations(root, name)) do
    local above = candidate.y < y or (candidate.y == y and candidate.x < x)
    local inside = candidate.end_y == 0 or y < candidate.end_y or
      (y == candidate.end_y and x <= candidate.end_x)
    if above and inside and (best == nil or candidate.y > best.y or
        (candidate.y == best.y and candidate.x > best.x)) then
      best = candidate
    end
  end
  return best ~= nil and best.type or nil
end

--- The module `call` requires, when it is `require("name")`.
local function required_name(call: Node | nil): string | nil
  if call == nil or call.kind ~= "op" then return nil end
  local op, callee, args = call.op, call.e1, call.e2
  if op == nil or op.op ~= "@funcall" or callee == nil or callee.kind ~= "variable" or
      callee.tk ~= "require" or args == nil then
    return nil
  end
  local only = args[1]
  if #args ~= 1 or only == nil or only.kind ~= "string" then return nil end
  return only.conststr
end

--- The modules the chunk requires at its top level, each by the name it
--- binds (`local Fs = require("cosmic.fs")`, or `local type Fs = ...`).
--- A module bound twice answers its first name.
local function required(root: Node): {string: string}
  local out: {string: string} = {}
  for _, statement in ipairs(root) do
    local name: string | nil = nil
    local alias: Node | nil = nil
    if statement.kind == "local_declaration" then
      local vars, exps = statement.vars, statement.exps
      if vars ~= nil and exps ~= nil and #vars == 1 and #exps == 1 then
        alias = vars[1]
        name = required_name(exps[1])
      end
    elseif statement.kind == "local_type" then
      alias = statement.var
      name = required_name(statement.value)
    end
    if name ~= nil and alias ~= nil and alias.tk ~= nil and out[name] == nil then
      out[name] = alias.tk
    end
  end
  return out
end

--- Where a call's name argument ends, as a byte offset into `source`: the
--- close of a quoted string with no escape in it, which a name is.
local function name_end(source: string, starts: {integer}, name: Node): integer | nil
  local at = ast.offset_of(starts, name.y, name.x)
  local quote = source:sub(at, at)
  if quote ~= '"' and quote ~= "'" then return nil end
  local close = source:find(quote, at + 1, true)
  if close == nil or source:sub(at + 1, close - 1):find("\\", 1, true) then return nil end
  return close
end

--- One call to resolve: where the text goes and what it says.
local record Splice
  at: integer
  text: string
end

--- What a call's name stands for.
local record Target
  type: Ty
  --- How the calling module spells the type: the name itself for a record
  --- it declares, through the alias it requires the module by otherwise.
  spelled: string
end

--- `name`, read as a record, or nil and why it is none.
local function resolve(name: string, owned: Node, y: integer, x: integer,
                       required_by: {string: string}, env: compiler.Env): Target | nil, string
  local first = name:match("^[^.]+")
  local own = declared(owned, first, y, x)
  if own ~= nil then
    local rest = name:sub(#first + 2)
    local at = rest == "" and own or nested(own, rest)
    if at == nil then return nil, ("%q has no field %q"):format(first, rest) end
    return { type = at, spelled = name }, ""
  end
  local longest = ""
  for module in pairs(required_by) do
    if name:sub(1, #module + 1) == module .. "." and #module > #longest then
      longest = module
    end
  end
  if longest == "" then
    return nil, "it names no record declared above it, and no " ..
      "module it requires at its top level (`local X = require(\"the.module\")`)"
  end
  local inside = name:sub(#longest + 2)
  -- TODO: read a record a required module declares but does not hand out
  -- through its returned record: [`receivers.record_named`] finds only the
  -- latter, so a local record of another module is refused as undeclared;
  -- it waits on build.receivers keeping each module's own record types.
  local found = receivers.record_named(env, longest, inside)
  if found == nil then
    return nil, ("module %q declares no record %q"):format(longest, inside)
  end
  return { type = view_of_type(found), spelled = required_by[longest] .. "." .. inside }, ""
end

--- `source` with each `Shape.record_of("name")` it holds given what the
--- build knows of `name`: the call's spec and a function that answers
--- the record's type ([`Shape.record_of`]'s `built` and `_witness`), spliced
--- after the name on its own line: lines a message names do not move, but
--- columns after the call on that line do.
--- Nothing changes in source that has no such call, which is every
--- module but the few that use it, and is not even checked then.
---
--- Answers nil and the refusal, as the compiler words one (`file:line:
--- ...`), when a call cannot be resolved: a name that is not a string
--- literal, a record the module does not reach, a field with no shape.
--- Source the compiler would refuse anyway comes back as it is, for the
--- compile that follows to report.
--- @param built the compiler
--- @param env the checker's environment, in which the module's
---   requires are loaded
--- @param file the module's file, for a message
--- @param path the module's import path
--- @param source the module's source
--- @return string | nil the source to compile, or nil
--- @return string "" or what was refused
function shape_specs.resolve(built: compiler, env: compiler.Env, file: string,
                             path: string, source: string): string | nil, string
  if not source:find("record_of", 1, true) then
    return source, ""
  end
  local parsed, _ = ast.parse(built, source, path)
  if parsed == nil then
    return source, ""
  end
  local root = parsed.node
  local aliases = required(root)
  local shape = aliases["cosmic.shape"]
  if shape == nil then
    return source, ""
  end
  local pattern, pattern_trouble = ast.compile_pattern(built, "$S.record_of($N)")
  if pattern == nil then return nil, pattern_trouble end
  local calls: {ast.Hit} = {}
  for _, hit in ipairs(ast.find_all(root, pattern)) do
    local on = hit.caps["_S"]
    if on ~= nil and on.kind == "variable" and on.tk == shape then
      calls[#calls + 1] = hit
    end
  end
  if #calls == 0 then
    return source, ""
  end

  -- The module is checked once as written, which reports the calls'
  -- answers as unresolved generics: the types are all that is read.
  local code, result = built.gen(source, env, nil, "tl")
  if code == nil or result == nil or #result.syntax_errors > 0 then
    return source, ""
  end
  local checked = result.ast
  if not (checked is Node) then
    return source, ""
  end

  local starts = ast.line_starts(source)
  local splices: {Splice} = {}
  for _, hit in ipairs(calls) do
    local name = hit.caps["_N"]
    local where = ("%s:%d: %s.record_of"):format(file, hit.node.y, shape)
    if name == nil or name.kind ~= "string" or name.conststr == nil then
      return nil, where .. ": the name must be a string literal, which the build reads"
    end
    local close = name_end(source, starts, name)
    if close == nil then
      return nil, where .. ": the name must be a plain quoted string with no escape in it"
    end
    local target, unresolved = resolve(name.conststr, checked, name.y, name.x, aliases, env)
    if target == nil then
      return nil, ("%s(%q): %s"):format(where, name.conststr, unresolved)
    end
    local at, why = unwrapped(target.type)
    if at == nil or at.typename ~= "record" then
      return nil, ("%s(%q): %s"):format(where, name.conststr,
        at == nil and why or ("it is " .. (at.typename == "enum" and "an enum, which " ..
          shape .. ".one_of checks" or "a " .. at.typename .. ", not a record")))
    end
    local spec, refusal = spec_of(at, name.conststr, shape, {})
    if spec == nil then
      return nil, ("%s(%q): %s"):format(where, name.conststr, refusal)
    end
    splices[#splices + 1] = { at = close, text = (", %s, function(): %s return nil end"):format(spec, target.spelled) }
  end
  table.sort(splices, function(a: Splice, b: Splice): boolean return a.at > b.at end)
  local out = source
  for _, splice in ipairs(splices) do
    out = out:sub(1, splice.at) .. splice.text .. out:sub(splice.at + 1)
  end
  return out, ""
end

return shape_specs
