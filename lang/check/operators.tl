--- The types of binary and unary expressions, `if` expressions, and what an `is` test reads.

local Ast = require("lang.ast")
local Flow = require("lang.flow")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local Refusals = require("lang.check.refusals")
local Names = require("lang.check.names")
local Lookup = require("lang.check.members")
local TableLiterals = require("lang.check.table_literals")
local Places = require("lang.check.places")
local Tests = require("lang.check.tests")
local Operands = require("lang.check.operands")
local Narrowing = require("lang.check.narrowing")
local type Type = Types.Type
local type Ctx = Context.Ctx
local below = Context.below
local has_enum = Context.has_enum
local is_bool = Context.is_bool
local is_integer_enum = Context.is_integer_enum
local is_text = Context.is_text
local listed = Context.listed
local members_of = Context.members_of
local nilable = Context.nilable
local quoted = Context.quoted
local report = Naming.report
local show = Context.show
local subject = Context.subject
local text_of = Context.text_of
local tq = Context.tq
local ARITHMETIC = Operands.ARITHMETIC
local BITWISE = Operands.BITWISE
local DIVISION = Operands.DIVISION
local KIND_WORDS = Lookup.KIND_WORDS
local ORDERED = Operands.ORDERED
local condition = Narrowing.condition
local condition_kind = Operands.condition_kind
local expect = Refusals.expect
local join = TableLiterals.join
local merge = Places.merge
local merge_all = Places.merge_all
local string_literal = Names.string_literal
local type_names = TableLiterals.type_names

--- The checks of a binary or unary operator, and of the `is` test and the `if` expression.
local record Operators
end

--- `a == b` and `a ~= b`: both sides overlap, else the test is dead.
function Operators.equality(ctx: Ctx, node: Ast.Binary, left: Type, right: Type)
  if not Operands.overlaps(ctx, left, right) then
    report(ctx, "compare_disjoint", node, subject(ctx, node.left) .. " is " .. tq(ctx, left) .. " and " ..
        subject(ctx, node.right) .. " is " .. tq(ctx, right) .. ", which share no value: the test is never " ..
        (if node.op == "==" then "true" else "false" end),
      "compare values of one type, or remove the test", { show(ctx, left), show(ctx, right) })
  end
end

--- `a < b` and the rest: two numbers or two strings.
--- Notes that the comparison `node` runs code of the program, which may shorten any array, as a call may.
function Operators.runs(ctx: Ctx, node: Ast.Binary)
  ctx.runs[node.id] = true
  ctx.flow = Flow.forget_lengths(ctx.flow)
end

function Operators.ordered(ctx: Ctx, node: Ast.Binary, left: Type, right: Type)
  local l, r = left, right
  local function number(t: Type): boolean
    return t.tag == "integer" or t.tag == "number" or is_integer_enum(t)
  end
  if l.tag == "invalid" or r.tag == "invalid" or l.tag == "never" or r.tag == "never" then
    return
  end
  if number(l) and number(r) or is_text(l) and is_text(r) then
    return
  end
  -- Two values of one parameter bounded by `Ordered` are both numbers or both strings; one bounded by `Numeric` is a number.
  if l == r and Operands.bounded_by(ctx, l, "Ordered") then
    Operators.runs(ctx, node)
    return
  end
  -- Two values of a class compare through the metamethod it declares: `<` and `>` call `__lt`, `<=` and `>=` `__le`.
  if l == r and (l.tag == "named") and l.decl.kind == "class" and not l.value then
    local meta = if node.op == "<" or node.op == ">" then "__lt" else "__le" end
    if Types.declares_method(l, meta) then
      Operators.runs(ctx, node)
      return
    end
    Operands.bad_operand(ctx, node.left, l, node.op, "numbers, strings, or values of a class that declares `" .. meta .. "`",
      "declare `function " .. meta .. "(self, other: " .. show(ctx, l) .. "): boolean` in " .. tq(ctx, l))
    return
  end
  if (Operands.bounded_by(ctx, l, "Numeric") or number(l)) and (Operands.bounded_by(ctx, r, "Numeric") or number(r)) then
    return
  end
  -- A value of a class compares only with another of the same class, which is given to its metamethod.
  local function class_of(t: Type): boolean
    return (t.tag == "named") and t.decl.kind == "class" and not t.value
  end
  if class_of(l) or class_of(r) then
    local fix = "compare two values of one class, which " .. quoted(node.op) .. " gives to its `" ..
      (if node.op == "<" or node.op == ">" then "__lt" else "__le" end) .. "`: it converts nothing"
    if class_of(l) then
      Operands.bad_operand(ctx, node.right, r, node.op, "a value of " .. tq(ctx, l) .. ", as its left operand is", fix)
    else
      Operands.bad_operand(ctx, node.left, l, node.op, "a value of " .. tq(ctx, r) .. ", as its right operand is", fix)
    end
    return
  end
  local fix = "compare two numbers or two strings: " .. quoted(node.op) .. " converts nothing"
  if number(l) or is_text(l) then
    local wanted = if number(l) then "a number" else "a string" end
    if nilable(r) or r.tag == "any" or (r.tag == "var") then
      Operands.bad_operand(ctx, node.right, r, node.op, wanted .. ", as its left operand is", fix)
    else
      Operands.bad_operand(ctx, node.right, r, node.op, wanted .. ", as its left operand is", fix)
    end
  elseif number(r) or is_text(r) then
    Operands.bad_operand(ctx, node.left, l, node.op, (if number(r) then "a number" else "a string" end) .. ", as its right operand is", fix)
  else
    Operands.bad_operand(ctx, node.left, l, node.op, "numbers or strings", fix)
  end
