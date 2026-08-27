-- The closure-* group of the carried tl patch: a narrow survives into
-- a closure exactly when nothing in the FILE can invalidate it.
--
-- Stock tl widens every narrow at a named-function boundary (dropping
-- sound ones: a guarded module-level value could not be used from any
-- closure without a cast), and widens only names assigned INSIDE the
-- closure at anonymous-function boundaries (keeping unsound ones: a
-- reassignment after the definition never widens, so the escaped
-- closure runs on a stale narrow). Both resolve the same way: widen
-- against the CHUNK ROOT, so a narrow is dropped at a function
-- boundary iff the name is assigned anywhere in the file. Name-level
-- matching over-approximates bindings — an unrelated same-named
-- assignment widens spuriously — which errs conservative, never
-- unsound. The nearest-enclosing-body scope was probed and rejected:
-- an upvalue narrowed inside a parent function, carried into a child
-- closure that ESCAPES, goes stale when the outer scope reassigns
-- after the parent returns.
--
-- The boundary answers two questions, and they want different scopes.
-- What the closure BODY may rely on is the chunk-root question above:
-- the body runs at an unknown later time, so any assignment in the
-- file can invalidate a narrow it captured. What the enclosing
-- CONTINUATION after the definition may rely on is narrower — that is
-- straight-line code, so only an assignment inside the closure's OWN
-- body can reach it. The two anonymous sites therefore snapshot the
-- enclosing scope's narrows, widen against the chunk root for the
-- body's sake, and restore the snapshot once the closure's subtree is
-- checked, keeping the narrows the body could not invalidate. The five
-- named-function sites do not restore: stock widened every narrow in
-- their continuation, so the chunk-root scan is already strictly more
-- permissive there and there is nothing to give back.
--
-- The `["label"]` site keeps stock widen-all: a narrow at a label must
-- hold for every goto path, including one from before the guard with
-- no assignment anywhere. The four loop sites — `while`, `repeat`,
-- `forin` and `fornum` — pass their own node, so a LOCAL keeps its
-- narrow unless the loop body assigns it. A GLOBAL does not: the
-- always-assigned test sits inside `widen_all_unions` itself, which
-- every one of those sites calls, so a global's narrow drops at loop
-- entry as well as at a function boundary — the same soundness
-- argument, since a loop body can run after another module assigns the
-- global. Straight-line use below the guard keeps its narrow.
--
-- The mechanism is _make/patch.tl: each entry is an exact `find`
-- string replaced by an exact `replace` string in one unpacked file,
-- and entry names share one namespace across every file in this
-- directory, applied in sorted-name order.
--
-- Carried, not forked: each anchor must match the pinned source exactly
-- once, so a tl pin bump that moves this code fails the fetch loudly
-- until the patch is re-audited (or dropped, once upstream lands it).
return {
  ["closure-assigned-scan"] = {
    file = "tl.lua",
    note = "assigned_anywhere aggregates PAST nil holes: else-blocks and declaration rvalues",
    find = [=====[         after = function(_, _node, children, ret)
            ret = ret or false
            for _, c in ipairs(children) do
               local ca = c
               if type(ca) == "boolean" then
                  ret = ret or c
               end
            end
            return ret
         end,]=====],
    replace = [=====[         after = function(_, _node, children, ret)
            ret = ret or false
            -- cosmic carried patch: an else-block has no condition, so
            -- its children table starts at a nil hole (xs[2] holds the
            -- body) and ipairs stops before it -- an assignment inside
            -- any else branch, or inside a declaration's rvalue (same
            -- hole at the missing decltuple), was invisible to this
            -- scan. pairs reads past the holes; order is irrelevant to
            -- a boolean-or.
            for _, c in pairs(children) do
               local ca = c
               if type(ca) == "boolean" then
                  ret = ret or c
               end
            end
            return ret
         end,]=====],
  },
  ["closure-anon-function"] = {
    file = "tl.lua",
    note = "an anonymous closure widens against the file, not its own body",
    find = [=====[      ["function"] = {
         before = function(self, node)
            self:widen_all_unions(node)
            self:begin_scope(node)

            local expected = node.expected
            if expected and expected.typename == "function" then]=====],
    replace = [=====[      ["function"] = {
         before = function(self, node)
            -- cosmic carried patch: the body widens against the chunk
            -- root -- widening against the closure's OWN node kept a
            -- narrow that a reassignment after the definition
            -- invalidates once the closure escapes -- while the
            -- enclosing continuation keeps the narrows this body
            -- cannot invalidate, which is what stock gave it here.
            node.carried_narrows = self:widen_for_closure(node)
            self:begin_scope(node)

            local expected = node.expected
            if expected and expected.typename == "function" then]=====],
  },
  ["closure-anon-macroexp"] = {
    file = "tl.lua",
    note = "the macroexp expression form widens against the file too",
    find = [=====[      ["macroexp"] = {
         before = function(self, node)
            self:widen_all_unions(node)
            self:begin_scope(node)
         end,]=====],
    replace = [=====[      ["macroexp"] = {
         before = function(self, node)
            -- cosmic carried patch: the body widens against the chunk
            -- root; the enclosing continuation keeps the narrows this
            -- body cannot invalidate, as stock gave it here.
            node.carried_narrows = self:widen_for_closure(node)
            self:begin_scope(node)
         end,]=====],
  },
  ["closure-continuation-carry"] = {
    file = "tl.lua",
    note = "the two anonymous boundaries widen the body's scope, not the continuation's",
    find = [=====[   function TypeChecker:add_global(node, varname, valtype, is_assigning)]=====],
    replace = [=====[   -- cosmic carried patch: the closure boundary asks two questions
   -- with one scan. The BODY may rely only on what nothing in the
   -- file can invalidate, so it widens against the chunk root; the
   -- enclosing CONTINUATION after the definition is straight-line
   -- code, so only an assignment inside the closure's OWN body can
   -- invalidate a narrow there. Snapshot the narrows an own-body scan
   -- would have kept, widen against the chunk root, and restore the
   -- snapshot once the closure's subtree is checked. Every
   -- widen_in_scope exit mutates ONE scope table -- in place at the
   -- top, and through add_var, which writes the top scope, below it --
   -- so one snapshot per name covers all three, and it holds the
   -- scope TABLE rather than its index because the stack has moved by
   -- restore time.
   function TypeChecker:widen_for_closure(node)
      local scope = self.st[#self.st]
      local carried = nil
      for i = #self.st, 1, -1 do
         local s = self.st[i]
         if s.narrows then
            for name, _ in pairs(s.narrows) do
               if (not carried) or carried[name] == nil then
                  if not assigned_anywhere(name, node) then
                     local v = scope.vars[name]
                     carried = carried or {}
                     carried[name] = {
                        scope = scope,
                        var = v,
                        t = v and v.t,
                        specialized_from = v and v.specialized_from,
                        is_specialized = v and v.is_specialized,
                        narrow = scope.narrows and scope.narrows[name] or nil,
                        widen = scope.widens and scope.widens[name] or nil,
                     }
                  end
               end
            end
         end
      end
      self:widen_all_unions(self.chunk_body)
      return carried
   end

   function TypeChecker:restore_carried_narrows(carried)
      if not carried then
         return
      end
      for name, c in pairs(carried) do
         local scope = c.scope
         if c.var then
            c.var.t = c.t
            c.var.specialized_from = c.specialized_from
            c.var.is_specialized = c.is_specialized
            scope.vars[name] = c.var
         else
            scope.vars[name] = nil
         end
         if scope.narrows then
            scope.narrows[name] = c.narrow
         end
         if scope.widens then
            scope.widens[name] = c.widen
         end
      end
   end

   function TypeChecker:add_global(node, varname, valtype, is_assigning)]=====],
  },
  ["closure-fn-rvalue"] = {
    file = "tl.lua",
    note = "a function rvalue in an assignment widens against the file",
    find = [=====[               if rval and rvar then

                  if rval.typename == "function" then
                     self:widen_all_unions()
                  end]=====],
    replace = [=====[               if rval and rvar then

                  if rval.typename == "function" then
                     self:widen_all_unions(self.chunk_body)
                  end]=====],
  },
  ["closure-global-function"] = {
    file = "tl.lua",
    note = "global function definitions widen against the file",
    find = [=====[      ["global_function"] = {
         before = function(self, node)
            self:widen_all_unions()
            self:begin_scope(node)]=====],
    replace = [=====[      ["global_function"] = {
         before = function(self, node)
            self:widen_all_unions(self.chunk_body)
            self:begin_scope(node)]=====],
  },
  ["closure-global-widen"] = {
    file = "tl.lua",
    note = "a global's assignment universe is every file, not this one",
    find = [=====[            for name, _ in pairs(scope.narrows) do
               if not node or assigned_anywhere(name, node) then]=====],
    replace = [=====[            for name, _ in pairs(scope.narrows) do
               -- cosmic carried patch: scope 1's vars table IS
               -- env.globals, shared by every file checked in one
               -- environment, so a global's assignment universe is not
               -- this file. assigned_anywhere only ever sees this
               -- chunk's AST, so another module's assignment is
               -- invisible to it and the narrow is kept -- an escaped
               -- closure then runs on a stale narrow. A narrow is a
               -- specialized shadow in a scope >= 2, so walk down for
               -- the scope the name is DECLARED in and treat scope 1
               -- as always-assigned. The walk, not st[1].vars[name],
               -- because env.globals also holds the stdlib: a local
               -- shadowing `tostring` would widen spuriously.
               local decl = 0
               for j = i, 1, -1 do
                  local sv = self.st[j].vars[name]
                  if sv and ((not sv.is_specialized) or sv.specialized_from) then
                     decl = j
                     break
                  end
               end
               if decl == 1 or not node or assigned_anywhere(name, node) then]=====],
  },
  ["closure-local-function"] = {
    file = "tl.lua",
    note = "local function definitions widen against the file, keeping safe narrows",
    find = [=====[      ["local_function"] = {
         before = function(self, node)
            self:widen_all_unions()
            if self.collector then]=====],
    replace = [=====[      ["local_function"] = {
         before = function(self, node)
            -- cosmic carried patch: with the chunk root as the scan
            -- scope, a name never assigned in the file keeps its narrow
            -- inside the function being defined -- the guarded
            -- module-value idiom stops needing a cast.
            self:widen_all_unions(self.chunk_body)
            if self.collector then]=====],
  },
  ["closure-local-macroexp"] = {
    file = "tl.lua",
    note = "local macroexp definitions widen against the file",
    find = [=====[      ["local_macroexp"] = {
         before = function(self, node)
            self:widen_all_unions()
            if self.collector then]=====],
    replace = [=====[      ["local_macroexp"] = {
         before = function(self, node)
            self:widen_all_unions(self.chunk_body)
            if self.collector then]=====],
  },
  ["closure-record-function"] = {
    file = "tl.lua",
    note = "record function definitions widen against the file",
    find = [=====[      ["record_function"] = {
         before = function(self, node)
            self:widen_all_unions()
            self:begin_scope(node)
         end,]=====],
    replace = [=====[      ["record_function"] = {
         before = function(self, node)
            self:widen_all_unions(self.chunk_body)
            self:begin_scope(node)
         end,]=====],
  },
  ["closure-restore-function"] = {
    file = "tl.lua",
    note = "give the continuation back the narrows the anonymous body could not invalidate",
    find = [=====[            self:end_function_scope(node)

            return wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.min_arity or 0,
               args = args,
               rets = self.get_rets(rets),
            }))]=====],
    replace = [=====[            self:end_function_scope(node)
            -- cosmic carried patch: the boundary widened the enclosing
            -- continuation against the chunk root for the body's sake;
            -- the continuation gets back the narrows only this body
            -- could have invalidated.
            self:restore_carried_narrows(node.carried_narrows)
            node.carried_narrows = nil

            return wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.min_arity or 0,
               args = args,
               rets = self.get_rets(rets),
            }))]=====],
  },
  ["closure-restore-macroexp"] = {
    file = "tl.lua",
    note = "the macroexp expression form restores its continuation too",
    find = [=====[            self:end_function_scope(node)
            return wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.min_arity or 0,
               args = args,
               rets = rets,
            }))]=====],
    replace = [=====[            self:end_function_scope(node)
            -- cosmic carried patch: the continuation gets back the
            -- narrows only this macroexp body could have invalidated.
            self:restore_carried_narrows(node.carried_narrows)
            node.carried_narrows = nil
            return wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.min_arity or 0,
               args = args,
               rets = rets,
            }))]=====],
  },
  ["closure-root"] = {
    file = "tl.lua",
    note = "the chunk root every function boundary scans for assignments",
    find = [=====[      assert(ast.kind == "statements")
      recurse_node(self, ast, visit_node, visit_type)]=====],
    replace = [=====[      assert(ast.kind == "statements")
      -- cosmic carried patch: the function-boundary widen sites scan
      -- this root for assignments; nil (an entrance that skips this
      -- assignment) falls back to stock widen-everything.
      self.chunk_body = ast
      recurse_node(self, ast, visit_node, visit_type)]=====],
  },
}
