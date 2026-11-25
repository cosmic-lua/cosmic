--- The types of functions: their parameters, what they return, and the narrowing a function proves.

local Ast = require("lang.ast")
local Flow = require("lang.flow")
local Lexer = require("lang.lexer")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local Names = require("lang.check.names")
local Tests = require("lang.check.tests")
local type Type = Types.Type
local type Fn = Types.Fn
local type Alt = Types.Alt
local type Ctx = Context.Ctx
local below = Context.below
local id_key = Context.id_key
local quoted = Context.quoted
local report = Naming.report
local show = Context.show
local subject = Context.subject
local tq = Context.tq
local unknown_lists = Names.unknown_lists

local record Functions
end

function Functions.rtype_base(item: Ast.RType): Ast.Base
  return item
end
local rtype_base = Functions.rtype_base

--- The return alternatives a written return list stands for, from the types the lowering gave its items.
local function alts_of_rets(ctx: Ctx, rets: Ast.Rets): {Alt}
  local alts: mut {Alt} = {}
  for _, list in ipairs(rets.lists) do
    local alt: Alt = { items = {} }
    local never = false
    for i, item in ipairs(list) do
      local t = ctx.store.boolean
      if not ((item.kind == "Narrows")) then
        t = ctx.lowered.types[rtype_base(item).id] or ctx.invalid
      end
      if t.tag == "never" then
        never = true
      elseif rets.variadic and i == #list then
        alt.tail = t -- checked: field_fixed
      else
        alt.items[#alt.items + 1] = t -- checked: view_written
      end
    end
    if not never then
      alts[#alts + 1] = alt
    end
  end
  return alts
end

--- The one function type of `expected`, or nil: the type itself, or the function of an optional.
local function expected_function(ctx: Ctx, expected: Type?): Fn?
  if expected == nil then
    return nil
  end
  local t = ctx.store:non_nil(expected)
  if (t.tag == "fn") and #t.tparams == 0 then
    return t
  end
  return nil
end

--- The type of the function written as `fn`. Its parameters are typed by its annotations, and by `expected` where a
--- literal leaves one out; a return list it leaves out is the one `expected` has. A parameter with neither is
--- `invalid` and reported.
function Functions.function_type(ctx: Ctx, fn: Ast.Fn, expected: Type?, name: string): Type
  local ex = expected_function(ctx, expected)
  local lowered = ctx.lowered.types[fn.id]
  if lowered ~= nil and (fn.rets ~= nil or ex == nil) then
    return lowered
  end
  local params: mut {Types.Param} = {}
  local rest: Type? = nil
  local ex_rest = ex ~= nil and ex.rest or nil -- checked: and_ternary
  for _, p in ipairs(fn.params) do
    local given = p.type
    local written = given ~= nil and ctx.lowered.types[given.id] or nil -- checked: and_ternary
    local j = #params + 1
    local t = ctx.invalid
    local omittable = p.optional
    if written ~= nil then
      t = written
    elseif not p.variadic and ex ~= nil and ex.params[j] ~= nil then
      t = ex.params[j].type
      omittable = omittable or ex.params[j].omittable == true
    elseif p.variadic and ex_rest ~= nil then
      t = ex_rest
    else
      if ctx.lenient == 0 then
        local binding = p.name
        report(ctx, "param_untyped", p, "the parameter " .. quoted(binding ~= nil and binding.name or "...") .. " of " .. -- checked: and_ternary
            name .. " has no type, and no function type is expected here to give it one",
          "write the type: `" .. (binding ~= nil and binding.name or "...") .. ": T`; a function literal passed " .. -- checked: and_ternary
            "where a function type is expected takes its parameter types from it")
      end
    end
    if p.variadic then
      rest = t
    else
      params[#params + 1] = { type = t, omittable = omittable }
    end
  end
  local alts: {Alt}? = nil
  local written_rets = fn.rets
  if written_rets ~= nil then
    alts = alts_of_rets(ctx, written_rets)
  elseif ex ~= nil then
    alts = ex.rets
  end
  return ctx.store:fn({ params = params, rest = rest, rets = alts })
end

--- The lists of values `alts` holds, as a program writes them.
function Functions.lists_text(ctx: Ctx, alts: {Alt}): string
  local lists: mut {string} = {}
  for i, alt in ipairs(alts) do
    local items: mut {string} = {}
    for j, t in ipairs(alt.items) do
      items[j] = show(ctx, t)
    end
    local tail = alt.tail
    if tail ~= nil then
      items[#items + 1] = show(ctx, tail) .. "..."
    end
    lists[i] = "(" .. table.concat(items, ", ") .. ")"
  end
  return table.concat(lists, " | ")
end
local lists_text = Functions.lists_text

--- Whether a function that returns `alts` may return no value: one of its lists is empty.
local function may_end(alts: {Alt}): boolean
  for _, alt in ipairs(alts) do
    if #alt.items == 0 then
      return true
    end
  end
  return false
end

--- The type of the place `key` in `f`: what it was narrowed to, else `declared`.
local function fact_type(f: Flow.State, key: string, declared: Type): Type
  local fact = f.facts[key]
  if fact ~= nil then
    return fact.type
  end
  return declared
end

--- Checks that the function being checked makes good the narrowing it declares at `node`, a `return` or its end. A
--- function declared `v is T` returns true only where `v` is a `T` and false only where it is not: the edges of the
--- value returned say so. One declared `asserts v is T` returns only where `v` is a `T`.
function Functions.narrows_proved(ctx: Ctx, node: Ast.Node, value: Ast.Exp?)
  local frame = ctx.frames[#ctx.frames]
  local nr = frame.narrows -- checked: nil_not_allowed
  local declared = frame.narrowed_type -- checked: nil_not_allowed
  if nr == nil or declared == nil or ctx.quiet > 0 or not ctx.flow.live then
    return
  end
  local key = id_key(ctx, frame.narrowed_id) -- checked: nil_not_allowed
  local want = nr.to
  local name = frame.narrowed_name -- checked: nil_not_allowed
  if nr.asserts then
    local got = fact_type(ctx.flow, key, declared)
    if not below(ctx, got, want) then
      report(ctx, "narrows_unproved", node, "this function is declared `asserts " .. name .. " is " .. show(ctx, want) ..
          "`, and here it returns with " .. quoted(name) .. " still " .. tq(ctx, got),
        "test the parameter and stop where it is not " .. tq(ctx, want) .. " (`if not (v is T) then error(...) end`), or " ..
          "declare the narrowing the test proves", { show(ctx, got), show(ctx, want) })
    end
    return
  end
  if value == nil then
    return
  end
  local yes, no = ctx.walk.edges(ctx, ctx.flow, value)
  local got = fact_type(yes, key, declared)
  if yes.live and not below(ctx, got, want) then
    report(ctx, "narrows_unproved", node, "this function is declared `" .. name .. " is " .. show(ctx, want) ..
        "`, and " .. subject(ctx, value) .. " does not show it when true: " .. quoted(name) .. " is then " .. tq(ctx, got),
      "return a test that decides " .. tq(ctx, want) .. " (`return v is T`, `return v.kind == \"...\"`), or declare the " ..
        "function `boolean`", { show(ctx, got), show(ctx, want) })
    return
  end
  local rest = Tests.drop_is(ctx, declared, want)
  local left = fact_type(no, key, declared)
  if no.live and not below(ctx, left, rest) then
    report(ctx, "narrows_unproved", node, "this function is declared `" .. name .. " is " .. show(ctx, want) ..
        "`, and " .. subject(ctx, value) .. " does not show it is not " .. tq(ctx, want) .. " when false: " ..
        quoted(name) .. " is then " .. tq(ctx, left),
      "return a test that decides " .. tq(ctx, want) .. " both ways (`return v is T`), or declare the function " ..
        "`boolean`", { show(ctx, left), show(ctx, rest) })
  end
end
local narrows_proved = Functions.narrows_proved

--- The fix for the local `name` of type `t` that is read before it is assigned. A function declared ahead for a
--- function that calls it before it is defined is the functions of a record, which one body may call before another is
--- defined.
function Functions.assign_fix(ctx: Ctx, name: string, t: Type, own: boolean): string
  if (t.tag == "fn") and own then
    return "declare " .. quoted(name) .. " where it is defined, `local function " .. name .. "(...)`, which a function " ..
      "may call itself in"
  elseif (t.tag == "fn") then
    return "define " .. quoted(name) .. " before the function that names it is made, or make the functions that call " ..
      "each other the functions of a record declared first (`local record Walk end`, `function Walk.visit(...)`)"
  end
  return "assign " .. quoted(name) .. " on every path before this read, give it a value where it is declared (`local " ..
    name .. ": " .. show(ctx, t) .. " = ...`), or declare it `" .. show(ctx, ctx.store:optional(t)) .. "`, which is nil " ..
    "until assigned and is checked where it is used"
end
local assign_fix = Functions.assign_fix

--- Notes that making the function `fn_id` reads each local of the code around it that it names, and reports one that no
--- path has assigned yet.
local function read_at_creation(ctx: Ctx, fn_id: integer, whole: Ast.Node)
  local list = ctx.reads[fn_id]
  if list == nil or ctx.flow.unsets == 0 then
    return
  end
  local tokens = ctx.tokens
  for _, v in ipairs(list) do
    if ctx.flow.unset[v.id] == true then
      local t = ctx.vars[v.id]
      report(ctx, "not_assigned", whole, "this function names " .. quoted(v.name) .. ", which no path has assigned yet, and " ..
          "making a function reads what it names",
        t ~= nil and assign_fix(ctx, v.name, t, ctx.assigning[v.id] == true) or "assign " .. quoted(v.name) .. " before this function is made", -- checked: and_ternary
        { t ~= nil and show(ctx, t) or "" }, -- checked: and_ternary
        { y = Lexer.y(tokens, v.declared), x = Lexer.x(tokens, v.declared), offset = Lexer.offset(tokens, v.declared),
          length = Lexer.length(tokens, v.declared) })
      ctx.flow = Flow.assigned(ctx.flow, v.id)
    end
  end
end

--- Checks a function body: its parameters are the variables of the types in `ft`, its `return`s are checked against
--- `ft`'s return list. `names` are the type parameters of a generic function, for display. The body starts from the
--- facts of the code around it that hold inside it ([`Flow.State`]'s `enter`), and a function that returns values
--- reaches its end only where the flow does not.
function Functions.function_body(ctx: Ctx, params: {Ast.Param}, body: Ast.Block, ft: Type, names: {string}, whole: Ast.Node,
                                 declared: boolean, fn_id: integer, owner: string)
  read_at_creation(ctx, fn_id, whole)
  if ctx.quiet > 0 then
    -- A pass that is settling a loop reports nothing, and a function's body changes nothing of the code around it.
    return
  end
  local f: Fn? = (ft.tag == "fn") and ft or nil -- checked: and_ternary
  local generic = f ~= nil and #f.tparams > 0
  if generic and f ~= nil then
    ctx.fn_names[f.id] = Types.kept_names(ctx.fn_names[f.id], names)
    ctx.judge:enter(f.tparams)
    ctx.binders[#ctx.binders + 1] = names
    ctx.bounds[#ctx.bounds + 1] = f.tparams
  end
  local j = 0
  local narrows: Types.Narrows? = nil
  local alts: {Alt} = f ~= nil and f.rets or unknown_lists(ctx) -- checked: and_ternary
  if #alts == 1 and alts[1].narrows ~= nil then
    narrows = alts[1].narrows
  end
  local narrowed_id = 0
  local narrowed_name = ""
  local narrowed_type: Type? = nil
  for _, p in ipairs(params) do
    if not p.variadic then
      j = j + 1
      local binding = p.name
      if binding ~= nil then
        ctx.vars[binding.id] = f ~= nil and f.params[j] ~= nil and f.params[j].type or ctx.invalid -- checked: and_ternary
        local given: Types.Param? = nil
        if f ~= nil then
          given = f.params[j]
        end
        -- Only a type the program writes is a declaration to hold a value to: a function literal's parameter that takes
        -- its type from the context (`table.sort(t, function(a, b) ... end)`) declares none.
        if given ~= nil and p.type ~= nil and given.type.tag ~= "any" and binding.name ~= "self" then
          ctx.boundaries[binding.id] = {
            id = fn_id, role = "parameter", name = binding.name, param = j, owner = owner, type = given.type,
            optional = p.optional or given.omittable == true, at = Lexer.offset(ctx.tokens, whole.first),
          }
        end
        if narrows ~= nil and narrows.param == j then
          narrowed_id, narrowed_name, narrowed_type = binding.id, binding.name, ctx.vars[binding.id]
          local assigned = ctx.scoped.vars[binding.id]
          if assigned ~= nil and assigned.assigned then
            report(ctx, "narrows_unproved", whole, "this function assigns " .. quoted(binding.name) .. ", the parameter it narrows, so " ..
                "what its body shows is about the new value and not the argument",
              "do not assign the parameter: copy it to a local and assign that")
          end
        end
      end
    end
  end
  local rest: Type? = ctx.invalid
  if f ~= nil then
    rest = f.rest
  end
  ctx.frames[#ctx.frames + 1] = {
    alts = alts, rest = rest, chunk = false, declared = declared, narrows = narrows, narrowed_id = narrowed_id,
    narrowed_name = narrowed_name, narrowed_type = narrowed_type,
  }
  local saved = ctx.lenient
  ctx.lenient = 0
  local outer_within = ctx.within
  ctx.within = fn_id
  local outer, outer_loops, outer_ranges = ctx.flow, ctx.loops, ctx.ranges
  ctx.flow, ctx.loops, ctx.ranges = Flow.enter(outer, ctx.unfixed[fn_id]), {}, {}
  local outer_unfixed = ctx.unfixed_now
  local unfixed_now: mut {integer: boolean} = {}
  for id in pairs(outer_unfixed) do
    unfixed_now[id] = true
  end
  for id in pairs(ctx.unfixed[fn_id] or {}) do
    unfixed_now[id] = true
  end
  ctx.unfixed_now = unfixed_now
  -- The scope of a `<close>` local around the function is not open while it runs.
  local outer_closers = ctx.closers
  ctx.closers = 0
  ctx.walk.block(ctx, body)
  ctx.closers = outer_closers
  ctx.unfixed_now = outer_unfixed
  if ctx.flow.live then
    local last = body.stats[#body.stats]
    local at: Ast.Node = last ~= nil and last or whole -- checked: and_ternary
    if f ~= nil and not may_end(alts) then
      if #alts == 0 then
        report(ctx, "missing_return", at, "this function is declared `never`, and control can reach its end",
          "end every path with `error(...)` or a call of a function that never returns, or declare the return list the " ..
            "function answers")
      else
        local lists = lists_text(ctx, alts)
        report(ctx, "missing_return", at, "control can reach the end of this function, which answers " .. lists .. ", with no " ..
            "`return`",
          "end every path with a `return` of " .. lists .. " (or `error(...)`), or declare the function without a return list",
          { lists })
      end
    elseif narrows ~= nil then
      narrows_proved(ctx, at, nil)
    end
  end
  ctx.flow, ctx.loops, ctx.ranges = outer, outer_loops, outer_ranges
  ctx.lenient = saved
  ctx.within = outer_within
  ctx.frames[#ctx.frames] = nil
  if generic then
    ctx.judge:leave()
    ctx.binders[#ctx.binders] = nil
    ctx.bounds[#ctx.bounds] = nil
  end
end

return Functions