end

--- `a or b`: both booleans, or a `T?` replaced by a default of its own type.
function Operators.disjunction(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type?): Type
  local store = ctx.store
  local left_kind = if left.tag == "invalid" then "bad" else condition_kind(ctx, node.left, left, node) end
  if left_kind == "bad" then
    local _ = ctx.walk.expr(ctx, node.right, nil)
    return ctx.invalid
  end
  if left_kind == "bool" then
    local right = ctx.walk.expr(ctx, node.right, expected)
    -- A `never` left cannot occur: the result is the right operand's, as in the `T?` path below, where `join` drops `never`.
    if left.tag == "never" then
      return right
    end
    if is_bool(right) or right.tag == "never" or right.tag == "invalid" then
      return store.boolean
    end
    report(ctx, "or_mix", node, subject(ctx, node.left) .. " is a boolean and " .. subject(ctx, node.right) .. " is " ..
        tq(ctx, right) .. ": `or` of a boolean and another type answers either",
      "write the test: `if " .. text_of(ctx, node.left) .. " then ... else ... end`, or make both operands booleans",
      { show(ctx, left), show(ctx, right) })
    return ctx.invalid
  end
  local kept = store:non_nil(left)
  -- An enum is not the position of a string: `x or "lit"` joins to `string`.
  local right: Type
  if kept.tag == "never" or has_enum(ctx, kept) then
    right = ctx.walk.expr(ctx, node.right, expected)
  else
    right = ctx.walk.expr(ctx, node.right, kept)
  end
  if right.tag == "invalid" then
    return right
  end
  local both = join(ctx, { kept, right })
  if both == nil then
    report(ctx, "or_mix", node, subject(ctx, node.left) .. " is " .. tq(ctx, left) .. " and " .. subject(ctx, node.right) ..
        " is " .. tq(ctx, right) .. ", which have no common type for the default",
      "give a default of " .. tq(ctx, kept) .. ", or write the test: `if " .. text_of(ctx, node.left) .. " == nil then " ..
        "... end`", { show(ctx, left), show(ctx, right) })
    return ctx.invalid
  end
  return both
end

