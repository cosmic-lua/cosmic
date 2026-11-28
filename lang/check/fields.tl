--- The reads of fields and indexes: the members a type has, a field it lacks, and the keys an index takes.

local Ast = require("lang.ast")
local LoadOrder = require("lang.load_order")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local Refusals = require("lang.check.refusals")
local Names = require("lang.check.names")
local Lookup = require("lang.check.members")
local TableLiterals = require("lang.check.table_literals")
local type Type = Types.Type
local type Named = Types.Named
local type Decl = Types.Decl
local type Ctx = Context.Ctx
local type Member = Context.Member
local base_of = Context.base_of
local below = Context.below
local is_enum = Context.is_enum
local is_text = Context.is_text
local nearest = Context.nearest
local nilable = Context.nilable
local peel = Context.peel
local quoted = Context.quoted
local report = Naming.report
local show = Context.show
local subject = Context.subject
local text_of = Context.text_of
local tq = Context.tq
local declaration_value = Names.declaration_value
local expect = Refusals.expect
local members_index = Lookup.members_index
local names_of = Lookup.names_of
local put_in = Lookup.put_in
local takes_receiver = Lookup.takes_receiver

local record Fields
end

--- The integer enum declared as `name` inside `decl`, a record or class with no type parameters, whose table holds the
--- enum's table under that name ([`lang.codegen`]'s `record_table`); nil where it declares none. A declaration of
--- another module is asked of the store's loader.
local function nested_integer_enum(ctx: Ctx, decl: Decl, name: string): Decl?
  -- TODO: read an integer enum nested in a nested record (`M.Inner.E`), once a nested record is a value: the code
  -- generator writes its table, and no read reaches it today.
  --
  -- TODO: read an integer enum nested in a generic record or class, once the code generator writes the nested tables of
  -- one: its table is `{}` today, so the read is refused as a field the record does not declare.
  if (decl.kind ~= "record" and decl.kind ~= "class") or (decl.arity or 0) ~= 0 then
    return nil
  end
  local store = ctx.store
  local path = decl.name .. "." .. name
  local found = store:find(decl.module, path)
  local loader = store.loader
  if found == nil and loader ~= nil then
    local text = loader(decl.module, path)
    if text ~= nil then
      -- A text the store refuses declares nothing it can read, as a missing one does.
      local made, _refused = store:decode_declaration(text)
      found = made
    end
  end
  if found ~= nil and found.kind == "integer_enum" then
    return found
  end
  return nil
end

--- The members called `name` of `t`, each with the type arguments put in.
function Fields.member_types(ctx: Ctx, t: Named, name: string): {Member}?
  local index = members_index(ctx, t.decl, t.value)
  if index == nil then
    return nil
  end
  local held = index.by_name[name]
  if held == nil and t.value then
    local nested = nested_integer_enum(ctx, t.decl, name)
    if nested ~= nil then
      held = { { type = declaration_value(ctx, nested), mut = false, method = false } }
      index.by_name[name] = held
    end
  end
  return held
end
local member_types = Fields.member_types

