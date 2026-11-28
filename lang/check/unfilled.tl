--- Empty tables that take their type from the first thing stored in them (`local rows = {}`, then `rows[#rows + 1] = row`).
---
--- A local made from an empty literal that no type is written for is unfilled until the walk reaches the first statement
--- that stores into it: an index write (`rows[#rows + 1] = row`, `seen[name] = true`), or `table.insert(rows, row)`. That
--- store gives the local the array or map of what it stores, as a declaration `local rows: mut {T} = {}` would. A read of
--- the local before any store, with no array or map expected of it, is refused: nothing says what it holds yet.

local Ast = require("lang.ast")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local TableLiterals = require("lang.check.table_literals")
local type Type = Types.Type
local type Ctx = Context.Ctx
local nilable = Context.nilable
local peel = Context.peel
local quoted = Context.quoted
local report = Naming.report
local show = Context.show

local record Unfilled
end

local FIX = "declare the type: `local name: mut {T} = {}` (or `mut {K: V}`), or store a value first"

--- Whether the `i`th binding of `s`, a statement that declares locals with no types written, makes an unfilled table: its
--- value is an empty literal (`local seen = {}`, or `local total, seen = 0, {}`). Returns the literal.
function Unfilled.candidate(ctx: Ctx, s: Ast.Local, i: integer): Ast.Table?
  local b = s.bindings[i]
  local given = s.values[i]
  if #s.types > 0 or b == nil or given == nil or b.attr ~= nil or ctx.lenient > 0 then
    return nil
  end
  local value = peel(given)
  if value.kind ~= "Table" or TableLiterals.shape_of(value.items) ~= "empty" then
    return nil
  end
  return value
end

--- Whether `e` is the literal of an unfilled local, which takes no type of its own.
function Unfilled.holds_literal(ctx: Ctx, e: Ast.Table): boolean
  return ctx.unfilled_n > 0 and ctx.unfilled_literals[e.id] == true
end

--- Makes the local `id` unfilled, from the literal `lit`.
function Unfilled.declare(ctx: Ctx, id: integer, lit: Ast.Table)
  if ctx.unfilled[id] == nil then
    ctx.unfilled_n = ctx.unfilled_n + 1
  end
  ctx.unfilled[id] = lit
  ctx.unfilled_literals[lit.id] = true
  ctx.vars[id] = ctx.invalid
end

--- Gives the unfilled local `id` the type `t` (invalid where its first use is refused).
local function fill(ctx: Ctx, id: integer, t: Type)
  local lit = ctx.unfilled[id]
  if lit == nil then
    return
  end
  ctx.unfilled[id] = nil
  ctx.unfilled_literals[lit.id] = nil
  ctx.unfilled_n = ctx.unfilled_n - 1
  ctx.vars[id] = t
  if ctx.typed then
    ctx.types[lit.id] = t
  end
end

--- Whether `e` names an unfilled local: its id.
local function unfilled_name(ctx: Ctx, e: Ast.Exp): integer?
  if ctx.unfilled_n == 0 then
    return nil
  end
  local name = peel(e)
  local id = if name.kind == "Name" then name.binding else nil end
  if id ~= nil and ctx.unfilled[id] ~= nil then
    return id
  end
  return nil
end

--- Whether `t` holds `never` as the element of a collection: only the type held while a first store is checked does.
local function holds_never(t: Type, depth: integer): boolean
  if depth > 6 then
    return false
  end
  if t.tag == "array" then
    return t.element.tag == "never" or holds_never(t.element, depth + 1)
  elseif t.tag == "map" then
    return t.value.tag == "never" or holds_never(t.value, depth + 1) or holds_never(t.key, depth + 1)
  elseif t.tag == "union" then
    for _, m in ipairs(t.members) do
      if holds_never(m, depth + 1) then
        return true
      end
    end
  end
  return false
end

--- The type of the first value stored, as the element of the table: a literal type is its wide type.
local function stored(ctx: Ctx, id: integer, value: Type): Type?
  local lit = assert(ctx.unfilled[id], "the local is unfilled")
  if value.tag == "invalid" then
    return nil
  end
  if holds_never(value, 0) then
    report(ctx, "literal_needs_type", lit, "the first value stored in this table holds the table itself, which has no type yet",
      FIX)
    return nil
  end
  if nilable(value) or value.tag == "never" then
    report(ctx, "literal_needs_type", lit, "the first value stored in this table is " .. Context.tq(ctx, value) ..
        ", which says no type for what it holds", FIX, { show(ctx, value) })
    return nil
  end
  return TableLiterals.widened(ctx, value, nil)
end

--- The first store of the statement `s` (`a[k] = v`, one target and one value) into an unfilled local: the local is given
--- its type, from the value `value` (checked by the caller before, with no type expected). Returns whether `s` stores.
function Unfilled.store_target(ctx: Ctx, s: Ast.Assign): Ast.Index?, integer?
  if ctx.unfilled_n == 0 or #s.targets ~= 1 or #s.values ~= 1 then
    return nil, nil
  end
  local target = s.targets[1]
  if target.kind ~= "Index" then
    return nil, nil
  end
  local id = unfilled_name(ctx, target.object)
  if id == nil then
    return nil, nil
  end
  return target, id
