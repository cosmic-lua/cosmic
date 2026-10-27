--- `cosmic migrate [--check] <path>...`: rewrites the Teal files of a project written for the fork's checker in place
--- into the new checker's grammar, and then makes the rewrites the new checker's findings direct.
---
--- THE TRANSLATION ([`lang.translate`]) is syntactic: it respells what the grammar cuts (`T | nil`, `goto continue`,
--- `function R:m`, `c and a or b` where `a` is plainly a value) and writes `mut` where the syntax shows a write. It cannot
--- tell what a name is, so its output still has findings the new checker refuses. Six codes of them have one mechanical
--- fix, which the finding's own place names, and this module makes it:
---
--- - `view_written`: a collection that is written is declared `mut`: `local names: {string}` and a parameter `names:
---   {string}` become `mut {string}`, and a field `items: {string}` of a record the project holds becomes `mut {string}`.
---   A local made from a view (`local copy: {string} = names`) is left, as `mut` would only move the refusal to the
---   initial value.
--- - `field_fixed`: a field of a record the project holds that is assigned after the record is made is declared `mut`.
--- - [`interface_disagrees`], where a type and an interface it lists declare a field `mut` and fixed: the field is made `mut` in
---   the interface, the type and every other type that lists the interface, whichever file declares them (the translator
---   does this within a file). A class that declares the field as a method cannot be `mut`, so the finding is left.
--- - `literal_needs_type`: `local seen = {}` is declared `local seen: mut {string: boolean} = {}` from the first
---   write the program makes to it, when the type of what is written is a plain one (a string, a number, a boolean or a
---   type of the same file) and the write appends or keys a string.
--- - `map_field`: `m.NAME` on a map is written `m["NAME"]`.
--- - `and_ternary`: `a and b or c` becomes `if a then b else c end`, when the checker's type of `b` can be neither false
---   nor nil. Otherwise the two answer differently where `b` is false or nil, and the finding is left.
---
--- Every rewrite is an edit of the bytes of the tokens it names, so comments and layout outside them stay. A rewrite
--- that changes a declaration in another file (a field of a record that file declares) is an edit of that file.
---
--- The checker runs again on the rewritten project and the rewrites go on, because one shows the next: `env.NAME = v` on
--- a map is a field write until `env["NAME"]` makes it an index write that needs `env` declared `mut`, and a local made
--- from a collection is a view until that collection is `mut`. They go on to a fixed point, at most 12
--- rounds, and a run that was still rewriting at the last round says so (`converged`). Every other finding is left and
--- reported, and nothing is made to pass by a cast or `any`.
---
--- A file already in the new grammar is translated to itself, so it is only given the rewrites it still needs, and a
--- project that was migrated is migrated again to itself.
---
--- THE PROGRAM is the files given, each the module its path names ([`build.driver`]), checked against the standard
--- library the tool carries and held to no ceiling ([`build.pipeline`]): the findings are what `COSMIC_GRAMMAR=new`
--- reports of a project outside cosmic's tree.
--
-- TODO: delete this verb, its tests and its section of the project guide in the release after the one that makes the new
-- checker the tool's own (doc/plans/strict-teal.md, "the switch"): the translator is kept for that one release as a
-- user-facing verb and then goes.
local Ast = require("lang.ast")
local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Driver = require("build.driver")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Lexer = require("lang.lexer")
local Pipeline = require("build.pipeline")
local Translate = require("lang.translate")
local TreeProgram = require("build.tree_program")
local Truthy = require("lang.truthy")
local Types = require("lang.types")
local bare = require("build.bare")
local plural = require("build.plural")
local verb_spec = require("build.verb_spec")

