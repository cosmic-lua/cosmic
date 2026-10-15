-- Captures: which function literals assign a local they do not declare.
--
-- A function literal (`function() ... end`, `local function`, `function f()`,
-- a record function, a macro expression) may read a local of the code
-- around it but must not assign one: the binding is the enclosing code's,
-- and only that code assigns it. So a call, whatever it calls, never changes
-- a local the checker has narrowed, and a value a function finds in a local
-- came from the code that made the function. A function that must hand a
-- value back returns it, or keeps it in a field of a table both read (a
-- field is not the local: `state.n = state.n + 1` assigns no local).
--
-- A local the literal declares itself is its own, its parameters among
-- them, and so are those of a function nested in it. A local declared
-- outside any function literal and assigned outside one (the forward
-- declaration `local f: function(); f = function() ... end`) is the
-- enclosing code's too. A name that no local declaration in sight binds is a
-- global, which this rule does not follow.
--
-- The checker (checker/tl.tl) asks for the assignments of a file once,
-- before it checks the file, and refuses each as the code
-- `captured_assigned`. The answer is computed from the tree on every ask.
--
-- This file holds only upstream Teal 0.24.8: the boot compiles it with
-- the vendored `tl.lua` (core/bridge.lua), as it does checker/tl.tl.

-- The node fields this walk reads. The checker's own `Node`
-- (checker/tl.tl) has all of them, and its callers cast to this type,
-- which the checker cannot name here without a require cycle.
local record captures
   record Node
      is {Node}
      kind: string
      tk: string
      y: integer
      x: integer
      exp: Node
      exps: Node
      vars: Node
      args: Node
      body: Node
      name: Node
      macrodef: Node
      if_blocks: {Node}
      from: Node
      to: Node
      step: Node
      var: Node
      implicit_global_function: boolean
   end

   -- An assignment to `variable`, a local declared outside the function
   -- literal the assignment is in: `at` is the name assigned, `declared`
   -- the name where the local is declared.
   record Capture
      variable: string
      at: Node
      declared: Node
   end

   find: function(Node): {Capture}
end

--- The assignments in `root`, a file's statements, to a local declared in
--- a function other than the one that assigns it, in the order they stand.
function captures.find(root: captures.Node): {captures.Capture}
   local found: {captures.Capture} = {}
   -- The locals in scope, innermost scope last, each with the depth of the
   -- function that declares it: the function literals around the code now.
   local scopes: {{string:captures.Node}} = {}
   local depth_of: {captures.Node:integer} = {}
   local inside = { depth = 0 }

   local function bind(node: captures.Node)
      if node and node.tk and #scopes > 0 then
         scopes[#scopes][node.tk] = node
         depth_of[node] = inside.depth
      end
   end

   local function assign(at: captures.Node)
      for i = #scopes, 1, -1 do
         local binder = scopes[i][at.tk]
         if binder then
            if depth_of[binder] < inside.depth then
               table.insert(found, { variable = at.tk, at = at, declared = binder })
            end
            return
         end
      end
   end

   local walk_expression: function(captures.Node) = nil
   local walk_statement: function(captures.Node) = nil
   local walk_block: function(captures.Node) = nil

   -- The body of a function, or the expression of a macro expression,
   -- with its arguments bound.
   local function walk_function(node: captures.Node)
      inside.depth = inside.depth + 1
      table.insert(scopes, {})
      for _, argument in ipairs(node.args or {}) do
         bind(argument)
      end
      if node.body then
         walk_block(node.body)
      end
      if node.exp then
         walk_expression(node.exp)
      end
      table.remove(scopes)
      inside.depth = inside.depth - 1
   end

   -- An expression is walked through every node it holds, since only a
   -- function literal in it matters and the scope is the same all through
   -- it.
   walk_expression = function(n: captures.Node)
      local kind = n.kind
      if kind == "function" or kind == "macroexp" then
         walk_function(n)
         return
      end
      for key, child in pairs(n as {any:any}) do
         if key ~= "if_parent" and key ~= "fn_owner" and type(child) == "table" then
            local node = child as captures.Node
            if node.kind then
               walk_expression(node)
            end
         end
      end
   end

   -- A type declaration holds expressions of its own: the `where` clause of a
   -- record or an interface, and of the records nested in it, is a macro
   -- expression, and its body may hold function literals. The declaration is
   -- walked through every table it holds, looking for those.
   local function walk_type(root: captures.Node)
      local seen: {any:boolean} = {}
      local function visit(n: any)
         if type(n) ~= "table" or seen[n] then return end
         seen[n] = true
         local node = n as captures.Node
         if node.kind == "macroexp" or node.kind == "function" then
            walk_function(node)
            return
         end
         for key, child in pairs(n as {any:any}) do
            if key ~= "if_parent" and key ~= "fn_owner" then
               visit(child)
            end
         end
      end
      visit(root)
   end

   walk_block = function(block: captures.Node)
      table.insert(scopes, {})
      for _, statement in ipairs(block) do
         walk_statement(statement)
      end
      table.remove(scopes)
   end

   walk_statement = function(s: captures.Node)
      local kind = s.kind
      if kind == "local_declaration" then
         if s.exps then
            walk_expression(s.exps)
         end
         for _, v in ipairs(s.vars) do
            bind(v)
         end
      elseif kind == "assignment" then
         if s.exps then
            walk_expression(s.exps)
         end
         for _, v in ipairs(s.vars) do
            if v.kind == "variable" then
               assign(v)
            else
               walk_expression(v)
            end
         end
      elseif kind == "local_function" then
         bind(s.name)
         walk_function(s)
      elseif kind == "global_function" then
         -- `function f()` with no `local` or `global` assigns a local `f`
         -- declared before it.
         if s.implicit_global_function then
            assign(s.name)
         end
         walk_function(s)
      elseif kind == "record_function" then
         walk_function(s)
      elseif kind == "local_macroexp" then
         bind(s.name)
         walk_function(s.macrodef)
      elseif kind == "if" then
         for _, block in ipairs(s.if_blocks) do
            if block.exp then
               walk_expression(block.exp)
            end
            walk_block(block.body)
         end
      elseif kind == "while" then
         walk_expression(s.exp)
         walk_block(s.body)
      elseif kind == "repeat" then
         -- The condition sees the body's locals.
         table.insert(scopes, {})
         for _, statement in ipairs(s.body) do
            walk_statement(statement)
         end
         walk_expression(s.exp)
         table.remove(scopes)
      elseif kind == "fornum" then
         walk_expression(s.from)
         walk_expression(s.to)
         if s.step then
            walk_expression(s.step)
         end
         table.insert(scopes, {})
         bind(s.var)
         walk_block(s.body)
         table.remove(scopes)
      elseif kind == "forin" then
         walk_expression(s.exps)
         table.insert(scopes, {})
         for _, v in ipairs(s.vars) do
            bind(v)
         end
         walk_block(s.body)
         table.remove(scopes)
      elseif kind == "do" then
         walk_block(s.body)
      elseif kind == "return" or kind == "global_declaration" then
         if s.exps then
            walk_expression(s.exps)
         end
      elseif kind == "local_type" or kind == "global_type" then
         walk_type(s)
      elseif kind == "break" or kind == "goto" or kind == "label" or kind == "pragma" then
         return
      else
         walk_expression(s)
      end
   end

   walk_block(root)
   return found
end

return captures