end

--- Fills the local `id` from the store `target = value`: an array where `target` appends or its key is a whole number, a
--- map of the key's type otherwise.
function Unfilled.fill_store(ctx: Ctx, id: integer, target: Ast.Index, value: Type, appends: boolean,
                             key: (function(): Type)?)
  if ctx.unfilled[id] == nil then
    return
  end
  local element = stored(ctx, id, value)
  if element == nil then
    fill(ctx, id, ctx.invalid)
    return
  end
  local store = ctx.store
  if appends then
    fill(ctx, id, store:array(element, true))
    return
  end
  local k = if key ~= nil then key() else ctx.invalid end
  if k.tag ~= "invalid" and nilable(k) then
    report(ctx, "literal_needs_type", assert(ctx.unfilled[id], "unfilled"), "the key of the first store in this table is " ..
        Context.tq(ctx, k) .. ", which may be nil and is no key of a map", FIX, { show(ctx, k) })
  end
  if k.tag == "invalid" or nilable(k) then
    fill(ctx, id, ctx.invalid)
    return
  end
  if Context.below(ctx, k, store.integer) then
    fill(ctx, id, store:array(element, true))
  elseif Types.keys_a_map(k) then
    fill(ctx, id, store:map(TableLiterals.widened(ctx, k, nil), element, true))
  else
    report(ctx, "literal_needs_type", assert(ctx.unfilled[id], "unfilled"), "the key of the first store in this table is " ..
        Context.tq(ctx, k) .. ", which is no key of a map", FIX, { show(ctx, k) })
    fill(ctx, id, ctx.invalid)
  end
  local _ = target
end

--- The type the unfilled table holds while the value of its first store is checked: an array or a map of the key's type,
--- with `never` as the element, which `or` gives up for the other side. Nil where the key says no array or map.
function Unfilled.provisional(ctx: Ctx, appends: boolean, key: function(): Type): Type?
  local store = ctx.store
  if appends then
    return store:array(store.never, true)
  end
  local k = key()
  if k.tag == "invalid" or nilable(k) then
    return nil
  end
  if Context.below(ctx, k, store.integer) then
    return store:array(store.never, true)
  elseif Types.keys_a_map(k) then
    return store:map(TableLiterals.widened(ctx, k, nil), store.never, true)
  end
  return nil
end

--- A read `at` of one element of the name `e` (`seen[name]`), only asked whether it is there, where `e` is an unfilled local: the
--- table is held as an array or map of the key, with `never` as its element, so the read is `never?` and the table
--- stays unfilled for the store that follows. Nil where `e` is no unfilled local or the key says no array or map.
function Unfilled.held_by_key(ctx: Ctx, e: Ast.Exp, at: Ast.Exp, key: function(): Type): Type?
  local id = unfilled_name(ctx, e)
  if id == nil or e.kind ~= "Name" or ctx.probes[at.id] ~= true then
    return nil
  end
  return Unfilled.provisional(ctx, false, key)
end

--- `table.insert(list, value)` where `list` is an unfilled local: the local is an array of the value's type.
function Unfilled.fill_insert(ctx: Ctx, args: {Ast.Exp}, value: Type)
  local list = args[1]
  local id = if list ~= nil then unfilled_name(ctx, list) else nil end
  if id == nil then
    return
  end
  local element = stored(ctx, id, value)
  fill(ctx, id, if element ~= nil then ctx.store:array(element, true) else ctx.invalid end)
end

--- Whether `table.insert(list, value)` is the call: its first argument names an unfilled local.
function Unfilled.inserts(ctx: Ctx, callee: string, args: {Ast.Exp}): boolean
  return ctx.unfilled_n > 0 and callee == "table.insert" and #args == 2 and unfilled_name(ctx, assert(args[1])) ~= nil
end

--- A read of the name `e`: where `e` is an unfilled local, it is given the array or map `expected` where that is a
--- `mut` collection, and refused otherwise.
function Unfilled.read(ctx: Ctx, e: Ast.Name, expected: Type?)
  local id = e.binding
  if id == nil or ctx.unfilled[id] == nil then
    return
  end
  local want = if expected ~= nil then ctx.store:non_nil(expected) else nil end
  if want ~= nil and (want.tag == "array" or want.tag == "map") and want.mut and want.open == 0 then
    fill(ctx, id, want)
    return
  end
  -- Reported where the literal is, as it was before: a held finding stays held where it occurs.
  report(ctx, "literal_needs_type", assert(ctx.unfilled[id], "unfilled"), "this literal has no items and no type to make it from, and " ..
      quoted(e.text) .. " is read before anything is stored in it", FIX)
  fill(ctx, id, ctx.invalid)
end

--- At the end of the module: a table nothing was stored in nor read from is left as it is, like any other local the
--- program does not read.
function Unfilled.finish(ctx: Ctx)
  if ctx.unfilled_n == 0 then
    return
  end
  for id in pairs(ctx.unfilled) do
    fill(ctx, id, ctx.invalid)
  end
end

return Unfilled
