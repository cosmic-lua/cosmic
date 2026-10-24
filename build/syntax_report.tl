--- What the readers that need the new checker's types take of a checked module: the subject they read ([`Report.Subject`],
--- the tree, the names, the declarations it lowered and the type of each node by id, [`build.driver`]'s report), and the
--- questions about declarations they ask of it alike: which record a type is an instance of, which module declares that
--- record and where under the module's own record, and which interface a field of it comes from.
---
--- [`build.syntax_receivers`] (the record-field uses `cosmic uses` lists) and [`build.syntax_contracts`] (the error-slot
--- discipline) are the two readers; [`build.receivers`] and [`build.contracts`] read the fork's types in their place.
--- A declaration of the new checker is named by its module and the names it is nested under ([`cosmic.zip`], `Zip` and
--- `Writer`), where the fork named a record by the type object tl gave it; the owner of a record is the module whose own
--- record declares it, under a path that leaves out that record's name (`Writer`), as the fork's rows spell a member.
local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Driver = require("build.driver")
local Scopes = require("lang.scopes")
local Types = require("lang.types")

local record Report
  --- A checked module as the readers take it.
  record Subject
    file: string
    program: Declarations.Program
    chunk: Ast.Chunk
    scoped: Scopes.Scoped
    lowered: Declarations.Lowered
    --- The type of each node by its id: the checker's, and the lowering's for a type node.
    types: {integer: Types.Type}
    --- The function each call took, by the id of the call node ([`lang.check`]'s `callees`).
    callees: {integer: Types.Type}
  end

  --- Where a record a module declares stands: the module, and the names under its own record joined by dots.
  record Owner
    module: string
    path: string
  end

  --- The subject `outcome` of `program` makes: nil where its text did not parse or its bodies were not checked with the
  --- types kept.
  of: function(program: Declarations.Program, outcome: Driver.Outcome): Subject | nil

  --- The declaration a type is an instance of (or, as a value, the table of): a record, class, interface, enum or
  --- userdata; nil for any other type.
  decl_of: function(t: Types.Type | nil): Types.Decl | nil

  --- The declaration `module` returns, if it returns one or a value typed as one; nil otherwise.
  root_of: function(program: Declarations.Program, module: string): Types.Decl | nil

  --- Where `decl` is declared, when it is nested under the record its module returns; nil for the module's own record,
  --- for a type the module keeps to itself and for one inside a function.
  owner_of: function(program: Declarations.Program, decl: Types.Decl): Owner | nil

  --- Where a method of `decl` is a use of, when it is no record nested under its module's own ([`Report.owner_of`]): the
  --- record or class the module returns, whose methods are `path` "" (the module's own members are `Z.f`, a call of
  --- which is the syntactic half's), or a record, class or interface declared at the top of its module's file, under
  --- its own name. nil for an enum, a type inside a function, and any other.
  home_of: function(program: Declarations.Program, decl: Types.Decl): Owner | nil

  --- Whether `decl` declares the method `name` itself (a class's `function name(self)`, not a field holding a function).
  has_method: function(decl: Types.Decl, name: string): boolean

  --- Whether `decl` declares the field or method `name` itself.
  has_member: function(decl: Types.Decl, name: string): boolean

  --- The interface among those `decl` lists, directly or through others, that declares the field `name`: the deepest one,
  --- since an interface that extends another carries its fields too; nil where none does.
  declaring: function(decl: Types.Decl, name: string): Types.Decl | nil

  --- The line of the token with index `token` of the subject's tree.
  line: function(subject: Subject, token: integer): integer
end

function Report.of(program: Declarations.Program, outcome: Driver.Outcome): Report.Subject | nil
  local lowered = outcome.lowered
  if outcome.broken or lowered == nil or outcome.checked == nil then
    return nil
  end
  return {
    file = outcome.source.filename, program = program, chunk = outcome.chunk, scoped = outcome.scoped, lowered = lowered,
    types = outcome.types, callees = outcome.callees,
  }
end

function Report.decl_of(t: Types.Type | nil): Types.Decl | nil
  if t ~= nil and t is Types.Named then
    return t.decl
  end
  return nil
end

function Report.root_of(program: Declarations.Program, module: string): Types.Decl | nil
  local known = program.modules[module]
  if known == nil then
    return nil
  end
  local export = known.export
  if export ~= nil then
    return export.decl
  end
  return Report.decl_of(known.value)
end

function Report.owner_of(program: Declarations.Program, decl: Types.Decl): Report.Owner | nil
  if #decl.names < 2 then
    return nil
  end
  local root = Report.root_of(program, decl.module)
  if root == nil or #root.names ~= 1 or root.names[1] ~= decl.names[1] then
    return nil
  end
  return { module = decl.module, path = table.concat(decl.names, ".", 2) }
end

function Report.home_of(program: Declarations.Program, decl: Types.Decl): Report.Owner | nil
  local kind = decl.kind
  local name = decl.names[1]
  if #decl.names ~= 1 or name == nil or decl.module:find("@", 1, true) ~= nil or
      (kind ~= "record" and kind ~= "class" and kind ~= "interface") then
    return nil
  end
  local root = Report.root_of(program, decl.module)
  if root ~= nil and root == decl then
    return { module = decl.module, path = "" }
  end
  return { module = decl.module, path = name }
end

function Report.has_method(decl: Types.Decl, name: string): boolean
  local body = decl.body
  if body == nil then
    return false
  end
  for _, m in ipairs(body.methods) do
    if m.name == name then
      return true
    end
  end
  return false
end

function Report.has_member(decl: Types.Decl, name: string): boolean
  local body = decl.body
  if body == nil then
    return false
  end
  for _, f in ipairs(body.fields) do
    if f.name == name then
      return true
    end
  end
  for _, m in ipairs(body.methods) do
    if m.name == name then
      return true
    end
  end
  return false
end

--- Every interface `decl` lists, those its listings list in turn after each, once.
local function listed(decl: Types.Decl, out: {Types.Decl}, seen: {Types.Decl: boolean})
  local body = decl.body
  if body == nil then
    return
  end
  for _, s in ipairs(body.supers) do
    local d = Report.decl_of(s)
    if d ~= nil and seen[d] ~= true then
      seen[d] = true
      out[#out + 1] = d
      listed(d, out, seen)
    end
  end
end

function Report.declaring(decl: Types.Decl, name: string): Types.Decl | nil
  local all: {Types.Decl} = {}
  local seen: {Types.Decl: boolean} = {}
  seen[decl] = true
  listed(decl, all, seen)
  for _, d in ipairs(all) do
    if Report.has_member(d, name) then
      local deeper = Report.declaring(d, name)
      if deeper ~= nil then
        return deeper
      end
      return d
    end
  end
  return nil
end

function Report.line(subject: Report.Subject, token: integer): integer
  return Lexer.y(subject.chunk.tokens, token)
end

return Report
