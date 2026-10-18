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
--   * `return`, `break` and `goto` always (the checker allows a `goto` only
--     as a continue: a jump forward to the label that ends the body of
--     the loop around it, so it skips the rest of a pass and leaves no
--     loop);
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
-- every path, or named by a function that code the checker marked
-- `runs_code` (a call, an operator that dispatches: what it drops narrowing
-- for, `TypeChecker:drop_all`) may call before then.
--
-- What counts as running code is what the checker marks `runs_code` for
-- the narrowing it drops, so the rule is blind to what that misses: reading
-- a declared field of a record that declares `__index`, which runs code
-- unseen (the TODO in checker/narrowing.tl names it); a metatable attached
-- at run time (the `setmetatable` TODOs in checker/tl.tl and the roadmap item
-- they wait on); and a global, which this rule does not follow (see the
-- TODOs below).
--
-- The answers are computed from the tree and its marks on every ask,
-- never kept on a node, so a statement's answer cannot disagree with its
-- parts'.
--
-- This file holds only upstream Teal 0.24.8: the boot compiles it with
-- the pinned release's seed (build.zig), as it does checker/tl.tl.
--
-- TODO: a global declared with a type and no value (`global gx: integer`)
-- is read as a value though nothing assigned it, and a local given a call
-- that returns no values (`local v: integer = f()`) is nil though its type
-- admits none: this module follows locals declared with no value and no
-- more. They wait on the roadmap's item that excludes nil from every type
-- but one that names it, which refuses both where they are declared.

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
      runs_code: boolean
      attribute: string
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
   unassigned_read: function(Node, integer, string, Node): Node, Node, Node, string
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
-- around it: a `break` or a `goto` that is not of a loop inside `body`
-- (`inside`). A `goto` is a continue, to the end of the body of the
-- innermost loop around it.
local function exits(body: flow.Node, inside: boolean): boolean
   for _, stmt in ipairs(body) do
      local kind = stmt.kind
      if (kind == "goto" or kind == "break") and not inside then
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
-- once nil is excluded from every type but one that names it (the new
-- checker's "nil is its own type", doc/plans/strict-teal.md), which the
-- switch brings. The seed that compiles this file narrows a local and not a
-- field, so each read of a `T | nil` field is copied to a local first; no
-- pin move changes that, as the new checker narrows only a local too.
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
-- skipped the assignment another path made, and the first function
-- literal the path made that names the variable (which code run before
-- the assignment may call, so is "pending"). A path that cannot be taken
-- has no state (nil).
local record State
   assigned: boolean
   skipped: flow.Node
   closure: flow.Node
end

local assigned_state <const>: State = { assigned = true, skipped = no_node, closure = no_node }
local unassigned_state <const>: State = { assigned = false, skipped = no_node, closure = no_node }

-- No state, for a path that cannot be taken.
local no_state: State = nil

-- The state where two paths meet: unassigned if either is, and with a
-- pending function if either has one.
local function meet(a: State, b: State): State
   if not a then
      return b
   elseif not b then
      return a
   elseif a.assigned then
      return b
   elseif b.assigned or a.closure or not b.closure then
      return a
   end
   return { assigned = false, skipped = a.skipped, closure = b.closure }
end

-- `s` with `by` as the statement it skipped, when it names none yet.
local function skipped_by(s: State, by: flow.Node): State
   if s and not s.assigned and not s.skipped then
      return { assigned = false, skipped = by, closure = s.closure }
   end
   return s
end

-- `s` with `fn`, a function literal that names the variable, made on its
-- path.
local function with_closure(s: State, fn: flow.Node): State
   if s.assigned or s.closure then
      return s
   end
   return { assigned = false, skipped = s.skipped, closure = fn }
end

-- The state each path leaves a loop by `break` (or the branches of an
-- `if`) brings together; nil where none does. `continued` is the state the
-- `goto`s of a loop's pass bring to the label that ends its body.
local record Exit
   state: State
   continued: State
   -- How many `<close>` locals were open (`Scan.closers`) where the loop
   -- began: a `break` or `goto` that leaves it runs the ones opened since.
   closers: integer
end

local record Scan
   name: string
   found: flow.Node
   skipped: flow.Node
   -- What may have run the function `found` is, when it is one: the call,
   -- operator, loop or `return` (nil at the end of the variable's
   -- scope), and which of them it is.
   ran: flow.Node
   how: string
   -- Whether a local of the same name hides the variable here: control
   -- still flows, but a read or a write is another variable's.
   hidden: boolean
   loops: {Exit}
   -- The `<close>` locals declared so far in the blocks around the walk's
   -- position, the innermost last. The checker marks a block that holds
   -- one whose type declares `__close` `runs_code`. The `__close` runs where
   -- the block ends, and before a `break` or `goto` that leaves it.
   closers: {flow.Node}
   -- What the walk's own block receives from outside any loop it walks: the
   -- `goto`s whose label ends the block (the body of the loop the variable
   -- is declared in) before the walk reaches it.
   outer: Exit
end

-- Something that may run code of the program's has run at `at`, in the way
-- `how` tells: the function this path made that names the variable may be
-- called before it is assigned.
local function ran(scan: Scan, st: State, at: flow.Node, how: string)
   if st and st.closure and not st.assigned and not scan.found then
      scan.found, scan.skipped, scan.ran, scan.how = st.closure, st.skipped, at, how
   end
end

-- The state after `fn`, a function literal, a named function or a macro
-- expression, is made: it reads nothing yet, but it is pending if it names
-- the variable.
local function made(scan: Scan, fn: flow.Node, st: State): State
   if scan.found or scan.hidden or st.assigned or not mention.of(fn, scan.name) then
      return st
   end
   return with_closure(st, fn)
end

-- Evaluates `e`, an expression, from `st` and answers the state after it:
-- a use of the variable is a read, a function literal that names it is
-- made, and what the checker marked as running code of the program's
-- (`runs_code`: a call, or an operator that dispatches) may call a function
-- made before it.
local function eval(scan: Scan, e: flow.Node, st: State): State
   if not e or scan.found or st.assigned then
      return st
   end
   local kind = e.kind
   if kind == "variable" then
      if e.tk == scan.name and not scan.hidden then
         scan.found, scan.skipped = e, st.skipped
      end
   elseif kind == "function" or kind == "macroexp" then
      return made(scan, e, st)
   elseif kind == "op" then
      local op = e.op.op
      local after = eval(scan, e.e1, st)
      -- The right side of `is` and `as` is a type.
      if op ~= "is" and op ~= "as" then
         -- Whether the right side of `and` or `or` runs or not, a function
         -- it makes is pending after, and code it runs has run on a path.
         after = eval(scan, e.e2, after)
      end
      if e.runs_code then
         ran(scan, after, e, op == "@funcall" and "call" or "operator")
      end
      -- A call that never returns ends the path, but a function made and
      -- not yet assigned over may already have got out (stored, or given
      -- to a caller up the stack that catches the error).
      -- TODO: `assert(cond)` and an operator that raises (`1 // d`, an
      -- index of a nil field) end a path in the same way, after a function
      -- that names the local has escaped, and are not seen as doing so
      -- (`reg.cb = function() return x.x end; assert(flag == false);
      -- x = {...}`, then a `pcall` of the body and `reg.cb()`). It waits on
      -- doc/roadmap.md's item that checks such a function where it escapes.
      if e.never_call then
         ran(scan, after, e, "never")
      end
      return after
   elseif kind == "paren" then
      return eval(scan, e.e1, st)
   elseif kind == "literal_table_item" then
      return eval(scan, e.value, eval(scan, e.key, st))
   elseif kind == "literal_table" or kind == "expression_list" or kind == "variable_list" then
      for _, child in ipairs(e) do
         st = eval(scan, child, st)
      end
   end
   return st
end

-- Walks the statements of a block, which call the walk of a block.
local record walk
   block: function(Scan, flow.Node, integer, State, flow.Node): State
   statement: function(Scan, flow.Node, State): State
   loop: function(Scan, flow.Node, State): State
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

-- Walks a loop: `while`, `repeat`, a numeric and a generic `for`. A pass
-- of the body that ends with a function pending goes round again, the
-- function made before the first statement of the next pass; it ends the
-- second time round, as the state only grows.
function walk.loop(scan: Scan, stmt: flow.Node, st: State): State
   local kind = stmt.kind
   local name = scan.name
   local entry = st
   if kind == "fornum" then
      entry = eval(scan, stmt.step, eval(scan, stmt.to, eval(scan, stmt.from, st)))
   elseif kind == "forin" then
      entry = eval(scan, stmt.exps, st)
   end
   local breaks: Exit = { state = no_state, continued = no_state, closers = #scan.closers }
   table.insert(scan.loops, breaks)
   local saved_hidden = scan.hidden
   local head: State = no_state
   local at_end: State = no_state
   for pass = 1, 2 do
      local from = entry
      if pass == 2 then
         if not at_end or at_end.assigned or not at_end.closure or entry.closure then
            break
         end
         from = meet(entry, at_end)
      end
      breaks.continued = no_state
      scan.hidden = saved_hidden
      local here = from
      local tail = no_node
      if kind == "while" then
         here = eval(scan, stmt.exp, from)
      elseif kind == "repeat" then
         tail = stmt.exp
      elseif kind == "forin" then
         if stmt.runs_code then
            ran(scan, from, stmt, "iterator")
         end
         if names_in(stmt.vars, name) then
            scan.hidden = true
         end
      elseif stmt.var.tk == name then
         scan.hidden = true
      end
      head = meet(head, here)
      local finished = walk.block(scan, stmt.body, 1, here, tail)
      at_end = pass == 1 and finished or meet(at_end, finished)
   end
   scan.hidden = saved_hidden
   table.remove(scan.loops)
   if kind == "while" and stmt.exp.kind == "boolean" and stmt.exp.tk == "true"
      or kind == "repeat" and stmt.exp.kind == "boolean" and stmt.exp.tk == "false" then
      return breaks.state
   elseif kind == "repeat" then
      return meet(at_end, breaks.state)
   end
   return after_loop(stmt, head, at_end, breaks)
end

function walk.statement(scan: Scan, stmt: flow.Node, st: State): State
   local kind = stmt.kind
   local name = scan.name
   if kind == "local_declaration" or kind == "global_declaration" then
      st = eval(scan, stmt.exps, st)
      if kind == "local_declaration" and names_in(stmt.vars, name) then
         scan.hidden = true
      end
   elseif kind == "assignment" then
      st = eval(scan, stmt.exps, st)
      local assigns = false
      for _, v in ipairs(stmt.vars) do
         if v.kind == "variable" then
            assigns = assigns or v.tk == name
         else
            st = eval(scan, v, st)
         end
      end
      if assigns and not scan.hidden then
         return assigned_state
      end
   elseif kind == "op" then
      st = eval(scan, stmt, st)
      if stmt.never_call then
         return nil
      end
   elseif kind == "local_function" then
      if stmt.name.tk == name then
         scan.hidden = true
      else
         st = made(scan, stmt, st)
      end
   elseif kind == "global_function" then
      st = made(scan, stmt, st)
      if stmt.name.tk == name and not scan.hidden then
         return assigned_state
      end
   elseif kind == "record_function" then
      st = made(scan, stmt, eval(scan, stmt.fn_owner, st))
   elseif kind == "local_macroexp" then
      st = made(scan, stmt.macrodef, st)
      if stmt.name.tk == name then
         scan.hidden = true
      end
   elseif kind == "return" then
      -- A function made and not yet assigned over may leave with the
      -- return, to be called when the variable is still unassigned.
      st = eval(scan, stmt.exps, st)
      ran(scan, st, stmt, "return")
      return nil
   elseif kind == "break" then
      local breaks = scan.loops[#scan.loops]
      if #scan.closers > (breaks and breaks.closers or 0) then
         ran(scan, st, scan.closers[#scan.closers], "close")
      end
      if breaks then
         breaks.state = meet(breaks.state, st)
      else
         -- It leaves the loop the variable is declared in, and with it the
         -- variable's scope.
         ran(scan, st, no_node, "scope")
      end
      return nil
   elseif kind == "goto" then
      -- A continue: the rest of this pass is skipped, and the label that
      -- ends the body of the loop is reached with this state.
      local continues = scan.loops[#scan.loops] or scan.outer
      if #scan.closers > continues.closers then
         ran(scan, st, scan.closers[#scan.closers], "close")
      end
      continues.continued = meet(continues.continued, st)
      return nil
   elseif kind == "do" then
      return walk.block(scan, stmt.body, 1, st, no_node)
   elseif kind == "if" then
      local ends: {Exit} = {}
      local blocks = stmt.if_blocks
      local any_assigned = false
      -- Each condition runs when those before it were false.
      local asked = st
      for i, b in ipairs(blocks) do
         asked = eval(scan, b.exp, asked)
         local s = walk.block(scan, b.body, 1, asked, no_node)
         if s and s.assigned then
            any_assigned = true
         end
         ends[i] = { state = s, continued = no_state, closers = #scan.closers }
      end
      local out: State = no_state
      if any_assigned then
         for i, b in ipairs(blocks) do
            out = meet(out, skipped_by(ends[i].state, b))
         end
         if blocks[#blocks].exp then
            out = meet(out, skipped_by(asked, stmt))
         end
      else
         for i = 1, #blocks do
            out = meet(out, ends[i].state)
         end
         if blocks[#blocks].exp then
            out = meet(out, asked)
         end
      end
      return out
   elseif kind == "while" or kind == "repeat" or kind == "fornum" or kind == "forin" then
      return walk.loop(scan, stmt, st)
   end
   return st
end

-- The variable of `stmt`, a declaration, that is `<close>` and that the
-- checker marked `runs_code` (its type declares `__close`); nil for any
-- other statement.
local function closer_in(stmt: flow.Node): flow.Node
   if stmt.kind ~= "local_declaration" then
      return nil
   end
   for _, v in ipairs(stmt.vars) do
      if v.attribute == "close" and v.runs_code then
         return v
      end
   end
   return nil
end

function walk.block(scan: Scan, body: flow.Node, first: integer, st: State, tail: flow.Node): State
   local saved = scan.hidden
   local opened = #scan.closers
   -- A `<close>` local declared before the walk's first statement is open.
   if body.runs_code then
      for i = 1, first - 1 do
         local closer = closer_in(body[i])
         if closer then
            table.insert(scan.closers, closer)
         end
      end
   end
   for i = first, #body do
      if scan.found then
         break
      end
      local stmt = body[i]
      if stmt.kind == "label" then
         local continues = scan.loops[#scan.loops] or scan.outer
         st = meet(st, continues.continued)
         continues.continued = no_state
      elseif st then
         st = walk.statement(scan, stmt, st)
      elseif declares(stmt, scan.name) then
         scan.hidden = true
      end
      -- Open once its initializer has run.
      local closer = body.runs_code and closer_in(stmt)
      if closer then
         table.insert(scan.closers, closer)
      end
   end
   if st and tail then
      st = eval(scan, tail, st)
   end
   -- The `__close` of its `<close>` locals, after the `until` of a `repeat`.
   -- TODO: this runs on the state a `goto` brought to a label after the
   -- `<close>` local too, though that path jumped over its declaration (a
   -- `continue` that skips it), so a pending function that path carries is
   -- refused for a `__close` that never ran. It waits on a state that tells
   -- whether it passed the declaration, which only this file's `State` and
   -- `meet` need.
   if #scan.closers > opened then
      ran(scan, st, scan.closers[#scan.closers], "close")
   end
   while #scan.closers > opened do
      table.remove(scan.closers)
   end
   scan.hidden = saved
   return st
end

--- The first place, in the statements of `body` from `first` on (and in
--- `tail`, the `until` of a `repeat` body), that reads the local `name`
--- declared just before `first` with no value, along a path that did not
--- assign it. A read is a use of `name`, or a function literal that names
--- it and that something may call before the assignment: the creation of
--- the function reads nothing, but a call, an operator that dispatches or a
--- loop's iterator the checker marked `runs_code` may call it, and so may
--- the code that gets it by a `return`, a call that never returns and the end
--- of the variable's scope; an assignment inside a function literal
--- assigns nothing for the code around it. The first answer is the
--- variable's node, or the function that names it. The second is a
--- statement a path went by that skipped the assignment another made (an
--- `if`, an `else`-less `if`'s branch, a loop), nil where none did. For a
--- function the third answer is what may run it (nil at the end of the
--- scope) and the fourth how: `call`, `operator`, `iterator`, `close`,
--- `return`, `never` or `scope`.
function flow.unassigned_read(body: flow.Node, first: integer, name: string, tail: flow.Node): flow.Node, flow.Node, flow.Node, string
   local scan: Scan = {
      name = name, found = no_node, skipped = no_node, ran = no_node, how = "", hidden = false,
      loops = {}, closers = {}, outer = { state = no_state, continued = no_state, closers = 0 },
   }
   local final = walk.block(scan, body, first, unassigned_state, tail)
   if final then
      ran(scan, final, no_node, "scope")
   end
   -- A `goto` whose label the walk did not reach leaves the block, and the
   -- variable's scope, for a label further out.
   ran(scan, scan.outer.continued, no_node, "scope")
   return scan.found, scan.skipped, scan.ran, scan.how
end

return flow
