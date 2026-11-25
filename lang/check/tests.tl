--- What a test of a value proves: its kinds, its tags, its length, and the calls that run no code of the program.

local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local Flow = require("lang.flow")
local Types = require("lang.types")
local Warnings = require("lang.warnings")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local TableLiterals = require("lang.check.table_literals")
local Places = require("lang.check.places")
local Writes = require("lang.check.writes")
local type Type = Types.Type
local type Named = Types.Named
local type Ctx = Context.Ctx
local base_of = Context.base_of
local below = Context.below
local members_of = Context.members_of
local nilable = Context.nilable
local peel = Context.peel
local report = Naming.report
local subject = Context.subject
local text_of = Context.text_of
local type Place = Places.Place
local current = Places.current
local place_of = Places.place_of

--- The tests of a type: what Lua value it is, which strings, tables and tags it holds, and what a test of a place leaves of it.
local record Tests
  lua_kind: function(t: Type): string
  kinds_of: function(ctx: Ctx, t: Type): {string: boolean}?
  enum_strings: function(ctx: Ctx, t: Type): {string}?
  table_members: function(ctx: Ctx, t: Type): {Type}?
  tag_field: function(ctx: Ctx, list: {Type}): string?, {string}?
  tag_values: function(ctx: Ctx, m: Type, name: string): {string}?
  nil_of: function(ctx: Ctx, cur: Type): Type
  not_nil_of: function(ctx: Ctx, cur: Type): Type
  by_kind: function(ctx: Ctx, cur: Type, kind: string, keep: boolean): Type
  keep_is: function(ctx: Ctx, cur: Type, tested: Type): Type
  drop_is: function(ctx: Ctx, cur: Type, tested: Type): Type
  by_literal: function(ctx: Ctx, cur: Type, lit: string, keep: boolean): Type
  record_tag: function(ctx: Ctx, value: Type, r: Type): {string}?
  --- Adds the warning `code` on the tokens of `node`; none in a pass that reports nothing.
  warn: function(ctx: Ctx, code: Warnings.Code, node: Ast.Node, msg: string, fix: string)
  --- Reports `(x) is T` where `x` is a place, which the parentheses make a value.
  parenthesized: function(ctx: Ctx, node: Ast.IsTest)
  --- The place `e` counts, if `e` is `#place` and the place holds an array.
  counted: function(ctx: Ctx, f: Flow.State, e: Ast.Node): Place?
  --- `f` where the array at `p` has at least `n` elements; nothing is known in the scope of a `<close>` local, whose
  --- handler may shorten the array where the scope ends.
  know_length: function(ctx: Ctx, f: Flow.State, p: Place, n: integer): Flow.State
  --- The edges of `left op right` (not `~=`) where one side is `#place`, the place holds an array, and the other is an
  --- integer literal: the states where it holds and where it fails, each knowing the least length that gives.
  length_edges: function(ctx: Ctx, f: Flow.State, op: string, left: Ast.Node, right: Ast.Node): Flow.State, Flow.State
  --- The state where `e`, a read `object[key]` of an array, is not nil: the array has the key, so it is at least that long
  --- where `key` is an integer literal of 1 or more or `#object`, and it has the key the local `key` holds, which only a
  --- read at that local relies on. `f` itself where `e` is no such read.
  has_element: function(ctx: Ctx, f: Flow.State, e: Ast.Node): Flow.State
  --- Whether an array of `element` holds the keys 1 to its length, which every length fact and counted loop relies on: no
  --- member of `element` is nil at run time. `any` may be nil, and so may a type variable, which stands for any type a
  --- caller gives (`mark<T>(...: T)` called with an optional), so `{ ... }` of such a vararg may have holes.
  dense: function(ctx: Ctx, element: Type): boolean
  --- Whether the read `object[key]` of an array is an element it has: `key` is an integer literal, or `#object`, and the
  --- flow has the array at least that long, or a local the flow has the array hold as a key.
  length_proves: function(ctx: Ctx, object: Ast.Exp, key: Ast.Exp): boolean
  --- Whether a call of `callee` runs no code of the program whatever it is given: `assert` and `type` of the standard library.
  quiet_callee: function(callee: Ast.Exp?): boolean
  --- Whether `t` holds no value that code of the program can run through a function of the standard library: scalars, enums,
  --- and arrays and maps of them. A class value may have a `__tostring`, which `tostring` and `string.format` run.
  plain: function(ctx: Ctx, t: Type): boolean
  --- Whether the call of `callee` (nil for a method call) names a function of the standard library that runs code of the
  --- program only through a value or a function it is given: `tostring`, `tonumber`, `select`, `rawlen`, `string.*`,
  --- `math.*`, `utf8.*`, `table.concat` and `table.unpack`. A name a program declares is never one.
  inert_callee: function(callee: Ast.Exp?): boolean
  --- Whether the code of `node` holds a call that is not inert (the `inert` of the context, set where the call is checked).
  --- It reads the tree with a list, so that a chain of any depth is read without recursion.
  has_call: function(ctx: Ctx, node: Ast.Node): boolean
  --- A `<close>` local is declared: nothing is known of the length of an array until its scope ends.
  closes: function(ctx: Ctx)
  --- A scope entered with `closers` open is left: the handlers of its `<close>` locals have run.
  leaves: function(ctx: Ctx, closers: integer)
