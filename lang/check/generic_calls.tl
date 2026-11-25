--- The calls of generic functions: the instance a call takes and what it knows after it returns.

local Ast = require("lang.ast")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local Fields = require("lang.check.fields")
local type Type = Types.Type
local type Union = Types.Union
local type Ctx = Context.Ctx
local is_text = Context.is_text
local quoted = Context.quoted
local report = Naming.report
local show = Context.show
local subject = Context.subject
local tq = Context.tq
local member_read = Fields.member_read
local member_types = Fields.member_types

local record GenericCalls
end

--- The method `name` called as `object:name(...)` through the union `u`: the function type every member declares it as
--- once the receiver is `u`, with its overloads, or nil after reporting that a member lacks it or declares it
--- differently. The value is one member at run time and each member's method takes that member as its receiver, so a
--- receiver that is the member itself (as a method has it) is replaced by `u`, and the call is typed when the members then
--- agree exactly: the same parameters, rest and return lists. A method that differs in any of them is the call of one of
--- several functions, which only a test of the value tells apart.
function GenericCalls.union_method(ctx: Ctx, node: Ast.MethodCall, u: Union): Type?, {Type}?
  local store = ctx.store
  local common: {Type}? = nil
  local first: Type? = nil
  local first_declared: Type = ctx.invalid
  for _, m in ipairs(u.members) do
    -- A member that is text (an enum or `string`) has the functions of `string`, which only a call reaches.
    if not is_text(m) and (not ((m.tag == "named")) or member_types(ctx, m, node.name) == nil) then
      report(ctx, "field_unknown", node, quoted(node.name) .. " is not a field of " .. tq(ctx, m) .. ", a member of " ..
          tq(ctx, u),
        "narrow the value to the member that has it (`x.kind == \"...\"` or `x is T`), or declare " .. quoted(node.name) ..
          " in every member", { show(ctx, u) })
      return nil, nil
    end
    ctx.cands, ctx.cand_node = nil, nil
    local read = member_read(ctx, node, m, node.name)
    local declared: {Type} = { read }
    if ctx.cand_node == node and ctx.cands ~= nil then
      declared = ctx.cands -- checked: nil_not_allowed
    end
    ctx.cands, ctx.cand_node = nil, nil
    if read.tag == "invalid" then
      return nil, nil
    end
    local replaced: mut {Type} = {}
    for i, each in ipairs(declared) do
      local f = each
      local receiver: Types.Param? = nil
      if f.tag == "fn" then
        receiver = f.params[1]
      end
      if (f.tag == "fn") and receiver ~= nil and receiver.type == m and not is_text(m) then
        local params: mut {Types.Param} = {}
        for j, p in ipairs(f.params) do
          params[j] = p
        end
        params[1] = { type = u, omittable = receiver.omittable }
        f = store:fn({ tparams = f.tparams, params = params, rest = f.rest, rets = f.rets })
      end
      replaced[i] = f
    end
    local held = common
    if held == nil then
      common = replaced
      first = m
      first_declared = declared[1] or read
    else
      local agree = #held == #replaced
      for i = 1, if agree then #held else 0 end do
        agree = agree and held[i] == replaced[i]
      end
      if not agree then
        local other = first
        report(ctx, "not_callable", node, subject(ctx, node) .. " calls the method " .. quoted(node.name) .. " of each member " ..
            "of " .. tq(ctx, u) .. ", and " .. tq(ctx, other ~= nil and other or m) .. " and " .. tq(ctx, m) .. -- checked: and_ternary
            " declare it differently: " .. quoted(show(ctx, first_declared)) .. " and " ..
            quoted(show(ctx, declared[1] or read)),
          "narrow the value to one member first (`x.kind == \"...\"` or `x is T`), or declare " .. quoted(node.name) ..
            " the same in every member", { show(ctx, first_declared), show(ctx, declared[1] or read) })
        return nil, nil
      end
    end
  end
  local list = common
  if list == nil or list[1] == nil then
    return nil, nil
  end
  return list[1], #list > 1 and list or nil -- checked: and_ternary
end

--- The Teal the overloads are written in, for `overload_none`.
function GenericCalls.overload_line(ctx: Ctx, f: Type, why: string): string
  return Types.display(f, ctx.binders, ctx.fn_names) .. (if why ~= "" then ": " .. why else "" end)
end

return GenericCalls