local record Migrate
  --- One finding of the checker.
  record Finding
    path: string
    y: integer
    x: integer
    code: string
    msg: string
    --- Why a finding with a rewrite was left, "" for the others.
    note: string
  end

  --- What a run is asked for.
  record Options
    --- The most rounds of rewrites: 12 where not given.
    rounds: integer?
  end

  --- What a run came to.
  record Result
    --- The text of every file given, by path, as it is after the run.
    texts: {string: string}
    --- The paths whose text is not what was given, sorted.
    changed: {string}
    --- The forms the translator does not handle, one line each with its place: a file with one is written with the form as
    --- it was, for a hand edit.
    untranslated: {string}
    --- How many findings of each code the project had once translated, and how many it has now.
    before: {string: integer}
    after: {string: integer}
    --- How many edits of each code were made.
    rewrites: {string: integer}
    --- The findings left, by file and then place.
    left: {Finding}
    --- The declarations whose `mut` was changed and that other files may list: files outside this run that mention one need the
    --- same change.
    shared: {Shared}
    --- The rounds of rewrites made.
    rounds: integer
    --- False when the last round was still rewriting.
    converged: boolean
    nanoseconds: integer
  end

  --- A declaration and the field of it that was made `mut` together with the declarations that list it.
  record Shared
    --- The name of the declaration, as the checker spells it (`Pins.Pin`).
    name: string
    field: string
  end

  --- What `main` reads and writes: what a test stands in for.
  record Io
    out: function(text: string): boolean, string
    err: function(line: string)
  end

  --- Migrates the project `files` (the text of each `.tl` and `.d.tl` file, by its path below the project's root). nil and
  --- why when the checker cannot be set up.
  run: function(files: {string: string}, options?: Options): Result?, string

  --- The `cosmic migrate` command line.
  main: function(argv: {string}, streams?: Io): integer

  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
end

--- The most rounds of rewrites a run makes where it is not asked for fewer.
local ROUNDS <const> = 12

local spec = Cli.verbs.migrate.spec or {}

local usage = "cosmic migrate [--check] <path>..."

--- The codes that have a rewrite.
local FIXABLE <const>: {string: boolean} = {
  view_written = true, field_fixed = true, literal_needs_type = true, map_field = true, and_ternary = true,
  interface_disagrees = true, view_as_mut = true,
}

--- The replacement of the bytes `lo` to `hi - 1` of a file by `text`; an insertion has `hi == lo`.
local record Edit
  lo: integer
  hi: integer
  text: string
end

--- The edits that make one rewrite, made together or not at all.
local record Rewrite
  code: string
  edits: {Edit}
  --- What tells two rewrites that make the same edits apart from none: they are one.
  key: string
end

--- A rewrite of a declaration in the file that holds it, found by what it declares.
local record Request
  code: string
  --- The declaration of the record, class or interface, and the field it declares.
  decl: Types.Decl
  field: string
  --- Whether the collection the field holds is declared `mut`, in place of the field.
  collection: boolean
  --- The finding it answers, which says why it was not made.
  finding: Migrate.Finding?
end

--- The nodes of one file, by what is asked of them.
local record Facts
  parent: mut {integer: Ast.Node}
  node: mut {integer: Ast.Node}
  --- The nodes whose first token starts at an offset, an outer node before the ones it holds.
  at: mut {integer: {Ast.Node}}
end

--- What one reading of the whole project found.
local record Survey
  counts: mut {string: integer}
  findings: mut {Migrate.Finding}
  --- The rewrites made from the findings of a file, by path.
  rewrites: mut {string: {Rewrite}}
  mut requests: mut {Request}
  --- The path of the file that holds each module.
  holders: mut {string: string}
  --- The families of declarations that were made `mut` together.
  shared: mut {Migrate.Shared}
end

--- Everything a rewrite needs of the file it reads.
local record Ctx
  outcome: Driver.Outcome
  facts: Facts
  tokens: Lexer.Tokens
  index: Driver.Index
  --- Every declaration of the program, to find the one that a member belongs to.
  decls: {Types.Decl}
end

local function base_of(node: Ast.Node): Ast.Base
  return node
end

local function peel(e: Ast.Exp): Ast.Exp
  local at = e
  while (at.kind == "Paren") do
    at = at.inner
  end
  return at
end

local function facts_of(chunk: Ast.Chunk): Facts
  local facts: Facts = { parent = {}, node = {}, at = {} }
  local tokens = chunk.tokens
  local stack: mut {Ast.Node} = { chunk }
  while #stack > 0 do
    local n = table.remove(stack)
    local b = base_of(n)
    facts.node[b.id] = n
    if b.last >= b.first then
      local offset = Lexer.offset(tokens, b.first)
      local list = facts.at[offset]
      if list == nil then
        list = {}
        facts.at[offset] = list
      end
      list[#list + 1] = n
    end
    Ast.children(n, function(child: Ast.Node)
      facts.parent[base_of(child).id] = n
      stack[#stack + 1] = child
    end)
  end
  return facts
end

local function type_of(ctx: Ctx, node: Ast.Node): Types.Type?
  return ctx.outcome.types[base_of(node).id]
end

--- The type of the value `node` read with the nil taken off a type that is only that and nil: a place a test showed was
--- not nil is typed by what it was declared as.
local function present(ctx: Ctx, node: Ast.Node): Types.Type?
  local t = type_of(ctx, node)
  if t ~= nil and (t.tag == "union") and #t.members == 1 then
    return t.members[1]
  end
  return t
end

local function text_edit(lo: integer, hi: integer, text: string): Edit
  return { lo = lo, hi = hi, text = text }
end

local function rewrite_of(code: string, edits: {Edit}): Rewrite
  local keys: mut {string} = {}
  for _, e in ipairs(edits) do
    keys[#keys + 1] = tostring(e.lo) .. ":" .. tostring(e.hi) .. ":" .. e.text
  end
  return { code = code, edits = edits, key = table.concat(keys, "\0") }
end

--- Whether `t` is a collection that is not `mut`.
local function is_view(t: Types.Type): boolean
  if (t.tag == "array") then
    return not t.mut
  elseif (t.tag == "map") then
    return not t.mut
  end
  return false
end

--- The target of an assignment that starts at `offset`.
local function target_at(ctx: Ctx, offset: integer): Ast.Exp?
  for _, n in ipairs(ctx.facts.at[offset] or {}) do
    local parent = ctx.facts.parent[base_of(n).id]
    if (parent.kind == "Assign") then
      for _, target in ipairs(parent.targets) do
        if target == n then
          return target
        end
      end
    end
  end
  return nil
end

--- The edit that declares the collection type `ty` `mut`, or why it cannot be.
local function mut_collection(tokens: Lexer.Tokens, ty: Ast.Type): Edit?, string
  local inner: Ast.Type = ty
  if (inner.kind == "TypeOptional") then
    inner = inner.inner
  end
  if (inner.kind == "TypeArray") or (inner.kind == "TypeMap") then
    local at = Lexer.offset(tokens, base_of(inner).first)
    return text_edit(at, at, "mut "), ""
  elseif (inner.kind == "TypeMut") then
    return nil, "its type is already `mut`"
  end
  return nil, "its type is a name or a union, which `mut` does not apply to"
end

--- The edit that declares the local or parameter `name` refers to `mut {T}`, or why it cannot be.
local function declared_mut(ctx: Ctx, name: Ast.Name): Edit?, string
  local id = name.binding
  if id == nil then
    return nil, "`" .. name.text .. "` is not a local or a parameter"
  end
  local owner = ctx.facts.parent[id]
  if (owner.kind == "Local") then
    for i, binding in ipairs(owner.bindings) do
      if base_of(binding).id == id then
        local ty = owner.types[i]
        if ty == nil then
          return nil, "`" .. name.text .. "` is declared with no type"
        end
        local value = owner.values[i]
        if value == nil then
          if #owner.values > 0 then
            return nil, "`" .. name.text .. "` is made by a call that answers several values, which may be views"
          end
        else
          local made = type_of(ctx, value)
          if made ~= nil and is_view(made) then
            return nil, "`" .. name.text .. "` is made from a view, which a copy would make a `mut` collection"
          end
        end
        return mut_collection(ctx.tokens, ty)
      end
    end
  elseif (owner.kind == "Param") then
    local ty = owner.type
    if ty == nil then
      return nil, "`" .. name.text .. "` is declared with no type"
    end
    return mut_collection(ctx.tokens, ty)
  end
  return nil, "`" .. name.text .. "` is not declared by a local or a parameter"
end

--- Whether `decl` declares the field `field`.
local function declares(decl: Types.Decl, field: string): boolean
  local body = decl.body
  if body == nil then
    return false
  end
  for _, f in ipairs(body.fields) do
    if f.name == field then
      return true
    end
  end
  return false
end

--- The request to declare the field `field` of the value `object`, or why it cannot be asked.
local function field_request(ctx: Ctx, code: string, object: Ast.Exp, field: string, collection: boolean):
    Request?, string
  local t = present(ctx, object)
  if t == nil or not ((t.tag == "named")) then
    return nil, "the value is not a record, a class or an interface"
  end
  if t.value then
    return nil, "`" .. t.decl.name .. "` here is the table of the module's functions, which a program does not assign"
  end
  if not declares(t.decl, field) then
    return nil, "`" .. t.decl.name .. "` does not declare the field `" .. field .. "`"
  end
  if ctx.index.by_module[t.decl.module] == nil then
    return nil, "`" .. t.decl.name .. "` is declared in the module `" .. t.decl.module .. "`, which this run does not write"
  end
  return { code = code, decl = t.decl, field = field, collection = collection, finding = nil }, ""
end

--- Whether `decl` declares a method `name`, which is fixed.
local function has_method(decl: Types.Decl, name: string): boolean
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

--- The declarations that must declare a field alike.
local record Family
  members: mut {Types.Decl}
  --- Why they cannot: a class that lists one of them declares the field as a method, which is never `mut`. "" otherwise.
  mut blocked: string
end

--- The declarations that must declare `field` as `decl` does: the interfaces above it that declare it, and the
--- declarations that list any of those and declare it, since a type that lists an interface declares each field with its
--- type and `mut`, or the checker refuses it ([`interface_disagrees`]).
local function family(list: {Types.Decl}, decl: Types.Decl, field: string): Family
  local made: Family = { members = { decl }, blocked = "" }
  if has_method(decl, field) then
    made.blocked = "`" .. decl.name .. "` declares `" .. field .. "` as a method, which is never `mut`"
  end
  local held: mut {Types.Decl: boolean} = { [decl] = true }
  local at = 1
  while at <= #made.members do
    local body = assert(made.members[at]).body
    if body ~= nil then
      for _, super in ipairs(body.supers) do
        if (super.tag == "named") and not held[super.decl] and declares(super.decl, field) then
          held[super.decl] = true
          made.members[#made.members + 1] = super.decl
        end
      end
    end
    at = at + 1
  end
  local grew = true
  while grew do
    grew = false
    for _, d in ipairs(list) do
      local body = d.body
      if body ~= nil and not held[d] then
        for _, super in ipairs(body.supers) do
          if (super.tag == "named") and held[super.decl] then
            if has_method(d, field) then
              made.blocked = "`" .. d.name .. "` lists `" .. super.decl.name .. "` and declares `" .. field ..
                "` as a method, which is never `mut`"
            elseif declares(d, field) then
              held[d] = true
              made.members[#made.members + 1] = d
              grew = true
            end
            break
          end
        end
      end
    end
  end
  return made
end

--- What tells two requests for the same declaration apart from none: they are one.
local function request_key(request: Request): string
  return request.decl.module .. "\0" .. request.decl.name .. "\0" .. request.field .. "\0" .. tostring(request.collection)
end

--- A rewrite of the file read, or a request for one of the file that declares a field, or why neither.
local record Made
  rewrite: Rewrite?
  request: Request?
  why: string
end

local function nothing(why: string): Made
  return { rewrite = nil, request = nil, why = why }
end

local function map_field(ctx: Ctx, p: Driver.Problem): Made
  for _, n in ipairs(ctx.facts.at[p.offset] or {}) do
    if (n.kind == "Field") then
      local t = present(ctx, n.object)
      if t ~= nil and t.tag == "map" then
        local last = base_of(n).last
        if Lexer.text(ctx.tokens, last - 1) ~= "." then
          return nothing("the field is not written `.name`")
        end
        local edit = text_edit(Lexer.offset(ctx.tokens, last - 1), Lexer.stop(ctx.tokens, last), "[\"" .. n.name .. "\"]")
        return { rewrite = rewrite_of("map_field", { edit }), request = nil, why = "" }
      end
    end
  end
  return nothing("no read of a field of a map starts here")
end

local function and_ternary(ctx: Ctx, p: Driver.Problem): Made
  for _, n in ipairs(ctx.facts.at[p.offset] or {}) do
    if (n.kind == "Binary") and n.op == "or" then
      local conjunction = n.left
      if (conjunction.kind == "Binary") and conjunction.op == "and" then
        local middle = type_of(ctx, conjunction.right)
        if middle == nil or Truthy.may_be_false(middle) then
          return nothing("the value after `and` can be false or nil, where `if` answers it and `or` answers what follows")
        end
        local first, last = base_of(n).first, base_of(n).last
        local and_at = base_of(conjunction.left).last + 1
        local or_at = base_of(conjunction).last + 1
        if Lexer.text(ctx.tokens, and_at) ~= "and" or Lexer.text(ctx.tokens, or_at) ~= "or" then
          return nothing("the operators are not where the tree puts them")
        end
        local start = Lexer.offset(ctx.tokens, first)
        local stop = Lexer.stop(ctx.tokens, last)
        local edits: {Edit} = {
          text_edit(start, start, "if "),
          text_edit(Lexer.offset(ctx.tokens, and_at), Lexer.stop(ctx.tokens, and_at), "then"),
          text_edit(Lexer.offset(ctx.tokens, or_at), Lexer.stop(ctx.tokens, or_at), "else"),
          text_edit(stop, stop, " end"),
        }
        return { rewrite = rewrite_of("and_ternary", edits), request = nil, why = "" }
      end
    end
  end
  return nothing("no `a and b or c` starts here")
end

local function view_written(ctx: Ctx, p: Driver.Problem): Made
  local target = target_at(ctx, p.offset)
  if (target.kind == "Index") then
    local owner = peel(target.object)
    if (owner.kind == "Name") then
      local edit, why = declared_mut(ctx, owner)
      if edit == nil then
        return nothing(why)
      end
      return { rewrite = rewrite_of("view_written", { edit }), request = nil, why = "" }
    elseif (owner.kind == "Field") then
      local request, why = field_request(ctx, "view_written", owner.object, owner.name, true)
      if request == nil then
        return nothing(why)
      end
      return { rewrite = nil, request = request, why = "" }
    end
    return nothing("the collection is neither a local, a parameter nor a field")
  end
  return nothing("no assignment to an element starts here")
end

local function field_fixed(ctx: Ctx, p: Driver.Problem): Made
  local target = target_at(ctx, p.offset)
  local object: Ast.Exp? = nil
  local field = ""
  if (target.kind == "Field") then
    object, field = target.object, target.name
  elseif (target.kind == "Index") then
    local key = peel(target.key)
    if (key.kind == "String") then
      object, field = target.object, key.value
    end
  end
  if object == nil then
    return nothing("no assignment to a field starts here")
  end
  local request, why = field_request(ctx, "field_fixed", object, field, false)
  if request == nil then
    return nothing(why)
  end
  return { rewrite = nil, request = request, why = "" }
end

--- The type `t` written as the type of an element, or nil where it is not a plain one.
local function plain(ctx: Ctx, t: Types.Type?): string?
  if t == nil then
    return nil
  end
  local tag = t.tag
  if tag == "string" or tag == "integer" or tag == "number" then
    return tag
  elseif tag == "boolean" then
    return "boolean"
  elseif (t.tag == "named") and #t.args == 0 and not t.value and t.decl.module == ctx.outcome.module then
    return t.decl.name
  end
  return nil
end

--- Whether `key` is `#object + 1`, which appends to `object`.
local function appends(key: Ast.Exp, object: Ast.Name): boolean
  local k = peel(key)
  if (k.kind == "Binary") and k.op == "+" then
    local length, one = k.left, k.right
    if (length.kind == "Unary") and length.op == "#" and (one.kind == "Integer") and one.value == 1 then
      local counted = peel(length.operand)
      return (counted.kind == "Name") and counted.binding == object.binding
    end
  end
  return false
end

--- The type of `local name = {}` that the first write to `name` shows: `mut {T}` for an append or a `table.insert`, and
--- `mut {string: T}` for a string key.
local function written_type(ctx: Ctx, var: integer): string?
  local scoped = ctx.outcome.scoped
  local entry = scoped.vars[var]
  if entry == nil then
    return nil
  end
  for _, read in ipairs(entry.reads) do
    local name = ctx.facts.node[read]
    local parent = ctx.facts.parent[read]
    if (name.kind == "Name") and (parent.kind == "Index") and peel(parent.object) == name then
      local assign = ctx.facts.parent[base_of(parent).id]
      if (assign.kind == "Assign") then
        for j, target in ipairs(assign.targets) do
          local value = assign.values[j]
          if target == parent and value ~= nil and #assign.targets == #assign.values then
            local element = plain(ctx, type_of(ctx, value))
            if element == nil then
              return nil
            end
            if appends(parent.key, name) then
              return "mut {" .. element .. "}"
            end
            local key = type_of(ctx, parent.key)
            if key ~= nil and key.tag == "string" then
              return "mut {string: " .. element .. "}"
            end
            return nil
          end
        end
      end
    elseif (name.kind == "Name") and (parent.kind == "Call") and parent.args[1] == name and #parent.args == 2 then
      local callee = parent.callee
      if (callee.kind == "Field") and callee.name == "insert" then
        local table_name = callee.object
        if (table_name.kind == "Name") and table_name.text == "table" then
          local element = plain(ctx, type_of(ctx, assert(parent.args[2])))
          if element == nil then
            return nil
          end
          return "mut {" .. element .. "}"
        end
      end
    end
  end
  return nil
end

local function literal_needs_type(ctx: Ctx, p: Driver.Problem): Made
  for _, n in ipairs(ctx.facts.at[p.offset] or {}) do
    if (n.kind == "Table") and #n.items == 0 then
      local owner = ctx.facts.parent[base_of(n).id]
      if (owner.kind == "Local") and #owner.bindings == 1 and #owner.values == 1 and #owner.types == 0 then
        local binding = assert(owner.bindings[1])
        if binding.attr ~= nil then
          return nothing("the local is declared with an attribute")
        end
        local shown = written_type(ctx, base_of(binding).id)
        if shown == nil then
          return nothing("the first write to the local does not show a plain element type")
        end
        local at = Lexer.stop(ctx.tokens, base_of(binding).last)
        return { rewrite = rewrite_of("literal_needs_type", { text_edit(at, at, ": " .. shown) }), request = nil, why = "" }
      end
    end
  end
  return nothing("the literal is not the value of a local with no type")
end

--- The `mut` of a field that a type and an interface it lists declare differently: the field is made `mut` in both and in
--- what else lists the interface ([`family`]), since the interface and every type that lists it declare it alike. A class
--- that declares the field as a method cannot, and the finding is left.
local function interface_disagrees(ctx: Ctx, p: Driver.Problem): Made
  if p.msg:find(" is fixed, but ", 1, true) == nil and p.msg:find(" is mut, but ", 1, true) == nil then
    return nothing("")
  end
  for _, n in ipairs(ctx.facts.at[p.offset] or {}) do
    local member: Ast.Node? = n
    if (n.kind == "Binding") then
      member = ctx.facts.parent[base_of(n).id]
    end
    if (member.kind == "FieldDecl") or (member.kind == "Method") then
      local names: mut {string} = {}
      local at = ctx.facts.parent[base_of(member).id]
      while at ~= nil and not ((at.kind == "Chunk")) do
        if (at.kind == "Record") or (at.kind == "Class") or (at.kind == "Interface") then
          table.insert(names, 1, at.name.name)
        elseif not ((at.kind == "Block")) then
          return nothing("the declaration is in the body of a function")
        end
        at = ctx.facts.parent[base_of(at).id]
      end
      local path = table.concat(names, ".")
      for _, d in ipairs(ctx.decls) do
        if d.module == ctx.outcome.module and d.name == path then
          local request: Request = {
            code = "interface_disagrees", decl = d, field = member.name.name, collection = false, finding = nil,
          }
          return { rewrite = nil, request = request, why = "" }
        end
      end
      return nothing("the checker has no declaration `" .. path .. "`")
    end
  end
  return nothing("no member of a declaration starts here")
end

--- A view passed where a `mut` collection is wanted: what a callee's `mut` parameter asks of its callers. It has no rewrite, and
--- says what to do.
--
-- TODO: declare the argument `mut` where it is made (a local or a parameter), as [`view_written`] does for a collection that is
-- written, once a rewrite can tell a collection made here from a view a call answers, whose copy it cannot write. Until then each
-- [`view_as_mut`] that a new `mut` parameter causes is listed with a note.
local function view_as_mut(_ctx: Ctx, _p: Driver.Problem): Made
  return nothing("a callee takes a `mut` collection now: declare the argument `mut` where it is made, or pass a copy")
end

local MAKERS <const>: {string: function(ctx: Ctx, p: Driver.Problem): Made} = {
  map_field = map_field, and_ternary = and_ternary, view_written = view_written, field_fixed = field_fixed,
  literal_needs_type = literal_needs_type, interface_disagrees = interface_disagrees,
  view_as_mut = view_as_mut,
}

--- Where the offsets of a text that a [`build.syntax_shape_specs`] splice lengthened were in the text it was made from.
local record Shift
  at: integer
  size: integer
end

--- The insertions that make `spliced` of `original`, as [`build.syntax_shape_specs`] splices a spec into the call of
--- [`Shape.record_of`], which the checker reads in place of the source. nil where `spliced` is more than insertions.
--
-- TODO: take the offsets of any text the checker adds to a file from the checker, not only a [`Shape.record_of`] splice found by
-- comparing the two texts, once [`Driver.Outcome`] answers the splices its source's `mend` and [`build.syntax_shape_specs`] made.
-- A file whose text is more than insertions is read, its findings are listed with a note, and nothing is rewritten in it.
local function insertions(original: string, spliced: string): {Shift}?
  local shifts: mut {Shift} = {}
  local i, j = 1, 1
  local n = #original
  while i <= n do
    if original:byte(i) == spliced:byte(j) then
      i = i + 1
      j = j + 1
    else
      local at = spliced:find(original:sub(i, i + 31), j, true)
      if at == nil or at == j then
        return nil
      end
      shifts[#shifts + 1] = { at = i - 1, size = at - j }
      j = at
    end
  end
  if j <= #spliced then
    shifts[#shifts + 1] = { at = n, size = #spliced - j + 1 }
  end
  return shifts
end

--- The offset in the text before the splices of `offset` in the text after them, or nil where it is inside a splice.
local function unshifted(shifts: {Shift}, offset: integer): integer?
  local added = 0
  for _, s in ipairs(shifts) do
    local start = s.at + 1 + added
    if offset >= start + s.size then
      added = added + s.size
    elseif offset >= start then
      return nil
    else
      break
    end
  end
  return offset - added
end

--- `edit`, which is in the text after the splices, as an edit of the text before them.
local function unshifted_edit(shifts: {Shift}, edit: Edit): Edit?
  if #shifts == 0 then
    return edit
  end
  local lo = unshifted(shifts, edit.lo)
  if lo == nil then
    return nil
  end
  if edit.hi == edit.lo then
    return text_edit(lo, lo, edit.text)
  end
  local last = unshifted(shifts, edit.hi - 1)
  if last == nil then
    return nil
  end
  return text_edit(lo, last + 1, edit.text)
end

--- Reads the project `texts` (the paths `paths`) with the checker and makes the rewrites its findings call for.
local function survey(texts: {string: string}, paths: {string}, options: Pipeline.Options): Survey
  local made: Survey = { counts = {}, findings = {}, rewrites = {}, requests = {}, holders = {}, shared = {} }
  local entries: mut {{string}} = {}
  for _, path in ipairs(paths) do
    entries[#entries + 1] = { path, assert(texts[path]) }
  end
  local index = Driver.index(entries, function(_: string): boolean
    return false
  end)
  local build = TreeProgram.build(index, options.globals, true, nil, Pipeline.carried())
  local modules: mut {string} = {}
  for _, source in ipairs(index.sources) do
    if index.by_module[source.module] == source then
      modules[#modules + 1] = source.module
      made.holders[source.module] = source.filename
    end
  end
  TreeProgram.stream(build, index, modules, true, function(module: string)
    local outcome = build:result(module, true)
    if outcome == nil then
      return
    end
    local path = outcome.source.filename
    local wanted = false
    local recorded: mut {Migrate.Finding} = {}
    for i, p in ipairs(outcome.errors) do
      made.counts[p.code] = (made.counts[p.code] or 0) + 1
      local finding: Migrate.Finding = { path = path, y = p.y, x = p.x, code = p.code, msg = p.msg, note = "" }
      made.findings[#made.findings + 1] = finding
      recorded[i] = finding
      if FIXABLE[p.code] then
        wanted = true
      end
    end
    if not wanted or outcome.broken then
      return
    end
    local original = assert(texts[path])
    local shifts: {Shift} = {}
    if outcome.text ~= original then
      local found = insertions(original, outcome.text)
      if found == nil then
        for i, p in ipairs(outcome.errors) do
          if FIXABLE[p.code] then
            assert(recorded[i]).note = "the checker read this file with text added that is more than a spliced call, which " ..
              "this run cannot map back to the source"
          end
        end
        return
      end
      shifts = found
    end
    local ctx: Ctx = { outcome = outcome, facts = facts_of(outcome.chunk), tokens = outcome.chunk.tokens, index = index,
      decls = build.program.store.list,
    }
    local list: mut {Rewrite} = {}
    for i, p in ipairs(outcome.errors) do
      local maker = MAKERS[p.code]
      if maker ~= nil then
        local done = maker(ctx, p)
        local request = done.request
        if request == nil and done.rewrite == nil then
          assert(recorded[i]).note = done.why
        end
        local rewrite = done.rewrite
        if request ~= nil then
          request.finding = recorded[i]
          made.requests[#made.requests + 1] = request
        elseif rewrite ~= nil then
          local edits: mut {Edit} = {}
          for _, e in ipairs(rewrite.edits) do
            local moved = unshifted_edit(shifts, e)
            if moved ~= nil then
              edits[#edits + 1] = moved
            end
          end
          if #edits == #rewrite.edits then
            list[#list + 1] = rewrite_of(rewrite.code, edits)
          else
            assert(recorded[i]).note = "an edit of the rewrite lies in text the checker added to the file"
          end
        end
      end
    end
    made.rewrites[path] = list
  end)
  local families: mut {string: Family} = {}
  local requests: mut {Request} = {}
  for _, request in ipairs(made.requests) do
    local key = request_key(request)
    local together = families[key]
    if together == nil then
      together = family(build.program.store.list, request.decl, request.field)
      families[key] = together
    end
    local finding = request.finding
    if together.blocked == "" then
      for _, member in ipairs(together.members) do
        if made.holders[member.module] == nil then
          together.blocked = "`" .. request.decl.name .. "." .. request.field .. "` is declared alike in `" .. member.name ..
            "` of the module `" .. member.module .. "`, which this run does not write"
          break
        end
      end
      if together.blocked == "" and #together.members > 1 then
        for _, member in ipairs(together.members) do
          made.shared[#made.shared + 1] = { name = member.name, field = request.field }
        end
      end
    end
    if together.blocked ~= "" then
      if finding ~= nil then
        finding.note = together.blocked
      end
    else
      for _, member in ipairs(together.members) do
        requests[#requests + 1] = {
          code = request.code, decl = member, field = request.field, collection = request.collection, finding = finding,
        }
      end
    end
  end
  made.requests = requests
  return made
end

--- The members of the declaration `node`, or nil where it declares none.
local function members_of(node: Ast.Node): {Ast.Member}?
  if (node.kind == "Record") or (node.kind == "Class") or (node.kind == "Interface") then
    return node.members
  end
  return nil
end

--- The declaration among `members` named `name`.
local function named(members: {Ast.Node}, name: string): Ast.Node?
  for _, m in ipairs(members) do
    if (m.kind == "Record") or (m.kind == "Class") or (m.kind == "Interface") then
      if m.name.name == name then
        return m
      end
    end
  end
  return nil
end

--- The rewrite that `request` asks for in the file `path` whose text is `text`, or why there is none.
local function resolved(request: Request, path: string, text: string): Rewrite?, string
  local dialect: Ast.Dialect = if path:match("%.d%.tl$") ~= nil then "decl" else "tl" end
  local read = Driver.parse(Driver.source(request.decl.module, path, text, dialect))
  if #read.syntax > 0 then
    return nil, path .. " does not parse"
  end
  local level: mut {Ast.Node} = {}
  for _, s in ipairs(read.chunk.body.stats) do
    level[#level + 1] = s
  end
  local found: Ast.Node? = nil
  for _, name in ipairs(request.decl.names) do
    found = named(level, name)
    if found == nil then
      return nil, "no declaration of `" .. name .. "` in " .. path
    end
    level = {}
    for _, m in ipairs(members_of(found) or {}) do
      level[#level + 1] = m
    end
  end
  for _, m in ipairs(level) do
    if (m.kind == "FieldDecl") and m.name.name == request.field then
      local tokens = read.chunk.tokens
      if request.collection then
        local edit, why = mut_collection(tokens, m.type)
        if edit == nil then
          return nil, why
        end
        return rewrite_of(request.code, { edit }), ""
      end
      if m.mut then
        return nil, ""
      end
      local at = Lexer.offset(tokens, base_of(m).first)
      return rewrite_of(request.code, { text_edit(at, at, "mut ") }), ""
    end
  end
  return nil, "no field `" .. request.field .. "` in " .. path
end

--- `text` with the edits of `rewrites` made, each rewrite once, and the rewrites made. No two edits share a byte or the place
--- of an insertion: a rewrite is one token or one declaration, and none edits another's.
local function edited(text: string, rewrites: {Rewrite}): string, {Rewrite}
  local made: mut {Rewrite} = {}
  local edits: mut {Edit} = {}
  local seen: mut {string: boolean} = {}
  for _, r in ipairs(rewrites) do
    if not seen[r.key] then
      seen[r.key] = true
      made[#made + 1] = r
      for _, e in ipairs(r.edits) do
        edits[#edits + 1] = e
      end
    end
  end
  table.sort(edits, function(a: Edit, b: Edit): boolean
    if a.lo ~= b.lo then
      return a.lo < b.lo
    elseif a.hi ~= b.hi then
      return a.hi < b.hi
    end
    return a.text < b.text
  end)
  local pieces: mut {string} = {}
  local at = 1
  for _, e in ipairs(edits) do
    assert(e.lo >= at, "two rewrites edit the same bytes")
    pieces[#pieces + 1] = text:sub(at, e.lo - 1)
    pieces[#pieces + 1] = e.text
    at = e.hi
  end
  pieces[#pieces + 1] = text:sub(at)
  return table.concat(pieces), made
end

--- Makes the rewrites of `found` in `texts`. The new texts of the files that changed
--- (every file is in `texts`), and the rewrites made by code.
local function apply(found: Survey, texts: {string: string}):
    {string: string}, {string: integer}
  local per_file: mut {string: {Rewrite}} = {}
  for path, list in pairs(found.rewrites) do
    per_file[path] = list
  end
  local requested: mut {string: boolean} = {}
  local refused: mut {string: string} = {}
  for _, request in ipairs(found.requests) do
    local key = request_key(request)
    local path = found.holders[request.decl.module]
    if path ~= nil and not requested[key] then
      requested[key] = true
      local rewrite, why = resolved(request, path, assert(texts[path]))
      if rewrite ~= nil then
        local list = per_file[path]
        if list == nil then
          list = {}
          per_file[path] = list
        end
        list[#list + 1] = rewrite
      else
        refused[key] = why
      end
    end
  end
  for _, request in ipairs(found.requests) do
    local why = refused[request_key(request)]
    local finding = request.finding
    if why ~= nil and finding ~= nil then
      finding.note = why
    end
  end
  local changed: mut {string: string} = {}
  local counts: mut {string: integer} = {}
  for path, list in pairs(per_file) do
    local text = assert(texts[path])
    local made_text, made = edited(text, list)
    if made_text ~= text then
      changed[path] = made_text
    end
    for _, r in ipairs(made) do
      counts[r.code] = (counts[r.code] or 0) + 1
    end
  end
  return changed, counts
end

function Migrate.run(files: {string: string}, options?: Migrate.Options): Migrate.Result?, string
  local started = Clock.monotonic_ns()
  local rounds = (options ~= nil and options.rounds) or ROUNDS
  local checking, why = Pipeline.alone()
  if checking == nil then
    return nil, why
  end
  local paths: mut {string} = {}
  for path in pairs(files) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  local result: Migrate.Result = {
    texts = {}, changed = {}, untranslated = {}, before = {}, after = {}, rewrites = {}, left = {},
    shared = {}, rounds = 0, converged = true, nanoseconds = 0,
  }
  local shared_seen: mut {string: boolean} = {}
  for _, path in ipairs(paths) do
    local translated = Translate.translate(assert(files[path]), path)
    result.texts[path] = translated.text
    for _, e in ipairs(translated.errors) do
      result.untranslated[#result.untranslated + 1] = path .. ":" .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg .. " (" .. e.code .. ")"
    end
  end
  local found = survey(result.texts, paths, checking)
  for code, n in pairs(found.counts) do
    result.before[code] = n
  end
  while true do
    local changed, counts = apply(found, result.texts)
    if next(changed) == nil then
      break
    end
    if result.rounds == rounds then
      result.converged = false
      break
    end
    result.rounds = result.rounds + 1
    for _, family_made in ipairs(found.shared) do
      local key = family_made.name .. "\0" .. family_made.field
      if not shared_seen[key] then
        shared_seen[key] = true
        result.shared[#result.shared + 1] = family_made
      end
    end
    for path, text in pairs(changed) do
      result.texts[path] = text
    end
    found = survey(result.texts, paths, checking)
    for code, n in pairs(counts) do
      result.rewrites[code] = (result.rewrites[code] or 0) + n
    end
  end
  for code, n in pairs(found.counts) do
    result.after[code] = n
  end
  result.left = found.findings
  table.sort(result.left, function(a: Migrate.Finding, b: Migrate.Finding): boolean
    if a.path ~= b.path then
      return a.path < b.path
    elseif a.y ~= b.y then
      return a.y < b.y
    elseif a.x ~= b.x then
      return a.x < b.x
    end
    return a.code < b.code
  end)
  for _, path in ipairs(paths) do
    if result.texts[path] ~= files[path] then
      result.changed[#result.changed + 1] = path
    end
  end
  result.nanoseconds = Clock.monotonic_ns() - started
  return result, ""
end

--- The counts by code as `code n, code n`, or `none`.
local function listed(counts: {string: integer}): string
  local parts: mut {string} = {}
  for code, n in pairs(counts) do
    parts[#parts + 1] = code .. " " .. tostring(n)
  end
  table.sort(parts)
  return if #parts == 0 then "none" else table.concat(parts, ", ") end
end

local function total(counts: {string: integer}): integer
  local sum = 0
  for _, n in pairs(counts) do
    sum = sum + n
  end
  return sum
end

--- The most findings left that a run lists.
local LISTED <const> = 200

--- Whether `path` is a file `migrate` reads: a `.tl` or `.d.tl` file.
local function is_source(path: string): boolean
  return path:match("%.tl$") ~= nil
end

--- The files of `path` below the working directory: itself where it is a file, and the `.tl` files below it where it is a
--- directory, apart from hidden directories and `vendor`. nil and why where it cannot be read.
local function expand(path: string): {string}?, string
  local directory, trouble = Fs.is_dir(path)
  if directory == nil then
    return nil, trouble
  end
  if not directory then
    return { path }, ""
  end
  local walked, why = Fs.walk(path, function(_: string, name: string, kind: Fs.Kind): boolean
    return kind == "dir" and (name:sub(1, 1) == "." or name == "vendor")
  end)
  if walked == nil then
    return nil, why
  end
  local out: mut {string} = {}
  local prefix = if path == "." then "" else path:gsub("/+$", "") .. "/" end
  for _, relative in ipairs(walked) do
    if is_source(relative) then
      out[#out + 1] = prefix .. relative
    end
  end
  return out, ""
end

--- The file a named path leads to, through the symbolic links it passes: the path itself where it is no link.
local function target_of(path: string): string
  local at = path
  for _ = 1, 16 do
    local link, _why = Fs.readlink(at)
    if link == nil then
      return at
    end
    at = link:sub(1, 1) == "/" and link or Fs.dirname(at) .. "/" .. link
  end
  return at
end

--- The files below the working directory that this run was not given and that mention a declaration it changed `mut` together
--- with the types that list it: they may list it, and need the same change. A line each; none where nothing was changed.
local function unnamed_mentions(files: {string: string}, shared: {Migrate.Shared}): {string}
  local lines: mut {string} = {}
  if #shared == 0 then
    return lines
  end
  local all, _ = expand(".")
  for _, path in ipairs(all or {}) do
    if files[path] == nil then
      local text, _ = Fs.read(path)
      for _, family_made in ipairs(shared) do
        local last = family_made.name:match("([^.]*)$")
        if text ~= nil and text:find(last, 1, true) ~= nil then
          lines[#lines + 1] = path .. ": mentions `" .. family_made.name .. "`, whose field `" .. family_made.field ..
            "` was made `mut` with the types that list it: name this file too"
          break
        end
      end
    end
  end
  return lines
end

function Migrate.main(argv: {string}, streams?: Migrate.Io): integer
  local to = streams or { out = bare.out, err = bare.err }
  local complain = bare.complainer("migrate", to.err)
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end
  if #parsed.words == 0 then
    complain("name a directory or a .tl file to migrate; " .. usage)
    return bare.refused
  end
  local checking = parsed.set["--check"] or false
  local files: mut {string: string} = {}
  local modes: mut {string: integer} = {}
  for _, word in ipairs(parsed.words) do
    if word == "" then
      complain(bare.empty_file)
      return bare.refused
    end
    local given = word
    while given:sub(1, 2) == "./" do
      given = given:sub(3)
    end
    local listed_files, why = expand(if given == "" then "." else given end)
    if listed_files == nil then
      complain(why)
      return bare.refused
    end
    if #listed_files == 0 then
      complain(given .. ": no .tl files below it")
      return bare.refused
    end
    for _, path in ipairs(listed_files) do
      if path:sub(1, 1) == "/" or ("/" .. path .. "/"):find("/../", 1, true) ~= nil then
        complain(path .. ": name files below the working directory, which module names are relative to")
        return bare.refused
      end
      if not is_source(path) then
        complain(path .. ": not a .tl source")
        return bare.refused
      end
      if files[path] == nil then
        local text, read_why = Fs.read(path)
        if text == nil then
          complain(read_why)
          return bare.refused
        end
        files[path] = text
        local st, _ = Fs.stat(path)
        modes[path] = if st ~= nil then st.mode & 0x1ff else 0x1a4 end
      end
    end
  end
  local result, run_why = Migrate.run(files)
  if result == nil then
    complain("cannot set up the checker: " .. run_why)
    return bare.failed
  end
  -- The files are written first, so that the report says what was written.
  local written: mut {string} = {}
  local write_trouble = ""
  if not checking then
    for _, path in ipairs(result.changed) do
      local at = target_of(path)
      local mode = modes[path] or 0x1a4
      local wrote, write_why = Fs.write(at, assert(result.texts[path]), mode)
      if wrote then
        wrote, write_why = Fs.chmod(at, mode)
      end
      if not wrote then
        write_trouble = write_why
        break
      end
      written[#written + 1] = path
    end
  end
  local lines: mut {string} = {}
  for _, path in ipairs(checking and result.changed or written) do
    lines[#lines + 1] = (if checking then "would migrate " else "migrated " end) .. path
  end
  for _, line in ipairs(result.untranslated) do
    lines[#lines + 1] = line .. ": not translated: write it by hand"
  end
  for i, f in ipairs(result.left) do
    if i > LISTED then
      lines[#lines + 1] = "... and " .. plural.count(#result.left - LISTED, "more finding") .. ", counted by code in the summary"
      break
    end
    local line = f.path .. ":" .. tostring(f.y) .. ":" .. tostring(f.x) .. ": " .. f.msg .. " (" .. f.code .. ")"
    if f.note ~= "" then
      line = line .. "; not rewritten: " .. f.note
    end
    lines[#lines + 1] = line
  end
  local outside = unnamed_mentions(files, result.shared)
  for _, line in ipairs(outside) do
    lines[#lines + 1] = line
  end
  local paths_count = 0
  for _ in pairs(files) do
    paths_count = paths_count + 1
  end
  lines[#lines + 1] = "read " .. plural.count(paths_count, "file") .. ", " .. (if checking then "would change " else "changed " end) ..
    tostring(#result.changed) .. "; findings " .. tostring(total(result.before)) .. " after the translation (" .. listed(result.before) ..
    "), " .. tostring(total(result.after)) .. " after " .. plural.count(total(result.rewrites), "rewrite") .. " in " ..
    plural.count(result.rounds, "round") .. " (" .. listed(result.after) .. ")"
  local open: mut {string} = {}
  if checking and #result.changed > 0 then
    open[#open + 1] = plural.count(#result.changed, "file") .. " would change"
  end
  if #result.left > 0 then
    open[#open + 1] = plural.count(#result.left, "finding") .. " left"
  end
  if #result.untranslated > 0 then
    open[#open + 1] = plural.count(#result.untranslated, "form") .. " not translated"
  end
  if #outside > 0 then
    open[#open + 1] = plural.count(#outside, "file") .. " outside this run to change with it"
  end
  if not result.converged then
    open[#open + 1] = "the rewrites were still going after " .. plural.count(result.rounds, "round") .. ": run migrate again"
  end
  if #open == 0 then
    lines[#lines + 1] = if checking then "migrate: nothing would change and nothing is left" else "migrate: nothing is left" end
  else
    lines[#lines + 1] = "migrate: exit 1: " .. table.concat(open, "; ")
  end
  local sent = bare.delivered(complain, to.out(table.concat(lines, "\n") .. "\n"))
  if write_trouble ~= "" then
    complain(write_trouble .. (if #written > 0 then "; already migrated: " .. table.concat(written, ", ") else "; none was written" end))
    return bare.failed
  end
  if not sent then
    return bare.refused
  end
  return #open == 0 and bare.ok or bare.failed
end

--- The `migrate` verb as [`build/verb_list.tl`] lists it. Reads the files it is given, never the tree: never
--- stale-checked.
Migrate.spec = {
  name = "migrate",
  guide = "none: rewrites an outside project into the new grammar, described by `cosmic help migrate` and doc/guides/project.md",
  tests = { "build.migrate_test", "build.migrate_tool_test" },
  run = function(argv: {string}): integer return Migrate.main(argv) end,
  bare = true,
  takes = "the directories and .tl files to migrate",
  exits = "`migrate` lists what it left, a summary and a last line that says why it exits 1, and exits 0 when nothing would " ..
    "change and nothing is left, 1 otherwise, 2 for a command line it refused.",
  passthrough = "its output is a report of the files it read, so its exit status is the verdict (build/migrate_test.tl)",
}

return Migrate
