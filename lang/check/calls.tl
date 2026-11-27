--- The checks of calls: the arguments against the parameters, overloads, methods, and the types of the library's functions.

local Ast = require("lang.ast")
local Generics = require("lang.generics")
local Literals = require("lang.literals")
local LoadOrder = require("lang.load_order")
local Relation = require("lang.relation")
local type Sql = require("lang.sql")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local Refusals = require("lang.check.refusals")
local Names = require("lang.check.names")
local Lookup = require("lang.check.members")
local ValueLists = require("lang.check.values")
local Tests = require("lang.check.tests")
local Functions = require("lang.check.functions")
local GenericCalls = require("lang.check.generic_calls")
local Operands = require("lang.check.operands")
local Unfilled = require("lang.check.unfilled")
local type Codes = require("lang.check_codes")
local type Type = Types.Type
local type Named = Types.Named
local type Fn = Types.Fn
local type Alt = Types.Alt
local type Decl = Types.Decl
local type Ctx = Context.Ctx
local accepts = Context.accepts
local base_of = Context.base_of
local below = Context.below
local is_bool = Context.is_bool
local is_text = Context.is_text
local members_of = Context.members_of
local nilable = Context.nilable
local peel = Context.peel
local quoted = Context.quoted
local report = Naming.report
local show = Context.show
local subject = Context.subject
local text_of = Context.text_of
local tq = Context.tq
local type Values = ValueLists.Values
local expect = Refusals.expect
local expect_argument = Refusals.expect_argument
local first_value = ValueLists.first_value
local function_body = Functions.function_body
local function_type = Functions.function_type
local holds_boolean = Refusals.holds_boolean
local members_index = Lookup.members_index
local names_invalid = Refusals.names_invalid
local overload_line = GenericCalls.overload_line
local put_in = Lookup.put_in
local refused = Refusals.refused
local rtype_base = Functions.rtype_base
local unchecked_arguments = Names.unchecked_arguments
local unknown_lists = Names.unknown_lists
local values_of = ValueLists.values_of

--- What the arguments of a call are before the function it calls is taken.
local record Prepared
  --- The type of each argument that is not a literal, by position; the values the last argument expands to follow the
  --- others.
  known: mut {integer: Type}
  --- The literal arguments, by position: their type depends on the position they stand in, so they are typed once the
  --- function is taken.
  pending: mut {integer: boolean}
  --- How many positions the arguments fill, the last one's values included.
  mut count: integer
  --- Set when the last argument is a call or `...` that ends in `T...`.
  mut tail: Type?
  --- Whether the last argument may add values (a call or `...`).
  open: boolean
  --- The lists of a last argument that returns several, which are no values.
  mut lists: {Alt}?
  --- The last argument, when it was expanded.
  mut last: Ast.Exp?
end

--- A bound a type does not meet, as `bound_unmet` words it.
local record Unmet
  message: string
  fix: string
  --- Each type that fails a bound and the bound, as shown.
  shown: {string}
  --- The argument the generic function is, and its instance with the bounds waived.
  arg: integer
  instance: Fn
end

local record Instance
  fn: Fn?
  why: string
  --- The type parameters that a shape the arguments lack left with no type, and nothing else reported (the instance
  --- holds `invalid` for them).
  holes: {integer}?
  --- One for each generic function passed as an argument that could not be taken because a type it was found for does
  --- not meet its bound: what `bound_unmet` says of it.
  unmets: {Unmet}?
end

--- The steps of a generic call.
local record Calls
  --- The mode of `setmetatable({}, { __mode = "k" })`, the one call of `setmetatable` a program makes, which makes a
  --- weak table: an empty literal, and a literal whose one item is `__mode` with "k", "v" or "kv". Nil for any other
  --- arguments. A weak "v" map may lose a value at any allocation, so the checker must never narrow a map index read
  --- (`m[k] ~= nil` then `m[k]`): only arrays have element facts, and no array is weak.
  weak_mode: function(args: {Ast.Exp}): string?
  prepare: function(ctx: Ctx, args: {Ast.Exp}, wants: {integer: Type}?, asserting?: string, early?: {integer: Type}): Prepared
  asserted: function(ctx: Ctx, alts: {Alt}, by_nil?: boolean): Alt?
  --- Notes that the call `node` runs no code of the program through the standard library: it was given a `string` receiver
  --- or none, and arguments of the types `types` and the `tail` an expanding last one gives, all plain ([`Tests.plain`]).
  note_plain: function(ctx: Ctx, node: Ast.Node, recv: Type?, types: {Type}, tail: Type?, lists: {Alt}?)
  replace_type: function(list: mut {Type}, at: integer, t: Type)
  spill_note: function(ctx: Ctx, args: {Ast.Exp}, n: integer, position: integer, arity?: boolean): string?
  hooks: function(ctx: Ctx): Generics.Hooks
  source: function(at: integer): string
  typed_literal: function(e: Ast.Exp): boolean
  shown: function(ctx: Ctx, declared: Fn, t: Type): string
  sparse: function(t: Type): Type?
  holes: function(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, solved: Instance, before: integer)
  --- What to do where no overload of a function takes the arguments, for a function whose overloads cannot say.
  fixes: {string: string}
  solve: function(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, args: {Ast.Exp}, prep: Prepared, off: integer,
                  recv: Type?, expected: Type?, loud: boolean): Instance
  generic: function(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, args: {Ast.Exp}, recv: Type?,
                    recv_node: Ast.Node?, expected: Type?): {Alt}
  plain_place: function(e: Ast.Exp): boolean
  library_call: function(ctx: Ctx, callee_node: Ast.Node, node: Ast.Node, args: {Ast.Exp}, recv: Type?, recv_node: Ast.Node?):
    Literals.Call?
  literal_text: function(ctx: Ctx, e: Ast.Node): string?
  library_value: function(ctx: Ctx, e: Ast.Node): string?
  lacking: function(ctx: Ctx, held: Type, bound: Type): string?
  kind_type: function(ctx: Ctx, kind: string): Type
  refine: function(ctx: Ctx, call: Literals.Call, f: Fn): Fn
  refine_overloads: function(ctx: Ctx, call: Literals.Call, list: {Type}): {Type}
  literal_arguments: function(ctx: Ctx, call: Literals.Call, node: Ast.Node, args: {Ast.Exp}, recv_node: Ast.Node?)
  gsub_key: function(ctx: Ctx, c: Fn, args: {Ast.Exp}, off: integer, key: string)
  method_dot: function(ctx: Ctx, n: Ast.Call, callee: Type, object: Type)
  expect_argument: function(ctx: Ctx, node: Ast.Node, got: Type, want: Type, callee: string, position: integer, named?: string, generic?: boolean):
    boolean
  dispatch: function(ctx: Ctx, node: Ast.Node, callee_node: Ast.Node, callee: string, ft: Type, cands: {Type}?,
                     args: {Ast.Exp}, recv: Type?, recv_node: Ast.Node?, expected: Type?): {Alt}
  type Prepared = Prepared
  type Unmet = Unmet
  type Instance = Instance
end

--- A function literal: its type, and its body checked.
function Calls.function_literal(ctx: Ctx, e: Ast.FunctionLit, expected: Type?): Type
  local ft = function_type(ctx, e.fn, expected, "this function")
  function_body(ctx, e.fn.params, e.fn.body, ft, {}, e, e.fn.rets ~= nil, e.fn.id, "function")
  if ctx.load.waiting > 0 and ctx.load.given[e.id] ~= true then
    LoadOrder.mention(ctx.load, ctx.within, e, LoadOrder.of_function(e.fn.id, "the function written here"))
  end
  return ft
end

--- Whether an argument is a literal, whose type depends on the position it stands in.
local function is_literal(e: Ast.Exp): boolean
  local at = peel(e)
  if (at.kind == "IfExp") then
    -- Its type is its arms': a literal where one of them is.
    for _, arm in ipairs(at.arms) do
      if is_literal(arm.value) then
        return true
      end
    end
    return is_literal(at.else_value)
  end
  return (at.kind == "Table") or (at.kind == "FunctionLit") or (at.kind == "String") or (at.kind == "Boolean")
end

function Calls.plural(n: integer, word: string): string
  return tostring(n) .. " " .. word .. (if n == 1 then "" else "s" end)
end
local plural = Calls.plural