end

function Tests.warn(ctx: Ctx, code: Warnings.Code, node: Ast.Node, msg: string, fix: string)
  if ctx.quiet > 0 then
    return
  end
  local b = base_of(node)
  Warnings.add(ctx.warnings, ctx.filename, ctx.tokens, code, b.first, b.last, msg, fix)
end

function Tests.parenthesized(ctx: Ctx, node: Ast.IsTest)
  local written = node.value
  if not ((written.kind == "Paren")) then
    return
  end
  local inner = peel(written)
  if (inner.kind == "Name") or (inner.kind == "Field") then
    report(ctx, "paren_is", written, "`" .. text_of(ctx, written) .. " is ...` tests a value: the parentheses make " ..
        subject(ctx, inner) .. " no place, so the test narrows nothing",
      "write `" .. text_of(ctx, inner) .. " is " .. text_of(ctx, node.type) .. "` without the parentheses, so that the test narrows it")
  end
end

--- The kind of Lua value a value of type `t` is, or "" where the type does not say (`any`, a type variable, a union).
function Tests.lua_kind(t: Type): string
  local tag = t.tag
  if tag == "integer" or tag == "number" then
    return "number"
  elseif tag == "string" then
    return "string"
  elseif tag == "boolean" or tag == "true" or tag == "false" then
    return "boolean"
  elseif tag == "nil" then
    return "nil"
  elseif tag == "fn" then
    return "function"
  elseif tag == "array" or tag == "map" then
    return "table"
  elseif (t.tag == "named") then
    local kind = t.decl.kind
    if kind == "enum" then
      return "string"
    elseif kind == "integer_enum" and not t.value then
      return "number"
    elseif kind == "userdata" then
      return "userdata"
    end
    return "table"
  end
  return ""
end

--- The kinds of Lua value a value of type `t` may be, or nil where it may be any.
function Tests.kinds_of(ctx: Ctx, t: Type): {string: boolean}?
  local out: mut {string: boolean} = {}
  for _, m in ipairs(members_of(ctx.store, t)) do
    local kind = Tests.lua_kind(m)
    if kind ~= "" then
      out[kind] = true
    elseif m.tag ~= "never" then
      return nil
    end
  end
  return out
end

--- The values of the enum a field of `m` is declared with, or nil where `m` has no such field or the field is `mut`.
function Tests.tag_values(ctx: Ctx, m: Type, name: string): {string}?
  if not ((m.tag == "named")) or m.value or (m.decl.kind ~= "record" and m.decl.kind ~= "class") then
    return nil
  end
  local field = TableLiterals.plain_field(ctx, m, name)
  if field ~= nil and field.mut == true then
    return nil
  end
  local t = field ~= nil and field.type or nil -- checked: and_ternary
  local body = t ~= nil and (t.tag == "named") and t.decl.kind == "enum" and t.decl.body or nil
  return body ~= nil and body.values or nil
end