function Fields.field_unknown(ctx: Ctx, node: Ast.Node, t: Type, name: string)
  if (t.tag == "named") and t.value and (ctx.program.absent[t.decl] or {})[name] == true then
    -- The function is a field every value holds, filled where the value is made: the table of the functions has none.
    local owner = quoted(Types.decl_name(t.decl))
    report(ctx, "field_unknown", node, owner .. " has no field " .. quoted(name) .. " in the table of its functions: " ..
        quoted(name) .. " is a function field of the values of " .. owner .. ", which no statement of its module gives " ..
        "that table",
      "call it on a value of " .. owner .. ": `v:" .. name .. "(...)`", { show(ctx, t) })
    return
  end
  if (t.tag == "named") and not t.value and (ctx.program.statics[t.decl] or {})[name] ~= nil then
    -- A module stored in a field typed with its record is typed as the record's value, which has none of its functions.
    local decl: Decl = t.decl
    local owner = quoted(Types.decl_name(decl))
    local through_field = false
    if (node.kind == "Field") then
      local object = node.object
      through_field = (object.kind == "Field")
    end
    local call = "call it on the declaration: `" .. decl.name .. "." .. name .. "(...)`"
    local fix = call
    local held = members_index(ctx, decl, false)
    local selfish = held ~= nil and held.selfish[name] == true
    -- A class has no module among its values, so its fix is the call alone.
    if decl.kind ~= "class" and through_field and decl.module ~= ctx.input.module and
        not decl.module:find("@", 1, true) then
      -- A record read through a field holds a module stored there, which a program requires where it uses it.
      fix = "require the module where you use it (`local " .. decl.name .. " = require(\"" .. decl.module .. "\")`) " ..
        "instead of reading it through a field; " .. call
    elseif decl.kind ~= "class" and selfish then
      -- It takes the record first, but the value is a table with the record's fields and no metatable to reach the function.
      fix = call .. "; `v:" .. name .. "(...)` finds no function in a value of a record, which has no metatable: declare " ..
        owner .. " as a class, or declare " .. quoted(name) .. " as a function field `" .. name .. ": function(" ..
        decl.name .. ", ...)` that every value holds"
    end
    report(ctx, "field_unknown", node, owner .. " has no field " .. quoted(name) .. ": " .. quoted(name) ..
        " is a function of the declaration " .. owner .. " used as a value, and this is typed as a value of it",
      fix, { show(ctx, t) })
    return
  end
  local owner = (t.tag == "named") and quoted(Types.decl_name(t.decl)) or tq(ctx, t) -- checked: and_ternary
  if (t.tag == "named") and not t.value and Types.inferred_record(t.decl) then
    local close = nearest(name, names_of(ctx, t))
    report(ctx, "field_unknown", node, tq(ctx, t) .. ", the record inferred for a literal, has no field " .. quoted(name) ..
        (if close ~= "" then ", nearest " .. quoted(close) else "" end),
      (if close ~= "" then "write " .. quoted(close) .. ", or " else "" end) .. TableLiterals.declare_fix(ctx, t, name),
      { show(ctx, t) })
    return
  end
  if (t.tag == "named") and t.decl.kind == "integer_enum" and not t.value then
    report(ctx, "field_unknown", node, owner .. " is an integer enum, whose values are integers and have no fields: " ..
        quoted(name) .. " is not one",
      "compare the value with `==` to a member (`" .. t.decl.name .. ".NAME`), or pass it where an `integer` is wanted",
      { show(ctx, t) })
    return
  end
  if is_enum(t) then
    -- A method call on an enum is served by `string` and never gets here: this reads a field, or a function as a value.
    report(ctx, "field_unknown", node, owner .. " is an enum, whose values have no fields: " .. quoted(name) .. " is not one",
      "call a function of `string` on it, `v:" .. name .. "(...)`, or compare it with `==` to a member", { show(ctx, t) })
    return
  end
  local names: {string} = {}
  if (t.tag == "named") then
    names = names_of(ctx, t)
  end
  local close = nearest(name, names)
  local declare = "declare " .. quoted(name) .. " in " .. owner
  local told: string? = nil
  if (t.tag == "named") and Types.shape_record(t.decl) then
    declare = "add `" .. name .. ": T` to the braces of " .. owner
  elseif (t.tag == "named") and t.value and t.decl.kind == "integer_enum" then
    declare = "add the member `" .. name .. " = n` to " .. owner
  end
  if (t.tag == "named") and t.decl.module:sub(1, 7) == "cosmic." and ctx.input.module:sub(1, 7) ~= "cosmic." then
    -- A record of cosmic's own modules is the binary's to a program, which cannot declare a field in it: what it has
    -- is told here, so the next try needs no lookup.
    told = Naming.members_told(ctx, t, name, close)
    declare = told or ("`cosmic docs " .. t.decl.module .. "` lists what " .. owner .. " has")
  end
  local advised = if (t.tag == "named") then Refusals.advice[t.decl.module .. " " .. t.decl.name .. " ." .. name] else nil end
  report(ctx, "field_unknown", node, owner .. " has no field " .. quoted(name) ..
      (if close ~= "" then ", nearest " .. quoted(close) else "" end),
    if advised ~= nil then advised elseif close ~= "" then
      "write " .. quoted(close) .. (if told ~= nil then "; " else ", or " end) .. declare else declare end,
    { show(ctx, t) })
end
local field_unknown = Fields.field_unknown

--- How a message names the static `name` of `decl` that a statement of the module has yet to give, and that statement:
--- a `function R.m(...)`, or an `M.f = v` that gives the module's table a value (`inits_module` in [`lang.check`]).
function Fields.static_words(ctx: Ctx, decl: Decl, name: string): string, string
  local owner = decl.name .. "." .. name
  local binding = ctx.module_table
  if binding ~= nil and ctx.given[name] == true then
    local entry = ctx.lowered.entries[binding]
    if entry ~= nil and entry.decl == decl then
      return "the value " .. quoted(owner), quoted(owner .. " = ...")
    end
  end
  return "the function " .. quoted(owner), "`function " .. owner .. "(...)`"
