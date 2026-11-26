--- The operands of the operators: the types an arithmetic, a comparison or a length takes, and the fix of one it refuses.

local Ast = require("lang.ast")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local ValueLists = require("lang.check.values")
local Refusals = require("lang.check.refusals")
local Lookup = require("lang.check.members")
local type Type = Types.Type
local type Ctx = Context.Ctx
local base_of = Context.base_of
local below = Context.below
local is_bool = Context.is_bool
local is_integer_enum = Context.is_integer_enum
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
local members_index = Lookup.members_index
local nil_fix = Refusals.nil_fix

--- The checks of the operands of an operator: what each takes, and the error where it is refused.
local record Operands
  ARITHMETIC: {string: boolean}
  DIVISION: {string: boolean}
  BITWISE: {string: boolean}
  ORDERED: {string: boolean}
  UNDECLARED_RETURN_FIX: string
  UNDECLARED_CALL_FIX: string
end

local ARITHMETIC <const>: {string: boolean} = { ["+"] = true, ["-"] = true, ["*"] = true, ["%"] = true, ["//"] = true }
Operands.ARITHMETIC = ARITHMETIC

local DIVISION <const>: {string: boolean} = { ["/"] = true, ["^"] = true }
Operands.DIVISION = DIVISION

local BITWISE <const>: {string: boolean} = { ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true }
Operands.BITWISE = BITWISE

local ORDERED <const>: {string: boolean} = { ["<"] = true, [">"] = true, ["<="] = true, [">="] = true }
Operands.ORDERED = ORDERED

--- Reports that the operand `node`, of type `t`, is not what `op` takes.
--- The fix for the class `class` held against `Ordered`: the comparison methods it does not declare.
function Operands.compare_fix(ctx: Ctx, class: Type): string
  local shown = show(ctx, class)
  local lt = Types.declares_method(class, "__lt")
  local le = Types.declares_method(class, "__le")
  local missing = if lt then "__le" elseif le then "__lt" else nil end
  if missing ~= nil then
    return "declare `function " .. missing .. "(self, other: " .. shown .. "): boolean` in " .. tq(ctx, class) .. ": it declares `" ..
      (if lt then "__lt" else "__le" end) .. "`, and `Ordered` takes a class that declares both"
  end
  return "declare `function __lt(self, other: " .. shown .. "): boolean` and `function __le(self, other: " .. shown ..
    "): boolean` in " .. tq(ctx, class) .. ", or pass numbers or strings"
end

function Operands.bad_operand(ctx: Ctx, node: Ast.Node, t: Type, op: string, takes: string, fix: string)
  local s = subject(ctx, node)
  if t.tag == "any" then
    report(ctx, "any_use", node, s .. " is untrusted data (`any`), and " .. quoted(op) .. " takes " .. takes,
      "validate it with a [`cosmic.shape`] validator, or test its tag, and use the checked value", { "any" })
  elseif (t.tag == "var") then
    local name = show(ctx, t)
    local bound = if ORDERED[op] == true then "Ordered" elseif ARITHMETIC[op] == true or DIVISION[op] == true or
        op == "-" or op:find("^for ") ~= nil then "Numeric" else nil end
    local ordered = ctx.judge:subtype(t, ctx.store:atom("Ordered"))
    local numeric = ctx.judge:subtype(t, ctx.store:atom("Numeric"))
    if bound == "Ordered" and ordered then
      -- `Ordered` says two values of the parameter compare, and nothing of a value of another type.
      bound = "Numeric"
    end
    local bound_fix = if bound ~= nil then "bound " .. quoted(name) .. " by `" .. bound .. "` where it is declared (`<" .. name ..
        " is " .. bound .. ">`): " .. (if bound == "Ordered" then "a number type, a string type, or a class that declares `__lt` and `__le` meets it, and `<` " ..
            "compares two values of " .. quoted(name) else "`integer` and `number` meet it, and arithmetic of two values of " ..
            quoted(name) .. " answers " .. quoted(name) end) else
      "convert the value first, or declare the parameter with the type " .. quoted(op) .. " takes: no bound declares it" end
    report(ctx, "generic_op", node, s .. " is the type parameter " .. tq(ctx, t) .. ", which " ..
        (if numeric then "is bounded by `Numeric`, which takes arithmetic and comparison with numbers" elseif ordered then
          "is bounded by `Ordered` alone, which compares two of its values"
          else "ranges over every type" end) .. ", and " .. quoted(op) .. " takes " .. takes, bound_fix, { name })
  elseif nilable(t) then
    report(ctx, "nil_not_allowed", node, s .. " is " .. tq(ctx, t) .. ", so it may be nil, and " .. quoted(op) .. " takes " .. takes,
      nil_fix(ctx, node, t), { show(ctx, t) })
  else
    report(ctx, "operand_type", node, s .. " is " .. tq(ctx, t) .. ", and " .. quoted(op) .. " takes " .. takes, fix,
      { show(ctx, t) })
  end
