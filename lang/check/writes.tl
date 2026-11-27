--- The checks of writes to tables: a write that leaves no hole in an array, a read counted by a test, and `table.move`.

local Ast = require("lang.ast")
local Codes = require("lang.check_codes")
local Lexer = require("lang.lexer")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local ValueLists = require("lang.check.values")
local type Type = Types.Type
local type Alt = Types.Alt
local type Ctx = Context.Ctx
local type Fill = Context.Fill
local type Grow = Context.Grow
local type Privacy = Context.Privacy
local type Span = Context.Span
local nilable = Context.nilable
local peel = Context.peel
local report = Naming.report
local show = Context.show
local subject = Context.subject
local text_of = Context.text_of
local type Values = ValueLists.Values

--- An index write to a `mut` array that is not an append, whose verdict waits for the values of its statement, which say
--- whether the value written is nil.
local record Pending
  target: Ast.Index
  --- Its place among the targets of the statement.
  at: integer
  owner: string
  base: Type
  --- The write is to a view: its `view_written` waits for the values, which tell whether the write may leave a hole.
  view: boolean
  --- The key is an integer, so a key in the range `1` to `#t` is a key of the array ([`Writes.ranges_of`]).
  integral: boolean
end

--- A bound that a comparison sets on a local integer ([`Writes.bound`]).
local record Bound
  --- The id of the binding of the local bounded.
  var: integer
  --- The local `t` of an upper bound `#t`, or nil for a lower bound of 1.
  array?: Ast.Exp
end

--- The rules by which an index write to an array, `mut` or a view, is no hole ([`Writes.leaves_no_hole`]).
local record Writes
  type Pending = Pending
  type Bound = Bound
end

--- Whether `a` and `b` name the same place: a name, or fields of one.
function Writes.same_place(a: Ast.Exp, b: Ast.Exp): boolean
  local x, y = peel(a), peel(b)
  if (x.kind == "Name") and (y.kind == "Name") then
    return x.binding ~= nil and x.binding == y.binding
  elseif (x.kind == "Field") and (y.kind == "Field") then
    return x.name == y.name and Writes.same_place(x.object, y.object)
  end
  return false
end

--- Whether `key` is `#object`: the key of the last element of the array `object`.
function Writes.is_length_of(key: Ast.Exp, object: Ast.Exp): boolean
  local len = peel(key)
  return (len.kind == "Unary") and len.op == "#" and Writes.same_place(len.operand, object)
end

--- Whether `e` is `#place` for `array`, or `#array - k` for a literal `k` of 0 or more: at most the length of the array.
function Writes.at_most_length(e: Ast.Exp, array: Ast.Exp): boolean
  local x = peel(e)
  if (x.kind == "Binary") and x.op == "-" then
    local k = peel(x.right)
    return (k.kind == "Integer") and k.value >= 0 and Writes.is_length_of(x.left, array)
  end
  return Writes.is_length_of(e, array)
end

--- Whether `e` is a name, or a field of one.
function Writes.is_place(e: Ast.Exp): boolean
  local x = peel(e)
  if (x.kind == "Name") then
    return true
  end
  return (x.kind == "Field") and Writes.is_place(x.object)
end

--- Whether the call `table.move(a1, f, e, t [, a2])` keeps the array it writes dense and copies only elements that are
--- there. `a1` and `a2` are arrays with elements 1 to their length, none nil, so the copy
---   - reads elements `f` to `e` of `a1`, all there when `f` is a literal of 1 or more and `e` is at most `#a1` (the
---     range is empty where `e` is below `f`), and
---   - writes them at `t` onward, a contiguous run that leaves no gap when `t` is 1 (it starts the array, and the
---     elements past the run stay as they were) or `#a2 + 1` (it continues the array).
--- Every argument is a literal, a place or the length of a place, so nothing runs between reading the lengths and the
--- copy to change them. `a2` may be a table literal where `t` is 1. A `t` of 0 or less writes keys no array has, and a `t`
--- above `#a2 + 1` leaves a hole, so neither stands.
function Writes.move_dense(args: {Ast.Exp}): boolean
  local a1, f, e, t, a2 = args[1], args[2], args[3], args[4], args[5]
  if a1 == nil or f == nil or e == nil or t == nil or #args > 5 or not Writes.is_place(a1) then
    return false
  end
  local from = peel(f)
  if not ((from.kind == "Integer") and from.value >= 1) or not Writes.at_most_length(e, a1) then
    return false
  end
  local to = peel(t)
  if (to.kind == "Integer") and to.value == 1 then
    return a2 == nil or Writes.is_place(a2) or peel(a2).kind == "Table"
  end
  local into = if a2 == nil then a1 else a2 end
  if not Writes.is_place(into) or not ((to.kind == "Binary") and to.op == "+") then
    return false
  end
  local one = peel(to.right)
  return (one.kind == "Integer") and one.value == 1 and Writes.is_length_of(to.left, into)
end

--- Reports the call `node` of `table.move` that [`Writes.move_dense`] does not accept.
function Writes.move_refuse(ctx: Ctx, node: Ast.Call)
  report(ctx, "array_hole", node, "`table.move` here may copy a nil or leave a hole in the array it writes",
    "copy elements that are there (`table.move(a, 1, #a, 1, b)`, the first element being a literal 1 or more and the last " ..
      "`#a`) and write them at 1 or at `#b + 1`; or append with `b[#b + 1] = v` or `table.insert`")