--- `a and b`: both booleans, or a `T?` guarding a value, which is optional.
function Operators.conjunction(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type?): Type
  local store = ctx.store
  local left_kind = if left.tag == "invalid" then "bad" else condition_kind(ctx, node.left, left) end
  if left_kind == "bad" then
    local _ = ctx.walk.expr(ctx, node.right, nil)
    return ctx.invalid
  end
  -- A `never` left cannot occur, so it is no boolean: the result is the right operand or nil, as for a `T?` left.
  local boolean = left_kind == "bool" and left.tag ~= "never"
  local right = ctx.walk.expr(ctx, node.right, if boolean then expected else nil end)
  if right.tag == "invalid" then
    return right
  end
  if boolean then
    if is_bool(right) or right.tag == "never" then
      return store.boolean
    end
    local parent = ctx.ternaries[node.id]
    if parent ~= nil then
      report(ctx, "and_ternary", parent, subject(ctx, parent) .. " is a ternary: it answers " .. subject(ctx, parent.right) ..
          " when " .. subject(ctx, node.right) .. " is false or nil",
        "use the `if` expression: `if " .. text_of(ctx, node.left) .. " then " .. text_of(ctx, node.right) .. " else " ..
          text_of(ctx, parent.right) .. " end`")
      return ctx.invalid
    end
    report(ctx, "or_mix", node, subject(ctx, node.left) .. " is a boolean and " .. subject(ctx, node.right) .. " is " ..
        tq(ctx, right) .. ": `and` answers the left operand when it is false",
      "write the test: `if " .. text_of(ctx, node.left) .. " then ... end`, or make both operands booleans",
      { show(ctx, left), show(ctx, right) })
    return ctx.invalid
  end
  return store:optional(right)
end

--- `a and b` and `a or b` whose left operand has type `left`: the right operand is evaluated under the state where the
--- left is true (`and`) or false (`or`), and what follows has the states of both ways out met: the left's short cut and
--- the right operand's end, which a call that never returns does not reach.
function Operators.logical(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type?): Type
  local is_and = node.op == "and"
  local ly, ln = ctx.walk.edges(ctx, ctx.flow, node.left)
  local into, short = ly, ln
  if not is_and then
    into, short = ln, ly
  end
  ctx.flow = into
  local result: Type
  if is_and then
    result = Operators.conjunction(ctx, node, left, expected)
  else
    result = Operators.disjunction(ctx, node, left, expected)
  end
  local after = ctx.flow
  local ry, rn = ctx.walk.edges(ctx, after, node.right)
  local yes, no = ry, merge(ctx, ln, rn)
  if not is_and then
    yes, no = merge(ctx, ly, ry), rn
  end
  local met = merge(ctx, short, after)
  ctx.edges[node.id] = { post = met, yes = yes, no = no }
  ctx.flow = met
  return result
end

--- A binary expression whose left operand has type `left`.
function Operators.binary(ctx: Ctx, node: Ast.Binary, left: Type, expected: Type?): Type
  local store = ctx.store
  local op = node.op
  if op == "or" or op == "and" then
    return Operators.logical(ctx, node, left, expected)
  end
  local outer = ctx.comparing
  if op == "==" or op == "~=" then ctx.comparing = node end
  local right = ctx.walk.expr(ctx, node.right, if op == "==" or op == "~=" then left else nil end)
  ctx.comparing = outer
  if op == ".." then
    local l, r = Operands.string_operand(ctx, node.left, left), Operands.string_operand(ctx, node.right, right)
    return (l and r) and store.string or ctx.invalid -- checked: and_ternary
  elseif ARITHMETIC[op] == true or DIVISION[op] == true then
    local l, r = Operands.arithmetic_operand(ctx, node.left, left, op), Operands.arithmetic_operand(ctx, node.right, right, op)
    if l == 0 or r == 0 then
      return ctx.invalid
    end
    if (l == 3 or r == 3) and ARITHMETIC[op] == true then
      -- A `Numeric` parameter is `integer` or `number`: with itself or an integer the operation gives its own type, as
      -- Lua's arithmetic of two integers is an integer and of a float a float.
      if l == 3 and (r == 1 or right == left) then
        return left
      elseif r == 3 and l == 1 then
        return right
      end
    end
    return (l == 1 and r == 1 and ARITHMETIC[op]) and store.integer or store.number -- checked: or_mix
  elseif BITWISE[op] == true then
    local l, r = Operands.integer_operand(ctx, node.left, left, op), Operands.integer_operand(ctx, node.right, right, op)
    return (l and r) and store.integer or ctx.invalid -- checked: and_ternary
  elseif ORDERED[op] == true then
    Operators.ordered(ctx, node, left, right)
    return store.boolean
  end
  local left_node = node.left
  if (left_node.kind == "String") and has_enum(ctx, right) then
    ctx.comparing = node
    local _ = string_literal(ctx, left_node, right)
    ctx.comparing = outer
  end
  Operators.equality(ctx, node, left, right)
  return store.boolean
end