end
local static_words = Fields.static_words

--- The type of the field or method `name` of the value of type `t`, reported where it has none. `node` is the
--- expression that reads it; it holds the overloads of the field in `ctx.cands` when it has several.
function Fields.member_read(ctx: Ctx, node: Ast.Node, t: Type, name: string): Type
  local store = ctx.store
  ctx.member_module, ctx.member_node = "", node
  -- A method call on an enum value is a call in `string`, which each enum is below; the read of a member as a value is not.
  local called = (node.kind == "MethodCall")
  if (t.tag == "named") and not (is_enum(t) and called) then
    local decl = t.decl
    ctx.member_module = decl.module
    local coroutines = ctx.program.globals["coroutine"]
    if coroutines ~= nil and coroutines.decl == decl then
      ctx.coroutine_reads[node.id] = true
    end
    local waiting = ctx.pending[decl]
    local as_declared = t.value or decl.kind == "class" or decl.kind == "interface"
    if waiting ~= nil and waiting[name] == true and as_declared then
      if ctx.within == 0 then
        -- The module's own code that runs as it loads reads the static before the statement that defines it has run.
        local what, statement = static_words(ctx, decl, name)
        report(ctx, "static_before_definition", node, subject(ctx, node) .. " reads " .. what ..
            " before the statement that defines it has run",
          "move the statement " .. statement .. " above this use, or use it in a function that runs after the module has " ..
            "loaded", { show(ctx, t) })
      else
        LoadOrder.read(ctx.load, ctx.within, { decl = decl, name = name, first = base_of(node).first })
      end
    end
    if as_declared and ctx.load.waiting > 0 then
      LoadOrder.mention(ctx.load, ctx.within, node, LoadOrder.of_static(decl, name, quoted(Types.decl_name(decl) .. "." .. name)))
    end
    local list = member_types(ctx, t, name)
    if list == nil then
      field_unknown(ctx, node, t, name)
      return ctx.invalid
    end
    local first = assert(list[1])
    if t.decl.kind == "interface" and not called and not first.method and ctx.probes[node.id] ~= true and
        takes_receiver(ctx, t.decl, first.type) then
      -- The implementation depends on the receiver, which agreement fixes to the implementing type: read as a value, it
      -- would be called with another implementer.
      local receiver = (node.kind == "Field") and text_of(ctx, node.object) or "v" -- checked: and_ternary
      local fix = "call it as `" .. receiver .. ":" .. name .. "(...)`"
      if nilable(first.type) then
        -- An optional method is there or not: a call needs the test of the place first, which narrows it.
        fix = "test that it is there, then call it: `if " .. receiver .. "." .. name .. " ~= nil then " .. receiver .. ":" ..
          name .. "(...) end`"
      end
      report(ctx, "interface_method_value", node, subject(ctx, node) .. " reads the method " .. quoted(name) ..
          " of the interface " .. tq(ctx, t) .. " as a value, and its implementation depends on the receiver",
        fix, { show(ctx, t) })
      return ctx.invalid
    end
    if #list > 1 then
      local all: mut {Type} = {}
      for i, m in ipairs(list) do
        all[i] = put_in(ctx, t, m.type)
      end
      ctx.cands = all
      ctx.cand_node = node
    end
    return put_in(ctx, t, list[1].type) -- checked: nil_not_allowed
  elseif (t.tag == "union") then
    -- Read as a value, the member is the union of their types; a call is typed by `union_method` in [`lang.check.generic_calls`] and not by this.
    local key = tostring(t.id) .. "." .. name
    local held = ctx.union_fields[key]
    if held ~= nil then
      return held
    end
    local types: mut {Type} = {}
    for _, m in ipairs(t.members) do
      if (m.tag == "named") and member_types(ctx, m, name) ~= nil then
        types[#types + 1] = Fields.member_read(ctx, node, m, name)
      elseif is_enum(m) then
        report(ctx, "field_unknown", node, quoted(name) .. " is not a field of " .. tq(ctx, m) ..
            ", an enum and a member of " .. tq(ctx, t),
          "call a function of `string` on it, `v:" .. name .. "(...)`, or narrow the value to the member that has it " ..
            "(`x is T`)", { show(ctx, t) })
        return ctx.invalid
      else
        report(ctx, "field_unknown", node, quoted(name) .. " is not a field of " .. tq(ctx, m) ..
            ", a member of " .. tq(ctx, t),
          "narrow the value to the member that has it (`x.kind == \"...\"` or `x is T`), or declare " .. quoted(name) ..
            " in every member", { show(ctx, t) })
        return ctx.invalid
      end
    end
    local made = store:union(types)
    ctx.union_fields[key] = made
    return made
  elseif (t.tag == "map") then
    report(ctx, "map_field", node, subject(ctx, node) .. " reads a field of a map, " .. tq(ctx, t) ..
        ", which is read by a key",
      "write `[\"" .. name .. "\"]` after the map, or declare a record for the fields",
      { show(ctx, t) })
    return ctx.invalid
  elseif is_text(t) then
    local entry = ctx.program.globals["string"]
    local decl = entry ~= nil and entry.decl or nil -- checked: and_ternary
    local index = decl ~= nil and members_index(ctx, decl, false) or nil -- checked: and_ternary
    local list = index ~= nil and index.by_name[name] or nil
    if list == nil then
      report(ctx, "field_unknown", node, (if is_enum(t) then tq(ctx, t) .. " is an enum, a string with no method " else
        "a string has no field " end) .. quoted(name),
        "call a function of `string` on it: `s:upper()`, `s:sub(i, j)`", { show(ctx, t) })
      return ctx.invalid
    end
    if #list > 1 then
      local all: mut {Type} = {}
      for _, m in ipairs(list) do
        all[#all + 1] = m.type
      end
      ctx.cands = all
      ctx.cand_node = node
    end
    return list[1].type
  elseif (t.tag == "var") then
    local scope = ctx.bounds[#ctx.bounds - t.depth]
    local parameter = scope ~= nil and scope[t.index + 1] or nil -- checked: and_ternary
    local bounds = if parameter ~= nil then parameter.bounds else nil end
    if bounds ~= nil then
      -- `T is A & B` has the fields of each: the first bound that declares one gives it.
      for _, bound in ipairs(bounds) do
        local index = if (bound.tag == "named") then members_index(ctx, bound.decl, false) else nil end
        if index ~= nil and index.by_name[name] ~= nil then
          return Fields.member_read(ctx, node, bound, name)
        end
      end
      if #bounds == 1 then
        return Fields.member_read(ctx, node, assert(bounds[1]), name)
      end
      report(ctx, "not_indexable", node, "the type parameter " .. tq(ctx, t) .. " has no field " .. quoted(name) ..
          ": none of its bounds, " .. quoted(Types.bounds_text(bounds, function(b: Type): string
            return show(ctx, b)
          end)) ..
          ", declares it",
        "bound it by an interface that declares " .. quoted(name) .. " as well (`<" .. show(ctx, t) .. " is " ..
          Types.bounds_text(bounds, function(b: Type): string return show(ctx, b) end) .. " & I>`)", { show(ctx, t) })
      return ctx.invalid
    end
    report(ctx, "not_indexable", node, "the type parameter " .. tq(ctx, t) .. " has no field " .. quoted(name),
      "bound it by an interface that declares " .. quoted(name) .. " (`T is I`)", { show(ctx, t) })
    return ctx.invalid
  end
  report(ctx, "not_indexable", node, subject(ctx, node) .. " reads a field of " .. tq(ctx, t) .. ", which has none",
    "read a field of a record, class or interface (`p.name` where `p: {name: string}`), or index a map with `m[key]`", { show(ctx, t) })
  return ctx.invalid
end

--- Checks that `key`, of type `kt`, may index a collection keyed by `want`: an `integer` where that is wanted, never
--- a `number`.
function Fields.key_ok(ctx: Ctx, key_node: Ast.Node, kt: Type, want: Type, of: string): boolean
  if below(ctx, kt, want) then
    return true
  end
  if kt.tag == "number" and want.tag == "integer" then
    report(ctx, "float_key", key_node, subject(ctx, key_node) .. " is a `number`, and " .. of .. " is keyed by `integer`",
      "convert it: `math.tointeger(" .. text_of(ctx, key_node) .. ")` or `math.floor(" .. text_of(ctx, key_node) .. ")`",
      { show(ctx, kt), show(ctx, want) })
    return false
  end
  return expect(ctx, key_node, kt, want, " as the key of " .. of)
end

--- The field names a key of type `kt` stands for when it is a string literal or an enum, or nil.
function Fields.key_names(key: Ast.Exp, kt: Type): {string}?
  local literal = peel(key)
  if (literal.kind == "String") then
    return { literal.value }
  end
  if (kt.tag == "named") and kt.decl.kind == "enum" then
    local body = kt.decl.body
    if body ~= nil then
      return body.values
    end
  end
  return nil
end

return Fields