end

--- Whether no value of `t` is nil ([`Types.present`]), where a type parameter of the code around is never nil once a
--- bound bounds it: each bound is below `Some`, which holds no `nil`.
function Operands.present(ctx: Ctx, t: Type): boolean
  return ValueLists.present(ctx, t)
end

--- Whether `t` is a type parameter bounded by `bound` (`Ordered` or `Numeric`), or by one below it.
function Operands.bounded_by(ctx: Ctx, t: Type, bound: Types.Atom_tag): boolean
  return (t.tag == "var") and ctx.judge:subtype(t, ctx.store:atom(bound))
end

--- What `t` is as an operand of a number operator: 1 `integer`, 2 `number`, 3 a type parameter bounded by `Numeric`,
--- 0 anything else (reported unless it is `invalid`).
function Operands.arithmetic_operand(ctx: Ctx, node: Ast.Node, t: Type, op: string): integer
  local tag = t.tag
  if tag == "integer" or tag == "never" or is_integer_enum(t) then
    return 1
  elseif tag == "number" then
    return 2
  elseif tag == "invalid" then
    return 0
  elseif Operands.bounded_by(ctx, t, "Numeric") then
    return 3
  end
  local inner = nilable(t) and ctx.store:non_nil(t) or t -- checked: and_ternary
  local fix = if is_text(t) then "convert it with `tonumber(" .. text_of(ctx, node) .. ")`" else
    "use a number: " .. quoted(op) .. " converts nothing" end
  Operands.bad_operand(ctx, node, t, op, "numbers", fix)
  if nilable(t) and inner.tag == "integer" then
    return 1
  elseif nilable(t) and inner.tag == "number" then
    return 2
  end
  return 0
end

--- Whether `t` is an `integer`, as the operand of a bit operator; reports it where not.
function Operands.integer_operand(ctx: Ctx, node: Ast.Node, t: Type, op: string): boolean
  if t.tag == "integer" or t.tag == "never" or is_integer_enum(t) then
    return true
  elseif t.tag == "invalid" then
    return false
  end
  local fix = if t.tag == "number" then "convert it with `math.tointeger(" .. text_of(ctx, node) .. ")` or `math.floor(" ..
      text_of(ctx, node) .. ")`" else "use an integer: " .. quoted(op) .. " converts nothing" end
  Operands.bad_operand(ctx, node, t, op, "integers", fix)
  return false
end

--- Whether `t` is a string, as an operand of `..`; reports it where not.
function Operands.string_operand(ctx: Ctx, node: Ast.Node, t: Type): boolean
  if is_text(t) or t.tag == "never" then
    return true
  end
  -- A union of enums and strings, none of it nil, is a string whichever member it is.
  -- TODO: take the same union as the operand of `#` and of the orderings, which [`is_text`] refuses where it is not one enum or
  -- `string`, once a program of the tree writes one.
  if (t.tag == "union") and not t.nilable then
    local text = true
    for _, m in ipairs(t.members) do
      text = text and is_text(m)
    end
    if text then
      return true
    end
  end
  if t.tag == "invalid" then
    return false
  end
  if t.tag == "integer" or t.tag == "number" or is_integer_enum(t) or is_bool(t) then
    report(ctx, "concat_type", node, subject(ctx, node) .. " is " .. tq(ctx, t) .. ", and `..` takes strings",
      "write `tostring(" .. text_of(ctx, node) .. ")` or `string.format(\"%d\", " .. text_of(ctx, node) .. ")`",
      { show(ctx, t) })
    return false
  end
  Operands.bad_operand(ctx, node, t, "..", "strings", "convert it to a string first: `tostring(" .. text_of(ctx, node) .. ")`")
  return false
end

--- Whether `t` has a length: a string, an array, a record with an array part.
function Operands.length_operand(ctx: Ctx, node: Ast.Node, t: Type): boolean
  if is_text(t) or (t.tag == "array") or t.tag == "never" then
    return true
  elseif t.tag == "invalid" then
    return false
  elseif (t.tag == "named") then
    local index = members_index(ctx, t.decl, t.value)
    if index ~= nil and index.array ~= nil then
      return true
    end
  end
  Operands.bad_operand(ctx, node, t, "#", "a string or an array", if (t.tag == "map") then
    "a map has no length: keep a count, or use an array" else "take the length of a string or an array" end)
  return false
end

