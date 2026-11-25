--- The lists of values an expression gives: `...`, the first value of a call, and the values a list of expressions spreads.

local Ast = require("lang.ast")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local type Type = Types.Type
local type Alt = Types.Alt
local type Ctx = Context.Ctx
local base_of = Context.base_of
local below = Context.below
local report = Naming.report
local subject = Context.subject

--- The values of an expression list.
local record Values
  --- One type for each value, a call or `...` at the end expanded to what it returns.
  types: mut {Type}
  --- Set when the last expression ends in `T...` or is `...`: any number more values of this type.
  mut tail: Type?
  --- Set when the last expression is a call with several lists, which are no values.
  mut lists: {Alt}?
  --- The last expression, when it was expanded.
  mut last: Ast.Exp?
end

local record ValueLists
  type Values = Values
end

--- A boolean literal: `true` or `false` where the position wants that and not `boolean`.
function ValueLists.boolean_literal(ctx: Ctx, e: Ast.Boolean, expected: Type?): Type
  local store = ctx.store
  if expected ~= nil and not below(ctx, store.boolean, expected) then
    local exact = store:atom(if e.value then "true" else "false" end)
    if below(ctx, exact, expected) then
      return exact
    end
  end
  return store.boolean
end

--- The type of `...` in the function being checked, reporting the one that has none.
function ValueLists.vararg_rest(ctx: Ctx, e: Ast.Node): Type
  local rest = ctx.frames[#ctx.frames].rest -- checked: nil_not_allowed
  if rest == nil then
    report(ctx, "vararg_outside", e, "`...` is used in a function that has no rest parameter",
      "declare the rest parameter `...: T`")
    return ctx.invalid
  end
  return rest
end
local vararg_rest = ValueLists.vararg_rest

--- The one list of `alts` that `assert` lets pass: the list whose first value is never nil or false, where the first
--- value of every other list is `nil` or `false` and nothing else, so `assert` raises at each of them. Nil where there
--- is no such list, more than one, or a list whose first value may be either (a `boolean`, an optional, `any`).
function ValueLists.asserted(ctx: Ctx, alts: {Alt}): Alt?
  local passed: Alt? = nil
  for _, alt in ipairs(alts) do
    local first = alt.items[1]
    if first == nil then
      return nil
    elseif Types.present_where(first, function(var: Types.Var): boolean
      return ctx.judge:subtype(var, ctx.store:atom("Some"))
    end) and not Types.may_be_false(first) then
      if passed ~= nil then
        return nil
      end
      passed = alt
    elseif first.tag ~= "nil" and first.tag ~= "false" then
      return nil
    end
  end
  return passed
end

--- The one value a call returning `alts` gives where a value is wanted.
function ValueLists.first_value(ctx: Ctx, node: Ast.Node, alts: {Alt}): Type
  if #alts == 0 then
    return ctx.store.never
  elseif #alts > 1 then
    local call = Naming.call(ctx, node)
    local raises = ""
    if ctx.filename:sub(-8) == "_test.tl" and (call:find("^pcall%(") ~= nil or call:find("^xpcall%(") ~= nil) then
      raises = "; to check that a call raises, `Test.raises(function() f(x) end, says?)` runs it and answers the message it raised"
    end
    -- Where `assert` tells the lists apart, `call!` takes the value, raising with the failure's reason.
    local taken = if ValueLists.asserted(ctx, alts) ~= nil then ", take the value with `" .. call .. "!`, which raises " ..
        "where it fails," else "" end
    report(ctx, "alternatives_as_value", node, subject(ctx, node) .. " answers one of " .. tostring(#alts) ..
        " lists of values, which is no value",
      "bind its values and test the first (`local " .. Naming.bound(alts) .. " = " .. call .. "`)" .. taken ..
        " or match the call: `match " .. call .. " do | ... end`" .. raises)
    return ctx.invalid
  end
  local alt = alts[1]
  if #alt.items > 1 or alt.tail ~= nil then
    ctx.spare[base_of(node).id] = true
  end
  local first = alt.items[1]
  if first ~= nil then
    return first
  end
  local tail = alt.tail
  if tail ~= nil then
    return tail.tag == "invalid" and tail or ctx.store:optional(tail) -- checked: and_ternary
  end
  report(ctx, "no_value", node, subject(ctx, node) .. " answers nothing, so it has no value here",
    "use the call as a statement, or call a function that answers a value")
  return ctx.invalid
end

--- The types of the expressions of `list`, each checked with the type its position expects (`wants[i]`, else
--- `rest_want`), the last expanded when it is a call or `...`.
function ValueLists.values_of(ctx: Ctx, list: {Ast.Exp}, wants: {integer: Type}?, rest_want: Type?): Values
  local out: Values = { types = {} } -- checked: literal_missing
  local n = #list
  for i, e in ipairs(list) do
    local want = rest_want
    if wants ~= nil and wants[i] ~= nil then
      want = wants[i]
    end
    if i < n then
      local t = ctx.walk.expr(ctx, e, want)
      out.types[#out.types + 1] = t
    elseif (e.kind == "Call") or (e.kind == "MethodCall") then
      local alts = ctx.walk.lists_of(ctx, e, want)
      out.last = e
      if #alts == 1 then
        for _, item in ipairs(alts[1].items) do
          out.types[#out.types + 1] = item
        end
        out.tail = alts[1].tail -- checked: nil_not_allowed
      elseif #alts == 0 then
        out.types[#out.types + 1] = ctx.store.never
      else
        out.lists = alts
      end
    elseif (e.kind == "Vararg") then
      out.last = e
      out.tail = vararg_rest(ctx, e)
    else
      local t = ctx.walk.expr(ctx, e, want)
      out.types[#out.types + 1] = t
    end
  end
  return out
end

return ValueLists