--- The strings a value of type `t` may be when `t` says no more of a string than the values of its enums, else nil.
function Tests.enum_strings(ctx: Ctx, t: Type): {string}?
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, m in ipairs(members_of(ctx.store, t)) do
    if Tests.lua_kind(m) == "string" then
      local body: Types.Body? = nil
      if (m.tag == "named") and m.decl.kind == "enum" then
        body = m.decl.body
      end
      if body == nil then
        return nil
      end
      for _, v in ipairs(body.values) do
        if seen[v] ~= true then
          seen[v] = true
          out[#out + 1] = v
        end
      end
    end
  end
  table.sort(out)
  return #out > 0 and out or nil -- checked: and_ternary
end

--- The members of `t` that are tables, or nil where `t` may be a table of any kind (`any`, a type variable).
function Tests.table_members(ctx: Ctx, t: Type): {Type}?
  local out: mut {Type} = {}
  for _, m in ipairs(members_of(ctx.store, t)) do
    local kind = Tests.lua_kind(m)
    if kind == "" and m.tag ~= "never" then
      return nil
    elseif kind == "table" then
      out[#out + 1] = m
    end
  end
  return out
end

--- How a run-time test tells that a value of type `value` is the record `r`: `{ "" }` where `r` is the one table `value`
--- may be, the tag field and its strings in `r` where a tag tells the tables apart, the one field `r` alone has where
--- that tells them ([`Tests.presence_field`]), or nil where no test can tell (a table of another kind, `any`, a type
--- variable, a record with type arguments, which no tag tells).
function Tests.record_tag(ctx: Ctx, value: Type, r: Type): {string}?
  if not ((r.tag == "named")) or r.value or #r.args > 0 then
    return nil
  end
  local tables = Tests.table_members(ctx, value)
  if tables == nil then
    return nil
  end
  local found = false
  for _, m in ipairs(tables) do
    found = found or m == r
  end
  if not found then
    return nil
  elseif #tables == 1 then
    return { "" }
  end
  local field = Tests.tag_field(ctx, tables)
  if field == nil then
    local alone = Tests.presence_field(ctx, tables, r)
    return if alone ~= nil then { alone } else nil end
  end
  local values = Tests.tag_values(ctx, r, field)
  if values == nil then
    return nil
  end
  local out: mut {string} = { field }
  for _, v in ipairs(values) do
    out[#out + 1] = v
  end
  return out
end

--- The field that tells the record `r` apart from the other records of `tables` by being there
--- ([`Declarations.presence_field`]). Nil where a member of `tables` is not a record, or `r` has no such field.
function Tests.presence_field(ctx: Ctx, tables: {Type}, r: Named): string?
  local records: mut {Named} = {}
  for _, m in ipairs(tables) do
    if not ((m.tag == "named")) or m.value or m.decl.kind ~= "record" or m.decl.body == nil then
      return nil
    end
    records[#records + 1] = m
  end
  return Declarations.presence_field(ctx.store, ctx.judge, records, r)
end

--- The field that tells the types of `list` apart: one every one declares with an enum, no value of which is in two of
--- them, and the values of the enums.
function Tests.tag_field(ctx: Ctx, list: {Type}): string?, {string}?
  local first = list[1]
  if first == nil or not ((first.tag == "named")) or first.decl.body == nil then
    return nil, nil
  end
  for _, f in ipairs(TableLiterals.fields_of(ctx, first.decl)) do
    local values: mut {string} = {}
    local seen: mut {string: boolean} = {}
    local apart = true
    for _, m in ipairs(list) do
      local v = Tests.tag_values(ctx, m, f.name)
      if v == nil then
        apart = false
        break
      end
      for _, value in ipairs(v) do
        if seen[value] == true then
          apart = false
        end
        seen[value] = true
        values[#values + 1] = value
      end
    end
    if apart and #values > 0 then
      return f.name, values
    end
  end
  return nil, nil
end

--- What a value of type `cur` is where a test says it is a `tested`: the members that are one, the tested type for a
--- member it is more specific than (`any` and an interface become the class tested), and nothing else.
function Tests.keep_is(ctx: Ctx, cur: Type, tested: Type): Type
  if cur.tag == "invalid" or tested.tag == "invalid" then
    return cur
  end
  local store = ctx.store
  local out: mut {Type} = {}
  local tested_members = members_of(store, tested)
  for _, m in ipairs(members_of(store, cur)) do
    if m.tag == "invalid" then
      out[#out + 1] = m
    elseif m.tag == "any" or (m.tag == "var") then
      for _, tm in ipairs(tested_members) do
        out[#out + 1] = tm
      end
    elseif below(ctx, m, tested) then
      out[#out + 1] = m
    else
      for _, tm in ipairs(tested_members) do
        if below(ctx, tm, m) then
          out[#out + 1] = tm
        end
      end
    end
  end
  return store:union(out)
end

--- What a value of type `cur` is where a test says it is no `tested`: the members that are not below it. `any`, an
--- interface and a type variable stay, since none is below a class.
function Tests.drop_is(ctx: Ctx, cur: Type, tested: Type): Type
  if cur.tag == "invalid" or tested.tag == "invalid" then
    return cur
  end
  local store = ctx.store
  local out: mut {Type} = {}
  local strings = Tests.enum_strings(ctx, tested)
  for _, m in ipairs(members_of(store, cur)) do
    local body = if (m.tag == "named") and not m.value and m.decl.kind == "enum" then m.decl.body else nil end
    if body ~= nil and strings ~= nil and not below(ctx, m, tested) then
      -- An enum keeps the strings the tested type does not hold, each as its literal type.
      local dropped: mut {string: boolean} = {}
      for _, v in ipairs(strings) do
        dropped[v] = true
      end
      local kept: mut {Type} = {}
      for _, v in ipairs(body.values) do
        if dropped[v] ~= true then
          kept[#kept + 1] = Types.literal(store, v)
        end
      end
      out[#out + 1] = if #kept == #body.values then m else store:union(kept) end
    elseif m == store.boolean and not below(ctx, m, tested) and below(ctx, store:atom("true"), tested) then
      -- `boolean` is `true | false`: a test of one leaves the other.
      out[#out + 1] = store:atom("false")
    elseif m == store.boolean and not below(ctx, m, tested) and below(ctx, store:atom("false"), tested) then
      out[#out + 1] = store:atom("true")
    elseif m.tag == "invalid" or not below(ctx, m, tested) then
      out[#out + 1] = m
    end
  end
  return store:union(out)
end

--- What a value of type `cur` is where a test says it is nil.
function Tests.nil_of(ctx: Ctx, cur: Type): Type
  if cur.tag == "invalid" then
    return cur
  elseif nilable(cur) or cur.tag == "any" or (cur.tag == "var") then
    return ctx.nil_type
  end
  return ctx.store.never
end

--- What a value of type `cur` is where a test says it is not nil.
function Tests.not_nil_of(ctx: Ctx, cur: Type): Type
  if cur.tag == "invalid" or cur.tag == "any" then
    return cur
  end
  return ctx.store:non_nil(cur)
end

--- The members of `cur` that are of the Lua type `kind` (`type(x) == "string"`), or none of them where `keep` is false.
--- `any` becomes the type the name says, where there is one.
function Tests.by_kind(ctx: Ctx, cur: Type, kind: string, keep: boolean): Type
  local store = ctx.store
  local out: mut {Type} = {}
  for _, m in ipairs(members_of(store, cur)) do
    local k = Tests.lua_kind(m)
    if m.tag == "any" and keep then
      if kind == "string" then
        out[#out + 1] = store.string
      elseif kind == "number" then
        out[#out + 1] = store.number
      elseif kind == "boolean" then
        out[#out + 1] = store.boolean
      elseif kind == "nil" then
        out[#out + 1] = ctx.nil_type
      else
        out[#out + 1] = m
      end
    elseif k == "" then
      out[#out + 1] = m
    elseif (k == kind) == keep then
      out[#out + 1] = m
    end
  end
  return store:union(out)
end

function Tests.counted(ctx: Ctx, f: Flow.State, e: Ast.Node): Place?
  local at = peel(e)
  if not ((at.kind == "Unary") and at.op == "#") then
    return nil
  end
  local p = place_of(ctx, f, at.operand)
  if p ~= nil and ctx.store:non_nil(current(f, p)).tag == "array" then
    return p
  end
  return nil
end

function Tests.know_length(ctx: Ctx, f: Flow.State, p: Place, n: integer): Flow.State
  if ctx.closers > 0 then
    return f
  end
  return Flow.know_length(f, p.key, n, ctx.store.boolean, ctx.store.integer)
end

function Tests.length_edges(ctx: Ctx, f: Flow.State, op: string, left: Ast.Node, right: Ast.Node): Flow.State, Flow.State
  local test = op
  local literal = peel(right)
  local p = Tests.counted(ctx, f, left)
  if p == nil then
    -- `n op #t` is `#t op' n`.
    p = Tests.counted(ctx, f, right)
    literal = peel(left)
    if op == "<" then
      test = ">"
    elseif op == ">" then
      test = "<"
    elseif op == "<=" then
      test = ">="
    elseif op == ">=" then
      test = "<="
    end
  end
  if p == nil or literal.kind ~= "Integer" then
    return f, f
  end
  -- A literal far from what a fact tells is held to the ends, which keeps `n + 1` in range: the least length it gives is
  -- still past what a fact tells, or below zero.
  local n = math.max(-1, math.min(literal.value, 65536))
  local yes, no = 0, 0
  if test == "==" then
    yes = n
    -- A length is not below zero, so `#t ~= 0` is a first element.
    if literal.value == 0 then
      no = 1
    end
  elseif test == ">=" then
    yes = n
  elseif test == ">" then
    yes = n + 1
  elseif test == "<" then
    no = n
  elseif test == "<=" then
    no = n + 1
  end
  return Tests.know_length(ctx, f, p, yes), Tests.know_length(ctx, f, p, no)
end

function Tests.has_element(ctx: Ctx, f: Flow.State, e: Ast.Node): Flow.State
  local at = peel(e)
  if not (at.kind == "Index") or ctx.closers > 0 then
    return f
  end
  local p = place_of(ctx, f, at.object)
  if p == nil then
    return f
  end
  if not (ctx.store:non_nil(current(f, p)).tag == "array") then
    return f
  end
  local key = peel(at.key)
  if (key.kind == "Integer") and key.value >= 1 then
    return Tests.know_length(ctx, f, p, key.value)
  elseif (key.kind == "Unary") and key.op == "#" then
    local same = place_of(ctx, f, key.operand)
    if same ~= nil and same.key == p.key then
      return Tests.know_length(ctx, f, p, 1)
    end
  elseif (key.kind == "Name") then
    local id = key.binding
    if id ~= nil then
      -- Only the read of the same key: the local may hold 0 where an array is not dense.
      return Flow.know_key(f, p.key, id, ctx.store.boolean, ctx.store.integer)
    end
  end
  return f
end

function Tests.dense(ctx: Ctx, element: Type): boolean
  -- TODO: take an array of a type variable as dense once a type argument may be held to exclude nil (a bound, or a
  -- refusal of an optional type argument where `{ ... }` of a `...: T` vararg is made): any caller may give nil now, so a
  -- `{T}` loses the length facts and counted loops a `{integer}` has.
  for _, m in ipairs(members_of(ctx.store, element)) do
    if m.tag == "var" or not Writes.present(m) then
      return false
    end
  end
  return true
end

function Tests.length_proves(ctx: Ctx, object: Ast.Exp, key: Ast.Exp): boolean
  local f = ctx.flow
  if next(f.lens) == nil then
    return false
  end
  local p = place_of(ctx, f, object)
  if p == nil then
    return false
  end
  local at = peel(key)
  if at.kind == "Integer" then
    return Flow.knows_length(f, p.key, at.value)
  elseif (at.kind == "Unary") and at.op == "#" then
    -- The last element is there where the first is.
    local same = place_of(ctx, f, at.operand)
    return same ~= nil and same.key == p.key and Flow.knows_length(f, p.key, 1)
  elseif (at.kind == "Name") then
    local id = at.binding
    return id ~= nil and Flow.knows_key(f, p.key, id)
  end
  return false
end

function Tests.quiet_callee(callee: Ast.Exp?): boolean
  return callee ~= nil and (callee.kind == "Name") and callee.binding == nil and (callee.text == "assert" or callee.text == "type")
end

function Tests.plain(ctx: Ctx, t: Type): boolean
  if t.atom then
    return t.tag ~= "any" and t.tag ~= "invalid"
  end
  -- A recursive alias reaches itself through an array, so a type met twice is not looked at again: it is plain if the rest is.
  local seen: mut {integer: boolean} = {}
  local waiting: mut {Type} = { t }
  while #waiting > 0 do
    local at = assert(waiting[#waiting])
    waiting[#waiting] = nil
    for _, m in ipairs(members_of(ctx.store, at)) do
      if seen[m.id] ~= true then
        seen[m.id] = true
        if (m.tag == "array") then
          waiting[#waiting + 1] = m.element
        elseif (m.tag == "map") then
          waiting[#waiting + 1] = m.key
          waiting[#waiting + 1] = m.value
        elseif (m.tag == "named") then
          if (m.decl.kind ~= "enum" and m.decl.kind ~= "integer_enum") or m.value then
            return false
          end
        elseif not m.atom or m.tag == "any" or m.tag == "invalid" then
          -- A function or a type variable, and any form not listed here, is not trusted.
          return false
        end
      end
    end
  end
  return true
end

function Tests.inert_callee(callee: Ast.Exp?): boolean
  if callee == nil then
    return true
  elseif (callee.kind == "Name") then
    local name = callee.text
    return callee.binding == nil and (name == "tostring" or name == "tonumber" or name == "select" or name == "rawlen")
  elseif (callee.kind == "Field") and (callee.object.kind == "Name") and callee.object.binding == nil then
    local library = callee.object.text
    return library == "string" or library == "math" or library == "utf8" or
      (library == "table" and (callee.name == "concat" or callee.name == "unpack"))
  end
  return false
end

function Tests.has_call(ctx: Ctx, node: Ast.Node): boolean
  local waiting: mut {Ast.Node} = { node }
  local found = false
  local function wait(child: Ast.Node)
    waiting[#waiting + 1] = child
  end
  while #waiting > 0 and not found do
    local at = assert(waiting[#waiting])
    waiting[#waiting] = nil
    if (at.kind == "Call" or at.kind == "MethodCall") and ctx.inert[at.id] ~= true then
      found = true
    elseif (at.kind == "Binary") and ctx.runs[at.id] == true then
      found = true
    elseif at.kind ~= "FunctionLit" then
      -- A function made here runs when it is called, and that call is a call.
      Ast.children(at, wait)
    end
  end
  return found
end

function Tests.closes(ctx: Ctx)
  ctx.closers = ctx.closers + 1
  ctx.flow = Flow.forget_lengths(ctx.flow)
end

function Tests.leaves(ctx: Ctx, closers: integer)
  if ctx.closers ~= closers then
    ctx.closers = closers
    ctx.flow = Flow.forget_lengths(ctx.flow)
  end
end

--- What a value of type `cur` is where a test says it is the string `lit` (`keep`) or is not: an enum that holds `lit`
--- splits into the literal type of `lit` and the literal types of its other values, and `string` holds `lit` and the
--- rest. A member that cannot be a string stays where the test fails, and a member the test says nothing of stays in both.
function Tests.by_literal(ctx: Ctx, cur: Type, lit: string, keep: boolean): Type
  if cur.tag == "invalid" then
    return cur
  end
  local store = ctx.store
  local out: mut {Type} = {}
  for _, m in ipairs(members_of(store, cur)) do
    local body = if (m.tag == "named") and not m.value and m.decl.kind == "enum" then m.decl.body else nil end
    if body ~= nil then
      local holds = false
      for _, v in ipairs(body.values) do
        holds = holds or v == lit
      end
      if keep and holds then
        out[#out + 1] = Types.literal(store, lit)
      elseif not keep and not holds then
        out[#out + 1] = m
      elseif not keep then
        for _, v in ipairs(body.values) do
          if v ~= lit then
            out[#out + 1] = Types.literal(store, v)
          end
        end
      end
    elseif m.tag == "string" then
      out[#out + 1] = if keep then Types.literal(store, lit) else m end
    elseif m.atom == true and m.tag ~= "any" and m.tag ~= "invalid" then
      -- A number, a boolean or nil is no string.
      if not keep then
        out[#out + 1] = m
      end
    elseif (m.tag == "array") or (m.tag == "map") or (m.tag == "fn") or ((m.tag == "named") and m.decl.kind ~= "userdata") then
      if not keep then
        out[#out + 1] = m
      end
    else
      out[#out + 1] = m
    end
  end
  return store:union(out)
end

return Tests