--- Whether the type of an `==` operand and another may be equal: they overlap, some member of one is below some member
--- of the other. `any` and `invalid` overlap everything; a type variable overlaps itself and nil.
function Operands.overlaps(ctx: Ctx, a: Type, b: Type): boolean
  if a == b or a.tag == "any" or b.tag == "any" or a.tag == "invalid" or b.tag == "invalid" or a.tag == "never" or
      b.tag == "never" then
    return true
  end
  local store = ctx.store
  for _, x in ipairs(members_of(store, a)) do
    for _, y in ipairs(members_of(store, b)) do
      if x == y or below(ctx, x, y) or below(ctx, y, x) then
        return true
      end
      if ((x.tag == "var") and y.tag == "nil") or ((y.tag == "var") and x.tag == "nil") then
        return true
      end
    end
  end
  return false
end

--- What the fix of a write through the view `base` adds where a local holds it: a local read out of a collection is a
--- view by that collection's type, which is where `mut` goes.
function Operands.read_out(ctx: Ctx, target: Ast.Index, base: Type): string
  local object = target.object
  if object.kind ~= "Name" then
    return ""
  end
  local id = object.binding
  local v = if id == nil then nil else ctx.scoped.vars[id] end
  if v == nil or not (v.kind == "local" or v.kind == "loop") then
    return ""
  end
  return "; one read out of a collection is `mut` where that collection's type says so (`{K: mut " .. show(ctx, base) .. "}`)"
end

--- Whether the return `s` returns the results of one call alone.
function Operands.returns_call(s: Ast.Return): boolean
  local only = s.values[1]
  return #s.values == 1 and only ~= nil and (only.kind == "Call" or only.kind == "MethodCall")
end

--- The fix of a value returned by a function that declares no return list: a function literal passed where one that
--- returns nothing is wanted is such a function, and the call it returns is written as a statement.
local UNDECLARED_RETURN_FIX <const> = "declare the return list: `function f(): T`"
Operands.UNDECLARED_RETURN_FIX = UNDECLARED_RETURN_FIX

local UNDECLARED_CALL_FIX <const> = UNDECLARED_RETURN_FIX .. "; where a function that answers nothing is wanted, write the call as " ..
  "a statement, with no `return`"
Operands.UNDECLARED_CALL_FIX = UNDECLARED_CALL_FIX

--- What a condition of type `t` is: "bool", "opt" (a `T?` for a `T` that is not a boolean), or "bad" after the error.
--- `default` is the `or` whose left `node` is, which asks for a default: a value that is never nil there needs no test, and
--- no default.
function Operands.condition_kind(ctx: Ctx, node: Ast.Node, t: Type, default?: Ast.Binary): string
  local tag = t.tag
  if is_bool(t) or tag == "never" or tag == "invalid" then
    return "bool"
  end
  local s = subject(ctx, node)
  if nilable(t) then
    local inner = ctx.store:non_nil(t)
    local boolean = false
    for _, m in ipairs(members_of(ctx.store, inner)) do
      boolean = boolean or is_bool(m)
    end
    if not boolean then
      return "opt"
    end
    report(ctx, "condition_type", node, s .. " is " .. tq(ctx, t) .. ": nil and false would not be told apart",
      "write the test: `" .. text_of(ctx, node) .. " == true` or `" .. text_of(ctx, node) .. " == nil`", { show(ctx, t) })
    return "bad"
  elseif tag == "any" then
    report(ctx, "any_use", node, s .. " is untrusted data (`any`) and is used as a condition",
      "test its tag (`type(" .. text_of(ctx, node) .. ") == \"string\"`) or validate it, and use the checked value", { "any" })
    return "bad"
  end
  local fix = "remove the condition: " .. s .. " is never false"
  if (t.tag == "var") then
    fix = "a type parameter may be nil or false: test it with `" .. text_of(ctx, node) .. " ~= nil` where it is bounded"
  elseif default ~= nil then
    local place = peel(node).kind
    -- `or` cuts a call to its first value. Where the call would then end a list of values (a return, the arguments of
    -- a call, a table), deleting the `or` passes on the values after it, so the fix keeps the cut for a call that may
    -- return more. `...` is always optional and never reaches here.
    local cut = if ctx.spare[base_of(node).id] == true then "replace `" ..
        text_of(ctx, default) .. "` with `(" .. text_of(ctx, node) .. ")`, which keeps only the first value, as `or` did" else
      "delete `or ...`" end
    fix = s .. " is never nil" .. (if place == "Name" or place == "Field" then " here (a test before may have narrowed it)" elseif place == "Index" then
      " here (a loop that counts its keys, or a test or an `assert` before of it or of the length, says so, until a call " ..
        "or a write to what it indexes)" else
      "" end) ..
      ", so the default is never used: " .. cut
  elseif is_text(t) then
    fix = "write the test: `" .. text_of(ctx, node) .. " ~= \"\"`"
  elseif tag == "integer" or tag == "number" then
    fix = "write the test: `" .. text_of(ctx, node) .. " ~= 0`"
  end
  report(ctx, "condition_type", node, s .. " is " .. tq(ctx, t) .. ", which is no boolean or optional, so it is no condition",
    fix, { show(ctx, t) })
  return "bad"
end

return Operands
