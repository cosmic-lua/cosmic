-- The narrow-* half of the carried tl patch: teaches the checker that
-- a nil union narrows through the guards Lua programmers actually
-- write — truthiness, `assert`, `x and x.field`, `== nil`, exiting
-- branches, disjunctive guards, `x or fallback` with a non-nil
-- fallback — each strictly better: more correct programs check, none
-- stop. `narrow-nil-union` installs the shared helpers; the census is
-- docs/design/nil-flow.md.
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
  ["narrow-and-operand"] = {
    file = "tl.lua",
    note = "whilp/cosmic#942: the left operand of `and` is read in boolean context",
    find = [=====[            if node.expected then
               if node.op.op == "and" then
                  node.e2.expected = node.expected
               elseif node.op.op == "or" then]=====],
    replace = [=====[            if node.expected then
               if node.op.op == "and" then
                  node.e2.expected = node.expected
                  -- cosmic carried patch (whilp/cosmic#942): the left
                  -- operand of `and` decides the branch, so inside a
                  -- boolean context it is read in one too -- which is
                  -- what gives `if st and st:is_dir()`, the idiom a Lua
                  -- programmer writes, its truthiness fact. tl already
                  -- applies e1's facts to e2 (before_e2), so the fact is
                  -- all that was missing. Only boolean_context
                  -- propagates: where a VALUE is expected, e1 is the
                  -- expression's own falsy result and keeps its type.
                  if node.expected.typename == "boolean_context" then
                     node.e1.expected = node.expected
                  end
               elseif node.op.op == "or" then]=====],
  },
  ["narrow-and-value"] = {
    file = "tl.lua",
    note = "`x and E` reads x for truthiness in value position too, not just under `if`",
    find = [=====[            if node.op.op == "not" then
               node.e1.expected = a_type(node, "boolean_context", {})
            end]=====],
    replace = [=====[            -- cosmic carried patch: `x and E` reads x for its truthiness
            -- wherever it appears, not only where a boolean is expected
            -- -- when x is falsy the whole expression is x and E never
            -- runs, so within E the variable is non-nil. Marking the read
            -- rather than propagating an expected boolean_context leaves
            -- the expression's own type alone, which is what
            -- `local y = x and x:upper()` needs.
            if node.op.op == "and" then
               node.e1.truthy_read = true
            end
            if node.op.op == "not" then
               node.e1.expected = a_type(node, "boolean_context", {})
            end]=====],
  },
  ["narrow-assert"] = {
    file = "tl.lua",
    note = "whilp/cosmic#942: assert(x) on a plain variable narrows its nil union",
    find = [=====[
      ["assert"] = function(self, node, a, b, argdelta)
         node.known = FACT_TRUTHY
         local r = self:type_check_function_call(node, a, b, argdelta)
         self:apply_facts(node, node.e2[1].known)
         return r
      end,]=====],
    replace = [=====[
      ["assert"] = function(self, node, a, b, argdelta)
         node.known = FACT_TRUTHY
         local r = self:type_check_function_call(node, a, b, argdelta)
         -- cosmic carried patch (whilp/cosmic#942): assert(x) on a plain
         -- variable of a nil union narrows like a truthiness guard --
         -- assert already applies its argument's facts to the statements
         -- that follow; this gives the argument one when it is a bare
         -- variable read.
         local arg1 = node.e2[1]
         if arg1 and arg1.kind == "variable" and not arg1.known and b.tuple[1] then
            local typ = without_nil(self, arg1, b.tuple[1], true)
            if typ then
               arg1.known = IsFact({ var = arg1.tk, typ = typ, w = arg1 })
            end
         end
         self:apply_facts(node, node.e2[1].known)
         return r
      end,]=====],
  },
  ["narrow-assert-decl"] = {
    file = "tl.lua",
    note = "whilp/cosmic#1065: assert strips nil, so it narrows in expression position",
    find = [=====[      assert: function<A, B>(A, ? B, ...: any): A --[[special_function]]
]=====],
    replace = [=====[      -- cosmic carried patch (whilp/cosmic#1065): assert's declared
      -- argument strips the nil, so `local db = assert(open(p))` and
      -- `local d2 = assert(d)` yield A rather than handing `A | nil`
      -- straight back. The statement form already narrowed (see
      -- narrow-assert below); this is the expression form, which is
      -- what a Lua programmer writes first.
      assert: function<A, B>(A | nil, ? B, ...: any): A --[[special_function]]
]=====],
  },
  ["narrow-assert-decl-tl-tl"] = {
    file = "tl.tl",
    note = "whilp/cosmic#1065: assert strips nil (Teal ground truth)",
    find = [=====[      assert: function<A, B>(A, ? B, ...: any): A --[[special_function]]
]=====],
    replace = [=====[      -- cosmic carried patch (whilp/cosmic#1065): assert's declared
      -- argument strips the nil, so `local db = assert(open(p))` and
      -- `local d2 = assert(d)` yield A rather than handing `A | nil`
      -- straight back. The statement form already narrowed (see
      -- narrow-assert below); this is the expression form, which is
      -- what a Lua programmer writes first.
      assert: function<A, B>(A | nil, ? B, ...: any): A --[[special_function]]
]=====],
  },
  ["narrow-eq-nil"] = {
    file = "tl.lua",
    note = "whilp/cosmic#942: == nil / ~= nil on a plain variable is an exact nil test",
    find = [=====[
               elseif self:is_a(ub, ua) or ua.typename == "typevar" then
                  if node.op.op == "==" and node.e1.kind == "variable" then
                     node.known = EqFact({ var = node.e1.tk, typ = ub, w = node })
                  end
               elseif self:is_a(ua, ub) or ub.typename == "typevar" then
                  if node.op.op == "==" and node.e2.kind == "variable" then
                     node.known = EqFact({ var = node.e2.tk, typ = ua, w = node })
                  end]=====],
    replace = [=====[
               elseif self:is_a(ub, ua) or ua.typename == "typevar" then
                  -- cosmic carried patch (whilp/cosmic#942): comparing a
                  -- variable against nil is an exact type test -- __eq
                  -- never fires with a nil operand -- so it carries an
                  -- IsFact, whose negation narrows, instead of an EqFact,
                  -- whose negation is deliberately information-free.
                  if node.e1.kind == "variable" and rb.typename == "nil" then
                     local f = IsFact({ var = node.e1.tk, typ = rb, w = node })
                     node.known = node.op.op == "==" and f or NotFact({ f1 = f, w = node })
                  elseif node.op.op == "==" and node.e1.kind == "variable" then
                     node.known = EqFact({ var = node.e1.tk, typ = ub, w = node })
                  end
               elseif self:is_a(ua, ub) or ub.typename == "typevar" then
                  if node.e2.kind == "variable" and ra.typename == "nil" then
                     local f = IsFact({ var = node.e2.tk, typ = ra, w = node })
                     node.known = node.op.op == "==" and f or NotFact({ f1 = f, w = node })
                  elseif node.op.op == "==" and node.e2.kind == "variable" then
                     node.known = EqFact({ var = node.e2.tk, typ = ua, w = node })
                  end]=====],
  },
  ["narrow-exit-break"] = {
    file = "tl.lua",
    note = "a branch ending in `break` cannot fall through, so the guard negation narrows",
    find = [=====[   visit_node.cbs["break"] = {
      after = function(_self, _node, _children)
         return NONE
      end,
   }
   visit_node.cbs["do"] = visit_node.cbs["break"]]=====],
    replace = [=====[   -- cosmic carried patch: `break` leaves the enclosing loop, so a
   -- branch ending in one cannot fall through -- the property `return`
   -- already has and the one a negated guard's narrowing rests on.
   -- `do` gets its own callback: a do-block DOES fall through.
   visit_node.cbs["break"] = {
      after = function(_self, node, _children)
         node.block_returns = true
         return NONE
      end,
   }
   visit_node.cbs["do"] = {
      after = function(_self, _node, _children)
         return NONE
      end,
   }]=====],
  },
  ["narrow-exit-goto"] = {
    file = "tl.lua",
    note = "a branch ending in `goto` cannot fall through, so the guard negation narrows",
    find = [=====[      ["goto"] = {
         after = function(self, node, _children)
            local label_id = node.label]=====],
    replace = [=====[      ["goto"] = {
         after = function(self, node, _children)
            -- cosmic carried patch: `goto` transfers control away, so the
            -- statement after the enclosing `if` is not reached from this
            -- branch -- the same terminator property as `return`.
            node.block_returns = true
            local label_id = node.label]=====],
  },
  ["narrow-exit-register"] = {
    file = "tl.lua",
    note = "resolve `error`/`os.exit` through the type so a shadowing local is not one",
    find = [=====[      set_special_function(stdlib_globals["require"].t, "require")]=====],
    replace = [=====[      set_special_function(stdlib_globals["require"].t, "require")
      -- cosmic carried patch: `error` and `os.exit` never return, so a
      -- branch ending in either cannot fall through. They are marked
      -- special so the terminator is recognised by TYPE: a local of the
      -- same name shadowing the global is not one.
      set_special_function(stdlib_globals["error"].t, "error")
      set_special_function(((stdlib_globals["os"].t).def).fields["exit"], "os.exit")]=====],
  },
  ["narrow-exit-special"] = {
    file = "tl.lua",
    note = "`error(...)` and `os.exit(...)` terminate their block like `return`",
    find = [=====[      ["rawget"] = function(self, node, _a, b, _argdelta)]=====],
    replace = [=====[      -- cosmic carried patch: neither returns, so the call statement
      -- ends its block (see narrow-exit-register for why by type).
      ["error"] = function(self, node, a, b, argdelta)
         node.block_returns = true
         return (self:type_check_function_call(node, a, b, argdelta))
      end,

      ["os.exit"] = function(self, node, a, b, argdelta)
         node.block_returns = true
         return (self:type_check_function_call(node, a, b, argdelta))
      end,

      ["rawget"] = function(self, node, _a, b, _argdelta)]=====],
  },
  ["narrow-metatable-helper"] = {
    file = "tl.lua",
    note = "recognize the std metatable<T> nominal against a map- or array-shaped is-target, inline or named",
    find = [=====[      local function invalid_from(f)
         return IsFact({ fact = "is", var = f.var, typ = a_type(f.w, "invalid", {}), w = f.w })
      end]=====],
    replace = [=====[      local function invalid_from(f)
         return IsFact({ fact = "is", var = f.var, typ = a_type(f.w, "invalid", {}), w = f.w })
      end

      -- cosmic carried patch: `is` against a table-kinded target
      -- used to refuse a metatable<T>-typed value outright, though a
      -- runtime `type(x) == "table"` test is exactly what a
      -- getmetatable() result supports. Recognized by IDENTITY against
      -- the std metatable nominal (cache_std_metatable_type), never by
      -- name. The is-fact carries the UNRESOLVED target type (ub), so a
      -- named type arrives with typename == "nominal": resolve it first
      -- and judge the STRUCTURAL kind, so an inline `{K: V}` map or
      -- `{T}` array and a `type X = {K: V}` alias of one are the same
      -- case. A record or an interface nominal resolves to record or
      -- interface, neither of which is in this set, so it keeps
      -- failing: a metatable carries metamethod keys, not a record's
      -- declared fields. The two call sites below share this closure,
      -- so `self` is passed explicitly.
      local table_kinded = { map = true, array = true }

      local function is_table_metatable(self, typ, target)
         if target.typename == "nominal" then
            target = self:resolve_nominal(target)
         end
         return table_kinded[target.typename] == true and
         self.cache_std_metatable_type ~= nil and
         typ.typename == "nominal" and typ.found ~= nil and
         typ.found.def == self.cache_std_metatable_type
      end]=====],
  },
  ["narrow-metatable-is"] = {
    file = "tl.lua",
    note = "the positive `mt is {K: V}` branch narrows to the target's KIND with `any` values, not to the target",
    find = [=====[               elseif not self:is_a(f.typ, typ) then
                  self.errs:add(f.w, f.var .. " (of type %s) can never be a %s", typ, f.typ)
                  return { [f.var] = invalid_from(f) }]=====],
    replace = [=====[               elseif not self:is_a(f.typ, typ) then
                  if is_table_metatable(self, typ, f.typ) then
                     -- cosmic carried patch: the rescue admits the
                     -- target by its KIND, so only the kind may reach
                     -- the narrowed variable. A metatable<T>'s values
                     -- are metamethods, not the target's value type,
                     -- so the fact is rebuilt over the same kind with
                     -- `any` values: `mt is {string: integer}` narrows
                     -- mt to {string: any}, never to {string: integer},
                     -- and mt.__index stops typing as integer.
                     local metatable_target = f.typ
                     if metatable_target.typename == "nominal" then
                        metatable_target = self:resolve_nominal(metatable_target)
                     end
                     local anyt = a_type(f.w, "any", {})
                     local opened
                     if metatable_target.typename == "array" then
                        opened = a_type(f.w, "array", { elements = anyt })
                     else
                        opened = a_type(f.w, "map", {
                           keys = metatable_target.keys, values = anyt,
                        })
                     end
                     return { [f.var] = IsFact({ fact = "is",
                        var = f.var, typ = opened, w = f.w,
                        no_infer = f.no_infer }) }
                  end
                  self.errs:add(f.w, f.var .. " (of type %s) can never be a %s", typ, f.typ)
                  return { [f.var] = invalid_from(f) }]=====],
  },
  ["narrow-metatable-not"] = {
    file = "tl.lua",
    note = "the negated branch keeps the metatable type instead of warning and poisoning",
    find = [=====[            elseif not self:is_a(f.typ, typ) then
               assert(f.fact == "is")
               self.errs:add_warning("branch", f.w, f.var .. " (of type %s) can never be a %s", show_type(typ), show_type(f.typ))]=====],
    replace = [=====[            elseif not self:is_a(f.typ, typ) and not is_table_metatable(self, typ, f.typ) then
               assert(f.fact == "is")
               self.errs:add_warning("branch", f.w, f.var .. " (of type %s) can never be a %s", show_type(typ), show_type(f.typ))]=====],
  },
  ["narrow-pack-n"] = {
    file = "tl.lua",
    note = "mixed-arity table.pack fallback returns PackTable<any>: .n stays integer",
    find = [=====[      pack: function(any...): {any:any} --[[needs_compat]]]=====],
    replace = [=====[      pack: function(any...): PackTable<any> --[[needs_compat]]]=====],
  },
  ["narrow-nil-union"] = {
    file = "tl.lua",
    note = "the two nil-union helpers the narrowing edits share",
    find = [=====[   function TypeChecker:arraytype_from_tuple(w, tupletype)]=====],
    replace = [=====[   -- cosmic carried patch: t with its nil member dropped, or nil when t
   -- is not a nil-carrying union. `strict` additionally refuses a union
   -- whose other members are not known to be truthy -- false, any,
   -- unknown, typevar -- which is what a truthiness guard needs and an
   -- `or` fallback does not.
   local function without_nil(self, w, t, strict)
      local rt = t
      if rt.typename == "nominal" then
         rt = self:resolve_nominal(rt)
      end
      if not (rt.typename == "union") then
         return nil
      end
      local has_nil, members = false, {}
      for _, m in ipairs(rt.types) do
         local rm = m
         if rm.typename == "nominal" then
            rm = self:resolve_nominal(rm)
         end
         if rm.typename == "nil" then
            has_nil = true
         elseif strict and (rm.typename == "boolean" or rm.typename == "any" or
            rm.typename == "unknown" or rm.typename == "boolean_context" or
            rm.typename == "typevar") then
            return nil
         else
            table.insert(members, m)
         end
      end
      if not has_nil or #members == 0 then
         return nil
      end
      return #members == 1 and members[1] or unite(w, members)
   end

   -- cosmic carried patch: does t hold nil? nil is a subtype of every
   -- type, so this stands in for is_a wherever a nil member would
   -- otherwise pass a target that cannot hold one.
   local function admits_nil(self, w, t)
      local rt = t
      if rt.typename == "nominal" then
         rt = self:resolve_nominal(rt)
      end
      return rt.typename == "nil" or rt.typename == "any" or
      rt.typename == "unknown" or rt.typename == "typevar" or
      without_nil(self, w, rt, false) ~= nil
   end

   function TypeChecker:arraytype_from_tuple(w, tupletype)]=====],
  },
  ["narrow-or-fallback"] = {
    file = "tl.lua",
    note = "`x or fallback` cannot be nil when the fallback cannot be",
    find = [=====[                  t = drop_constant_value(ra)]=====],
    replace = [=====[                  -- cosmic carried patch: `x or fallback` drops the nil
                  -- member instead of taking the left union whole, so
                  -- `fs.read(p) or ""` is a string. Skipped when the
                  -- fallback itself admits nil; the both-operands-are-
                  -- unions case never reaches here and stays a union.
                  local nonnil = not admits_nil(self, node, rb) and
                  without_nil(self, node, ra, false)
                  t = drop_constant_value(nonnil or ra)]=====],
  },
  ["narrow-or-guard"] = {
    file = "tl.lua",
    note = "a nil member must not survive intersection with a type that cannot hold nil",
    find = [=====[               if self:is_a(t, t2) then
                  table.insert(out, t)
               end]=====],
    replace = [=====[               -- cosmic carried patch: nil is a subtype of everything, so
               -- the bare is_a keeps a union's nil member against a
               -- target that cannot hold nil. That is what stopped
               -- `if x == nil or x == "" then return end` narrowing x
               -- below the guard: the two negated facts meet here.
               local keep = self:is_a(t, t2)
               if keep and t.typename == "nil" then
                  keep = admits_nil(self, w, t2)
               end
               if keep then
                  table.insert(out, t)
               end]=====],
  },
  ["narrow-truthiness"] = {
    file = "tl.lua",
    note = "whilp/cosmic#942: truthiness narrows nil-unions of records/maps/arrays",
    find = [=====[
            if t.typename == "typedecl" then
               t = typedecl_to_nominal(node, node.tk, t, t)
            end

            return t]=====],
    replace = [=====[
            if t.typename == "typedecl" then
               t = typedecl_to_nominal(node, node.tk, t, t)
            end

            -- cosmic carried patch (whilp/cosmic#942): a plain variable
            -- read for its truthiness carries a truthiness fact. Lua has
            -- no falsy tables, so for a union of nil with non-boolean
            -- members, truthy exactly means "not nil": the positive
            -- branch narrows to the members, and the negated
            -- early-return shape narrows below the guard.
            if node.truthy_read or
               (node.expected and node.expected.typename == "boolean_context") then
               local typ = without_nil(self, node, t, true)
               if typ then
                  node.known = IsFact({ var = node.tk, typ = typ, w = node })
               end
            end

            return t]=====],
  },
}