--- A unary expression whose operand has type `operand`.
function Operators.unary(ctx: Ctx, node: Ast.Unary, operand: Type): Type
  local op = node.op
  if op == "not" then
    local _ = condition_kind(ctx, node.operand, operand)
    return ctx.store.boolean
  elseif op == "#" then
    return Operands.length_operand(ctx, node.operand, operand) and ctx.store.integer or ctx.invalid -- checked: and_ternary
  elseif op == "-" then
    local c = Operands.arithmetic_operand(ctx, node.operand, operand, "-")
    if c == 3 then
      return operand
    end
    return c == 1 and ctx.store.integer or c == 2 and ctx.store.number or ctx.invalid -- checked: and_ternary, or_mix
  end
  return Operands.integer_operand(ctx, node.operand, operand, "~") and ctx.store.integer or ctx.invalid -- checked: and_ternary
end

--- Whether a value of type `value` may be a `tested`: some member of one is below some member of the other (a class
--- below the interface the value is of, a number below `number`), as for `==`. `any`, `invalid` and a type variable,
--- which the code around may instantiate as the type, overlap everything.
function Operators.testable(ctx: Ctx, value: Type, tested: Type): boolean
  if value == tested or value.tag == "any" or tested.tag == "any" or value.tag == "invalid" or tested.tag == "invalid" or
      value.tag == "never" or tested.tag == "never" then
    return true
  end
  local store = ctx.store
  for _, x in ipairs(members_of(store, value)) do
    for _, y in ipairs(members_of(store, tested)) do
      if x == y or (x.tag == "var") or (y.tag == "var") or below(ctx, x, y) or below(ctx, y, x) then
        return true
      end
    end
  end
  return false
end

--- `e is T`: a test of a run-time tag.
function Operators.is_test(ctx: Ctx, node: Ast.IsTest, value: Type): Type
  local tested = ctx.lowered.types[node.type.id] or ctx.invalid
  if tested.tag == "invalid" or value.tag == "invalid" then
    return ctx.store.boolean
  end
  Tests.parenthesized(ctx, node)
  Operators.tested(ctx, node, node.type, node.value, value, tested, false)
  return ctx.store.boolean
end