end

--- Reports the reads of `table.move` that are no call: a function value that is called later has no arguments to check.
function Writes.move_stray(ctx: Ctx)
  for _, read in pairs(ctx.moves) do
    report(ctx, "array_hole", read, "`table.move` is read as a value, and a call of it is checked only where it is written",
      "call it where you name it: `table.move(a, 1, #a, 1, b)`")
  end
end

--- Notes the read of the member `name` of `base` at `node`, if it is `table.move` ([`Writes.move_stray`]). Whatever spells
--- the read (`table.move`, `table["move"]`, a name for the library), the member is the one the declaration of `table` has.
function Writes.note_move(ctx: Ctx, node: Ast.Node, base: Type, name: string)
  local library = ctx.program.globals["table"]
  if name == "move" and library ~= nil and (base.tag == "named") and base.decl == library.decl then
    ctx.moves[node.id] = node
  end
end

--- The type column `i` of the lists `alts` gives a name: the union of what each has there, `T?` where one has a tail
--- and nil where one lacks the position.
function Writes.column(ctx: Ctx, alts: {Alt}, i: integer): Type
  local types: mut {Type} = {}
  for _, alt in ipairs(alts) do
    local item = alt.items[i]
    local tail = alt.tail
    if item ~= nil then
      types[#types + 1] = item
    elseif tail ~= nil then
      types[#types + 1] = ctx.store:optional(tail)
    else
      types[#types + 1] = ctx.nil_type
    end
  end
  return ctx.store:union(types)
end
local column = Writes.column

--- The type value `i` of `vals` gives a name, or nil where there is none.
function Writes.value_at(ctx: Ctx, vals: Values, i: integer): Type?
  local held = vals.types[i]
  local several, tail = vals.lists, vals.tail
  if held ~= nil then
    return held
  elseif several ~= nil then
    return column(ctx, several, i)
  elseif tail ~= nil then
    if tail.tag == "invalid" then
      return tail
    end
    return ctx.store:optional(tail)
  end
  return nil
end
local value_at = Writes.value_at

--- Whether the key of `target` is `#object + 1`, which appends.
function Writes.is_append(target: Ast.Index): boolean
  local key = peel(target.key)
  if (key.kind == "Binary") and key.op == "+" then
    local one = key.right
    return Writes.is_length_of(key.left, target.object) and (one.kind == "Integer") and one.value == 1
  end
  return false
end

--- Whether a value of type `t` is known not to be nil: an optional is not, nor is `any`, nor a type with no value.
function Writes.present(t: Type): boolean
  local tag = t.tag
  return not nilable(t) and tag ~= "any" and tag ~= "invalid" and tag ~= "never"
end

--- Whether the statements `body` of a loop leave the number of elements of the array held by the local `array` from falling
--- below what it was before them, and never assign the local `var`, the index of the loop. The code that may shorten the
--- array is a call, an iterator of a generic `for` (a call of its own) and the `__close` of a `<close>` local, and a
--- write of a nil or of the array's name, and a comparison that may call a class's `__lt` or `__le`
--- ([`Writes.plain_compare`]). No other code runs in the body, because no other metamethod can: `class_metamethod` lets
--- a class declare only `__close`, `__tostring` (both reached by the forms above), `__lt`, `__le` and `__gc` (which the VM
--- runs only at a call that is not inert, or of `collectgarbage`, patch/lua/19-finalizers-at-calls-gc.txt), `setmetatable_call`
--- refuses `setmetatable`, and `operand_type` refuses any other operator on a record or a class. The loop rule must be
--- revisited if any of the three is relaxed; lang/check_test.tl pins them beside the loop tests. [`Writes.length_limit`]
--- also relies on `math.min` taking only `Numeric` values (lang/stdlib.d.tl), so that its comparisons call no `__lt`.
---
--- With `pending`, a call that is no [`Writes.scalar_math`] is not refused here but put in `pending`: whether it runs code
--- of the program depends on the types of what it is given, which the walk of the body finds (`ctx.inert`, set where
--- the call is checked). The caller walks the body quietly with the proof and keeps the proof only if each call there
--- was inert (lang/check/init.tl's `for_numeric` and `if_statement`).
function Writes.scalar_math(call: Ast.Call, var: integer): boolean
  local callee = call.callee
  if not ((callee.kind == "Field") and (callee.object.kind == "Name") and callee.object.binding == nil and callee.object.text == "math") then
    return false
  end
  for _, given in ipairs(call.args) do
    if not Writes.scalar(given, var) then
      return false
    end
  end
  return true
end

--- The comparison that holds when the operands of another are swapped: `k <= i` is `i >= k`.
local TURNED <const>: {string: string} = { ["<="] = ">=", ["<"] = ">", [">="] = "<=", [">"] = "<" }

--- Whether the binary `e` runs no code of the program: it is no `<`, `<=`, `>` or `>=`, or an operand is seen to be a
--- number or a string (a literal, an arithmetic or a concatenation, a unary operator, or the local `var`, the index of a
--- loop), and so the other is too and no class's `__lt` or `__le` is called.
function Writes.plain_compare(e: Ast.Binary, var: integer): boolean
  if TURNED[e.op] == nil then
    return true
  end
  for _, side in ipairs({ e.left, e.right }) do
    local at = peel(side)
    if at.kind == "Integer" or at.kind == "Float" or at.kind == "String" or (at.kind == "Unary") or
        ((at.kind == "Name") and at.binding == var) or ((at.kind == "Binary") and TURNED[at.op] == nil and at.op ~= "and" and
            at.op ~= "or" and at.op ~= "==" and at.op ~= "~=") then
      return true
    end
  end
  return false
end

function Writes.scalar(e: Ast.Exp, var: integer): boolean
  local at = peel(e)
  if (at.kind == "Name") then
    return at.binding == var
  elseif (at.kind == "Binary") then
    return at.op ~= "and" and at.op ~= "or" and Writes.plain_compare(at, var)
  elseif (at.kind == "Unary") then
    return true
  end
  return at.kind == "Integer" or at.kind == "Float" or at.kind == "String" or at.kind == "Boolean"
end

function Writes.keeps_length(body: Ast.Node, array: integer, var: integer, pending?: mut {Ast.Node}): boolean
  -- A closure may not assign a local of its function, so a way the body may change the length is a mark in a list. The
  -- statements wait in a list too, so that a body of any depth is read without recursion.
  local marks: mut {boolean} = {}
  local waiting: mut {Ast.Node} = { body }
  local function wait(child: Ast.Node)
    waiting[#waiting + 1] = child
  end
  while #waiting > 0 and #marks == 0 do
    local node = assert(waiting[#waiting])
    waiting[#waiting] = nil
    if pending ~= nil and ((node.kind == "Call" and not Writes.scalar_math(node, var)) or (node.kind == "MethodCall")) then
      -- Whether the call runs code of the program is known once its arguments are typed.
      pending[#pending + 1] = node
    elseif (node.kind == "Call" and not Writes.scalar_math(node, var)) or (node.kind == "MethodCall") or (node.kind == "ForIn") or
        ((node.kind == "Binary") and not Writes.plain_compare(node, var)) then
      marks[#marks + 1] = true
    elseif (node.kind == "Local") then
      for _, binding in ipairs(node.bindings) do
        if binding.attr == "close" then
          marks[#marks + 1] = true
        end
      end
    elseif (node.kind == "Assign") then
      -- A target with no value of its own is given nil.
      if #node.values < #node.targets then
        marks[#marks + 1] = true
      end
      for i, target in ipairs(node.targets) do
        local value = node.values[i]
        if (target.kind == "Name") then
          -- `t = {}` is another table, and the index of the loop is not assigned.
          if target.binding == array or target.binding == var then
            marks[#marks + 1] = true
          end
        elseif (target.kind == "Index") then
          local object = peel(target.object)
          if value ~= nil and peel(value).kind == "Nil" then
            -- Any table may be the array under another name.
            marks[#marks + 1] = true
          elseif (object.kind == "Name") and object.binding == array then
            -- The write at the index of the loop overwrites; any other write may append or leave a hole.
            local key = peel(target.key)
            if not ((key.kind == "Name") and key.binding == var) then
              marks[#marks + 1] = true
            end
          end
        end
      end
    end
    Ast.children(node, wait)
  end
  return #marks == 0
end

--- The local `t` whose length the limit `to` of a numeric loop with the index `var` is at most, and the literal `b`
--- it stops short of that length by: `#t`, `#t - b`, or a `math.min` of such a one and other values that run no code
--- of the program ([`Writes.keeps_length`] of each), so that nothing they run can change `t` between its length and the
--- loop. `math.min` returns the least of its arguments, so the limit is at most `#t - b`. Nil for another form.
function Writes.length_limit(to: Ast.Exp, var: integer, pending?: mut {Ast.Node}): (Ast.Exp, integer) | (nil, integer)
  local at = peel(to)
  local slack = 0
  if (at.kind == "Binary") and at.op == "-" then
    local by = peel(at.right)
    if not ((by.kind == "Integer") and by.value >= 0) then
      return nil, 0
    end
    slack = by.value
    at = peel(at.left)
  end
  if (at.kind == "Unary") and at.op == "#" then
    local operand = peel(at.operand)
    if (operand.kind == "Name") then
      return operand, slack
    end
    return nil, 0
  end
  if not ((at.kind == "Call") and slack == 0) then
    return nil, 0
  end
  local callee = peel(at.callee)
  if not ((callee.kind == "Field") and callee.name == "min" and (callee.object.kind == "Name") and
      callee.object.binding == nil and callee.object.text == "math") then
    return nil, 0
  end
  local found: Ast.Exp? = nil
  local inner = 0
  local which = 0
  for i, given in ipairs(at.args) do
    if found == nil and peel(given).kind ~= "Call" then
      local object, short = Writes.length_limit(given, var, pending)
      if object ~= nil then
        found, inner, which = object, short, i
      end
    end
  end
  local held = if found ~= nil and (found.kind == "Name") then found.binding else nil end
  if found == nil or held == nil then
    return nil, 0
  end
  for i, given in ipairs(at.args) do
    if i ~= which and not Writes.keeps_length(given, held, var, pending) then
      return nil, 0
    end
  end
  return found, inner
end

--- What the numeric loop `s` knows of its index, if it counts the keys of an array: `for i = 1, #t do` (or a limit
--- [`Writes.length_limit`] holds at most `#t`, such as `math.min(n, #t)`), from a literal
--- of 1 or more by a literal step of 1 or more, over a local `t` that the body does not assign, append to, shorten or
--- pass to a call, and whose index nothing assigns. `t` has at least as many elements at each pass as it had when the
--- loop began, so `i` is a key it has.
function Writes.fill_of(s: Ast.ForNum, pending?: mut {Ast.Node}): Fill?
  local from = peel(s.from)
  local step = s.step
  if not ((from.kind == "Integer") and from.value >= 1) then
    return nil
  elseif step ~= nil then
    local given = peel(step)
    if not ((given.kind == "Integer") and given.value >= 1) then
      return nil
    end
  end
  local object, slack = Writes.length_limit(s.to, s.var.id, pending)
  if object == nil or slack ~= 0 or not (object.kind == "Name") then
    return nil
  end
  local held = object.binding
  if held == nil or not Writes.keeps_length(s.body, held, s.var.id, pending) then
    return nil
  end
  local unit = true
  if step ~= nil then
    local given = peel(step)
    unit = given.kind == "Integer" and given.value == 1
  end
  return { var = s.var.id, object = object, unit = unit }
end

--- The bound that the comparison `e` sets on a local, if it is written in one of the forms of a range test: a lower bound
--- of 1 for `i >= k` with a literal `k` of 1 or more, or `i > k` with one of 0 or more; an upper bound of `#t` for
--- `i <= #t` or `i < #t` with `t` a local. Either operand may come first (`1 <= i`, `#t >= i`).
function Writes.bound(e: Ast.Node): Bound?
  local at = peel(e)
  if at.kind ~= "Binary" then
    return nil
  end
  local op: string = at.op
  local left, right = peel(at.left), peel(at.right)
  -- `k <= i` is `i >= k`: the local goes on the left.
  if right.kind == "Name" and left.kind ~= "Name" then
    left, right, op = right, left, TURNED[op] or ""
  end
  if left.kind ~= "Name" then
    return nil
  end
  local var = left.binding
  if var == nil then
    return nil
  end
  if right.kind == "Integer" then
    if (op == ">=" and right.value >= 1) or (op == ">" and right.value >= 0) then
      return { var = var }
    end
  elseif right.kind == "Unary" and right.op == "#" and (op == "<=" or op == "<") then
    local array = peel(right.operand)
    if array.kind == "Name" and array.binding ~= nil then
      return { var = var, array = array }
    end
  end
  return nil
end

--- What the condition `cond` of an `if` arm with the block `body` knows of the keys of arrays: for each local `t` and local
--- `i` that the condition bounds from both sides (`i >= 1 and i <= #t`, among the operands of a chain of `and`), where
--- [`Writes.keeps_length`] says neither the condition nor the block can change the length of `t`, assign `t` or assign
--- `i`, `i` is a key `t` has in the whole block, so a value that is not nil written at it overwrites an element
--- ([`Writes.leaves_no_hole`], which also wants `i` an integer) and a read at it is an element
--- ([`Writes.counted_read`], an integer key too).
---
--- Why it holds. The block runs only where every operand of the chain was true when it was evaluated, so `1 <= i <= #t`
--- then. A comparison of an integer and a length runs no code, and [`Writes.keeps_length`] refuses the code that could
--- run after it: a call, an iterator, a `__close`, a write of nil or at another key of `t`, and an assignment of `t` or
--- `i`. So `t` keeps every element it had and `i` its value, in the block and in the operands of the chain evaluated after
--- the bounds; the range is given to the block alone, so a read in such an operand is still optional. A function made in the block may run when `t` is shorter: its body starts with no range
--- ([`Functions.function_body`]).
function Writes.ranges_of(cond: Ast.Exp, body: Ast.Block, pending?: mut {Ast.Node}): {Fill}
  local operands: mut {Ast.Node} = {}
  local waiting: mut {Ast.Exp} = { cond }
  while #waiting > 0 do
    local e = peel(assert(waiting[#waiting]))
    waiting[#waiting] = nil
    if e.kind == "Binary" and e.op == "and" then
      waiting[#waiting + 1] = e.right
      waiting[#waiting + 1] = e.left
    else
      operands[#operands + 1] = e
    end
  end
  local low: mut {integer: boolean} = {}
  local highs: mut {Bound} = {}
  for _, operand in ipairs(operands) do
    local bound = Writes.bound(operand)
    if bound ~= nil and bound.array == nil then
      low[bound.var] = true
    elseif bound ~= nil then
      highs[#highs + 1] = bound
    end
  end
  local out: mut {Fill} = {}
  for _, high in ipairs(highs) do
    local array = high.array
    local object = if array ~= nil then peel(array) else nil end
    local held: integer? = nil
    if object ~= nil and object.kind == "Name" then
      held = object.binding
    end
    if array ~= nil and held ~= nil and low[high.var] == true and Writes.keeps_length(cond, held, high.var, pending) and
        Writes.keeps_length(body, held, high.var, pending) then
      out[#out + 1] = { var = high.var, object = array, unit = true }
    end
  end
  return out
end

--- What the numeric loop `s` knows of the keys around its index, if it counts keys of an array by 1: `for i = a, #t do`
--- or `for i = a, #t - b do`, or a limit of `math.min(n, #t - b)` ([`Writes.length_limit`]), from a literal `a` of 1
--- or more to at most the length of a local `t` less a literal `b` of 0 or more, with no step or a literal step of 1, where [`Writes.keeps_length`] says the body cannot shorten `t`, assign `t`
--- or assign `i`. The limit is computed once, before the first pass, so `a <= i <= #t - b` for the length `t` had then,
--- and `t` has at least as many elements at each pass.
function Writes.span_of(s: Ast.ForNum, pending?: mut {Ast.Node}): Span?
  local from = peel(s.from)
  local step = s.step
  if not ((from.kind == "Integer") and from.value >= 1) then
    return nil
  elseif step ~= nil then
    local given = peel(step)
    if not ((given.kind == "Integer") and given.value == 1) then
      return nil
    end
  end
  local object, slack = Writes.length_limit(s.to, s.var.id, pending)
  if object == nil or not (object.kind == "Name") then
    return nil
  end
  local held = object.binding
  if held == nil or not Writes.keeps_length(s.body, held, s.var.id, pending) then
    return nil
  end
  return { var = s.var.id, object = object, from = from.value, slack = slack }
end

--- Whether `node`, a read of an array at an integer key, reads an element the array has, by one of two proofs. The read
--- is then the element type, not an optional.
---
--- A counted loop ([`Writes.span_of`]): the key is `i`, `i + c` or `i - c`, with `i` the index of a loop `for i = a,
--- #t - b do` by 1 over the local `t` the read names and `c` a literal, where the offset (`c` or `-c`) keeps the key
--- inside the array: `a` plus the offset is 1 or more, and the offset is at most `b`. The index is an integer from `a`
--- to `#t - b`, as `#t` was when the loop began, and `t` has kept every key it had then through each pass, so the key
--- is from 1 to `#t`. In `for i = 2, #t - 1 do` the reads `t[i - 1]`, `t[i]` and `t[i + 1]` are all elements.
---
--- A range test ([`Writes.ranges_of`]): the key is a local `i`, and the read is in the block of an `if` whose condition
--- holds `i >= 1 and i <= #t` for the local `t` the read names, where neither the condition nor the block can change
--- the length of `t`, assign `t` or assign `i`.
---
--- A function made in the body or the block begins with no loop and no range around it ([`Functions.function_body`]), so a read
--- there, which may run when `t` is shorter, stays optional. The proof holds for a program the checker accepts: a write
--- of a value that may be nil into `t` is an error of its own statement, and a checked run (`cosmic test --check-types`)
--- tests the read.
---
--- A body may call the functions of the standard library that run no code of the program, given plain values
--- ([`Writes.keeps_length`] with `pending`): `print`, `tostring`, `string.*`, a string's methods and the rest of
--- [`Tests.inert_callee`].
---
--- TODO: read the index of a loop whose body calls a function of the program, once the checker can show that no code the
--- call runs names the array ([`Writes.unreachable`] shows it only for a local made `{}`): such a body keeps the read `T?`
--- now.
function Writes.counted_read(ctx: Ctx, node: Ast.Index): boolean
  local key = peel(node.key)
  local name = key
  local offset = 0
  if (key.kind == "Binary") and (key.op == "+" or key.op == "-") then
    local by = peel(key.right)
    if not ((by.kind == "Integer") and by.value >= 0) then
      return false
    end
    offset = if key.op == "+" then by.value else -by.value end
    name = peel(key.left)
  end
  if name.kind ~= "Name" or name.binding == nil then
    return false
  end
  for _, loop in ipairs(ctx.loops) do
    local span = loop.span
    -- `from + offset` wraps to a negative where the sum is past the largest integer, which refuses the read.
    if span ~= nil and name.binding == span.var and span.from + offset >= 1 and offset <= span.slack and
        Writes.same_place(span.object, node.object) then
      return true
    end
  end
  if offset ~= 0 then
    return false
  end
  for _, range in ipairs(ctx.ranges) do
    if name.binding == range.var and Writes.same_place(range.object, node.object) then
      return true
    end
  end
  return false
end

--- Whether `child`, a name read in `parent`, only indexes the table it names, takes its length, returns it or hands it to a
--- function of the standard library that does not keep it: nothing then holds the table but the local that names it.
function Writes.stays_private(ctx: Ctx, parent: Ast.Node, child: Ast.Node): boolean
  if parent.kind == "Index" then
    return parent.object == child
  elseif parent.kind == "Unary" then
    return parent.op == "#"
  elseif parent.kind == "Return" then
    return true
  elseif parent.kind ~= "Call" or parent.args[1] ~= child then
    return false
  end
  local callee = peel(parent.callee)
  local resolved = ctx.scoped.resolved
  if callee.kind == "Name" then
    return resolved[callee.id] == nil and (callee.text == "ipairs" or callee.text == "pairs")
  elseif callee.kind == "Field" then
    local library = peel(callee.object)
    local name = callee.name
    return library.kind == "Name" and library.text == "table" and resolved[library.id] == nil and
      (name == "insert" or name == "remove" or name == "concat" or name == "unpack" or name == "sort")
  end
  return false
end

--- What the program does with each local that holds a table literal ([`Privacy`]), worked out the first time it is asked.
function Writes.privacy(ctx: Ctx): Privacy
  local held = ctx.privacy
  if held ~= nil then
    return held
  end
  local made: Privacy = { literal = {}, empty = {}, escapes = {}, loops = {} }
  local waiting: mut {Ast.Node} = { ctx.input.chunk }
  while #waiting > 0 do
    local node = assert(waiting[#waiting])
    waiting[#waiting] = nil
    if node.kind == "Local" then
      for i, binding in ipairs(node.bindings) do
        local value = node.values[i]
        if value ~= nil and binding.attr ~= "close" then
          local made_of = peel(value)
          if made_of.kind == "Table" then
            made.literal[binding.id] = true
            if #made_of.items == 0 then
              made.empty[binding.id] = true
            end
          end
        end
      end
    elseif node.kind == "While" or node.kind == "Repeat" or node.kind == "ForNum" or node.kind == "ForIn" then
      made.loops[#made.loops + 1] = { first = node.first, last = node.last }
    end
    Ast.children(node, function(child: Ast.Node)
      if child.kind == "Name" then
        local id = child.binding
        if id ~= nil and not Writes.stays_private(ctx, node, child) then
          local list: mut {integer} = made.escapes[id] or {}
          made.escapes[id] = list
          list[#list + 1] = child.first
        end
      end
      waiting[#waiting + 1] = child
    end)
  end
  ctx.privacy = made
  return made
end

--- Whether the table that the local `id` holds can be named by no code but its own function's while the tokens `first` to `last`
--- run: the local is declared with a table literal, is never assigned or read by a function nested in its own, and has not
--- been let out ([`Writes.stays_private`]) by a read at or before `last`, nor by a read in a loop that holds the tokens (the
--- next pass would find the table out). Code that runs there then has no way to name the table.
function Writes.unreachable(ctx: Ctx, id: integer, first: integer, last: integer): boolean
  local v = ctx.scoped.vars[id]
  local privacy = Writes.privacy(ctx)
  if v == nil or v.kind ~= "local" or v.assigned or #v.captures > 0 or privacy.literal[id] ~= true then
    return false
  end
  -- The tokens and the loops that hold them, inside the scope of the local: where a read lets the table out in time.
  local from, to = first, last
  for _, loop in ipairs(privacy.loops) do
    if loop.first <= first and last <= loop.last and loop.first >= v.from then
      from, to = math.min(from, loop.first), math.max(to, loop.last)
    end
  end
  for _, at in ipairs(privacy.escapes[id] or {}) do
    if at <= last or (at >= from and at <= to) then
      return false
    end
  end
  return true
end

--- Whether the statement `s`, which writes `object[#object + 1]` and runs code, may find `object` shortened by that code
--- between computing the key and writing the element. It may not where `object` is a local that [`Writes.unreachable`] says
--- no code but its own function's can name when the statement runs. A parameter, a local made from a call or from another
--- name, a field and a local read by a closure may be named from elsewhere, and no call is known not to.
function Writes.may_shorten(ctx: Ctx, object: Ast.Exp, s: Ast.Assign): boolean
  local array = peel(object)
  local id: integer? = nil
  if array.kind == "Name" then
    id = array.binding
  end
  if id == nil or not Writes.unreachable(ctx, id, s.first, s.last) then
    return true
  end
  -- A read of the local by the code the statement runs (`xs[#xs + 1] = table.remove(xs)`, `g(xs)`) reaches the table in the
  -- very call that may shorten it, whatever [`Writes.stays_private`] says of the same read elsewhere.
  local used: mut {boolean} = {}
  local function look(node: Ast.Node)
    if node.kind == "Name" and node.binding == id then
      used[#used + 1] = true
    else
      Ast.children(node, look)
    end
  end
  for _, target in ipairs(s.targets) do
    local held = peel(target)
    local own = false
    if held.kind == "Index" then
      local base = peel(held.object)
      if base.kind == "Name" then
        own = base.binding == id
      end
    end
    if not own then
      look(target)
    end
  end
  for _, value in ipairs(s.values) do
    look(value)
  end
  return #used > 0
end

--- Whether the statement `stat` holds a `continue`, which skips the rest of the pass of the loop that holds it. A `continue`
--- of an inner loop or of a function made in `stat` is counted too: no other statement is read for it.
function Writes.holds_continue(stat: Ast.Node): boolean
  local found: mut {boolean} = {}
  local waiting: mut {Ast.Node} = { stat }
  while #waiting > 0 and #found == 0 do
    local node = assert(waiting[#waiting])
    waiting[#waiting] = nil
    if node.kind == "Continue" then
      found[#found + 1] = true
    end
    Ast.children(node, function(child: Ast.Node)
      waiting[#waiting + 1] = child
    end)
  end
  return #found > 0
end

--- Whether the statements `body` of a loop write the array held by the local `array`, or take elements from it, other
--- than by a write at the index `var` of the loop: a write at another key, or `table.remove`. `table.insert` is not one: it
--- only appends, so it leaves the keys the array had. The reads of `array` that [`Writes.unreachable`] allows are those of
--- [`Writes.stays_private`] (an index, a length, `return`, `ipairs`, `pairs` and five functions of `table`), and of these
--- only a write of an index and `table.remove` change the keys the array has, and `table.insert` and `table.sort` leave the
--- keys it had.
function Writes.rewrites_array(ctx: Ctx, body: Ast.Node, array: integer, var: integer): boolean
  local marks: mut {boolean} = {}
  local waiting: mut {Ast.Node} = { body }
  while #waiting > 0 and #marks == 0 do
    local node = assert(waiting[#waiting])
    waiting[#waiting] = nil
    if node.kind == "Assign" then
      for _, target in ipairs(node.targets) do
        local held = peel(target)
        if held.kind == "Index" then
          local object = peel(held.object)
          local key = peel(held.key)
          if object.kind == "Name" and object.binding == array and not (key.kind == "Name" and key.binding == var) then
            marks[#marks + 1] = true
          end
        end
      end
    elseif node.kind == "Call" then
      local callee = peel(node.callee)
      local first = node.args[1]
      if callee.kind == "Field" and callee.name == "remove" and first ~= nil then
        local library = peel(callee.object)
        local taken = peel(first)
        if library.kind == "Name" and library.text == "table" and ctx.scoped.resolved[library.id] == nil and
            taken.kind == "Name" and taken.binding == array then
          marks[#marks + 1] = true
        end
      end
    end
    Ast.children(node, function(child: Ast.Node)
      waiting[#waiting + 1] = child
    end)
  end
  return #marks > 0
end

--- What the loop `loop` knows of the arrays it fills, if its index `var` counts 1, 2, 3 and so on (the caller has seen that
--- it does: [`Writes.counts_from_one`]). An array `a` is filled where
---   - a statement of the body, before any statement that holds a `continue`, assigns `a[var]`, so every pass that reaches
---     its end has written the key it is on,
---   - `a` is a local declared before the loop (a local made in the body is a new array in each pass) that holds a table
---     literal with no item, and [`Writes.unreachable`] says no code but the function's
---     own can name it while the loop runs (so a call in the loop, or in the value written, cannot shorten it), and
---   - nothing in the body writes `a` at another key or takes an element out ([`Writes.rewrites_array`]),
---   - nothing assigns `var`.
---
--- Why a write at `var` leaves no hole. A `mut` array has the keys 1 to its length. Before the pass on `var`, every pass
--- before it ran to its end (a `break` or a `return` leaves the loop, and an error raises) and wrote `a[1]` to `a[var - 1]`, and
--- nothing took an element out, so `a` has at least the keys 1 to `var - 1`: the write at `var` overwrites a key or is the
--- append. A loop left at a `break` at the pass on `k` has the keys 1 to `k - 1`, as every array has the keys 1 to its length.
--- A pass cannot skip its write: the write is in a statement of the body itself (not in an `if`, an inner loop or a
--- function), and no statement before it can `continue`. The value written is not nil ([`Writes.leaves_no_hole`]), so the key
--- is a key afterwards. The array may hold elements before the loop (a loop inside a loop, or a loop after an append): it
--- only has more keys.
function Writes.grow_in(ctx: Ctx, loop: Ast.Node, var: Ast.Binding, body: Ast.Block): Grow?
  local v = ctx.scoped.vars[var.id]
  if v == nil or v.assigned then
    return nil
  end
  local arrays: mut {integer: boolean} = {}
  local count = 0
  for _, stat in ipairs(body.stats) do
    if stat.kind == "Assign" then
      for _, target in ipairs(stat.targets) do
        local held = peel(target)
        if held.kind == "Index" then
          local object = peel(held.object)
          local key = peel(held.key)
          local id: integer? = nil
          if object.kind == "Name" then
            id = object.binding
          end
          if id ~= nil and key.kind == "Name" and key.binding == var.id and arrays[id] == nil then
            arrays[id] = true
            count = count + 1
          end
        end
      end
    end
    if Writes.holds_continue(stat) then
      break
    end
  end
  if count == 0 then
    return nil
  end
  local privacy = Writes.privacy(ctx)
  local filled: mut {integer: boolean} = {}
  local live = 0
  for id in pairs(arrays) do
    local declared = ctx.scoped.vars[id]
    -- A local made in the body is a new array in each pass, with no key from the passes before.
    if declared ~= nil and declared.from <= loop.first and privacy.empty[id] == true and
        Writes.unreachable(ctx, id, loop.first, loop.last) and not Writes.rewrites_array(ctx, body, id, var.id) then
      filled[id] = true
      live = live + 1
    end
  end
  if live == 0 then
    return nil
  end
  return { var = var.id, arrays = filled }
end

--- Whether the numeric loop `s` counts 1, 2, 3 and so on: it starts at a literal of 1 and steps by a literal of 1 or by
--- nothing, so the pass `k` has the index `k`. The limit may be any number.
function Writes.counts_from_one(s: Ast.ForNum): boolean
  local from = peel(s.from)
  if not (from.kind == "Integer" and from.value == 1) then
    return false
  end
  local step = s.step
  if step == nil then
    return true
  end
  local given = peel(step)
  return given.kind == "Integer" and given.value == 1
end

--- Whether the generic loop `s` is `for i, v in ipairs(t) do`: `ipairs` of the library, called with one array, returns the
--- keys 1, 2, 3 and so on in turn, whatever the body does to `t`.
function Writes.counts_ipairs(ctx: Ctx, s: Ast.ForIn): boolean
  local only = s.iterators[1]
  if #s.iterators ~= 1 or only == nil or #s.vars < 1 then
    return false
  end
  local call = peel(only)
  if call.kind ~= "Call" or #call.args ~= 1 then
    return false
  end
  local callee = peel(call.callee)
  return callee.kind == "Name" and callee.text == "ipairs" and ctx.scoped.resolved[callee.id] == nil
end

--- Whether the write `p` leaves the array it writes with no hole: the statement has the values `vals`. The array has its
--- elements from 1 to its length, so a write that puts a value that is not nil
---   - at 1 appends (the array is empty) or overwrites (it is not),
---   - at the index of a loop over `1` to the length of the array ([`Writes.fill_of`]), which has that element,
---   - at the index of a loop that counts from 1 by 1 and writes the array in every pass ([`Writes.grow_in`]), which has
---     the keys before it,
---   - at an integer `i` in the block of an `if` whose condition holds `i >= 1 and i <= #t` ([`Writes.ranges_of`]),
--- overwrites an element and leaves the others where they are. A nil would take an element out of the middle, and a write at
--- the length (`t[#t] = v`) is at 0 where the array is empty, which is no key of an array.
---
--- A write in a function made inside the loop (`saved = function() u[i] = 1 end`) or the block is refused only because the
--- body of a function does not inherit `ctx.loops` or `ctx.ranges` ([`Functions.function_body`]), which hold the fill and the
--- range; [`Writes.keeps_length`] does not decide it. Keep the two apart: a closure may run when the array is shorter.
function Writes.leaves_no_hole(ctx: Ctx, vals: Values, p: Pending): boolean
  local written = value_at(ctx, vals, p.at)
  if written == nil or not Writes.present(written) then
    return false
  end
  local target = p.target
  local key = peel(target.key)
  if (key.kind == "Integer") and key.value == 1 then
    return true
  end
  if (key.kind == "Name") then
    local object = peel(target.object)
    local array: integer? = nil
    if object.kind == "Name" then
      array = object.binding
    end
    for _, loop in ipairs(ctx.loops) do
      local fill = loop.fill
      if fill ~= nil and key.binding == fill.var and Writes.same_place(fill.object, target.object) then
        return true
      end
      local grow = loop.grow
      if grow ~= nil and array ~= nil and key.binding == grow.var and grow.arrays[array] == true then
        return true
      end
    end
    for _, range in ipairs(ctx.ranges) do
      if p.integral and key.binding == range.var and Writes.same_place(range.object, target.object) then
        return true
      end
    end
  end
  -- TODO: let the swap `t[i], t[j] = t[j], t[i]` stand, whose values are elements that are there, once the checker narrows a
  -- read of an index (`if t[i] ~= nil`) to the element type: `t[i]` is `T?` after any test now, so the swap is refused.
  return false
end

--- Whether the assignment `s` calls a function between computing the key of its targets and writing them. Lua computes every
--- target's table and key first, then the values, so a call in a value (or in a key of another target) may shorten an array
--- after `#t + 1` is computed, and the write then lands past the end. A function literal is no call: its body runs elsewhere.
function Writes.runs_code(s: Ast.Assign): boolean
  local calls: mut {boolean} = {}
  local function visit(node: Ast.Node)
    if (node.kind == "Call") or (node.kind == "MethodCall") then
      calls[#calls + 1] = true
    elseif node.kind ~= "FunctionLit" then
      Ast.children(node, visit)
    end
  end
  for _, target in ipairs(s.targets) do
    visit(target)
  end
  for _, value in ipairs(s.values) do
    visit(value)
  end
  return #calls > 0
end

--- The `array_hole` error of a write at an index that may leave a hole in an array, whether the array is `mut` or a view
--- (a view's write is also a `view_written`, so one run names both). The statement has the values `vals`. The fix offers
--- the range test of [`Writes.ranges_of`] only where it would let the write stand: a value that is not nil written to a
--- local at an integer local.
function Writes.report_hole(ctx: Ctx, vals: Values, p: Pending)
  local target = p.target
  if Writes.is_append(target) then
    report(ctx, "array_hole", target, subject(ctx, target) .. " is written by a statement that calls a function, which " ..
        "may shorten the array " .. p.owner .. " after the key is computed and leave a hole",
      "call first and write after: `local v = f()`, then `" .. text_of(ctx, target) .. " = v`", { show(ctx, p.base) })
  else
    local t = text_of(ctx, target.object)
    local key, object = peel(target.key), peel(target.object)
    local written = value_at(ctx, vals, p.at)
    local guard = ""
    if key.kind == "Name" and key.binding ~= nil and object.kind == "Name" and object.binding ~= nil and p.integral and
        written ~= nil and Writes.present(written) then
      local i = key.text
      guard = "overwrite an element inside `if " .. i .. " >= 1 and " .. i .. " <= #" .. t .. " then` (a block that " ..
        "calls no function but `math`'s, writes nil to no table, writes `" .. t .. "` at no other key and assigns " ..
        "neither `" .. i .. "` nor `" .. t .. "`), "
    end
    report(ctx, "array_hole", target, subject(ctx, target) .. " may leave a hole in the array " .. p.owner,
      "append with `" .. t .. "[#" .. t .. " + 1] = v` or `table.insert`, " .. guard .. "remove with `table.remove`, " ..
        "or key a map `{integer: T}` for sparse data", { show(ctx, p.base) })
  end
end

--- The rewrite of a write to the view `object`: `mut ` before the type it is declared with, where it is a local of this
--- text declared with a type that is an array or a map (`local seen: {string: boolean} = {}`). Nil for any other, which a
--- choice puts right: a parameter, a field, a local that takes its type from its value.
function Writes.view_rewrite(ctx: Ctx, object: Ast.Node): Codes.Rewrite?
  local name = peel(object)
  if not (name.kind == "Name") then return nil end
  local binding = name.binding
  if binding == nil then return nil end
  local declared = ctx.annotated[binding]
  if declared == nil or not (declared.kind == "TypeArray" or declared.kind == "TypeMap") then
    return nil
  end
  local tokens = ctx.tokens
  local first = declared.first
  return { before = "mut ", after = "", place = { y = Lexer.y(tokens, first), x = Lexer.x(tokens, first),
    offset = Lexer.offset(tokens, first), length = 0 } }
end

return Writes
