-- Reachability: whether control can go past a statement. This module
-- decides it for every form that ends its block, and the checker
-- (checker/tl.tl) asks it wherever it needs the answer: a function
-- declared `: never` must end its body, a function that returns a value
-- must not reach its end, and an `if` all of whose branches end narrows
-- what follows by the negation of its conditions.
--
-- A statement ends its block when control cannot reach the statement
-- after it:
--
--   * `return`, `break` and `goto` always;
--   * `do ... end` and each branch of an `if` when the last statement of
--     its body ends;
--   * an `if` when it has an `else` and every branch ends;
--   * `while true` and `repeat ... until false` when no `break` leaves
--     the loop;
--   * a call that never returns, which only the type checker can tell, as
--     it is a call of a function typed `: never`: it marks the call with
--     [`flow.mark_never_call`] once it has typed it.
--
-- [`flow.unassigned_read`] asks the other question of the same paths: whether
-- a local declared with no value is read before an assignment reaches it on
-- every path.
--
-- The answers are computed from the tree and its marks on every ask,
-- never kept on a node, so a statement's answer cannot disagree with its
-- parts'.
--
-- This file holds only upstream Teal 0.24.8: the boot compiles it with
-- the vendored `tl.lua` (core/bridge.lua), as it does checker/tl.tl.
--
-- TODO: a `goto` ends its block whatever its label is, and a loop that
-- only a `goto` leaves counts as one with no exit (`breaks_out` looks
-- for `break` alone). Both let the checker narrow after code control can
-- reach through the label. It waits on this module resolving labels,
-- which needs the checker's scopes of labels moved into it.

-- The statement fields reachability reads. The checker's own `Node`
-- (checker/tl.tl) has all of them, and its callers cast to this type,
-- which the checker cannot name here without a require cycle.
local record flow
   record Operator
      op: string
   end

   record Node
      is {Node}
      kind: string
      tk: string
      exp: Node
      body: Node
      if_blocks: {Node}
      never_call: boolean
      vars: Node
      exps: Node
      args: Node
      name: Node
      fn_owner: Node
      is_method: boolean
      op: Operator
      e1: Node
      e2: Node
      key: Node
      value: Node
      var: Node
      from: Node
      to: Node
      step: Node
      label: string
      macrodef: Node
   end

   ends: function(Node): boolean
   ends_body: function(Node): boolean
   ends_all: function({Node}): boolean
   leaves: function(Node): boolean
   leaves_body: function(Node): boolean
   mark_never_call: function(Node)
   unassigned_read: function(Node, integer, string, Node): Node, Node
end

-- Whether `body`, a loop's body, holds a `break` that leaves that loop.
local function breaks_out(body: flow.Node): boolean
   for _, stmt in ipairs(body) do
      if stmt.kind == "break" then
         return true
      elseif stmt.kind == "do" then
         if breaks_out(stmt.body) then
            return true
         end
      elseif stmt.kind == "if" then
         for _, b in ipairs(stmt.if_blocks) do
            if breaks_out(b.body) then
               return true
            end
         end
      end
   end
   return false
end

--- Whether control cannot go past `body`'s last statement: that one ends
--- the block. An empty body does not.
function flow.ends_body(body: flow.Node): boolean
   return #body > 0 and flow.ends(body[#body])
end

--- Whether every one of `blocks`, the branches of an `if`, ends.
function flow.ends_all(blocks: {flow.Node}): boolean
   for _, b in ipairs(blocks) do
      if not flow.ends(b) then
         return false
      end
   end
   return true
end