--- Reports a test at `node` of whether the value of `value_node`, of type `value`, is a `tested`, written as `type_node`,
--- where the run-time Lua cannot tell it, and notes how the code generator tells a record ([`Check.Checked`]'s `tags`).
--- `arm` says the test is the arm of a typed `match`, which the messages name.
function Operators.tested(ctx: Ctx, node: Ast.Node, type_node: Ast.Type, value_node: Ast.Node, value: Type, tested: Type,
                          arm: boolean)
  local store = ctx.store
  local written = if arm then "the arm `| " .. show(ctx, tested) .. "`" else "`is " .. show(ctx, tested) .. "`" end
  local function refuse(why: string, fix?: string)
    report(ctx, "is_on_record", node, written .. " cannot be told by a run-time tag: " .. why,
      fix or "test a tag (`x.kind == \"...\"`), declare a class, or validate the data with a [`cosmic.shape`] validator",
      { show(ctx, tested) })
  end
  local library = ctx.program.globals["table"]
  if (tested.tag == "named") and library ~= nil and tested.decl == library.decl then
    return
  end
  local before = #ctx.errors
  local tag = if (tested.tag == "named") and tested.decl.kind == "record" then Tests.record_tag(ctx, value, tested) else nil end
  local untold: Type? = nil
  if (tested.tag == "union") then
    -- An alias of a union is tested for each member, and a record among them by a test the code generator writes for
    -- the alias wherever it is used: none is written, and the test is refused.
    for _, m in ipairs(members_of(store, tested)) do
      if untold == nil and (m.tag == "named") and m.decl.kind == "record" and not m.value then
        untold = m
      end
    end
  end
  if tag ~= nil then
    -- The record is the one table the value may be, or the one its tag says.
    ctx.tags[type_node.id] = tag
  elseif untold ~= nil then
    refuse("an alias of a union is tested for each member, and the record " .. tq(ctx, untold) .. " among them is not",
      if arm then "write an arm for each record (`| A a then ... | B b then ...`), which reads its tag" else
        "test each record apart (`v is A or v is B`), which reads its tag" end)
  elseif (tested.tag == "named") and tested.decl.kind ~= "enum" and tested.decl.kind ~= "class" then
    local word = KIND_WORDS[tested.decl.kind] or "type"
    local tables = Tests.table_members(ctx, value)
    local records = tables ~= nil
    for _, m in ipairs(tables or {}) do
      records = records and (m.tag == "named") and (m.decl.kind == "record" or m.decl.kind == "class")
    end
    if tested.decl.kind == "record" and #tested.args == 0 and tables ~= nil and #tables > 1 and records then
      -- A record is told by its tag where the other tables the value may be have one too.
      refuse(subject(ctx, value_node) .. " is " .. tq(ctx, value) .. ", whose tables no tag field tells apart",
        "give each record of the union a fixed field of its own string literal type (`kind: \"" ..
          (if Types.shape_record(tested.decl) then "name" else tested.decl.name:lower() end) ..
          "\"`), so that `is` tests it, or validate the data with a [`cosmic.shape`] validator")
    else
      refuse((if word:sub(1, 1) == "i" then "an " else "a " end) .. word .. " leaves nothing to test")
    end
  elseif (tested.tag == "named") and tested.decl.kind == "class" and TableLiterals.out_of_reach(ctx, tested.decl) ~= "" then
    report(ctx, "class_scope", node, written .. " tests the metatable of " ..
        TableLiterals.out_of_reach(ctx, tested.decl),
      TableLiterals.reach_fix(ctx, tested.decl, "test in " .. quoted(tested.decl.module) .. " with a function of the class (`function " ..
          tested.decl.name .. ".owns(v: any): boolean`), and call it here"), { show(ctx, tested) })
  elseif (tested.tag == "named") and tested.decl.kind == "class" and #tested.args > 0 then
    refuse("the metatable tells the class and not its type arguments")
  elseif (tested.tag == "fn") then
    refuse("a function type is tested as `function` and its parameters go unchecked")
  elseif value.tag == "any" and ((tested.tag == "array") or (tested.tag == "map") or (tested.tag == "union")) then
    refuse("the tag says `table` and the contents of untrusted data go unchecked")
  elseif (tested.tag == "array") or (tested.tag == "map") then
    refuse("the tag says `table` and the elements go unchecked")
  end
  -- A test the rules refuse is reported once, for that.
  if #ctx.errors == before and not Operators.testable(ctx, value, tested) then
    report(ctx, "is_disjoint", node, subject(ctx, node) .. " is always false: " .. subject(ctx, value_node) .. " is " ..
        tq(ctx, value) .. ", and no value of it is " .. tq(ctx, tested),
      "this test is always false: remove it and the branch it guards, or test a type that " .. subject(ctx, value_node) ..
        " can have (" .. tq(ctx, value) .. ")", { show(ctx, value), show(ctx, tested) })
  end
end

--- An `if` expression: conditions, and arms with a common type. Each arm is evaluated under the state where its
--- condition holds and those before it do not.
function Operators.if_expression(ctx: Ctx, node: Ast.IfExp, expected: Type?): Type
  local types: mut {Type} = {}
  local ends: mut {Flow.State} = {}
  for _, arm in ipairs(node.arms) do
    local _ = condition(ctx, arm.cond)
    local yes, no = ctx.walk.edges(ctx, ctx.flow, arm.cond)
    ctx.flow = yes
    types[#types + 1] = ctx.walk.expr(ctx, arm.value, expected)
    ends[#ends + 1] = ctx.flow
    ctx.flow = no
  end
  types[#types + 1] = ctx.walk.expr(ctx, node.else_value, expected)
  ends[#ends + 1] = ctx.flow
  ctx.flow = merge_all(ctx, ends)
  local both = join(ctx, types)
  if both == nil then
    if expected ~= nil and expected.tag ~= "any" then
      -- No common type, but each arm may be what the position wants.
      local ok = true
      for i, arm in ipairs(node.arms) do
        ok = expect(ctx, arm.value, types[i], expected, " as an arm of this `if`") and ok -- checked: index_may_be_nil
      end
      local _ = expect(ctx, node.else_value, types[#types], expected, " as an arm of this `if`") -- checked: index_may_be_nil
      return expected
    end
    report(ctx, "arms_differ", node, "the arms of this `if` have no common type: " .. listed(type_names(ctx, types)),
      "type the result: `local name: " .. show(ctx, types[1]) .. " = if ... end`, or make the arms one type") -- checked: index_may_be_nil
    return ctx.invalid
  end
  return both
end

return Operators
