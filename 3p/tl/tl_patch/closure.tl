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
-- The `["label"]` site keeps stock widen-all: a narrow at a label must
-- hold for every goto path, including one from before the guard with
-- no assignment anywhere. Loop and if sites keep their own nodes —
-- they widen for a different question (assigned in the loop body).
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
            -- cosmic carried patch: widening against the closure's OWN
            -- node kept a narrow that a reassignment after the
            -- definition invalidates once the closure escapes.
            self:widen_all_unions(self.chunk_body)
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
            self:widen_all_unions(self.chunk_body)
            self:begin_scope(node)
         end,]=====],
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