--- Whether control cannot go past `node`, a statement, a branch of an
--- `if` or, for a macro expression, its expression.
function flow.ends(node: flow.Node): boolean
   local kind = node.kind
   if kind == "return" or kind == "break" or kind == "goto" then
      return true
   elseif kind == "do" or kind == "if_block" then
      return flow.ends_body(node.body)
   elseif kind == "if" then
      -- Only an `else` closes the last way past: without one, control
      -- reaches the next statement when every condition is false.
      return flow.ends_all(node.if_blocks) and not node.if_blocks[#node.if_blocks].exp
   elseif kind == "while" or kind == "repeat" then
      local endless = kind == "while" and "true" or "false"
      return node.exp.kind == "boolean" and node.exp.tk == endless and not breaks_out(node.body)
   end
   return not not node.never_call
end

--- Whether control never goes past `node` to the code after the block that
--- holds it, nor to code after a loop: it ends in a `return` or a call that
--- never returns, not in a `break` or a `goto`, which leave for code the
--- block's effects reach. Loops are taken to be left only by a `break`.
function flow.leaves(node: flow.Node): boolean
   local kind = node.kind
   if kind == "return" then
      return true
   elseif kind == "do" or kind == "if_block" then
      return flow.leaves_body(node.body)
   elseif kind == "if" then
      for _, b in ipairs(node.if_blocks) do
         if not flow.leaves(b) then
            return false
         end
      end
      return not node.if_blocks[#node.if_blocks].exp
   elseif kind == "break" or kind == "goto" or kind == "while" or kind == "repeat" then
      return false
   end
   return not not node.never_call
end

-- Whether a statement of `body`, at any depth, may go out of it to the code
-- around it: a `break` that is not of a loop inside `body` (`inside`), or any
-- `goto`, whose label may be anywhere.
local function exits(body: flow.Node, inside: boolean): boolean
   for _, stmt in ipairs(body) do
      local kind = stmt.kind
      if kind == "goto" or (kind == "break" and not inside) then
         return true
      elseif kind == "do" then
         if exits(stmt.body, inside) then
            return true
         end
      elseif kind == "if" then
         for _, b in ipairs(stmt.if_blocks) do
            if exits(b.body, inside) then
               return true
            end
         end
      elseif kind == "while" or kind == "repeat" or kind == "forin" or kind == "fornum" then
         if stmt.body and exits(stmt.body, true) then
            return true
         end
      end
   end
   return false
end

--- Whether control never goes past `body` to the code around it: its last
--- statement leaves (see [`flow.leaves`]) and no path through it goes out
--- by a `break` of a loop around it or by a `goto` before reaching it.
function flow.leaves_body(body: flow.Node): boolean
   return #body > 0 and flow.leaves(body[#body]) and not exits(body, false)
end

--- Records that `node`, a call, never returns: its function is typed
--- `: never`. The type checker decides that, once it has typed the call.
function flow.mark_never_call(node: flow.Node)
   node.never_call = true
end

-- Whether `name` is one of the names `list` (a `variable_list` of
-- declarations or loop variables, or an argument list) declares.
local function names_in(list: flow.Node, name: string): boolean
   for _, v in ipairs(list) do
      if v.tk == name then
         return true
      end
   end
   return false
end

-- The absent node, which a call gives where it has none and a record keeps
-- until it has one. The checker's own source relies on nil being in every
-- type, as the rest of this directory does.
-- TODO: type what may be absent `T | nil` and narrow it where it is read,
-- once nil is excluded from every type but one that names it, and the
-- checker's source may use what upstream's `tl.lua` (the seed that compiles
-- it) refuses today: indexing a `T | nil` after its guard.
local no_node: flow.Node = nil

-- The references to a name in an expression, a block and a function, which
-- call one another.
local record mention
   in_expression: function(flow.Node, string): flow.Node
   in_block: function(flow.Node, string, flow.Node): flow.Node
   of: function(flow.Node, string): flow.Node
end

-- The first reference to `name` in `e`, an expression: a use of the
-- variable, or a function literal that names it. Creating a function
-- literal reads every variable it names, so it counts where it stands.
function mention.in_expression(e: flow.Node, name: string): flow.Node
   if not e then
      return nil
   end
   local kind = e.kind
   if kind == "variable" then
      return e.tk == name and e or nil
   elseif kind == "function" or kind == "macroexp" then
      return mention.of(e, name) and e or nil
   elseif kind == "op" then
      local found = mention.in_expression(e.e1, name)
      if found then
         return found
      end
      -- The right side of `is` and `as` is a type.
      if e.op.op == "is" or e.op.op == "as" then
         return nil
      end
      return mention.in_expression(e.e2, name)
   elseif kind == "paren" then
      return mention.in_expression(e.e1, name)
   elseif kind == "literal_table_item" then
      return mention.in_expression(e.key, name) or mention.in_expression(e.value, name)
   elseif kind == "literal_table" or kind == "expression_list" or kind == "variable_list" then
      for _, child in ipairs(e) do
         local found = mention.in_expression(child, name)
         if found then
            return found
         end
      end
   end
   return nil
end

-- Whether `stmt` declares `name` for the statements after it in its block.
local function declares(stmt: flow.Node, name: string): boolean
   local kind = stmt.kind
   if kind == "local_declaration" then
      return names_in(stmt.vars, name)
   end
   return (kind == "local_function" or kind == "local_macroexp") and stmt.name.tk == name
end

-- The first reference to `name` in the statements of `body` that its
-- declaration there does not hide, and in `tail`, an expression in the
-- scope of the block's locals (the `until` of a `repeat`).
function mention.in_block(body: flow.Node, name: string, tail: flow.Node): flow.Node
   for _, stmt in ipairs(body) do
      local kind = stmt.kind
      local found: flow.Node = no_node
      if kind == "local_declaration" or kind == "global_declaration" or kind == "return" then
         found = mention.in_expression(stmt.exps, name)
      elseif kind == "assignment" then
         found = mention.in_expression(stmt.vars, name) or mention.in_expression(stmt.exps, name)
      elseif kind == "op" then
         found = mention.in_expression(stmt, name)
      elseif kind == "local_function" then
         found = stmt.name.tk ~= name and mention.of(stmt, name) or nil
      elseif kind == "global_function" then
         if stmt.name.tk == name then
            found = stmt.name
         else
            found = mention.of(stmt, name) and stmt or nil
         end
      elseif kind == "record_function" then
         found = mention.in_expression(stmt.fn_owner, name) or mention.of(stmt, name)
      elseif kind == "local_macroexp" then
         found = mention.of(stmt.macrodef, name)
      elseif kind == "do" then
         found = mention.in_block(stmt.body, name, no_node)
      elseif kind == "if" then
         for _, b in ipairs(stmt.if_blocks) do
            found = mention.in_expression(b.exp, name) or mention.in_block(b.body, name, no_node)
            if found then
               break
            end
         end
      elseif kind == "while" then
         found = mention.in_expression(stmt.exp, name) or mention.in_block(stmt.body, name, no_node)
      elseif kind == "repeat" then
         found = mention.in_block(stmt.body, name, stmt.exp)
      elseif kind == "fornum" then
         found = mention.in_expression(stmt.from, name)
         if not found then
            found = mention.in_expression(stmt.to, name)
         end
         if not found then
            found = mention.in_expression(stmt.step, name)
         end
         if not found and stmt.var.tk ~= name then
            found = mention.in_block(stmt.body, name, no_node)
         end
      elseif kind == "forin" then
         found = mention.in_expression(stmt.exps, name)
         if not found and not names_in(stmt.vars, name) then
            found = mention.in_block(stmt.body, name, no_node)
         end
      end
      if found then
         return found
      end
      if declares(stmt, name) then
         return nil
      end
   end
   return mention.in_expression(tail, name)
end

-- The first reference to `name` in `fn`, a function literal, a named
-- function or a macro expression, unless its own arguments hide the name.
function mention.of(fn: flow.Node, name: string): flow.Node
   if (fn.is_method and name == "self") or (fn.args and names_in(fn.args, name)) then
      return nil
   end
   if fn.kind == "macroexp" then
      return mention.in_expression(fn.exp, name)
   end
   return mention.in_block(fn.body, name, no_node)
end

-- What a path knows of the variable being followed: whether it has been
-- assigned, and, when it has not, the statement a path went by that
-- skipped the assignment another path made. A path that cannot be taken
-- has no state (nil).
local record State
   assigned: boolean
   skipped: flow.Node
end

local assigned_state <const>: State = { assigned = true, skipped = no_node }
local unassigned_state <const>: State = { assigned = false, skipped = no_node }

-- No state, for a path that cannot be taken.
local no_state: State = nil

-- The state where two paths meet.
local function meet(a: State, b: State): State
   if not a then
      return b
   elseif not b or not a.assigned then
      return a
   end
   return b
end

-- `s` with `by` as the statement it skipped, when it names none yet.
local function skipped_by(s: State, by: flow.Node): State
   if s and not s.assigned and not s.skipped then
      return { assigned = false, skipped = by }
   end
   return s
end

-- The state the paths that leave a loop by `break` (or the branches of an
-- `if`) bring together; nil where none does.
local record Exit
   state: State
end

local record Scan
   name: string
   found: flow.Node
   skipped: flow.Node
   -- Whether a local of the same name hides the variable here: control
   -- still flows, but a read or a write is another variable's.
   hidden: boolean
   loops: {Exit}
   -- The state each `goto` brought to a label it has not reached yet.
   gotos: {string:State}
end

-- Notes the first read of the variable in `e`, an expression, or in `fn`,
-- a function, at state `st`, when that state has not assigned it.
local function read(scan: Scan, e: flow.Node, st: State, fn?: boolean)
   if st.assigned or scan.hidden or scan.found or not e then
      return
   end
   local found: flow.Node
   if fn then
      found = mention.of(e, scan.name) and e or nil
   else
      found = mention.in_expression(e, scan.name)
   end
   if found then
      scan.found = found
      scan.skipped = st.skipped
   end
end

-- Walks the statements of a block, which call the walk of a block.
local record walk
   block: function(Scan, flow.Node, integer, State, flow.Node): State
   statement: function(Scan, flow.Node, State): State
end

-- The state after a loop whose body ran from `st` and ended in `at_end`
-- (nil where it cannot): the body may run no time, so the loop assigns
-- nothing the code after it can count on, but for the paths that `break`.
local function after_loop(loop: flow.Node, st: State, at_end: State, breaks: Exit): State
   local broken = breaks.state
   local assigned_inside = (at_end and at_end.assigned) or (broken and broken.assigned)
   if assigned_inside then
      return meet(skipped_by(st, loop), broken)
   end
   return meet(st, broken)
end

function walk.statement(scan: Scan, stmt: flow.Node, st: State): State
   local kind = stmt.kind
   local name = scan.name
   if kind == "local_declaration" or kind == "global_declaration" then
      read(scan, stmt.exps, st)
      if kind == "local_declaration" and names_in(stmt.vars, name) then
         scan.hidden = true
      end
   elseif kind == "assignment" then
      read(scan, stmt.exps, st)
      local assigns = false
      for _, v in ipairs(stmt.vars) do
         if v.kind == "variable" then
            assigns = assigns or v.tk == name
         else
            read(scan, v, st)
         end
      end
      if assigns and not scan.hidden then
         return assigned_state
      end
   elseif kind == "op" then
      read(scan, stmt, st)
      if stmt.never_call then
         return nil
      end
   elseif kind == "local_function" then
      if stmt.name.tk == name then
         scan.hidden = true
      else
         read(scan, stmt, st, true)
      end
   elseif kind == "global_function" then
      read(scan, stmt, st, true)
      if stmt.name.tk == name and not scan.hidden then
         return assigned_state
      end
   elseif kind == "record_function" then
      read(scan, stmt.fn_owner, st)
      read(scan, stmt, st, true)
   elseif kind == "local_macroexp" then
      read(scan, stmt.macrodef, st, true)
      if stmt.name.tk == name then
         scan.hidden = true
      end
   elseif kind == "return" then
      read(scan, stmt.exps, st)
      return nil
   elseif kind == "break" then
      local breaks = scan.loops[#scan.loops]
      if breaks then
         breaks.state = meet(breaks.state, st)
      end
      return nil
   elseif kind == "goto" then
      scan.gotos[stmt.label] = meet(scan.gotos[stmt.label], st)
      return nil
   elseif kind == "do" then
      return walk.block(scan, stmt.body, 1, st, no_node)
   elseif kind == "if" then
      local ends: {Exit} = {}
      local blocks = stmt.if_blocks
      local any_assigned = false
      for i, b in ipairs(blocks) do
         read(scan, b.exp, st)
         local s = walk.block(scan, b.body, 1, st, no_node)
         if s and s.assigned then
            any_assigned = true
         end
         ends[i] = { state = s }
      end
      local out: State = no_state
      if any_assigned then
         for i, b in ipairs(blocks) do
            out = meet(out, skipped_by(ends[i].state, b))
         end
         if blocks[#blocks].exp then
            out = meet(out, skipped_by(st, stmt))
         end
      else
         for i = 1, #blocks do
            out = meet(out, ends[i].state)
         end
         if blocks[#blocks].exp then
            out = meet(out, st)
         end
      end
      return out
   elseif kind == "while" or kind == "repeat" then
      local breaks: Exit = { state = no_state }
      table.insert(scan.loops, breaks)
      local endless = kind == "while" and "true" or "false"
      local at_end: State = no_state
      if kind == "while" then
         read(scan, stmt.exp, st)
         at_end = walk.block(scan, stmt.body, 1, st, no_node)
      else
         at_end = walk.block(scan, stmt.body, 1, st, stmt.exp)
      end
      table.remove(scan.loops)
      if stmt.exp.kind == "boolean" and stmt.exp.tk == endless then
         return breaks.state
      elseif kind == "repeat" then
         return meet(at_end, breaks.state)
      end
      return after_loop(stmt, st, at_end, breaks)
   elseif kind == "fornum" or kind == "forin" then
      if kind == "fornum" then
         read(scan, stmt.from, st)
         read(scan, stmt.to, st)
         read(scan, stmt.step, st)
      else
         read(scan, stmt.exps, st)
      end
      local breaks: Exit = { state = no_state }
      table.insert(scan.loops, breaks)
      local saved = scan.hidden
      if kind == "fornum" and stmt.var.tk == name or kind == "forin" and names_in(stmt.vars, name) then
         scan.hidden = true
      end
      local at_end = walk.block(scan, stmt.body, 1, st, no_node)
      scan.hidden = saved
      table.remove(scan.loops)
      return after_loop(stmt, st, at_end, breaks)
   end
   return st
end

function walk.block(scan: Scan, body: flow.Node, first: integer, st: State, tail: flow.Node): State
   local saved = scan.hidden
   for i = first, #body do
      if scan.found then
         break
      end
      local stmt = body[i]
      if stmt.kind == "label" then
         st = meet(st, scan.gotos[stmt.label])
         scan.gotos[stmt.label] = nil
      elseif st then
         st = walk.statement(scan, stmt, st)
      elseif declares(stmt, scan.name) then
         scan.hidden = true
      end
   end
   if st and tail then
      read(scan, tail, st)
   end
   scan.hidden = saved
   return st
end

-- TODO: let a function literal name a local not yet assigned when nothing
-- can call it before the assignment: a function declared ahead for two to
-- call each other (`local g: function(); local function h() g() end;
-- g = ...`), which the tree writes 40 times and holds today as a value that
-- raises (`local g: function() = function() error("...") end`). It waits on
-- this module telling which expressions may run a function (a call, an
-- iterator, an operator that dispatches), and the last needs the types
-- only the checker has.
--- The first place, in the statements of `body` from `first` on (and in
--- `tail`, the `until` of a `repeat` body), that reads the local `name`
--- declared just before `first` with no value, along a path that did not
--- assign it. A read is a use of `name` or a function literal that names it,
--- which reads it where it is made; an assignment inside a function
--- literal assigns nothing for the code around it; the first answer is the
--- variable's node, or the function that names it. The second answer is a
--- statement a path went by that skipped the assignment another made (an
--- `if`, an `else`-less `if`'s branch, a loop), nil where none did.
function flow.unassigned_read(body: flow.Node, first: integer, name: string, tail: flow.Node): flow.Node, flow.Node
   local scan: Scan = { name = name, found = no_node, skipped = no_node, hidden = false, loops = {}, gotos = {} }
   walk.block(scan, body, first, unassigned_state, tail)
   return scan.found, scan.skipped
end

return flow
