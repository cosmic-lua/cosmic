--- The checks of a table literal against the type it is written for, and the type it has where none is written.

local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local LoadOrder = require("lang.load_order")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local Refusals = require("lang.check.refusals")
local Names = require("lang.check.names")
local Lookup = require("lang.check.members")
local ValueLists = require("lang.check.values")
local type Type = Types.Type
local type Named = Types.Named
local type Union = Types.Union
local type Decl = Types.Decl
local type Ctx = Context.Ctx
local type Member = Context.Member
local below = Context.below
local is_enum = Context.is_enum
local listed = Context.listed
local members_of = Context.members_of
local nearest = Context.nearest
local nilable = Context.nilable
local peel = Context.peel
local quoted = Context.quoted
local report = Naming.report
local show = Context.show
local subject = Context.subject
local tq = Context.tq
local type Values = ValueLists.Values
local expect = Refusals.expect
local expect_argument = Refusals.expect_argument
local first_value = ValueLists.first_value
local members_index = Lookup.members_index
local names_of = Lookup.names_of
local nil_fix = Refusals.nil_fix
local put_in = Lookup.put_in
local string_value = Names.string_value
local values_of = ValueLists.values_of

local record TableLiterals
end

--- The record inferred for a literal of named items with the fields `fields`: one record for each set of names, types
--- and `mut`, named `__literal` and a number and shown by its fields ([`Types.inferred_record`]).
function TableLiterals.inferred_of(ctx: Ctx, list: {Types.Field}): Type
  local store = ctx.store
  local fields: mut {Types.Field} = {}
  for _, f in ipairs(list) do
    fields[#fields + 1] = f
  end
  table.sort(fields, function(a: Types.Field, b: Types.Field): boolean return a.name < b.name end)
  local function key_of(given: {Types.Field}): string
    local out: mut {string} = {}
    for _, f in ipairs(given) do
      out[#out + 1] = (if f.mut == true then "mut " else "" end) .. f.name .. ":" .. tostring(f.type.id)
    end
    return table.concat(out, ",")
  end
  local key = key_of(fields)
  local decl = ctx.inferred[key]
  if decl == nil then
    -- A record of the name an earlier check of the module made is this one where its fields are.
    local count = 1
    local found = store:find(ctx.input.module, "__literal1")
    while found ~= nil do
      local body = found.body
      if body ~= nil and found.inferred == true and key_of(body.fields) == key then
        break
      end
      count = count + 1
      found = store:find(ctx.input.module, "__literal" .. tostring(count))
    end
    if found ~= nil then
      decl = found
    else
      decl = store:declare("record", ctx.input.module, { "__literal" .. tostring(count) }, 0)
      decl.inferred = true
      store:define(decl, { tparams = {}, supers = {}, fields = fields, methods = {}, values = {} })
    end
    ctx.inferred[key] = decl
  end
  return store:named(decl, {}, false)
end

--- The record two or more inferred records `list` join to: each field of any of them, of the join of its types, and
--- nilable where one of them lacks it; `mut` where each has it `mut` of one type. Nil where two types of a field have
--- no join.
function TableLiterals.inferred_join(ctx: Ctx, list: {Type}, join_of: function({Type}): Type?): Type?
  local names: mut {string} = {}
  local types: mut {string: mut {Type}} = {}
  local muts: mut {string: integer} = {}
  for _, t in ipairs(list) do
    if not ((t.tag == "named") and not t.value and Types.inferred_record(t.decl)) then
      return nil
    end
    for _, f in ipairs(assert(t.decl.body, "an inferred record is defined where it is made").fields) do
      local held: mut {Type} = types[f.name] or {}
      if types[f.name] == nil then
        types[f.name] = held
        names[#names + 1] = f.name
      end
      held[#held + 1] = f.type
      if f.mut == true then
        muts[f.name] = (muts[f.name] or 0) + 1
      end
    end
  end
  local fields: mut {Types.Field} = {}
  for _, name in ipairs(names) do
    local held = assert(types[name])
    local joined = join_of(held)
    if joined == nil then
      return nil
    end
    local every = #held == #list
    if not every then
      joined = ctx.store:optional(joined)
    end
    local same = true
    for _, t in ipairs(held) do
      same = same and t == joined
    end
    fields[#fields + 1] = { name = name, type = joined, mut = every and same and muts[name] == #list, omittable = false }
  end
  return TableLiterals.inferred_of(ctx, fields)
end

--- The type every type of `list` is below, or nil where there is none. A `nil` in the list makes the result
--- optional; `never` is ignored; an empty list is `never`.
function TableLiterals.join(ctx: Ctx, list: {Type}): Type?
  local store = ctx.store
  local best: Type? = nil
  local saw_nil = false
  for _, t in ipairs(list) do
    if t.tag == "nil" then
      saw_nil = true
    elseif t.tag ~= "never" then
      local held = best
      if held == nil or t.tag == "invalid" then
        best = t
      elseif t ~= held and held.tag ~= "invalid" then
        if below(ctx, held, t) then
          best = t
        end
      end
    end
  end
  if best == nil then
    return saw_nil and ctx.nil_type or store.never -- checked: and_ternary
  end
  for _, t in ipairs(list) do
    if t.tag ~= "nil" and t.tag ~= "never" and not below(ctx, t, best) then
      -- Records inferred for literals of named items join to one with the fields of each.
      local records: mut {Type} = {}
      for _, r in ipairs(list) do
        if r.tag ~= "nil" and r.tag ~= "never" then
          records[#records + 1] = r
        end
      end
      local merged = TableLiterals.inferred_join(ctx, records, function(types: {Type}): Type?
        return TableLiterals.join(ctx, types)
      end)
      if merged == nil then
        return nil
      end
      return if saw_nil then store:optional(merged) else merged end
    end
  end
  return saw_nil and store:optional(best) or best -- checked: and_ternary
end
local join = TableLiterals.join

--- The distinct types of `types` (the first four), quoted and in order, for a message.
function TableLiterals.type_names(ctx: Ctx, types: {Type}): {string}
  local out: mut {string} = {}
  local seen: mut {integer: boolean} = {}
  for _, t in ipairs(types) do
    if seen[t.id] ~= true and #out < 4 then
      seen[t.id] = true
      out[#out + 1] = tq(ctx, t)
    end
  end
  table.sort(out)
  return out
end
local type_names = TableLiterals.type_names

--- Checks the values of the items of a literal that has no shape to be checked against, so that what is in them
--- is checked.
function TableLiterals.items_unshaped(ctx: Ctx, items: {Ast.Item})
  ctx.lenient = ctx.lenient + 1
  for _, item in ipairs(items) do
    if (item.kind == "Keyed") then
      local _ = ctx.walk.expr(ctx, item.key, nil)
      local _ = ctx.walk.expr(ctx, item.value, nil)
    elseif (item.kind == "Named") then
      local _ = ctx.walk.expr(ctx, item.value, nil)
    elseif (item.kind == "Positional") or (item.kind == "Spread") then
      local _ = ctx.walk.expr(ctx, item.value, nil)
    end
  end
  ctx.lenient = ctx.lenient - 1
end

--- The kinds of item a literal holds: "positional", "named", "keyed", "mixed" or "empty".
function TableLiterals.shape_of(items: {Ast.Item}): string
  local shape = "empty"
  for _, item in ipairs(items) do
    local kind = if (item.kind == "Positional") then "positional" elseif (item.kind == "Named") then "named" else "keyed" end
    if shape == "empty" then
      shape = kind
    elseif shape ~= kind then
      return "mixed"
    end
  end
  return shape
end

--- The values of the positional items of `items`.
function TableLiterals.positional_values(items: {Ast.Item}): {Ast.Exp}
  local out: mut {Ast.Exp} = {}
  for _, item in ipairs(items) do
    if (item.kind == "Positional") then
      out[#out + 1] = item.value
    end
  end
  return out
end

--- Whether a map is keyed by `k`: the key types of [`lang.declarations`].
function TableLiterals.valid_key(k: Type): boolean
  local tag = k.tag
  return tag == "integer" or tag == "string" or tag == "boolean" or k.tag == "invalid" or
    ((k.tag == "named") and k.decl.kind ~= "enum" or is_enum(k))
end

--- The fix for an array literal whose elements `all` have no common type. An array of the first element's type
--- cannot hold the others, so the fix is an array of their union, or, where the values differ by position (a row
--- such as `{ "name", 1.0 }`), a record whose fields name the positions.
function TableLiterals.differ_fix(ctx: Ctx, all: {Type}): string
  local names: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, t in ipairs(all) do
    local name = show(ctx, t)
    if seen[name] ~= true then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  local row = "for values that differ by position (a row), declare a record and write each row by name " ..
    "(`{ name = ..., weight = ... }`)"
  local tables = false
  for _, name in ipairs(names) do
    tables = tables or name:sub(1, 1) == "{" or name:sub(1, 4) == "mut "
  end
  -- A union of tables is one a literal cannot pick a member of (literal_ambiguous), so tables get the record alone.
  if #names > 4 or tables then
    return row .. ", or make the elements one type"
  end
  return "type the literal with their union: `local name: {" .. table.concat(names, " | ") .. "} = ...`; " .. row
end

--- A literal with no type expected: an array or a map of the join of its items.
--- `t` with each string literal type among its members made the enum of `from` that holds its string, or `string`:
--- what a place that a program may write another string to holds, where a test had narrowed the value it starts with
--- (`local cur = s` after `s == "x"`). `from` is the declared type of the place the value was read from.
function TableLiterals.widened(ctx: Ctx, t: Type, from?: Type): Type
  local members = members_of(ctx.store, t)
  local changed = false
  local out: mut {Type} = {}
  local enums: mut {Types.Named} = {}
  if from ~= nil then
    for _, m in ipairs(members_of(ctx.store, from)) do
      if (m.tag == "named") and not m.value and m.decl.kind == "enum" and Types.literal_value(m) == nil then
        enums[#enums + 1] = m
      end
    end
  end
  for _, m in ipairs(members) do
    local value = Types.literal_value(m)
    if value ~= nil then
      local wide = ctx.store.string
      for _, e in ipairs(enums) do
        local body = e.decl.body
        if body ~= nil then
          for _, v in ipairs(body.values) do
            if v == value then
              wide = e
            end
          end
        end
      end
      out[#out + 1] = wide
      changed = true
    else
      out[#out + 1] = m
    end
  end
  return if changed then ctx.store:union(out) else t end
end

function TableLiterals.literal_inferred(ctx: Ctx, e: Ast.Table): Type
  local store = ctx.store
  local items = e.items
  local shape = TableLiterals.shape_of(items)
  if shape == "empty" then
    if ctx.lenient > 0 then
      return ctx.invalid
    end
    report(ctx, "literal_needs_type", e, "this literal has no items and no type to make it from",
      "declare the type: `local name: mut {T} = {}` (or `mut {K: V}`)")
    return ctx.invalid
  elseif shape == "mixed" then
    report(ctx, "literal_shape", e, "this literal mixes positional, named and keyed items, which no array or map holds",
      "write one kind of item, or declare a record and write its fields by name")
    TableLiterals.items_unshaped(ctx, items)
    return ctx.invalid
  end
  if shape == "positional" then
    local types = values_of(ctx, TableLiterals.positional_values(items), nil, nil)
    local all = types.types
    local tail = types.tail
    if tail ~= nil then
      all[#all + 1] = tail
    end
    local several, last = types.lists, types.last
    if several ~= nil and last ~= nil then
      local _ = first_value(ctx, last, several)
      return ctx.invalid
    end
    local element = join(ctx, all)
    if element == nil then
      report(ctx, "arms_differ", e, "the elements of this literal have no common type: " .. listed(type_names(ctx, all)),
        TableLiterals.differ_fix(ctx, all))
      return ctx.invalid
    end
    if nilable(element) then
      report(ctx, "array_of_optional", e, "an element of this literal may be nil, and an array is dense",
        "use a map `{integer: T}` for sparse data, or keep the missing element out", { show(ctx, element) })
      return ctx.invalid
    end
    return store:array(TableLiterals.widened(ctx, element), true)
  end
  local keys: mut {Type} = {}
  local values: mut {Type} = {}
  for _, item in ipairs(items) do
    if (item.kind == "Named") then
      keys[#keys + 1] = store.string
      values[#values + 1] = TableLiterals.widened(ctx, ctx.walk.expr(ctx, item.value, nil))
    elseif (item.kind == "Keyed") then
      keys[#keys + 1] = TableLiterals.widened(ctx, ctx.walk.expr(ctx, item.key, nil))
      values[#values + 1] = TableLiterals.widened(ctx, ctx.walk.expr(ctx, item.value, nil))
    end
  end
  if shape == "named" then
    -- Named items are the fields of a record the literal makes, inferred from their values.
    return TableLiterals.inferred(ctx, e, values)
  end
  local key = join(ctx, keys)
  local value = join(ctx, values)
  if key == nil or value == nil then
    report(ctx, "arms_differ", e, "the " .. (if key == nil then "keys" else "values" end) .. " of this literal have no common type",
      "declare a record for the fields (`record R ... end`) and write the literal against it, or make the values one type")
    return ctx.invalid
  end
  if key.tag == "number" then
    report(ctx, "float_key", e, "a key of this literal is a `number`, and a map is keyed by `integer`",
      "key by `integer`, and convert a float with `math.tointeger(n)` or `math.floor(n)`")
    return ctx.invalid
  end
  if not TableLiterals.valid_key(key) then
    report(ctx, "literal_shape", e, "the keys of this literal are " .. tq(ctx, key) .. ", which no map is keyed by",
      "key by `integer`, `string`, `boolean`, an enum, or a record, class, interface or userdata")
    return ctx.invalid
  end
  if nilable(value) then
    report(ctx, "array_of_optional", e, "a value of this literal may be nil, and `m[k] = nil` deletes the key",
      "keep the missing value out of the literal", { show(ctx, value) })
    return ctx.invalid
  end
  return store:map(key, value, true)
end

--- The fix for a field `name` that the record `t` inferred for a literal lacks: give it in the literal, or declare a type.
function TableLiterals.declare_fix(ctx: Ctx, t: Type, name: string): string
  return "give " .. quoted(name) .. " in the literal (`" .. name .. " = ...`), or declare a record or a map " ..
    "(`{string: T}`) for the value and write the literal against it, as " .. tq(ctx, t) .. " has only the fields the " ..
    "literal names"
end

--- Reports the write of the field `name` of `base`, a record inferred for a literal, that the program does not write
--- through the local the literal is given to, which alone makes a field `mut`.
function TableLiterals.fixed(ctx: Ctx, target: Ast.Node, base: Type, name: string)
  report(ctx, "field_fixed", target, "the field " .. quoted(name) .. " of " .. tq(ctx, base) .. ", a record inferred for a " ..
      "literal, is fixed: a field is `mut` where the program writes it through the local the literal is given to",
    "write it through that local (`local p = { ... }` then `p." .. name .. " = v`), or declare a record with `mut " ..
      name .. "` and write the literal against it", { show(ctx, base) })
end

--- The names of the fields the program writes of each table literal it gives a local, by the id of the literal's
--- node: `p.x = v` (or `p["x"] = v`) writes `x` of the literal of `local p = { ... }`, and `p.at.x = v` writes `x` of
--- the literal given as `at` in it. A field of a record inferred from a literal is `mut` where it is written so.
function TableLiterals.writes(ctx: Ctx): {integer: {string: boolean}}
  local held = ctx.literal_writes
  if held ~= nil then
    return held
  end
  -- The paths written through each local, `at.x` for `p.at.x = v`, by the id of the local's binding.
  local paths: mut {integer: mut {string: boolean}} = {}
  local bound: mut {integer: Ast.Table} = {}
  local function path_of(target: Ast.Exp): integer, string
    local names: mut {string} = {}
    local at = peel(target)
    while true do
      if (at.kind == "Field") then
        table.insert(names, 1, at.name)
        at = peel(at.object)
      elseif (at.kind == "Index") and (peel(at.key).kind == "String") then
        local key = peel(at.key)
        table.insert(names, 1, if (key.kind == "String") then key.value else "" end)
        at = peel(at.object)
      else
        break
      end
    end
    local id = if (at.kind == "Name") then at.binding else nil end
    if id ~= nil and #names > 0 then
      return id, table.concat(names, ".")
    end
    return 0, ""
  end
  local waiting: mut {Ast.Node} = { ctx.input.chunk }
  while #waiting > 0 do
    local node = assert(waiting[#waiting])
    waiting[#waiting] = nil
    if (node.kind == "Local") then
      for i, binding in ipairs(node.bindings) do
        local value = node.values[i]
        if value ~= nil and (peel(value).kind == "Table") then
          local literal = peel(value)
          if (literal.kind == "Table") then
            bound[binding.id] = literal
          end
        end
      end
    elseif (node.kind == "Assign") then
      for _, target in ipairs(node.targets) do
        local id, path = path_of(target)
        if id ~= 0 then
          local set: mut {string: boolean} = paths[id] or {}
          paths[id] = set
          set[path] = true
        end
      end
    end
    Ast.children(node, function(child: Ast.Node)
      waiting[#waiting + 1] = child
    end)
  end
  local made: mut {integer: {string: boolean}} = {}
  local function mark(literal: Ast.Table, written: {string: boolean}, prefix: string)
    local names: mut {string: boolean} = {}
    for _, item in ipairs(literal.items) do
      if (item.kind == "Named") then
        local path = prefix .. item.name
        if written[path] == true then
          names[item.name] = true
        end
        local inner = peel(item.value)
        if (inner.kind == "Table") then
          mark(inner, written, path .. ".")
        end
      end
    end
    made[literal.id] = names
  end
  for id, literal in pairs(bound) do
    mark(literal, paths[id] or {}, "")
  end
  ctx.literal_writes = made
  return made
end

--- The record a literal of named items `e` makes, its values of the types `values`: a field for each item, of the
--- type of its value, `mut` where the program writes it ([`TableLiterals.writes`]). Two literals with fields of the
--- same names, types and `mut` make one record, named `__literal` and a number and shown by its fields (`{ x: integer, y: integer }`), so that values
--- made at two places join.
function TableLiterals.inferred(ctx: Ctx, e: Ast.Table, values: {Type}): Type
  local written = TableLiterals.writes(ctx)[e.id] or {}
  local fields: mut {Types.Field} = {}
  local seen: mut {string: boolean} = {}
  local failed = false
  for i, item in ipairs(e.items) do
    local t = values[i]
    if (item.kind == "Named") and t ~= nil then
      if seen[item.name] == true then
        -- `literal_repeated` reports the second; the record has the first.
        failed = failed
      elseif t.tag == "invalid" then
        failed = true
      elseif t.tag == "nil" or t.tag == "never" then
        report(ctx, "literal_needs_type", item, "the field " .. quoted(item.name) .. " of this literal is " .. tq(ctx, t) ..
            ", which says no type for it",
          "declare a record with the field (`" .. item.name .. "?: T`) and write the literal against it")
        failed = true
      elseif t.open > 0 then
        report(ctx, "literal_needs_type", item, "the field " .. quoted(item.name) .. " of this literal is " .. tq(ctx, t) ..
            ", a type parameter, which a record inferred from a literal cannot hold",
          "declare a generic record (`record R<T> ... end`) or a map type, and write the literal against it")
        failed = true
      else
        seen[item.name] = true
        fields[#fields + 1] = { name = item.name, type = t, mut = written[item.name] == true, omittable = false }
      end
    end
  end
  if failed then
    return ctx.invalid
  end
  return TableLiterals.inferred_of(ctx, fields)
end

--- An item of the wrong shape for what the literal is checked against.
function TableLiterals.wrong_shape(ctx: Ctx, item: Ast.Node, got: string, want: Type, fix: string)
  report(ctx, "literal_shape", item, "this " .. got .. " item cannot be in a literal of " .. tq(ctx, want), fix,
    { show(ctx, want) })
end

--- Checks the values `vals` of the positional items `exps` against `element`: each, the `T...` a last item ends in,
--- and the lists of a last item that returns several (which are no values).
function TableLiterals.check_elements(ctx: Ctx, exps: {Ast.Exp}, vals: Values, element: Type, of: string)
  for i, t in ipairs(vals.types) do
    local _ = expect(ctx, exps[math.min(i, #exps)], t, element, " as an element of " .. of) -- checked: index_may_be_nil
  end
  local tail, several, last = vals.tail, vals.lists, vals.last
  if tail ~= nil and tail.tag ~= "invalid" then
    local _ = expect(ctx, exps[#exps], tail, element, " as an element of " .. of) -- checked: index_may_be_nil
  end
  if several ~= nil and last ~= nil then
    local _ = first_value(ctx, last, several)
  end
end

--- A literal checked against an array type.
function TableLiterals.literal_array(ctx: Ctx, e: Ast.Table, want: Types.Array): Type
  local reported = false
  for _, item in ipairs(e.items) do
    if not ((item.kind == "Positional")) and not reported then
      reported = true
      TableLiterals.wrong_shape(ctx, item, if (item.kind == "Named") then "named" else "keyed" end, want,
        "write the elements by position, or declare a record for the named fields")
    end
  end
  if reported then
    TableLiterals.items_unshaped(ctx, e.items)
    return ctx.invalid
  end
  local exps = TableLiterals.positional_values(e.items)
  TableLiterals.check_elements(ctx, exps, values_of(ctx, exps, nil, want.element), want.element, tq(ctx, want))
  return ctx.store:array(want.element, true)
end

--- A literal checked against a map type.
function TableLiterals.literal_map(ctx: Ctx, e: Ast.Table, want: Types.Map): Type
  local store = ctx.store
  for _, item in ipairs(e.items) do
    if (item.kind == "Positional") then
      TableLiterals.wrong_shape(ctx, item, "positional", want, "write `[key] = value` or `name = value` items")
      TableLiterals.items_unshaped(ctx, e.items)
      return ctx.invalid
    elseif (item.kind == "Named") then
      local k = string_value(ctx, item, item.name, want.key)
      local _ = expect(ctx, item, k, want.key, " as a key of " .. tq(ctx, want))
      local v = ctx.walk.expr(ctx, item.value, want.value)
      local _ = expect(ctx, item.value, v, want.value, " as a value of " .. tq(ctx, want))
    elseif (item.kind == "Keyed") then
      local k = ctx.walk.expr(ctx, item.key, want.key)
      local _ = expect(ctx, item.key, k, want.key, " as a key of " .. tq(ctx, want))
      local v = ctx.walk.expr(ctx, item.value, want.value)
      local _ = expect(ctx, item.value, v, want.value, " as a value of " .. tq(ctx, want))
    end
  end
  return store:map(want.key, want.value, true)
end

--- The field of `n` called `name`, not a method.
function TableLiterals.plain_field(ctx: Ctx, n: Named, name: string): Member?
  local index = members_index(ctx, n.decl, n.value)
  local list = index ~= nil and index.by_name[name] or nil -- checked: and_ternary
  if list ~= nil and not list[1].method then
    return list[1]
  end
  return nil
end

--- The field a literal item names: `name = v`, or `["name"] = v`.
function TableLiterals.item_name(item: Ast.Item): string?
  if (item.kind == "Named") then
    return item.name
  elseif (item.kind == "Keyed") then
    local key = peel(item.key)
    if (key.kind == "String") then
      return key.value
    end
  end
  return nil
end

--- Why the table of the class `decl` is out of reach of the module being checked, or "" where it is in reach: the
--- class is one of this module's (its module is this one, or a module of a declaration in a function's body, which is
--- this one with `@` and the node's id after it, [`lang.declarations`]), and is no member of another type, which has
--- no table of its own at run time.
function TableLiterals.out_of_reach(ctx: Ctx, decl: Decl): string
  local body = decl.body
  if body ~= nil and body.schema ~= nil then
    return "a `local schema`, whose handles have the metatable of `cosmic.sqlite`'s Handle and are made by " ..
      "`Sqlite.open` and `Sqlite.memory` alone"
  elseif decl.module:gsub("@.*$", "") ~= ctx.input.module then
    return "a class of the module " .. quoted(decl.module) .. ", whose metatable only that module reaches"
  elseif decl.module:find("@", 1, true) ~= nil then
    return "a class declared in a block, whose table is made again each time the block runs, so values of one run " ..
      "are no values of the next"
  elseif ctx.declared[decl] ~= true then
    return "a class declared further down the module, whose table is not made yet where this stands"
  elseif #decl.names > 1 then
    return "a class declared inside " .. quoted(table.concat(decl.names, ".", 1, #decl.names - 1)) ..
      ", which has no table of its own at run time"
  end
  return ""
end

--- The fix for a class out of reach: made, or tested, by a function of the class in the module that has its table.
function TableLiterals.reach_fix(ctx: Ctx, decl: Decl, function_name: string): string
  local body = decl.body
  if body ~= nil and body.schema ~= nil then
    return "open the database with `Sqlite.open(path, { schema = " .. decl.name .. " })` or `Sqlite.memory`, which give a " ..
      decl.name .. ", and keep the type where the handle goes"
  elseif decl.module == ctx.input.module and ctx.declared[decl] ~= true and #decl.names == 1 then
    return "move the declaration of " .. quoted(Types.decl_name(decl)) .. " above this, or make the value with a function of the " ..
      "class declared after it"
  elseif decl.module:find("@", 1, true) ~= nil and decl.module:gsub("@.*$", "") == ctx.input.module then
    return "declare " .. quoted(Types.decl_name(decl)) .. " at the top level of the module, as a statement of it"
  elseif #decl.names > 1 and decl.module == ctx.input.module then
    return "declare " .. quoted(Types.decl_name(decl)) .. " beside the type around it, as a statement of the module"
  end
  return function_name
end

--- The fields of a value of `decl`: those it declares, then those it has from the interfaces it lists
--- ([`Declarations.inherited`]).
function TableLiterals.fields_of(ctx: Ctx, decl: Types.Decl): {Types.Field}
  local body = decl.body
  local out: mut {Types.Field} = {}
  if body == nil then
    return out
  end
  for _, f in ipairs(body.fields) do
    out[#out + 1] = f
  end
  for _, f in ipairs(Declarations.inherited(ctx.store, ctx.judge, decl)) do
    out[#out + 1] = f
  end
  return out
end

--- A literal checked against a record or a class: each field given once and none the declaration lacks, every field
--- that is not omittable given (a class names every field), each value checked against its field. A literal of a
--- class of this module is noted for the code generator, which writes the class literal; the table of a class of
--- another module is out of reach, so it is refused.
function TableLiterals.literal_record(ctx: Ctx, e: Ast.Table, n: Named): Type
  local body = n.decl.body
  local index = members_index(ctx, n.decl, false)
  if body == nil or index == nil then
    TableLiterals.items_unshaped(ctx, e.items)
    return n
  end
  local is_class = n.decl.kind == "class"
  if is_class then
    local why = TableLiterals.out_of_reach(ctx, n.decl)
    if why == "" then
      ctx.literals[e.id] = n.decl
      if ctx.load.waiting > 0 then
        -- Lua runs the metamethods a class admits by itself, at a `tostring`, the end of a `<close>` local or a comparison, on
        -- any value the literals make: the value is mentioned with them.
        for _, meta in ipairs({ "__tostring", "__close", "__lt", "__le" }) do
          LoadOrder.mention(ctx.load, ctx.within, e, LoadOrder.of_static(n.decl, meta, quoted(Types.decl_name(n.decl) .. "." .. meta)))
        end
      end
    else
      report(ctx, "class_scope", e, "this literal makes a value of " .. quoted(Types.decl_name(n.decl)) .. ", " .. why,
        TableLiterals.reach_fix(ctx, n.decl, "make the value in " .. quoted(n.decl.module) .. " with a function of the class (`function " ..
            n.decl.name .. ".new(...): " .. n.decl.name .. "`), and call it here"), { show(ctx, n) })
    end
  end
  local given: mut {string: boolean} = {}
  local owner = if Types.inferred_record(n.decl) then tq(ctx, n) else quoted(Types.decl_name(n.decl)) end
  local array_part = index.array
  local shaped = true
  -- A spread, which `spread_literal` (in [`table_literal`]) has checked, gives every field the items after it do not.
  local copied = ctx.spreads[e.id] ~= nil
  for _, item in ipairs(e.items) do
    local name = TableLiterals.item_name(item)
    if (item.kind == "Spread") then
      -- Its source is checked where the literal is, against the record.
    elseif name ~= nil and not ((item.kind == "Positional")) then
      local value = (item.kind == "Named") and item.value or (item.kind == "Keyed") and item.value or nil -- checked: and_ternary, or_mix
      local field = TableLiterals.plain_field(ctx, n, name)
      if field == nil then
        local close = nearest(name, names_of(ctx, n))
        local advised = Refusals.advice[n.decl.module .. " " .. n.decl.name .. " ." .. name]
        report(ctx, "literal_unknown", item, owner .. " has no field " .. quoted(name) ..
            (if close ~= "" then ", nearest " .. quoted(close) else "" end),
          if advised ~= nil then advised else (if close ~= "" then "write " .. quoted(close) .. ", or declare " else
            "declare " end) .. quoted(name) .. " in " .. owner end)
      elseif value ~= nil then
        given[name] = true
        local want = put_in(ctx, n, field.type)
        local v = ctx.walk.expr(ctx, value, want)
        -- A field of the language's `metatable` declared `any` (`__index`, `__newindex`) is read by Lua alone, which
        -- takes any value there, as a parameter declared `any` does.
        local lua_reads = n.decl.name == "metatable" and #n.decl.names == 1 and #n.args == 1 and
          (n.decl.module == "lang.prelude" or n.decl.module == "checker.prelude")
        local _ = (if lua_reads then expect_argument else expect end)(ctx, value, v, want,
          " as the field " .. quoted(name) .. " of " .. owner)
      end
      if field == nil and value ~= nil then
        ctx.lenient = ctx.lenient + 1
        local _ = ctx.walk.expr(ctx, value, nil)
        ctx.lenient = ctx.lenient - 1
      end
    elseif (item.kind == "Positional") and array_part ~= nil then
      -- Checked together below, so that the last item may expand.
    else
      if shaped then
        shaped = false
        TableLiterals.wrong_shape(ctx, item, if (item.kind == "Positional") then "positional" else "keyed" end, n,
          "write the fields of " .. owner .. " by name: `field = value`")
      end
      TableLiterals.items_unshaped(ctx, { item })
    end
  end
  if array_part ~= nil then
    local exps = TableLiterals.positional_values(e.items)
    if #exps > 0 then
      local element = put_in(ctx, n, array_part)
      TableLiterals.check_elements(ctx, exps, values_of(ctx, exps, nil, element), element, owner)
    end
  end
  local missing: mut {string} = {}
  local first_missing: Types.Field? = nil
  local optional_field: Types.Field? = nil
  for _, f in ipairs(TableLiterals.fields_of(ctx, n.decl)) do
    if (is_class or f.omittable ~= true) and given[f.name] ~= true and not copied then
      missing[#missing + 1] = quoted(f.name)
      if first_missing == nil then first_missing = f end
      if optional_field == nil and nilable(f.type) then
        optional_field = f
      end
    end
  end
  if #missing > 0 and shaped and first_missing ~= nil then
    -- The fix shows the forms on a field the literal leaves out, by its own name and type.
    local example = optional_field or first_missing
    local plain = show(ctx, ctx.store:non_nil(put_in(ctx, n, example.type)))
    report(ctx, "literal_missing", e, "this literal of " .. owner .. " leaves out " .. listed(missing, "and"),
      if is_class then "add " .. listed(missing, "and") .. " to the literal: a class literal names every field, a field " ..
          "not yet known as its empty value (`fd = -1`) and a `?` field as `" .. example.name .. " = nil`" else
        "add " .. listed(missing, "and") .. " to the literal (`" .. example.name .. " = nil` for a value that may be nil), " ..
          "or declare " .. (if #missing == 1 then "the field" else "them" end) .. " `" .. example.name .. "?: " .. plain .. "`" ..
          (if optional_field ~= nil then ": `" .. optional_field.name .. ": " .. plain .. "?` is a field that must be " ..
              "written, though it may hold nil; `" .. optional_field.name .. "?: " .. plain .. "` is a field that may be left out"
            else "" end) end)
  end
  return n
end

--- The member of the union `u` that the literal `e` is, or nil with the error reported. `written` is `u` as the program
--- names it, where `u` is the type a recursive alias names.
function TableLiterals.literal_member(ctx: Ctx, e: Ast.Table, u: Union, written: Type): Type?
  -- Every type of `types` quoted once, in order, without the `nil`: the arms of a type a message names.
  local function arms_named(types: {Type}): {string}
    local out: mut {string} = {}
    local seen: mut {integer: boolean} = {}
    for _, t in ipairs(types) do
      if t.tag ~= "nil" and seen[t.id] ~= true then
        seen[t.id] = true
        out[#out + 1] = tq(ctx, t)
      end
    end
    table.sort(out)
    return out
  end

  -- Whether a literal of the given `shape` could make a value of `m`, an array, a map, a record or a class: positional
  -- items make an array, or a record with an array part; items with keys make a map or a record.
  local function made_from(m: Type, shape: string): boolean
    if (m.tag == "array") then
      return shape == "positional"
    elseif (m.tag == "map") then
      return shape == "keyed"
    elseif (m.tag == "named") then
      if shape == "positional" then
        local index = members_index(ctx, m.decl, false)
        return index ~= nil and index.array ~= nil
      end
      return shape ~= "mixed"
    end
    return false
  end
  local candidates: mut {Type} = {}
  for _, m in ipairs(members_of(ctx.store, u)) do
    if ((m.tag == "named") and not m.value and (m.decl.kind == "record" or m.decl.kind == "class")) or (m.tag == "array") or (m.tag == "map") then
      candidates[#candidates + 1] = m
    end
  end
  local arms = if written ~= u then ", which is " .. listed(arms_named(members_of(ctx.store, u)), "or") else "" end
  if #candidates == 0 then
    report(ctx, "literal_shape", e, "a table literal is checked against " .. tq(ctx, written) .. arms .. ", which has no member a " ..
        "table makes",
      "write a value of one of its members", { show(ctx, written) })
    return nil
  end
  -- The kinds of item tell an array from a map, and a record that has an array part from one that has not.
  -- `name =` and `[k] =` are one kind of item here: both give a key. Only a positional item beside them mixes.
  local shape = "empty"
  local positional, keyed = false, false
  for _, item in ipairs(e.items) do
    if (item.kind == "Positional") then
      positional = true
    else
      keyed = true
    end
  end
  if positional and keyed then
    shape = "mixed"
  elseif positional then
    shape = "positional"
  elseif keyed then
    shape = "keyed"
  end
  if #candidates > 1 and shape ~= "empty" then
    local fitting: mut {Type} = {}
    for _, m in ipairs(candidates) do
      if made_from(m, shape) then
        fitting[#fitting + 1] = m
      end
    end
    if #fitting == 0 then
      report(ctx, "literal_shape", e, "this literal's items (" .. (if shape == "mixed" then "some by position and some by key" elseif shape == "positional" then
        "by position" else "by key" end) .. ") make none of " .. listed(type_names(ctx, candidates), "or") ..
          ", the tables " .. tq(ctx, written) .. " takes",
        "write the items by position for an array, or `key = value` for a map, and not both", { show(ctx, written) })
      return nil
    end
    candidates = fitting
  end
  if #candidates == 1 then
    return candidates[1]
  end
  -- A tag: a named item whose string value is a value of the enum a member's field of that name has, where every
  -- candidate has an enum there, as a tag is. Another member with the value too is `untagged_union` where the union is
  -- declared, and leaves the literal ambiguous here.
  for _, item in ipairs(e.items) do
    local name = TableLiterals.item_name(item)
    local value = (item.kind == "Named") and peel(item.value) or (item.kind == "Keyed") and peel(item.value) or nil -- checked: and_ternary, or_mix
    if name ~= nil and value ~= nil and (value.kind == "String") then
      local tagged: mut {Type} = {}
      local everywhere = true
      for _, m in ipairs(candidates) do
        local field = (m.tag == "named") and TableLiterals.plain_field(ctx, m, name) or nil -- checked: and_ternary
        local t = field ~= nil and field.type or nil
        local body = t ~= nil and (t.tag == "named") and t.decl.kind == "enum" and t.decl.body or nil
        if body == nil then
          everywhere = false
        else
          local has = false
          for _, v in ipairs(body.values) do
            has = has or v == value.value
          end
          if has then
            tagged[#tagged + 1] = m
          end
        end
      end
      if everywhere and #tagged == 1 then
        return tagged[1]
      end
    end
  end
  -- A record told by being there: the one candidate that declares every field the literal names, where each
  -- candidate is a record.
  local every_record = true
  for _, m in ipairs(candidates) do
    every_record = every_record and (m.tag == "named") and not m.value and m.decl.kind == "record"
  end
  if every_record then
    local declaring: mut {Type} = {}
    for _, m in ipairs(candidates) do
      if (m.tag == "named") then
        local held = Declarations.names_held(ctx.store, ctx.judge, m.decl)
        local all = true
        for _, item in ipairs(e.items) do
          local name = TableLiterals.item_name(item)
          all = all and (name == nil or held[name] == true)
        end
        if all then
          declaring[#declaring + 1] = m
        end
      end
    end
    if #declaring == 1 then
      return declaring[1]
    end
  end
  local records = false
  for _, m in ipairs(candidates) do
    records = records or (m.tag == "named")
  end
  if records then
    report(ctx, "literal_ambiguous", e, "this literal could be any of " .. listed(type_names(ctx, candidates)),
      "give the tag field of the member it is (`kind = \"...\"`) or a field only that member declares, or type " ..
        "the literal first: `local v: Member = {...}`")
  elseif shape == "empty" then
    local fix = "write an item, or type the literal as the one it is: `local v: " .. show(ctx, candidates[1]) .. " = {}`" -- checked: index_may_be_nil
    if (written.tag == "named") then
      local advised = Refusals.advice[written.decl.module .. " " .. written.decl.name .. " empty"]
      if advised ~= nil then
        fix = advised
      end
    end
    report(ctx, "literal_ambiguous", e, "this literal has no items, so it could be any of " .. listed(type_names(ctx, candidates)), fix)
  else
    report(ctx, "literal_ambiguous", e, "this literal could be any of " .. listed(type_names(ctx, candidates)),
      "type the literal as the one it is: `local v: " .. show(ctx, candidates[1]) .. " = {...}`") -- checked: index_may_be_nil
  end
  return nil
end

--- The type to read from when the value of `node` has type `t`: `t` without its nil, after reporting that it may
--- be nil. Nil where the access has nothing to read (an error already reported, or `invalid`).
function TableLiterals.readable(ctx: Ctx, node: Ast.Node, t: Type, what: string): Type?
  local tag = t.tag
  if tag == "invalid" or tag == "never" then
    return nil
  elseif tag == "any" then
    report(ctx, "any_use", node, subject(ctx, node) .. " is untrusted data (`any`), so " .. what,
      "validate it with a [`cosmic.shape`] validator, or test its tag, and use the checked value", { "any" })
    return nil
  elseif tag == "nil" then
    report(ctx, "nil_not_allowed", node, subject(ctx, node) .. " is nil, so " .. what,
      "give it a value, or do not read it", { "nil" })
    return nil
  elseif nilable(t) then
    report(ctx, "nil_not_allowed", node, subject(ctx, node) .. " is " .. tq(ctx, t) .. ", so it may be nil, and " .. what,
      nil_fix(ctx, node, t), { show(ctx, t) })
    return ctx.store:non_nil(t)
  end
  return t
end
local readable = TableLiterals.readable

--- A table literal. Checked against a type it is a record, a class, an array or a map as that type is; with no type it
--- is an array or a map of the join of its items.
function TableLiterals.table_literal(ctx: Ctx, e: Ast.Table, expected: Type?): Type
  --- A literal that begins with a spread, `{ ...r, field = v }`: a copy of the record `r` with the fields written after
  --- the spread given their own values. The spread is the first item, and the only one. Its source is a record, not
  --- nilable, and a value of the record wanted, or of the record the literal is made of where none is wanted: the
  --- copy is a value of that record. The fields after it are checked as those of a literal of the record are, and the
  --- literal need not give the fields the spread does. A record with an array part is refused, since the spread would
  --- drop the array. The code generator is told, by `spreads`, the fields the spread copies.
  local function spread_literal(): Type
    local items = e.items
    -- Checks the items after the first, which are no part of the literal that was refused.
    local function items_after_first()
      local rest: mut {Ast.Item} = {}
      for i, item in ipairs(items) do
        if i > 1 then
          rest[#rest + 1] = item
        end
      end
      TableLiterals.items_unshaped(ctx, rest)
    end
    local first = items[1]
    if first == nil or (first.kind ~= "Spread") then
      for _, item in ipairs(items) do
        if (item.kind == "Spread") then
          report(ctx, "literal_spread", item, "a spread must be the first item of a literal, and this one follows another",
            "write the spread first, and the fields that replace its own after it: `{ ...r, field = v }`")
        end
      end
      TableLiterals.items_unshaped(ctx, items)
      return ctx.invalid
    end
    for i, item in ipairs(items) do
      if i > 1 and (item.kind == "Spread") then
        report(ctx, "literal_spread", item, "this literal has a second spread, and a copy is made from one record",
          "remove it, and write the fields it would give: `{ ...r, field = v }`")
        ctx.lenient = ctx.lenient + 1
        local _ = ctx.walk.expr(ctx, item.value, nil)
        ctx.lenient = ctx.lenient - 1
      end
    end
    local source = first.value
    if (peel(source).kind == "Table") then
      report(ctx, "literal_spread", source, "a spread copies a record value, and this is a table literal",
        "write the fields by name, or spread a value held in a local")
      items_after_first()
      return ctx.invalid
    end
    local got = ctx.walk.expr(ctx, source, nil)
    local readable_type = readable(ctx, source, got, "its fields cannot be copied")
    if readable_type == nil then
      items_after_first()
      return ctx.invalid
    end
    local open = Types.unfold(readable_type)
    if not ((open.tag == "named") and not open.value and open.decl.kind == "record") then
      local why = if (open.tag == "array") then "a spread copies the fields of a record, not the elements of an array" elseif
        (open.tag == "map") then "a spread copies the fields of a record, not the entries of a map" elseif
        (open.tag == "named") and open.decl.kind == "class" then "a spread copies the fields of a record, and a class value is not one" else
        "a spread copies the fields of a record"
        end
      report(ctx, "literal_spread", source, subject(ctx, source) .. " is " .. tq(ctx, readable_type) .. ", and " .. why,
        "spread a value of a record type, or write the fields by name", { show(ctx, readable_type) })
      items_after_first()
      return ctx.invalid
    end
    local made = open
    local wanted: Type? = nil
    if expected ~= nil and ctx.lenient == 0 then
      local want = ctx.store:non_nil(expected)
      if want.tag ~= "invalid" and want.tag ~= "any" and want.tag ~= "never" then
        wanted = want
        local unfolded = Types.unfold(want)
        if (unfolded.tag == "named") and not unfolded.value and unfolded.decl.kind == "record" then
          made = unfolded
        elseif unfolded.tag ~= "union" then
          report(ctx, "literal_spread", e, "this literal has a spread, which makes a record, and " .. tq(ctx, want) .. " is wanted",
            "write the fields by name, or spread into a record type", { show(ctx, want) })
          items_after_first()
          return ctx.invalid
        end
      end
    end
    if wanted ~= nil and not expect(ctx, source, readable_type, wanted, " as the source of a spread") then
      items_after_first()
      return ctx.invalid
    end
    if not ((made.tag == "named")) then
      items_after_first()
      return ctx.invalid
    end
    local body = made.decl.body
    local index = members_index(ctx, made.decl, false)
    if body == nil or index == nil then
      items_after_first()
      return made
    end
    if index.array ~= nil then
      report(ctx, "literal_spread", source, quoted(Types.decl_name(made.decl)) .. " has an array part, which a spread does not copy",
        "make the copy by hand, or declare the elements as a field", { show(ctx, made) })
      items_after_first()
      return made
    end
    local fields: mut {string} = {}
    for _, f in ipairs(TableLiterals.fields_of(ctx, made.decl)) do
      fields[#fields + 1] = f.name
    end
    ctx.spreads[e.id] = fields
    return TableLiterals.literal_record(ctx, e, made)
  end

  -- Reports each key a table literal gives a second time: a name (`a = 1`), a constant key (`["a"]`, `[1]`, `[true]`), or the
  -- place of a positional item (`{ "x", [1] = "y" }`). The second value would replace the first, whatever type the literal is
  -- checked against, so this stands apart from the shape of the literal. A name and the same string as a key are one key.
  local seen: mut {string: boolean} = {}
  local place = 0
  local spread = false
  for _, item in ipairs(e.items) do
    local key: string? = nil
    local shown = ""
    if (item.kind == "Spread") then
      spread = true
    elseif (item.kind == "Positional") then
      place = place + 1
      key, shown = "n" .. tostring(place), tostring(place)
    elseif (item.kind == "Named") then
      key, shown = "s" .. item.name, quoted(item.name)
    elseif (item.kind == "Keyed") then
      local at = peel(item.key)
      if (at.kind == "String") then
        key, shown = "s" .. at.value, quoted(at.value)
      elseif (at.kind == "Integer") then
        key, shown = "n" .. tostring(at.value), tostring(at.value)
      elseif (at.kind == "Boolean") then
        key, shown = "b" .. tostring(at.value), tostring(at.value)
      end
    end
    if key ~= nil then
      if seen[key] == true then
        report(ctx, "literal_repeated", item, "the key " .. shown .. " is written twice in this literal",
          "remove the second " .. shown .. ", or give the two different keys")
      end
      seen[key] = true
    end
  end
  if spread then
    return spread_literal()
  end
  if expected == nil or ctx.lenient > 0 then
    return TableLiterals.literal_inferred(ctx, e)
  end
  local want = ctx.store:non_nil(expected)
  if want.tag == "invalid" then
    TableLiterals.items_unshaped(ctx, e.items)
    return want
  elseif want.tag == "any" or want.tag == "never" then
    return TableLiterals.literal_inferred(ctx, e)
  end
  local written = want
  want = Types.unfold(want)
  if (want.tag == "union") then
    local member = TableLiterals.literal_member(ctx, e, want, written)
    if member == nil then
      TableLiterals.items_unshaped(ctx, e.items)
      return ctx.invalid
    end
    want = member
  end
  if (want.tag == "named") then
    local kind = want.decl.kind
    if want.value then
      report(ctx, "literal_shape", e, "a table literal cannot make " .. tq(ctx, want) .. ", the table of the functions of " ..
          quoted(Types.decl_name(want.decl)),
        "write a value of " .. quoted(Types.decl_name(want.decl)) .. " where one is wanted, or the declaration itself", { show(ctx, want) })
      TableLiterals.items_unshaped(ctx, e.items)
      return ctx.invalid
    elseif kind == "record" or kind == "class" then
      return TableLiterals.literal_record(ctx, e, want)
    end
    local advised = Refusals.advice[want.decl.module .. " " .. want.decl.name]
    report(ctx, "literal_shape", e, "a table literal cannot make " .. tq(ctx, want) .. ", " ..
        (if kind == "interface" then "an interface" elseif kind == "enum" then "an enum" else "a userdata record" end),
      if kind == "interface" then (if advised ~= nil then advised else "make the value with a class that lists " ..
          quoted(Types.decl_name(want.decl)) .. " (`class C is " .. want.decl.name .. "`)" end) else "write a value of " ..
          quoted(Types.decl_name(want.decl)) end, { show(ctx, want) })
    TableLiterals.items_unshaped(ctx, e.items)
    return ctx.invalid
  elseif (want.tag == "array") then
    return TableLiterals.literal_array(ctx, e, want)
  elseif (want.tag == "map") then
    return TableLiterals.literal_map(ctx, e, want)
  end
  report(ctx, "literal_shape", e, "a table literal cannot make " .. tq(ctx, want),
    "write a value of " .. tq(ctx, want), { show(ctx, want) })
  TableLiterals.items_unshaped(ctx, e.items)
  return ctx.invalid
end

return TableLiterals