--- Whether a function literal takes the arguments a call of `g` passes: every count from the required parameters of
--- `g` to all of them (and any more where it has a rest parameter), as the relation meets a call's argument list
--- exactly. A parameter the literal leaves untyped takes its type and whether it may be omitted from the position, so
--- the position has to have it, and it is never the one that requires an argument.
local function arguments_fit(lit: Ast.FunctionLit, g: Fn): boolean
  local total, last_required, last_untyped, rest, rest_untyped = 0, 0, 0, false, false
  for _, p in ipairs(lit.fn.params) do
    if p.variadic then
      rest = true
      rest_untyped = p.type == nil
    else
      total = total + 1
      if p.type == nil then
        last_untyped = total
      elseif not p.optional then
        last_required = total
      end
    end
  end
  if last_untyped > #g.params or (rest_untyped and g.rest == nil) then
    return false
  end
  local needed = 0
  for pos, p in ipairs(g.params) do
    if p.omittable ~= true then
      needed = pos
    end
  end
  return last_required <= needed and (#g.params <= total or rest) and (g.rest == nil or rest)
end

--- Whether the enum `m` has the member `value`, or has no body to say.
local function enum_holds(m: Named, value: string): boolean
  local body = m.decl.body
  if body == nil then
    return true
  end
  for _, v in ipairs(body.values) do
    if v == value then
      return true
    end
  end
  return false
end

--- Whether the return lists a function literal writes have as many values as some list of `g` returns (the relation meets
--- the returns of a function by the number of values), or the literal writes none and takes `g`'s.
local function returns_fit(ctx: Ctx, lit: Ast.FunctionLit, g: Fn): boolean
  local written = lit.fn.rets
  if written == nil then
    return true
  end
  for _, list in ipairs(written.lists) do
    local never = false
    for _, item in ipairs(list) do
      if not ((item.kind == "Narrows")) then
        local t = ctx.lowered.types[rtype_base(item).id]
        never = never or (t ~= nil and t.tag == "never")
      end
    end
    if not never then
      local values = #list - (if written.variadic then 1 else 0 end)
      local fits = false
      for _, alt in ipairs(g.rets) do
        fits = fits or (#alt.items == values and (alt.tail ~= nil) == written.variadic)
      end
      if not fits then
        return false
      end
    end
  end
  return true
end

--- Whether the literal `e` could be a value of `want`: its form fits, which is all a position can tell of a literal
--- before it is checked against the overload. A function literal fits a function type whose calls it takes, and a
--- string literal a `string` or an enum that has it, which tells overloads of enums apart.
local function literal_fits(ctx: Ctx, written: Ast.Exp, want: Type): boolean
  if want.tag == "any" or want.tag == "invalid" then
    return true
  end
  local e = peel(written)
  if (e.kind == "IfExp") then
    -- Each arm that is a literal fits; an arm that is not says nothing yet.
    for _, arm in ipairs(e.arms) do
      if is_literal(arm.value) and not literal_fits(ctx, arm.value, want) then
        return false
      end
    end
    return not is_literal(e.else_value) or literal_fits(ctx, e.else_value, want)
  end
  for _, m in ipairs(members_of(ctx.store, want)) do
    if (e.kind == "FunctionLit") then
      if (m.tag == "fn") and (#m.tparams > 0 or arguments_fit(e, m)) and returns_fit(ctx, e, m) then
        return true
      end
    elseif (e.kind == "Table") then
      if (m.tag == "array") or (m.tag == "map") or (m.tag == "named") or (m.tag == "var") then
        return true
      end
    elseif (e.kind == "String") then
      if m.tag == "string" or ((m.tag == "named") and m.decl.kind == "enum" and enum_holds(m, e.value)) then
        return true
      end
    elseif (e.kind == "Boolean") then
      if is_bool(m) then
        return true
      end
    else
      return true
    end
  end
  return false
end

--- Why `f` cannot be called with `n` known arguments (and a receiver where `off` is 1), or nil. `open` says the last
--- argument may add values: those it is known to give are in `n`, so a surplus among them is certain, and a missing one
--- is not (the tail fills it, [`tail_problem`] checks that).
local function arity_problem(f: Fn, off: integer, n: integer, open: boolean): string?
  local np = #f.params
  if n + off > np and f.rest == nil then
    return "too many"
  end
  if not open then
    for pos = n + off + 1, np do
      if f.params[pos].omittable ~= true then -- checked: nil_not_allowed
        return "too few"
      end
    end
  end
  return nil
end

--- Where the `tail` (`T...`) that the last argument of a call ends in does not fit what it fills, or nil: the call
--- passes `n` values (a receiver where `off` is 1) before it, so the tail gives the parameters from `n + 1` and then the
--- rest parameter. A parameter it may leave empty takes `T?`, and the rest parameter takes `T`. Returns the position of
--- the argument (from 1, after the receiver), the type wanted there, and whether the tail fits that type and only the
--- missing value is the fault.
local function tail_problem(ctx: Ctx, f: Fn, off: integer, n: integer, tail: Type, strict?: boolean): integer?, Type?, boolean
  if tail.tag == "invalid" then
    return nil, nil, false
  end
  local maybe = ctx.store:optional(tail)
  local np = #f.params - off
  for pos = n + 1, np do
    local want = f.params[pos + off].type -- checked: nil_not_allowed
    if strict == true then
      -- a function that raises where a value is missing, nil or not: the tail may be empty
      return pos, want, true
    elseif want.tag ~= "any" then
      if not below(ctx, tail, want) then
        return pos, want, false
      elseif not below(ctx, maybe, want) then
        return pos, want, true
      end
    end
  end
  local rest = f.rest
  if rest ~= nil and rest.tag ~= "any" and not below(ctx, tail, rest) then
    return math.max(n + 1, np + 1), rest, false
  end
  return nil, nil, false
end

--- Reports a call with the wrong number of arguments.
local function arity_error(ctx: Ctx, node: Ast.Node, callee: string, f: Fn, off: integer, n: integer, why: string)
  local np = #f.params - off
  local required = 0
  for pos = 1 + off, #f.params do
    if f.params[pos].omittable ~= true then -- checked: nil_not_allowed
      required = pos - off
    end
  end
  if why == "too many" then
    report(ctx, "arity", node, callee .. " takes " .. plural(np, "argument") .. ", but " .. tostring(n) .. " " ..
        (if n == 1 then "is" else "are" end) .. " given",
      "remove the extra " .. (if n - np == 1 then "argument" else "arguments" end) .. ", or declare the parameter in the function " ..
        "type", { Types.display(f, ctx.binders, ctx.fn_names) })
  else
    local missing = f.params[n + off + 1]
    report(ctx, "arity", node, callee .. " takes " .. (if required < np then tostring(required) .. " to " .. plural(np, "argument") else
      plural(required, "argument") end) .. ", but " .. tostring(n) .. " " .. (if n == 1 then "is" else "are" end) .. " given",
      "pass the missing argument " .. tostring((n + 1)) .. (if missing ~= nil then ", " .. tq(ctx, missing.type) else "" end) ..
        ", or declare the parameter `name?: T`", { Types.display(f, ctx.binders, ctx.fn_names) })
  end
end

--- The type the call's position `i` (from 1, after the receiver) wants of `f`.
local function parameter_at(f: Fn, off: integer, i: integer): Type?
  local p = f.params[i + off]
  if p ~= nil then
    return p.type
  end
  return f.rest
end

--- Checks the receiver of a method call against the first parameter of `f`.
local function check_receiver(ctx: Ctx, f: Fn, callee: string, recv: Type, recv_node: Ast.Node)
  local p1 = f.params[1]
  if p1 == nil then
    report(ctx, "arity", recv_node, callee .. " takes no receiver, so it cannot be called with `:`",
      "call it with `.`: it is a function of its module, not a method")
  else
    local _ = expect(ctx, recv_node, recv, p1.type, " as the receiver of " .. quoted(callee))
  end
end

--- [`expect_argument`] for argument `position` of a call of `callee`: an error it reports says so ([`Codes.Argument`]).
function Calls.expect_argument(ctx: Ctx, node: Ast.Node, got: Type, want: Type, callee: string, position: integer,
                               named?: string, generic?: boolean): boolean
  ctx.argument = { callee = callee, module = ctx.callee_module, position = position }
  ctx.no_drop = generic == true
  local ok = expect_argument(ctx, node, got, want, " as argument " .. tostring(position) .. " of " .. quoted(callee), named)
  ctx.no_drop = false
  ctx.argument = nil
  return ok
end

--- Overwrites the element `at` of `list`, which must have it: `table.insert` refuses a position past the end, so no
--- hole can come of a position that is wrong.
function Calls.replace_type(list: mut {Type}, at: integer, t: Type)
  assert(at >= 1 and at <= #list)
  table.remove(list, at)
  table.insert(list, at, t)
end

--- Types the arguments of a call that are not literals, and notes the literals. `wants` are the types a position expects
--- where the callee is known to expect one.
---
--- Given `asserting`, the name of the callee `assert` or `must`, a last argument that returns several lists gives the
--- values of the one list whose first value is never nil or false (for `must`, never nil): the callee raises at any
--- other, so `assert(Fs.read(path))` is the text, and `Json.decode(text)!` the value.
function Calls.prepare(ctx: Ctx, args: {Ast.Exp}, wants: {integer: Type}?, asserting?: string, early?: {integer: Type}): Prepared
  local n = #args
  local last = args[n]
  local open = last ~= nil and ((last.kind == "Call") or (last.kind == "MethodCall") or (last.kind == "Vararg"))
  local prep: Prepared = { known = {}, pending = {}, count = n, open = open } -- checked: literal_missing
  -- The arguments before an expanding last one are typed as the others; the last one gives the values it is known to
  -- give, and the tail.
  local written = if open then n - 1 else n end
  for i = 1, written do
    local a = assert(args[i], "an argument is within the count")
    local before = if early ~= nil then early[i] else nil end
    if before ~= nil then
      prep.known[i] = before
    elseif is_literal(a) then
      prep.pending[i] = true
    else
      prep.known[i] = ctx.walk.expr(ctx, a, if wants ~= nil then wants[i] else nil end)
    end
  end
  if open and last ~= nil then
    -- The last argument stands alone, so what its position wants is the first want.
    local alone: mut {integer: Type} = {}
    local lone = if wants ~= nil then wants[n] else nil end
    if lone ~= nil then
      alone[1] = lone
    end
    local vals = values_of(ctx, { last }, if wants ~= nil then alone else nil end, nil)
    local several = vals.lists
    if several ~= nil and asserting ~= nil then
      local passed = ValueLists.asserted(ctx, several, asserting == "must")
      if passed ~= nil then
        for _, item in ipairs(passed.items) do
          vals.types[#vals.types + 1] = item
        end
        vals.tail = passed.tail
        vals.lists = nil
        several = nil
      end
    end
    for j, t in ipairs(vals.types) do
      prep.known[written + j] = t
    end
    prep.count = written + #vals.types
    prep.tail = vals.tail
    prep.last = vals.last
    if several ~= nil and asserting ~= nil then
      -- `assert` raises at a nil or a false first value, so it passes a list only where that value is neither; `must`
      -- (`e!`) raises at a nil one alone.
      prep.lists = several
      local call = Naming.call(ctx, last)
      local said = if asserting == "must" then
        "`" .. call .. "!` tells none of them apart from the others: `!` passes one list whose first value is never nil " ..
          "where the first value of each other list is `nil`, and these lists are not so"
        else
        "`assert` tells none of them apart from the others: it passes one list whose first value is never nil or " ..
          "false where the first value of each other list is `nil` or `false`, and these lists are not so"
        end
      report(ctx, "alternatives_as_value", last, subject(ctx, last) .. " answers one of " .. tostring(#several) ..
          " lists of values, and " .. said,
        "bind its values and test the one that tells the lists apart (`local " .. Naming.bound(several) .. " = " .. call ..
          "`), or match the call: `match " .. call .. " do | ... end`")
      -- The argument is reported: it stands as no type, so no overload is refused for lacking it.
      prep.known[written + 1] = ctx.invalid
      prep.count = written + 1
    elseif several ~= nil then
      prep.lists = several
      local _ = first_value(ctx, last, several)
    end
  end
  return prep
end

--- The field of the interface `bound` that `held` lacks, as the interface declares it (`mut name?: T`), or nil.
function Calls.lacking(ctx: Ctx, held: Type, bound: Type): string?
  local r = ctx.judge:refuse(held, bound)
  local field = if r ~= nil then r.field else nil end
  if field == nil then
    return nil
  end
  return (if field.mut == true then "mut " else "" end) .. field.name .. (if field.omittable == true then "?" else "" end) ..
    ": " .. show(ctx, if field.omittable == true then ctx.store:non_nil(field.type) else field.type end)
end

--- The name of the type parameter at `index` (from 1) of the callee `declared`, as its author wrote it where that name
--- is free, or its letter.
function Calls.parameter_name(ctx: Ctx, declared: Fn, index: integer): string
  local own = ctx.fn_names[declared.id]
  if own ~= nil and #own == #declared.tparams and Naming.free_of(ctx.binders, own) then
    return assert(own[index])
  end
  return Types.letter(index - 1)
end

function Calls.shown(ctx: Ctx, declared: Fn, t: Type): string
  if #declared.tparams == 0 then
    return show(ctx, t)
  end
  local letters: mut {string} = {}
  for i = 1, #declared.tparams do
    letters[i] = Types.letter(i - 1)
  end
  local binders: mut {{string}} = {}
  for i, b in ipairs(ctx.binders) do
    binders[i] = b
  end
  local names: {string} = letters
  local own = ctx.fn_names[declared.id]
  if own ~= nil and #own == #declared.tparams and Naming.free_of(binders, own) then
    names = own
  end
  binders[#binders + 1] = names
  return Types.display(t, binders, ctx.fn_names)
end

function Calls.note_plain(ctx: Ctx, node: Ast.Node, recv: Type?, types: {Type}, tail: Type?, lists: {Alt}?)
  if lists ~= nil or (recv ~= nil and recv ~= ctx.store.string) or (tail ~= nil and not Tests.plain(ctx, tail)) then
    return
  end
  for _, t in ipairs(types) do
    if not Tests.plain(ctx, t) then
      return
    end
  end
  ctx.inert[base_of(node).id] = true
end

--- What to add to the fix of an error at parameter `position` of a call with `n` values from `args`: the last argument is a
--- call whose values spilled into the following parameters. Nil where they did not.
function Calls.spill_note(ctx: Ctx, args: {Ast.Exp}, n: integer, position: integer, arity?: boolean): string?
  local last = args[#args]
  if last == nil or position <= #args or not (last.kind == "Call" or last.kind == "MethodCall") then
    return nil
  end
  local call = text_of(ctx, last)
  local answers = n - #args + 1
  local landed = if arity == true then "are passed as further arguments" else "land in the following parameters" end
  return "; " .. quoted(call) .. " is the last argument and answers " .. tostring(answers) .. " values, so " ..
    (if answers == 2 then "value 2" else "values 2.." .. tostring(answers) end) .. " " ..
    (if answers == 2 and arity ~= true then "lands in the following parameter" else landed end) .. ": write `(" .. call ..
    ")` to pass its first value alone, or bind it to a local" ..
    (if call:sub(1, 7) == "assert(" then " (`assert(f())` passes every value of `f()` through)" else "" end)
end

--- A call of the function `f`, with the arguments checked against its parameters. Returns its return lists. `given`
--- holds the values of the arguments when the caller typed them already (a generic call types its arguments to solve the
--- function's type parameters).
local function apply_function(ctx: Ctx, node: Ast.Node, callee: string, f: Fn, args: {Ast.Exp}, recv: Type?,
                              recv_node: Ast.Node?, given?: Values, declared?: Fn, strict?: boolean): {Alt}
  local off = if recv ~= nil then 1 else 0 end
  if recv ~= nil and recv_node ~= nil then
    check_receiver(ctx, f, callee, recv, recv_node)
  end
  local vals: Values
  if given ~= nil then
    vals = given
  else
    local wants: mut {integer: Type} = {}
    for i = 1, #args do
      local w = parameter_at(f, off, i)
      if w ~= nil then
        wants[i] = w
      end
    end
    vals = values_of(ctx, args, wants, f.rest)
  end
  local several, last = vals.lists, vals.last
  if several ~= nil and last ~= nil and given == nil then
    local _ = first_value(ctx, last, several)
  end
  local open = vals.tail ~= nil or vals.lists ~= nil
  local n = #vals.types
  local why = arity_problem(f, off, n, open)
  local reported = false
  local generic = false
  if declared ~= nil then
    generic = #declared.tparams > 0
  end
  for i, t in ipairs(vals.types) do
    local want = parameter_at(f, off, i)
    local at = args[math.min(i, #args)] or node
    if want == nil then
      if not reported and why == "too many" then
        reported = true
        ctx.spill = Calls.spill_note(ctx, args, n, n, true)
        arity_error(ctx, node, quoted(callee), f, off, n, why)
        ctx.spill = nil
      end
    else
      local named: string? = nil
      local original = declared ~= nil and parameter_at(declared, off, i) or nil -- checked: and_ternary
      if original ~= nil and declared ~= nil and names_invalid(want) then
        named = Calls.shown(ctx, declared, original)
      end
      ctx.spill = Calls.spill_note(ctx, args, n, i)
      local _ = Calls.expect_argument(ctx, at, t, want, callee, i, named, generic)
      ctx.spill = nil
    end
  end
  if why == "too few" or (why == "too many" and not reported) then
    arity_error(ctx, node, quoted(callee), f, off, n, why)
  end
  Calls.note_plain(ctx, node, recv, vals.types, vals.tail, vals.lists)
  local opened = if (node.kind == "Call") then Calls.opened_handle(ctx, node, f.rets) else nil end
  local tail = vals.tail
  if tail ~= nil and last ~= nil and why == nil then
    local pos, want, missing = tail_problem(ctx, f, off, n, tail, strict)
    if pos ~= nil and want ~= nil then
      if missing then
        local fix = "varargs end in nil: take the values into locals and test them (`local a, b = " .. text_of(ctx, last) ..
          " if b == nil then ... end`), or declare the parameter `name?: T`"
        if strict == true then
          fix = "pass the values explicitly (`" .. callee .. "(..., a, b)`), or count them first (`select(\"#\", ...)` or " ..
            "`#t`) and index each value, since " .. quoted(callee) .. " raises on a conversion that has no value, nil or not"
        end
        report(ctx, "nil_not_allowed", last, subject(ctx, last) .. " ends in " .. quoted(show(ctx, tail) .. "...") ..
            ", so argument " .. tostring(pos) .. " of " .. quoted(callee) .. " may be missing, where " .. tq(ctx, want) .. " is wanted",
          fix, { show(ctx, ctx.store:optional(tail)), show(ctx, want) })
      else
        ctx.argument = { callee = callee, module = ctx.callee_module, position = pos }
        local _ = expect(ctx, last, tail, want, " as argument " .. tostring(pos) .. " of " .. quoted(callee))
        ctx.argument = nil
      end
    end
  end
  return opened or f.rets
end

--- What [`lang.generics`] reads types through: the judge, and the array part of a record.
function Calls.hooks(ctx: Ctx): Generics.Hooks
  local held = ctx.hooks
  if held ~= nil then
    return held
  end
  local made: Generics.Hooks = {
    below = function(a: Type, b: Type): boolean
      return below(ctx, a, b)
    end,
    listed = function(n: Named): {Type}
      return ctx.judge:listed(n).types
    end,
    fields = function(pattern: Named, actual: Named): {Type}?
      return Relation.field_pairs(ctx.judge, pattern, actual)
    end,
    array_part = function(n: Named): Type?
      local index = members_index(ctx, n.decl, false)
      local part = index ~= nil and index.array or nil -- checked: and_ternary
      return part ~= nil and put_in(ctx, n, part) or nil -- checked: and_ternary
    end,
  }
  ctx.hooks = made
  return made
end

Calls.fixes = {
  pcall = "`pcall` passes on at most 6 values, takes a function that answers at most 3 values and none that answers `T...`, " ..
    "and takes no function that may be nil; a function that answers alternatives (`(T) | (nil, Failure)`) goes in a " ..
    "closure that binds its values (`pcall(function(): T? local v, _ = f(x) return v end)`): pass arguments one " ..
    "overload accepts, in its order",
  xpcall = "`xpcall` passes on at most 3 values, takes a function that answers at most 3 values and none that answers " ..
    "`T...`, and takes no function that may be nil: pass arguments one overload accepts, in its order",
  ["table.sort"] = "pass a comparator (`table.sort(xs, function(a, b) return a.key < b.key end)`), because `<` orders only " ..
    "numbers and strings of one type, and classes that declare `__lt` and `__le`; or pass arguments one overload accepts, in its order",
}

--- How many refused overloads an `overload_none` names: a builtin such as `pcall` has about 30, and every one's reason
--- is about 4 KB of text the reader pays for and does not need.
local shown_overloads <const> = 3

--- The reasons an `overload_none` gives, of `reasons` (one per refused candidate, in their order): those of the
--- candidates that take as many arguments as the call gives (`counted`) come first, at most `shown_overloads` of them,
--- and the rest are counted.
function Calls.nearest_reasons(reasons: {string}, counted: {boolean}, callee: string): string
  if #reasons <= shown_overloads then return table.concat(reasons, "; ") end
  local picked: mut {string} = {}
  for pass = 1, 2 do
    for i, reason in ipairs(reasons) do
      if #picked < shown_overloads and (counted[i] == true) == (pass == 1) then
        picked[#picked + 1] = reason
      end
    end
  end
  local rest <const> = #reasons - #picked
  return table.concat(picked, "; ") .. "; and " .. tostring(rest) .. " more " .. (if rest == 1 then "overload" else "overloads" end) ..
    " of " .. quoted(callee) ..
    " refused"
end

--- Where a type came from, in the words of a message: the receiver, or an argument.
function Calls.source(at: integer): string
  if at == 0 then
    return "the receiver"
  end
  return "argument " .. tostring(at)
end

--- Whether a function literal gives every parameter a type, so that its type does not depend on the position it stands in.
function Calls.typed_literal(e: Ast.Exp): boolean
  local at = peel(e)
  if not ((at.kind == "FunctionLit")) then
    return false
  end
  for _, p in ipairs(at.fn.params) do
    if p.type == nil then
      return false
    end
  end
  return true
end

--- The function type `c`, which is generic, as a call with these arguments instantiates it: each type parameter solved
--- from the receiver and the arguments, then from what the call is `expected` to return, then from a literal whose position
--- names a parameter nothing else solved (typed on its own), and each checked against its bound ([`lang.generics`]). Where it cannot
--- be, a `loud` call reports it (`infer_conflict`, `cannot_infer`, `bound_unmet`) and goes on with `invalid` for the
--- parameter, so the arguments are checked and one mistake is one error; a call that is not loud (a candidate among
--- overloads) returns nil and why.
function Calls.solve(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, args: {Ast.Exp}, prep: Prepared, off: integer,
                     recv: Type?, expected: Type?, loud: boolean): Instance
  local store = ctx.store
  local solver = Generics.new(store, c, Calls.hooks(ctx))
  if recv ~= nil and c.params[1] ~= nil then
    Generics.match(solver, c.params[1].type, recv, "into", 0)
  end
  for i = 1, prep.count do
    local t = prep.known[i]
    local want = parameter_at(c, off, i)
    if t ~= nil and want ~= nil then
      Generics.match(solver, want, t, "into", i)
    end
  end
  local tail = prep.tail
  if tail ~= nil then
    for pos = prep.count + 1, #c.params - off do
      Generics.match(solver, c.params[pos + off].type, tail, "into", prep.count + 1) -- checked: nil_not_allowed
    end
    local rest = c.rest
    if rest ~= nil then
      Generics.match(solver, rest, tail, "into", prep.count + 1)
    end
  end
  -- A generic function passed where the callee takes a function is instantiated from the parameters the callee passes it,
  -- as far as the other arguments have solved them, and what the instance returns solves the callee's own parameters:
  -- `pcall(id, v)` returns the type of `v`, where a parameter nothing fixes would be `invalid`, which every type accepts.
  local unmets: mut {Unmet} = {}
  for i = 1, prep.count do
    local given_fn, wanted_fn = prep.known[i], parameter_at(c, off, i)
    if given_fn ~= nil and wanted_fn ~= nil and given_fn.tag == "fn" and #given_fn.tparams > 0 and
        wanted_fn.tag == "fn" and #wanted_fn.tparams == 0 then
      local trial: mut {Type} = {}
      for k = 1, #c.tparams do
        trial[k] = Generics.value(solver, k) or ctx.invalid
      end
      local seen_callee = Relation.specialize(store, c, trial)
      local seen = if seen_callee ~= nil then parameter_at(seen_callee, off, i) else nil end
      if seen ~= nil and seen.tag == "fn" then
        local sub = Generics.new(store, given_fn, Calls.hooks(ctx))
        for k, p in ipairs(given_fn.params) do
          local passed = seen.params[k]
          if passed ~= nil and not Calls.mentions_invalid(passed.type) then
            Generics.match(sub, p.type, passed.type, "into", k)
          end
        end
        local solved: mut {Type} = {}
        for k = 1, #given_fn.tparams do
          local held = Generics.value(sub, k)
          if held ~= nil then solved[#solved + 1] = held end
        end
        -- The instance is taken only if every type parameter is solved, none conflicts, and each meets its bounds.
        local meets = #solved == #given_fn.tparams and #sub.conflicts == 0
        -- Whether the callee's own declaration gives the function every parameter type, whatever its type parameters
        -- are: nothing the call passes can change a type found for the function, and no bound it fails can be met here.
        local fixed = #seen.params == #wanted_fn.params
        for k, w in ipairs(wanted_fn.params) do
          local got = seen.params[k]
          if got == nil or got.type ~= w.type then fixed = false end
        end
        -- Every bound a type fails, so that one message names them all.
        local said: mut {string} = {}
        local fixes: mut {string} = {}
        local shown: mut {string} = {}
        for k, tp in ipairs(given_fn.tparams) do
          local held = solved[k]
          for _, bound in ipairs(tp.bounds or {}) do
            if meets and held ~= nil and not below(ctx, held, bound) then
              local wanted_bound = "`is " .. show(ctx, bound) .. "`"
              local fix = if Types.builtin_bound(bound) then "pass a function over " .. Types.bound_meets(bound.tag) else
                "pass a type that declares " .. wanted_bound end
              -- Only a type the program declares can be given the interface.
              local declarable = not Types.builtin_bound(bound) and held.tag == "named" and (held.decl.kind == "record" or
                held.decl.kind == "class" or held.decl.kind == "interface")
              if declarable then
                fix = "declare " .. wanted_bound .. " on " .. tq(ctx, held) .. ", or " .. fix
              end
              local why = tq(ctx, held) .. (if Types.builtin_bound(bound) then " does not meet " .. quoted(bound.tag) else
                " does not declare " .. wanted_bound end)
              if fixed and not declarable and held.tag ~= "var" then
                -- No declaration gives this type the interface, and the call cannot pass another.
                why = "the declaration of " .. quoted(callee) .. " gives it " .. tq(ctx, held) .. ", so this argument cannot " ..
                  "satisfy the bound here"
                fix = "pass a function whose type parameter is not bounded by " .. tq(ctx, bound)
              end
              said[#said + 1] = tq(ctx, held) .. " is the type parameter " .. quoted(Types.letter(k - 1)) ..
                " of the function passed as argument " .. tostring(i) .. " of " .. quoted(callee) .. ", which is bounded by " ..
                tq(ctx, bound) .. ", and " .. why
              fixes[#fixes + 1] = fix
              shown[#shown + 1] = show(ctx, held)
              shown[#shown + 1] = show(ctx, bound)
            end
          end
        end
        if #said > 0 then meets = false end
        -- The bound is the failure only if the function would otherwise be taken as the parameter, and the rest of the call
        -- taken with it ([`apply_overloads`] asks again with the instance in its place).
        if #said > 0 and #solved == #given_fn.tparams and #sub.conflicts == 0 then
          local instance = Relation.specialize(store, given_fn, solved)
          if instance ~= nil and below(ctx, instance, seen) then
            unmets[#unmets + 1] = { message = table.concat(said, "; "), fix = table.concat(fixes, "; "), shown = shown,
              arg = i, instance = instance }
          end
        end
        if meets then
          local instance = Relation.specialize(store, given_fn, solved)
          if instance ~= nil then
            Generics.match(solver, wanted_fn, instance, "into", i)
          end
        end
      end
    end
  end
  -- What the call is expected to return solves a parameter before a literal is held to the instance.
  if expected ~= nil then
    local alt = c.rets[1]
    local item = alt ~= nil and (alt.items[1] or alt.tail) or nil -- checked: and_ternary
    if item ~= nil then
      Generics.expect(solver, item, expected)
    end
  end
  local failure = ""
  for i = 1, #args do
    local want = parameter_at(c, off, i)
    if prep.pending[i] == true and want ~= nil and Generics.unsolved(solver, want) then
      local a = assert(args[i], "an argument is within the count")
      local e = peel(a)
      if (e.kind == "Table") or (e.kind == "String") or (e.kind == "Boolean") or (e.kind == "IfExp") or Calls.typed_literal(a) then
        local t = ctx.walk.expr(ctx, a, nil)
        prep.pending[i] = nil
        prep.known[i] = t
        Generics.match(solver, want, t, "into", i)
      elseif failure == "" then
        failure = "argument " .. tostring(i) .. " is a literal whose type depends on a type parameter nothing else gives"
      end
    end
  end
  local given: mut {Type} = {}
  local unbound: mut {integer} = {}
  local holes: mut {integer} = {}
  for i = 1, #c.tparams do
    local held = Generics.value(solver, i)
    if held ~= nil then
      given[#given + 1] = held
    else
      given[#given + 1] = ctx.invalid
      -- A parameter an `invalid` type was found for is not reported: the mistake that made it is, where it was made.
      if solver.tainted[i] ~= true and solver.invalid_at[i] ~= true then
        unbound[#unbound + 1] = i
      elseif solver.tainted[i] == true and solver.invalid_at[i] ~= true then
        holes[#holes + 1] = i
      end
    end
  end
  local name = quoted(callee)
  local problems: mut {string} = {}
  if failure ~= "" then
    problems[#problems + 1] = failure
  end
  for _, k in ipairs(solver.conflicts) do
    local letter = quoted(Calls.parameter_name(ctx, c, k.index))
    local same = k.first_at == k.second_at
    local msg = letter .. " of " .. name .. " is " .. tq(ctx, k.first) .. " from " .. Calls.source(k.first_at) .. " and " ..
      tq(ctx, k.second) .. " from " .. (if same then "another type in it" else Calls.source(k.second_at) end) .. ", which " ..
      (if k.exact then "must be one type here: a type parameter is solved as one type from a `mut` collection or the arguments " ..
          "of a generic" else
        "have no common type" end)
    problems[#problems + 1] = msg
    -- The parameter is none: the arguments are not held to a type they disagree on, so the mistake is the one error.
    Calls.replace_type(given, k.index, ctx.invalid)
    if loud then
      report(ctx, "infer_conflict", args[k.second_at] or node, msg,
        if same then "narrow " .. Calls.source(k.first_at) .. " to one of its types first (`if v is ... then`), or declare the " ..
            "parameter as the union" else
          "pass values of one type to " .. name .. ", or convert " .. Calls.source(k.second_at) .. " to " .. tq(ctx, k.first) end,
        { show(ctx, k.first), show(ctx, k.second) })
    end
  end
  for _, i in ipairs(unbound) do
    local letter = quoted(Calls.parameter_name(ctx, c, i))
    local msg = name .. " is generic, and nothing fixes its type parameter " .. letter .. ": no argument has it, and the " ..
      "call is not expected to answer it"
    problems[#problems + 1] = msg
    if loud then
      report(ctx, "cannot_infer", node, msg,
        "type the result, so the call is expected to have the type (`local v: T = " .. callee .. "(...)`), or pass an " ..
          "argument that has it", { Types.display(c, ctx.binders, ctx.fn_names) })
    end
  end
  for i, tp in ipairs(c.tparams) do
    local held = given[i]
    for _, bound in ipairs(tp.bounds or {}) do
      if held.tag ~= "invalid" and not below(ctx, held, bound) then -- checked: nil_not_allowed
        local builtin = Types.builtin_bound(bound)
        local lacking = Calls.lacking(ctx, held, bound)
        local msg = tq(ctx, held) .. " is the type parameter " .. quoted(Calls.parameter_name(ctx, c, i)) .. " of " .. name ..
          ", which is bounded by " .. tq(ctx, bound) .. ", and " .. tq(ctx, held) ..
          (if held.tag == "var" then " is not bounded by it" elseif builtin then
            (if bound.tag == "Ordered" then " is not a type whose values are all numbers or all strings, nor a class that declares `__lt` " ..
                "and `__le`" else
              " is not " .. Types.bound_meets(bound.tag) end) elseif lacking ~= nil then
            " has no field " .. quoted(lacking) .. " as it declares" else " neither lists it nor has its fields" end)
        problems[#problems + 1] = msg
        if loud and held.tag == "var" then
          local held_name = show(ctx, held)
          local scope = if (held.tag == "var") then ctx.bounds[#ctx.bounds - held.depth] else nil end
          local own_param = if scope ~= nil and (held.tag == "var") then scope[held.index + 1] else nil end
          local own = if own_param ~= nil then own_param.bounds else nil end
          local wanted: mut {Type} = {}
          for _, b in ipairs(own or {}) do
            wanted[#wanted + 1] = b
          end
          wanted[#wanted + 1] = bound
          report(ctx, "bound_unmet", node, msg, "bound " .. quoted(held_name) .. " by " .. tq(ctx, bound) ..
              " where it is declared (`<" .. held_name .. " is " .. Types.bounds_text(assert(Types.bounds(wanted)),
                function(b: Type): string return show(ctx, b) end) .. ">`)", { held_name, show(ctx, bound) })
        elseif loud and builtin then
          report(ctx, "bound_unmet", node, msg,
            if bound.tag == "Numeric" then "pass `integer` or `number` values: their arithmetic answers their own type" elseif
              bound.tag == "Key" then "pass " .. Types.bound_meets("Key") .. ": a map is keyed by one of them" elseif
              bound.tag == "Some" then "pass a value that is never nil: test it against `nil` first, or declare it so" elseif
              held.tag == "named" and held.decl.kind == "class" then Operands.compare_fix(ctx, held) else
              "pass numbers, or strings, of one type: `<` of a number and a string raises, so a union of the two meets no " ..
                "`Ordered`" end, { show(ctx, held), show(ctx, bound) })
        elseif loud then
          -- Only a type the program declares, or a type variable of the caller, can be given the interface.
          local declarable = held.tag == "var" or (held.tag == "named" and (held.decl.kind == "record" or
            held.decl.kind == "class" or held.decl.kind == "interface"))
          report(ctx, "bound_unmet", node, msg,
            (if declarable and lacking ~= nil then "declare `" .. lacking .. "` in " .. tq(ctx, held) ..
                ", as the interface does, or pass a type that has it" elseif declarable then
              "declare the fields of " .. tq(ctx, bound) .. " in " .. tq(ctx, held) .. ", or pass a type that has them" else
              "pass a type that has the fields of " .. tq(ctx, bound) end),
            { show(ctx, held), show(ctx, bound) })
        end
        Calls.replace_type(given, i, ctx.invalid)
        break
      end
    end
  end
  if #problems > 0 and not loud then
    return { why = problems[1], unmets = unmets } -- checked: literal_missing
  end
  local made = Relation.specialize(store, c, given)
  local sparse: Type? = nil
  for i = 1, #c.tparams do
    local held = given[i]
    if made ~= nil and sparse == nil and (held.tag == "nil" or (held.tag == "union") and held.nilable) then -- checked: nil_not_allowed
      sparse = Calls.sparse(made)
    end
  end
  if sparse ~= nil then
    local msg = name .. " with these type arguments has " .. tq(ctx, sparse) .. ", whose elements may be nil, and an array is dense"
    if loud then
      report(ctx, "array_of_optional", node, msg, "use a map `{integer: T}` for sparse data, or pass a value that is not " ..
          "optional: test it for nil first", { show(ctx, sparse) })
    end
    return { why = msg, unmets = unmets } -- checked: literal_missing
  end
  if made == nil then
    if loud then
      report(ctx, "not_assignable", node, name .. " with these type arguments nests more than " .. tostring(Types.max_depth) ..
          " types deep", "name a part of the arguments with a record, which a type does not unfold")
    end
    return { why = "its instance nests too deep", unmets = unmets } -- checked: literal_missing
  end
  return { fn = made, why = "", holes = holes, unmets = unmets }
end

--- An array or map type that `t` holds whose elements or values may be nil, or nil: what an instance makes of a type
--- parameter that an argument gave as optional.
function Calls.sparse(t: Type): Type?
  local function maybe(x: Type): boolean
    return x.tag == "nil" or (x.tag == "union") and x.nilable
  end
  if (t.tag == "array") and maybe(t.element) then
    return t
  elseif (t.tag == "map") and maybe(t.value) then
    return t
  end
  for _, part in ipairs(Types.parts(t)) do
    local found = Calls.sparse(part)
    if found ~= nil then
      return found
    end
  end
  return nil
end

--- Reports the type parameters of a call of the generic `c` that the shapes of the arguments left with no type, if
--- nothing else was reported for the call since `before` errors: the instance holds `invalid` for them, which the
--- argument check does not refuse, and a hole needs its error.
function Calls.holes(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, solved: Instance, before: integer)
  local holes = solved.holes
  if holes == nil or #holes == 0 or #ctx.errors ~= before then
    return
  end
  local letters: mut {string} = {}
  for _, i in ipairs(holes) do
    letters[#letters + 1] = quoted(Types.letter(i - 1))
  end
  report(ctx, "cannot_infer", node, quoted(callee) .. " is generic, and its type " .. (if #holes == 1 then "parameter " else "parameters " end) ..
      table.concat(letters, ", ") .. " get no type from the arguments: a parameter that is a union of shapes with " ..
      "a type parameter in each (`{T} | {U}`) says no more of an argument than that it is one of them",
    "give the parameter one shape, or one type parameter for the whole union (`x: T`)",
    { Types.display(c, ctx.binders, ctx.fn_names) })
end

function Calls.mentions_invalid(t: Type): boolean
  if t.tag == "invalid" then return true end
  for _, part in ipairs(Types.parts(t)) do
    if Calls.mentions_invalid(part) then return true end
  end
  return false
end

--- A call of the generic function `c`: its type parameters solved from the arguments and the type expected, then the
--- instance applied as any function is.
function Calls.generic(ctx: Ctx, node: Ast.Node, callee: string, c: Fn, args: {Ast.Exp}, recv: Type?,
                       recv_node: Ast.Node?, expected: Type?): {Alt}
  local off = if recv ~= nil then 1 else 0 end
  -- A position that names no type parameter of the function expects its type of the argument there.
  local wants: mut {integer: Type} = {}
  for i = 1, #args do
    local w = parameter_at(c, off, i)
    if w ~= nil and w.open == 0 then
      wants[i] = w
    end
  end
  local prep = Calls.prepare(ctx, args, wants)
  local before = #ctx.errors
  local solved = Calls.solve(ctx, node, callee, c, args, prep, off, recv, expected, true)
  local made = solved.fn
  if made == nil then
    unchecked_arguments(ctx, args)
    return unknown_lists(ctx)
  end
  for i = 1, #args do
    if prep.pending[i] == true then
      local a = assert(args[i], "an argument is within the count")
      prep.known[i] = ctx.walk.expr(ctx, a, parameter_at(made, off, i))
    end
  end
  local vals: Values = { types = {}, tail = prep.tail, lists = prep.lists, last = prep.last }
  for i = 1, prep.count do
    vals.types[#vals.types + 1] = prep.known[i] or ctx.invalid
  end
  local alts = apply_function(ctx, node, callee, made, args, recv, recv_node, vals, c)
  Calls.holes(ctx, node, callee, c, solved, before)
  return alts
end

--- A call of the first of `cands`, in declared order, whose parameters accept the arguments; the literal arguments are
--- checked last, against it. A generic candidate is instantiated by the arguments first.
--- Reports a table that `gsub` looks matches up in when its keys are not what the literal pattern captures: `key` is
--- `string` for a captured text (or the whole match) and `integer` for a position `()`. `c` is the overload taken.
function Calls.gsub_key(ctx: Ctx, c: Fn, args: {Ast.Exp}, off: integer, key: string)
  local table_arg = args[3 - off]
  local declared = parameter_at(c, off, 3 - off)
  if table_arg == nil or declared == nil or not ((declared.tag == "map")) then
    return
  end
  local held = declared.key.tag
  if (key == "string" and held == "string") or (key == "integer" and held == "integer") then
    return
  end
  local wants = if key == "string" then "the captured text, a `string`" else "the position of a `()` capture, an `integer`" end
  report(ctx, "gsub_key", table_arg, "the table of `gsub` is looked up with " .. wants .. " as the key, and its keys are " ..
      tq(ctx, declared.key),
    "declare the table `{" .. key .. ": string}`" .. (if key == "string" then ", or capture a position with `()` for " ..
        "integer keys" else ", or capture text with `( ... )` for string keys" end), { show(ctx, declared) })
end

--- Holds the first argument of a call `node` of the global `assert`, of type `t`, to the rule of a condition
--- ([`Operands.condition_kind`]) where it is an optional whose value may be a boolean: `assert` raises for false as for nil, so
--- one written to say that the value is there raises where it is there and false. `results` is how many values the
--- argument gives where it is a call that is the only argument, and 0 otherwise.
--
-- TODO: refuse an optional of a type parameter too (`T?`, as in `function unwrap<T>(x: T?): T return assert(x) end`,
-- which raises for `false` where `T` is `boolean`). [`Operands.condition_kind`] takes `T?` as an optional that holds no boolean,
-- so `if x then` has the same gap; it waits on the rule for both: a bound that keeps a boolean out of `T`, or a refusal
-- of every `T?` as a condition, with the tree's generic code rewritten to `~= nil`.
local function asserted_boolean(ctx: Ctx, node: Ast.Node, args: {Ast.Exp}, t: Type?, results: integer)
  local first = args[1]
  if first == nil or t == nil or node.kind ~= "Call" then
    return
  end
  local callee = node.callee
  if callee.kind ~= "Name" or callee.binding ~= nil or callee.text ~= "assert" or not holds_boolean(ctx, t) then
    return
  end
  local text = text_of(ctx, first)
  local at = peel(first)
  local fix = "say which is asserted: `assert(" .. text .. " ~= nil)` that it is there, or `assert(" .. text .. " == true)` that it is true"
  -- `assert` passes the value where it is `true`. A call's other values would be cut by `==`, so a call has no rewrite.
  local rewrite: Codes.Rewrite? = if Operands.only_boolean(ctx, t) then Operands.is_true(first) else nil end
  if at.kind == "Call" or at.kind == "MethodCall" then
    rewrite = nil
    -- A comparison keeps only the first value of a call, so a reason it gives is named to be passed on. A call that
    -- gives one value has none to name, and one cut to its first value by a message after it is named alone.
    local names, rest = "value", if #args > 1 then ", ..." else "" end
    if results >= 2 then
      names, rest = "value, reason", ", reason"
    end
    fix = "name what it gives (`local " .. names .. " = " .. text .. "`) and say which is asserted: `assert(value ~= nil" ..
      rest .. ")` that it is there, or `assert(value == true" .. rest .. ")` that it is true"
  end
  report(ctx, "condition_type", first, subject(ctx, first) .. " is " .. tq(ctx, t) .. ": nil and false would not be told apart", fix,
    { show(ctx, t) }, nil, rewrite)
end

local function apply_overloads(ctx: Ctx, node: Ast.Node, callee: string, cands: {Type}, args: {Ast.Exp}, recv: Type?,
                               expected: Type?, key?: string): {Alt}
  local off = if recv ~= nil then 1 else 0 end
  -- `assert(f())` alone: in `assert(x, f())` it is `x` that `assert` tests, and the call is no value as anywhere else.
  local asserting: string? = nil
  if (callee == "assert" or callee == "must") and #args == 1 and (node.kind == "Call") and Tests.quiet_callee(node.callee) then
    asserting = callee
  end
  -- The first store into an empty table with no type gives it one: the value is checked first.
  local early: mut {integer: Type}? = nil
  if Unfilled.inserts(ctx, callee, args) then
    local value = ctx.walk.expr(ctx, assert(args[2], "two arguments"), nil)
    Unfilled.fill_insert(ctx, args, value)
    early = { [2] = value }
  end
  local prep = Calls.prepare(ctx, args, nil, asserting, early)
  local known, pending, tail, count = prep.known, prep.pending, prep.tail, prep.count
  local reasons: mut {string} = {}
  -- Whether each of `reasons` is of a candidate that takes as many arguments as the call gives.
  local counted: mut {boolean} = {}
  local unmet: Unmet? = nil
  -- Set when two candidates each reach `bound_unmet` with a different message: the order of the overloads does not say
  -- which the call meant, so none is named.
  local ambiguous = false
  for _, declared in ipairs(cands) do

    if (declared.tag == "fn") then
      -- The number of arguments does not depend on the type parameters, so a candidate that takes another is not solved.
      local wrong_count = arity_problem(declared, off, count, prep.open and tail ~= nil)
      --- Why the candidate is not taken ("" where it is), the candidate as instantiated, and the bound it met in each
      --- argument that is a generic function.
      local function evaluate(): string, Fn, {Unmet}
        local c: Fn = declared
        local failure = ""
        local own: {Unmet} = {}
        if wrong_count == nil and #declared.tparams > 0 then
          local solved = Calls.solve(ctx, node, callee, declared, args, prep, off, recv, expected, false)
          local made = solved.fn
          own = solved.unmets or {}
          if made == nil then
            failure = solved.why
          elseif solved.holes ~= nil and #solved.holes > 0 then
            failure = "a type parameter gets no type from the arguments"
          else
            c = made
          end
        end
        local receiver_param = c.params[1]
        if failure ~= "" then
          -- The candidate could not be instantiated.
        elseif wrong_count ~= nil then
          failure = wrong_count .. " arguments"
        elseif recv ~= nil and receiver_param ~= nil and not accepts(ctx, recv, receiver_param.type) then
          local declared_receiver = declared.params[1]
          local wanted_receiver = receiver_param.type
          if declared_receiver ~= nil then
            wanted_receiver = declared_receiver.type
          end
          failure = "the receiver is " .. tq(ctx, recv) .. ", where " .. quoted(Calls.shown(ctx, declared, wanted_receiver)) ..
            " is wanted"
        else
          for i = 1, count do
            local want = parameter_at(c, off, i)
            local t = known[i]
            local wanted = ""
            if want ~= nil then
              local original = parameter_at(declared, off, i)
              wanted = quoted(Calls.shown(ctx, declared, original ~= nil and original or want)) -- checked: and_ternary
            end
            if t ~= nil and (want == nil or not accepts(ctx, t, want)) then
              failure = "argument " .. tostring(i) .. " is " .. tq(ctx, t) .. (if want ~= nil then ", where " .. wanted ..
                  " is wanted" else ", which it does not take" end)
              break
            elseif pending[i] == true and (want == nil or not literal_fits(ctx, args[i], want)) then -- checked: index_may_be_nil
              failure = "argument " .. tostring(i) .. " is a literal that is not " .. (if want ~= nil then "a " .. wanted else "taken" end)
              break
            end
          end
        end
        if failure == "" and tail ~= nil then
          local pos, want, missing = tail_problem(ctx, c, off, count, tail)
          if pos ~= nil and want ~= nil then
            failure = "argument " .. tostring(pos) .. " is filled by " .. quoted(show(ctx, tail) .. "...") .. (if missing then
              ", which may leave it missing, where " else ", where " end) .. tq(ctx, want) .. " is wanted"
          end
        end
        return failure, c, own
      end
      local failure, c, own = evaluate()
      -- The bound is the reason only if the call would be taken with it met: asked again with the function's instance
      -- (the bounds waived) as the argument, so that the rest of the call is held to its parameters too.
      -- Every argument that met one is waived together, since the first run solved each independently of the others'
      -- instances; a bound only the instances reveal joins them, and a call that fails for another reason stays refused.
      if failure ~= "" and #own > 0 then
        local held: mut {integer: Type} = {}
        local waived: mut {Unmet} = {}
        local again, found = failure, own
        while again ~= "" do
          local grew = false
          for _, u in ipairs(found) do
            local was = known[u.arg]
            if was ~= nil and held[u.arg] == nil then
              held[u.arg] = was
              known[u.arg] = u.instance
              waived[#waived + 1] = u
              grew = true
            end
          end
          if not grew then break end
          local next_again, _next, next_found = evaluate()
          again, found = next_again, next_found
        end
        for i, was in pairs(held) do
          known[i] = was
        end
        local first = waived[1]
        if again == "" and first ~= nil then
          local said: mut {string} = {}
          local fixes: mut {string} = {}
          local shown: mut {string} = {}
          for _, u in ipairs(waived) do
            said[#said + 1] = u.message
            fixes[#fixes + 1] = u.fix
            for _, t in ipairs(u.shown) do shown[#shown + 1] = t end
          end
          local message = table.concat(said, "; ")
          if unmet == nil then
            unmet = { message = message, fix = table.concat(fixes, "; "), shown = shown, arg = first.arg,
              instance = first.instance }
          elseif unmet.message ~= message then
            ambiguous = true
          end
        end
      end
      if failure == "" then
        for i, a in ipairs(args) do
          if pending[i] == true then
            local want = parameter_at(c, off, i)
            local t = ctx.walk.expr(ctx, a, want)
            known[i] = t
            if want ~= nil then
              local _ = Calls.expect_argument(ctx, a, t, want, callee, i, nil, #declared.tparams > 0)
            end
          end
        end
        if key ~= nil then
          Calls.gsub_key(ctx, c, args, off, key)
        end
        if recv == nil then
          asserted_boolean(ctx, node, args, known[1], if #args == 1 then (if tail ~= nil then count + 1 else count end) else 0 end)
        end
        local given: mut {Type} = {}
        for i = 1, count do
          given[i] = known[i] or ctx.invalid
        end
        Calls.note_plain(ctx, node, recv, given, tail, prep.lists)
        if ctx.typed and (node.kind == "Call") then
          -- The callee is the overload taken (instantiated, for a generic one), not the first the name has.
          ctx.types[base_of(node.callee).id] = c
        end
        if ctx.typed then
          ctx.callees[base_of(node).id] = c
        end
        return c.rets
      end
      reasons[#reasons + 1] = overload_line(ctx, declared, failure)
      counted[#counted + 1] = wrong_count == nil
    end
  end
  for i, a in ipairs(args) do
    if pending[i] == true then
      ctx.lenient = ctx.lenient + 1
      local _ = ctx.walk.expr(ctx, a, nil)
      ctx.lenient = ctx.lenient - 1
    end
  end
  local shown: mut {string} = {}
  for i = 1, count do
    local t = known[i]
    if t ~= nil then
      local text = show(ctx, t)
      shown[#shown + 1] = text
    else
      local literal = args[i]
      shown[#shown + 1] = if (literal.kind == "String") then "string" elseif (literal.kind == "Boolean") then "boolean" elseif -- checked: nil_not_allowed
        (literal.kind == "FunctionLit") then "function" else "table" end
    end
  end
  -- A module given beside a collection of its values (`table.insert(list, Queues)`): the argument is what is wrong.
  local function holds_values_of(t: Type, decl: Decl): boolean
    if (t.tag == "named") and not t.value and t.decl == decl then
      return true
    end
    for _, part in ipairs(Types.parts(t)) do
      if holds_values_of(part, decl) then
        return true
      end
    end
    return false
  end
  for i = 1, count do
    local held = known[i]
    local given = args[i]
    if given ~= nil and held ~= nil and (held.tag == "named") and held.value and (held.decl.kind == "record" or held.decl.kind == "class") then
      for j = 1, count do
        local other = known[j]
        if j ~= i and other ~= nil and holds_values_of(other, held.decl) then
          local why: Relation.Refusal = { code = "declaration_value", path = {}, sub = held, super = other }
          ctx.argument = { callee = callee, module = ctx.callee_module, position = i }
          refused(ctx, given, held, other, why, " as argument " .. tostring(i) .. " of " .. quoted(callee), held.decl.name)
          ctx.argument = nil
          return unknown_lists(ctx)
        end
      end
    end
  end
  local first = reasons[1]
  -- `unmet` is set only for a candidate that the bound alone kept from being taken: meeting it would accept the call. Several
  -- candidates that say alike are one reason.
  if unmet ~= nil and not ambiguous then
    report(ctx, "bound_unmet", node, unmet.message, unmet.fix, unmet.shown)
    return unknown_lists(ctx)
  end
  report(ctx, "overload_none", node, "no overload of " .. quoted(callee) .. " takes the arguments (" ..
      table.concat(shown, ", ") .. ")",
    (Calls.fixes[callee] or "pass arguments one overload accepts, in its order") .. ": " ..
      Calls.nearest_reasons(reasons, counted, callee),
    { first or "" })
  return unknown_lists(ctx)
end

--- The function of the string library `e` denotes, by what it is and not by how it is spelled: `string.f`, `string["f"]`, the
--- same through a local that holds the library table (`local str = string`) or through a text (`("x").format`, `s.find` of a
--- text `s`), and a local that was given one of these and is never assigned (`local f = string.f`, `local g = f`). Nil for
--- anything else, a function of a record that is called alike among them.
function Calls.library_value(ctx: Ctx, e: Ast.Node): string?
  local at = peel(e)
  local name: string? = nil
  local object: Ast.Node? = nil
  local bound: integer? = nil
  if (at.kind == "Name") then
    bound = at.binding
  end
  if bound ~= nil then
    return ctx.library[bound]
  elseif (at.kind == "Field") then
    name, object = at.name, peel(at.object)
  elseif (at.kind == "Index") then
    local key = peel(at.key)
    if (key.kind == "String") then
      name, object = key.value, peel(at.object)
    end
  end
  if name == nil or object == nil or Literals.functions[name] ~= true then
    return nil
  end
  if (object.kind == "String") then
    return name
  elseif (object.kind == "Name") then
    local object_binding = object.binding
    if object_binding == nil then
      return object.text == "string" and name or nil -- checked: and_ternary
    end
    local held = ctx.vars[object_binding]
    local library = ctx.program.globals["string"]
    if held ~= nil and (is_text(held) or ((held.tag == "named") and library ~= nil and held.decl == library.decl)) then
      return name
    end
  end
  return nil
end

--- The text `e` is: a string literal, or a name that was given one and is never assigned.
function Calls.literal_text(ctx: Ctx, e: Ast.Node): string?
  if (e.kind == "String") then
    return e.value
  elseif (e.kind == "Name") then
    local bound = e.binding
    if bound ~= nil then
      return ctx.consts[bound]
    end
  end
  return nil
end

--- The type an argument or a result has for a `kind` of [`lang.literals`]: a type of a conversion, an option or a capture.
function Calls.kind_type(ctx: Ctx, kind: string): Type
  local store = ctx.store
  if kind == "integer" or kind == "position" then
    return store.integer
  elseif kind == "number" then
    return store.number
  elseif kind == "string" then
    return store.string
  elseif kind == "quoted" then
    return store:union({ store.string, store.number, store.boolean, ctx.nil_type })
  end
  return store:atom("any")
end

--- The function `f`, a function of the string library called with the literals `call` gives, with the types they say: the
--- arguments of `format` and `pack` are those their conversions and options take, and the captures of `find`, `match` and
--- `gmatch` and the results of `unpack` are those of the pattern and the format (a position `()` is an integer). `f` itself
--- where a literal is not read or is wrong, which is reported by [`Calls.literal_arguments`].
function Calls.refine(ctx: Ctx, call: Literals.Call, f: Fn): Fn
  local store = ctx.store
  local fn = call.fn
  local format = call.literals[1]
  local pattern = call.literals[2]
  local first = f.rets[1]
  local function made(params: {Types.Param}, rest: Type?, rets: {Alt}): Fn
    local built = store:fn({ tparams = f.tparams, params = params, rest = rest, rets = rets })
    if (built.tag == "fn") then
      return built
    end
    return f
  end
  if (fn == "format" or fn == "pack") and format ~= nil and f.params[1] ~= nil then
    local kinds: {string} = {}
    local trouble: Literals.Problem? = nil
    if fn == "format" then
      local read = Literals.format(format)
      kinds, trouble = read.kinds, read.problem
    else
      local read = Literals.pack(format)
      kinds, trouble = read.kinds, read.problem
    end
    if trouble ~= nil then
      return f
    end
    local params: mut {Types.Param} = { f.params[1] } -- checked: index_may_be_nil
    for _, kind in ipairs(kinds) do
      params[#params + 1] = { type = Calls.kind_type(ctx, kind) }
    end
    return made(params, nil, f.rets)
  elseif fn == "unpack" and format ~= nil then
    local read = Literals.pack(format)
    if read.problem ~= nil then
      return f
    end
    local items: mut {Type} = {}
    for _, kind in ipairs(read.kinds) do
      items[#items + 1] = Calls.kind_type(ctx, kind)
    end
    items[#items + 1] = store.integer
    return made(f.params, f.rest, { { items = items } })
  elseif pattern ~= nil and (fn == "match" or fn == "gmatch" or fn == "find") then
    local read = Literals.pattern(pattern)
    local reads = fn ~= "find" or call.plain == "none" or call.plain == "false"
    if read.problem ~= nil or not reads or first == nil or #f.rets ~= 1 then
      return f
    end
    local captures: mut {Type} = {}
    for _, kind in ipairs(read.captures) do
      captures[#captures + 1] = Calls.kind_type(ctx, kind)
    end
    if #captures == 0 and fn ~= "find" then
      captures[1] = store.string
    end
    if fn == "gmatch" then
      local iterator = first.items[1]
      if iterator ~= nil and (iterator.tag == "fn") then
        local each = store:fn({ tparams = iterator.tparams, params = iterator.params, rest = iterator.rest,
          rets = { { items = captures } } })
        return made(f.params, f.rest, { { items = { each } } })
      end
      return f
    end
    local items: mut {Type} = {}
    for _, item in ipairs(first.items) do
      items[#items + 1] = item
    end
    for _, captured in ipairs(captures) do
      items[#items + 1] = store:optional(captured)
    end
    return made(f.params, f.rest, { { items = items } })
  end
  return f
end

--- The overloads `list` of `gsub` called with a literal pattern, where a callback takes the captures the pattern gives: the
--- type of each capture, so that a `()` is an integer, and no more parameters than there are captures (a pattern with none
--- passes the whole match). A callback that takes more is no overload.
function Calls.refine_overloads(ctx: Ctx, call: Literals.Call, list: {Type}): {Type}
  local pattern = call.literals[2]
  if call.fn ~= "gsub" or pattern == nil then
    return list
  end
  local read = Literals.pattern(pattern)
  if read.problem ~= nil then
    return list
  end
  local given: mut {Type} = {}
  for _, kind in ipairs(read.captures) do
    given[#given + 1] = Calls.kind_type(ctx, kind)
  end
  if #given == 0 then
    given[1] = ctx.store.string
  end
  local out: mut {Type} = {}
  for _, each in ipairs(list) do
    local callback: Type? = nil
    if each.tag == "fn" then
      local third = each.params[3]
      if third ~= nil then
        callback = third.type
      end
    end
    if (each.tag == "fn") and callback ~= nil and (callback.tag == "fn") then
      if #callback.params <= #given then
        local params: mut {Types.Param} = {}
        for i = 1, #callback.params do
          params[i] = { type = given[i] } -- checked: index_may_be_nil
        end
        local made = ctx.store:fn({ tparams = callback.tparams, params = params, rest = nil, rets = callback.rets })
        local rebuilt: mut {Types.Param} = {}
        for i, p in ipairs(each.params) do
          rebuilt[i] = if i == 3 then { type = made, omittable = p.omittable } else p end
        end
        out[#out + 1] = ctx.store:fn({ tparams = each.tparams, params = rebuilt, rest = each.rest, rets = each.rets })
      end
    else
      out[#out + 1] = each
    end
  end
  return out
end

--- The literal arguments of a call of the string library, written `string.f(...)`, `s:f(...)` on text, or `f(...)` of a local
--- that was given `string.f` and is never assigned, or nil. A string literal is an argument that is one, or a name given one
--- and never assigned (`local P <const> = "%b("`). A library function that is passed on or stored in a field is not read.
function Calls.library_call(ctx: Ctx, callee_node: Ast.Node, node: Ast.Node, args: {Ast.Exp}, recv: Type?,
                            recv_node: Ast.Node?): Literals.Call?
  local fn: string? = nil
  local method = false
  if (node.kind == "MethodCall") then
    method = recv ~= nil and is_text(recv)
    if method then
      fn = node.name
    end
  else
    fn = Calls.library_value(ctx, callee_node)
  end
  if fn == nil or Literals.functions[fn] ~= true then
    return nil
  end
  local off = if method then 1 else 0 end
  local literals: mut {integer: string} = {}
  local receiver = recv_node ~= nil and peel(recv_node) or nil -- checked: and_ternary
  local held = receiver ~= nil and Calls.literal_text(ctx, receiver) or nil -- checked: and_ternary
  if method and held ~= nil then
    literals[1] = held
  end
  for i, a in ipairs(args) do
    local text = Calls.literal_text(ctx, peel(a))
    if text ~= nil then
      literals[i + off] = text
    end
  end
  local plain = "none"
  local fourth = args[4 - off]
  if fourth ~= nil then
    local written = peel(fourth)
    plain = (written.kind == "Boolean") and tostring(written.value) or "other" -- checked: and_ternary
  end
  return { fn = fn, literals = literals, plain = plain }
end

--- Reports what Lua raises on in the literal arguments of `call`, a call of the string library.
function Calls.literal_arguments(ctx: Ctx, call: Literals.Call, node: Ast.Node, args: {Ast.Exp}, recv_node: Ast.Node?)
  local off = if recv_node ~= nil then 1 else 0 end
  for _, found in ipairs(Literals.check(call)) do
    local place = recv_node ~= nil and found.place == 1 and recv_node or args[found.place - off] or node -- checked: and_ternary
    report(ctx, found.code, place, found.msg, found.fix)
  end
end

--- The name of the function of [`cosmic.sqlite`] that `callee` is ([`Sqlite.open`] is "open"), or nil: a field of a local
--- that holds the module.
function Calls.sqlite_function(ctx: Ctx, callee: Ast.Node): string?
  local at = peel(callee)
  if not (at.kind == "Field") then
    return nil
  end
  local object = peel(at.object)
  if not (object.kind == "Name") then
    return nil
  end
  local bound = object.binding
  if bound == nil then
    return nil
  end
  local held = ctx.vars[bound]
  if held == nil or not (held.tag == "named") or not held.value or held.decl.module ~= "cosmic.sqlite" then
    return nil
  end
  return at.name
end

--- What `Sqlite.open(path, { schema = S })`, `Sqlite.memory({ schema = S })` and `Sqlite.hold(db, S)` return
--- where `S` is a `local schema`: the lists `rets` with each handle a handle of `S`.
function Calls.opened_handle(ctx: Ctx, node: Ast.Call, rets: {Alt}): {Alt}?
  local fn = Calls.sqlite_function(ctx, node.callee)
  local value: Ast.Node? = nil
  if fn == "hold" then
    local given = node.args[2]
    value = if given ~= nil then peel(given) else nil end
  else
    local opts = if fn == "open" then node.args[2] elseif fn == "memory" then node.args[1] else nil end
    local given = if opts ~= nil then peel(opts) else nil end
    if given == nil or not (given.kind == "Table") then
      return nil
    end
    for _, item in ipairs(given.items) do
      if (item.kind == "Named") and item.name == "schema" then
        value = peel(item.value)
      end
    end
  end
  local schema: Type? = nil
  -- A name or a field of one, which reads no value but the one the call was given.
  if value ~= nil and ((value.kind == "Name") or ((value.kind == "Field") and (peel(value.object).kind == "Name"))) then
    -- Read again, quiet: the call's own check of the argument reported what it found.
    ctx.quiet = ctx.quiet + 1
    schema = ctx.walk.expr(ctx, value, nil)
    ctx.quiet = ctx.quiet - 1
  end
  if schema == nil or not (schema.tag == "named") or not schema.value then
    return nil
  end
  local schema_body = schema.decl.body
  if schema_body == nil or schema_body.schema == nil then
    return nil
  end
  local handle = ctx.store:named(schema.decl, {})
  local made: mut {Alt} = {}
  for _, alt in ipairs(rets) do
    local items: mut {Type} = {}
    for i, item in ipairs(alt.items) do
      local is_handle = (item.tag == "named") and not item.value and item.decl.module == "cosmic.sqlite" and
        item.decl.name == "Handle"
      items[i] = if is_handle then handle else item end
    end
    made[#made + 1] = { items = items, tail = alt.tail, narrows = alt.narrows }
  end
  return made
end

--- The text of `e` where every part is a literal: a string, a local that holds one, or a `..` of them.
function Calls.joined_text(ctx: Ctx, e: Ast.Node): string?
  local at = peel(e)
  if (at.kind == "Binary") and at.op == ".." then
    local left = Calls.joined_text(ctx, at.left)
    if left == nil then
      return nil
    end
    local right = Calls.joined_text(ctx, at.right)
    if right == nil then
      return nil
    end
    return left .. right
  end
  return Calls.literal_text(ctx, at)
end

--- The DDL and its argument where `e` is `Sqlite.schema(ddl)` with a literal `ddl`; nil otherwise.
function Calls.schema_call(ctx: Ctx, e: Ast.Node): string?, Ast.Node?
  local at = peel(e)
  if not (at.kind == "Call") or Calls.sqlite_function(ctx, at.callee) ~= "schema" then
    return nil, nil
  end
  local given = at.args[1]
  if given == nil then
    return nil, nil
  end
  return Calls.joined_text(ctx, given), given
end

--- Reads the SQL of a call on a handle of a `local schema` (its receiver's type `recv`) against that schema: SQL that
--- SQLite refuses there, and a values list written out whose length is not the number of values the SQL binds.
function Calls.sql_arguments(ctx: Ctx, method: string, node: Ast.Node, args: {Ast.Exp}, recv_node: Ast.Node, recv: Type?)
  -- Required here, not in the main chunk, whose locals are at their ceiling.
  local Reads = require("lang.sql")
  local valued = Reads.methods[method]
  local receiver = peel(recv_node)
  local sql = args[1]
  local decl = if recv ~= nil and (recv.tag == "named") and not recv.value then recv.decl else nil end
  local body = if decl ~= nil then decl.body else nil end
  local ddl = if body ~= nil then body.schema else nil end
  if decl == nil or ddl == nil or ctx.unread_schemas[decl] == true then
    return
  end
  local schema_name = decl.name
  local runs_any = method == "exec" or method == "exec_result"
  if method == "migrate" then
    ctx.unread_schemas[decl] = true
    return
  end
  if sql == nil or (valued == nil and not runs_any) then
    return
  end
  local text = Calls.joined_text(ctx, sql)
  -- SQL that may make a table or attach a database ends the reads of the schema's handles in the rest of the
  -- module, whichever handle it is sent to: what they hold is no longer the schema alone.
  if (runs_any and text == nil) or (text ~= nil and Reads.changes_schema(text)) then
    ctx.unread_schemas[decl] = true
    return
  end
  if text == nil or valued == nil then
    return
  end
  local read = Reads.read(ddl, text)
  if read == nil then
    return
  end
  local refusal = read.refused
  local shown = text_of(ctx, receiver)
  if refusal ~= nil then
    local fix = if refusal:find("statement", 1, true) ~= nil then
      "send one statement a call, or several with `" .. shown .. ":exec`" else
      "name only the tables and columns the schema creates, in SQL that SQLite reads" end
    report(ctx, "sql_refused", sql, quoted(shown) .. " is a handle of the schema " .. quoted(schema_name) ..
        ", and SQLite refuses this SQL against it: " .. refusal, fix, { refusal })
    return
  end
  if method == "rows" or method == "one" then
    ctx.call_columns[base_of(node).id] = read.columns
  end
  local project = if method == "map" then args[3] else nil end
  local made = if project ~= nil then peel(project) else nil end
  if made ~= nil and (made.kind == "FunctionLit") then
    local param = made.fn.params[1]
    local row = if param ~= nil then param.name else nil end
    local held = if row ~= nil then ctx.scoped.vars[row.id] else nil end
    if row ~= nil and held ~= nil and not held.assigned then
      ctx.row_columns[row.id] = read.columns
    end
  end
  if not valued then
    return
  end
  local values = args[2]
  local given = if values ~= nil then peel(values) else nil end
  local count: integer? = nil
  if given == nil or (given.kind == "Nil") then
    count = 0
  elseif (given.kind == "Table") then
    count = #given.items
    for k, item in ipairs(given.items) do
      local value = if (item.kind == "Positional") then peel(item.value) else nil end
      -- A call or `...` last in the list may give any number of values.
      if value == nil or (k == #given.items and ((value.kind == "Call") or (value.kind == "MethodCall") or
          (value.kind == "Vararg"))) then
        count = nil
        break
      end
    end
  end
  if count ~= nil and count ~= read.parameters then
    local wanted = if read.parameters == 1 then "1 value" else tostring(read.parameters) .. " values" end
    report(ctx, "sql_parameters", values or node, "the SQL binds " .. wanted .. ", and " .. tostring(count) ..
        (if count == 1 then " is" else " are" end) .. " given", "give " .. wanted .. ", one for each parameter, in order",
      { tostring(read.parameters), tostring(count) })
  end
end

--- The result columns of `e` where it is `db:rows(sql)` or `db:one(sql)`, either in `assert`, on a handle
--- of a `local schema`, with literal SQL that SQLite prepares against its schema: the columns, and whether the
--- call returns a list of rows (`rows`) or one row (`one`). An element of a list [`Ctx.row_lists`] holds (`rows[1]`) is
--- one row of its columns. Nil otherwise.
function Calls.result_columns(ctx: Ctx, e: Ast.Node): {Sql.Column}?, boolean
  local at = peel(e)
  if (at.kind == "Call") then
    local callee = peel(at.callee)
    local first = at.args[1]
    if (callee.kind == "Name") and callee.binding == nil and (callee.text == "assert" or callee.text == "must") and
        first ~= nil then
      at = peel(first)
    end
  end
  if (at.kind == "Index") then
    local list = peel(at.object)
    local held = if (list.kind == "Name") then list.binding else nil end
    return if held ~= nil then ctx.row_lists[held] else nil end, false
  end
  if not (at.kind == "MethodCall") or (at.name ~= "rows" and at.name ~= "one") then
    return nil, false
  end
  local columns = ctx.call_columns[at.id]
  return columns, columns ~= nil and at.name == "rows"
end

--- Reads a call of `method` on a row whose result columns are known ([`Ctx.row_columns`], or an element of a list
--- [`Ctx.row_lists`] holds) with a literal column: a column past the last, and a read that raises on every cell of the
--- column's declared type (`row:text(i)` of an `INTEGER` column).
function Calls.row_read(ctx: Ctx, method: string, args: {Ast.Exp}, recv_node: Ast.Node)
  local Reads = require("lang.sql")
  local index = args[1]
  if index == nil or Reads.row_reads[method] == nil then
    return
  end
  local at = peel(index)
  if not (at.kind == "Integer") then
    return
  end
  local receiver = peel(recv_node)
  local columns: {Sql.Column}? = nil
  local own = if (receiver.kind == "Name") then receiver.binding else nil end
  if own ~= nil then
    columns = ctx.row_columns[own]
  elseif (receiver.kind == "Index") then
    local list = peel(receiver.object)
    local bound = if (list.kind == "Name") then list.binding else nil end
    if bound ~= nil then
      columns = ctx.row_lists[bound]
    end
  end
  if columns == nil then
    return
  end
  local n = at.value
  local column = columns[n]
  if column == nil then
    local count = #columns
    local counted = if count == 1 then "1 column" else tostring(count) .. " columns" end
    report(ctx, "sql_column", index, "the SQL gives " .. counted .. ", so this row has no column " .. tostring(n),
      "read a column from 1 to " .. tostring(count), { tostring(count), tostring(n) })
    return
  end
  local kind, origin, declared = column.kind, column.origin, column.declared
  if kind == nil or origin == nil or declared == nil or not Reads.refuses(column, method) then
    return
  end
  local better: string = kind
  local said = if column.strict then " in a STRICT table, so `" .. method .. "` raises on each of its cells"
    else ", so `" .. method .. "` raises on each cell of its declared type" end
  local fix = "read it with `" .. better .. "(" .. tostring(n) .. ")`" ..
    (if column.strict then "" else ", or `as_text(" .. tostring(n) .. ")` where the column holds cells of other types" end)
  report(ctx, "sql_column", index, "column " .. tostring(n) .. " is " .. origin .. ", declared " .. declared .. said, fix,
    { origin, declared })
end

--- Gives the variable of `for _, row in ipairs(rows)` the result columns of `rows`, where [`Ctx.row_lists`] holds them.
function Calls.for_rows(ctx: Ctx, s: Ast.ForIn)
  local first = s.iterators[1]
  local row = s.vars[2]
  local at = if first ~= nil then peel(first) else nil end
  if row == nil or at == nil or not (at.kind == "Call") or #s.iterators ~= 1 then
    return
  end
  local callee = peel(at.callee)
  local list = at.args[1]
  local over = if list ~= nil then peel(list) else nil end
  local bound = if over ~= nil and (over.kind == "Name") then over.binding else nil end
  if not (callee.kind == "Name") or callee.binding ~= nil or callee.text ~= "ipairs" or bound == nil then
    return
  end
  local columns = ctx.row_lists[bound]
  local held = ctx.scoped.vars[row.id]
  if columns ~= nil and held ~= nil and not held.assigned then
    ctx.row_columns[row.id] = columns
  end
end

--- The lists a call returns, where the callee has type `ft` (and the overloads `cands`, if it has several). `expected`
--- is the type the call is expected to return, which solves a type parameter no argument does.
function Calls.dispatch(ctx: Ctx, node: Ast.Node, callee_node: Ast.Node, callee: string, ft: Type, cands: {Type}?,
                        args: {Ast.Exp}, recv: Type?, recv_node: Ast.Node?, expected: Type?): {Alt}
  local list = cands or { ft }
  local first = list[1]
  if first.tag == "invalid" then -- checked: nil_not_allowed
    unchecked_arguments(ctx, args)
    return unknown_lists(ctx)
  elseif first.tag == "any" then
    report(ctx, "any_use", callee_node, quoted(callee) .. " is untrusted data (`any`) and is called",
      "validate it with a [`cosmic.shape`] validator, and call the checked function", { "any" })
    unchecked_arguments(ctx, args)
    return unknown_lists(ctx)
  end
  if cands == nil and nilable(first) and first.tag ~= "nil" then
    report(ctx, "nil_not_allowed", callee_node, quoted(callee) .. " is " .. tq(ctx, first) .. ", so it may be nil, and it is called",
      "test it first (`if " .. callee .. " ~= nil then ... end`), or copy it to a local and test that", { show(ctx, first) })
    first = ctx.store:non_nil(first)
    list = { first }
  end
  local library = Calls.library_call(ctx, callee_node, node, args, recv, recv_node)
  local key: string? = nil
  local refined: Fn? = nil
  if (node.kind == "MethodCall") and recv_node ~= nil then
    Calls.sql_arguments(ctx, node.name, node, args, recv_node, recv)
    Calls.row_read(ctx, node.name, args, recv_node)
  end
  if library ~= nil then
    Calls.literal_arguments(ctx, library, node, args, recv_node)
    local pattern = library.fn == "gsub" and library.literals[2] or nil -- checked: and_ternary
    key = pattern ~= nil and Literals.key(pattern) or nil -- checked: and_ternary
    if #list == 1 and (first.tag == "fn") then
      refined = Calls.refine(ctx, library, first)
    else
      list = Calls.refine_overloads(ctx, library, list)
    end
  end
  if #list == 1 then
    if (first.tag == "fn") then
      if ctx.typed then
        ctx.callees[base_of(node).id] = first
      end
      if #first.tparams > 0 then
        return Calls.generic(ctx, node, callee, first, args, recv, recv_node, expected)
      end
      local strict = refined ~= nil and library ~= nil and library.fn == "format"
      return apply_function(ctx, node, callee, refined or first, args, recv, recv_node, nil, nil, strict)
    end
    report(ctx, "not_callable", callee_node, quoted(callee) .. " is " .. tq(ctx, first) .. ", which is not a function",
      if (first.tag == "union") then "narrow it to one function first" else "call a function" end, { show(ctx, first) })
    unchecked_arguments(ctx, args)
    return unknown_lists(ctx)
  end
  return apply_overloads(ctx, node, callee, list, args, recv, expected, key)
end

function Calls.weak_mode(args: {Ast.Exp}): string?
  local made, meta = args[1], args[2]
  if #args ~= 2 or made == nil or meta == nil or not ((made.kind == "Table")) or #made.items ~= 0 or
      not ((meta.kind == "Table")) or #meta.items ~= 1 then
    return nil
  end
  local item = meta.items[1]
  if not ((item.kind == "Named")) or item.name ~= "__mode" then
    return nil
  end
  local value = item.value
  if (value.kind == "String") and (value.value == "k" or value.value == "v" or value.value == "kv") then
    return value.value
  end
  return nil
end

--- The hint for `r.m(r, ...)`, a call of a method with `.` and its receiver as the first argument. `callee` is the type of the
--- function: a method is a function whose first parameter is the declaration of the object it is read from, and the call
--- passes a value of that declaration first.
--- Whether `e` is a name, or a chain of fields of a name: a place that reads the same each time, with no call, method call or
--- index to run between.
function Calls.plain_place(e: Ast.Exp): boolean
  local node = e
  while (node.kind == "Field") do
    node = node.object
  end
  return (node.kind == "Name")
end

function Calls.method_dot(ctx: Ctx, n: Ast.Call, callee: Type, object: Type)
  local field = n.callee
  if not ((field.kind == "Field")) or not ((callee.tag == "fn")) or not ((object.tag == "named")) or object.value then
    return
  end
  local first = callee.params[1]
  local given = n.args[1]
  if first == nil or given == nil then
    return
  end
  local receiver = first.type
  if not ((receiver.tag == "named")) or receiver.value or receiver.decl ~= object.decl then
    return
  end
  -- The receiver named twice: the first argument is the object the method was read from. Only a place that reads the same
  -- twice (a name, or fields of one) is: `mk().get(mk())` makes two objects, and `mk():get()` would make one.
  if not Calls.plain_place(field.object) then
    return
  end
  local who = text_of(ctx, field.object)
  if text_of(ctx, given) ~= who then
    return
  end
  local rest: mut {string} = {}
  for i = 2, #n.args do
    local item = n.args[i]
    if item ~= nil then
      rest[#rest + 1] = text_of(ctx, item)
    end
  end
  local call = who .. ":" .. field.name .. "(" .. table.concat(rest, ", ") .. ")"
  Tests.warn(ctx, "method_dot", n, quoted(field.name) .. " is a method of " .. tq(ctx, object) .. ", called with `.` and its " ..
      "receiver as the first argument", "write " .. quoted(call) .. " and pass the receiver once")
end

return Calls
