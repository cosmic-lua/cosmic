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
   record Node
      is {Node}
      kind: string
      tk: string
      exp: Node
      body: Node
      if_blocks: {Node}
      never_call: boolean
   end

   ends: function(Node): boolean
   ends_body: function(Node): boolean
   ends_all: function({Node}): boolean
   leaves: function(Node): boolean
   leaves_body: function(Node): boolean
   mark_never_call: function(Node)
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

--- Whether the last statement of `body` leaves (see [`flow.leaves`]).
function flow.leaves_body(body: flow.Node): boolean
   return #body > 0 and flow.leaves(body[#body])
end

--- Records that `node`, a call, never returns: its function is typed
--- `: never`. The type checker decides that, once it has typed the call.
function flow.mark_never_call(node: flow.Node)
   node.never_call = true
end

return flow
