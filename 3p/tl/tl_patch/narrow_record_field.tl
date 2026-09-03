-- Record-field narrowing: the gap docs/design/casts.md's "record union
-- after guard" section names -- a guard on `x.field` narrows nothing
-- today, so the documented workaround is copying the field to a local
-- (or casting it). This teaches the checker the same guard shapes
-- narrow.tl already carries for a bare variable -- truthiness,
-- `assert`, `== nil` / `~= nil` -- when the guarded expression is a
-- record field on a plain variable instead.
--
-- The mechanism: `x.field`'s fact key is the string "x.field" -- one no
-- real Lua identifier can ever collide with, since a name never
-- contains a dot -- so it shares the exact scope.vars table a plain
-- variable's narrow already lives in, and gets that table's shadowing,
-- widening (loop re-entry) and end-of-scope cleanup for free, with no
-- new storage of its own. The one piece a bare variable's fact does
-- not need: the FIRST time a field is guarded, no scope entry exists
-- yet to read a "current type" from, so `TypeChecker:fact_base_type`
-- falls back to re-deriving the field's declared type from the base
-- variable's current type, through the same `type_check_index` a `.`
-- read already calls. Invalidation -- dropping the fact on a write to
-- `x.field` or to `x` itself -- is `TypeChecker:drop_field_narrows`,
-- called from the assignment handler.
--
-- Only a bare-variable base is tracked (`x.field`, not `a.b.field`);
-- `cosmic/teal_test.tl`'s `test_narrowing_canary` is the regression
-- canary, worked the same way the bare-variable shapes are canaried
-- there.
return {
  ["narrow-record-field-helpers"] = {
    file = "tl.lua",
    note = "teal-language/tl#PENDING: fact_key/fact_base_type/drop_field_narrows the record-field entries below share",
    find = [=====[   function TypeChecker:type_check_index(anode, bnode, a, b)
]=====],
    replace = [=====[   -- cosmic carried patch (teal-language/tl#PENDING): a fact key for
   -- record-field narrowing. A bare variable's key is its own name;
   -- `x.field`'s key is "varname.fieldname" -- a string no real
   -- identifier can collide with, since Lua names never contain a
   -- dot -- so a field guard shares the SAME scope.vars table a
   -- plain variable's narrow lives in, getting the same shadowing,
   -- widening and end-of-scope cleanup for free. Only a bare-variable
   -- base is tracked; `a.b.c` does not chain.
   local function fact_key(n)
      if n.kind == "variable" then
         return n.tk
      end
      if n.kind == "op" and n.op.op == "." and n.e1.kind == "variable" then
         return n.e1.tk .. "." .. n.e2.tk
      end
      return nil
   end

   -- The current type behind a fact key, even the first time a field
   -- key is narrowed: a plain variable's is whatever the checker
   -- already tracks for it (find_var_type finds it directly); a
   -- field key with no narrow recorded yet falls back to the field's
   -- type as declared on the base variable's CURRENT type. This must
   -- be a SILENT query -- by the time a fact composed with another
   -- (an `or`, say) is finally applied, the scope that temporarily
   -- narrowed the base variable while the fact was built has already
   -- closed, so its current type can be one the field access that
   -- created the fact never actually ran against (`any`, typically).
   -- match_record_key (unlike type_check_index) never adds an error
   -- itself -- it hands nil plus a message back to its caller to
   -- report -- so a base that turns out not to carry this field
   -- after all just answers nil here, same as an unknown variable
   -- would.
   function TypeChecker:fact_base_type(f)
      local typ = self:find_var_type(f.var, "check_only")
      if typ then
         return typ
      end
      local dot = string.find(f.var, ".", 1, true)
      if not dot then
         return nil
      end
      local base = self:find_var_type(string.sub(f.var, 1, dot - 1), "check_only")
      if not base then
         return nil
      end
      local fname = string.sub(f.var, dot + 1)
      return (self:match_record_key(base, f.w, fname))
   end

   -- A write to `x` or to `x.field` drops any narrow recorded for
   -- that field -- do not narrow across an intervening write, the
   -- same rule a bare variable's own fact already follows. `prefix`
   -- is "x." to drop every field of x, or the exact field key itself
   -- to drop only that one.
   function TypeChecker:drop_field_narrows(prefix)
      for i = #self.st, 1, -1 do
         local scope = self.st[i]
         for name in pairs(scope.vars) do
            if name:sub(1, #prefix) == prefix then
               scope.vars[name] = nil
            end
         end
      end
   end

   function TypeChecker:type_check_index(anode, bnode, a, b)
]=====],
  },
  ["narrow-record-field-dot"] = {
    file = "tl.lua",
    note = "teal-language/tl#PENDING: a truthy `x.field` (`if x.field then`, the left operand of `and`) narrows the field, and a prior narrow on it is read back here",
    find = [=====[            if node.op.op == "." then
               node.receiver = ua

               assert(node.e2.kind == "identifier")
               local bnode = node_at(node.e2, {
                  tk = node.e2.tk,
                  kind = "string",
               })
               local btype = a_type(node.e2, "string", { literal = node.e2.tk })
               local t = self:type_check_index(node.e1, bnode, ua, btype)

               if t.needs_compat and self.gen_compat ~= "off" then

                  if node.e1.kind == "variable" and node.e2.kind == "identifier" then
                     local key = node.e1.tk .. "." .. node.e2.tk
                     node.kind = "variable"
                     node.tk = "_tl_" .. node.e1.tk .. "_" .. node.e2.tk
                     self.all_needs_compat[key] = true
                  end
               end

               return t
            end]=====],
    replace = [=====[            if node.op.op == "." then
               node.receiver = ua

               assert(node.e2.kind == "identifier")
               local bnode = node_at(node.e2, {
                  tk = node.e2.tk,
                  kind = "string",
               })
               local btype = a_type(node.e2, "string", { literal = node.e2.tk })
               local t = self:type_check_index(node.e1, bnode, ua, btype)

               -- cosmic carried patch (teal-language/tl#PENDING): a
               -- guard on `x.field` narrows the field's nil union at
               -- reads of `x.field` after the guard, the same as a
               -- plain variable already does -- a truthy read here
               -- (`if x.field then`, the left operand of `and`, which
               -- already marks truthy_read regardless of kind) sets
               -- the fact; `==`/`~=` nil and `assert` set it at their
               -- own call sites, keyed the same way. A prior narrow
               -- recorded for this field is read back here too, so a
               -- chain like `o.sub.x` sees it through `o.sub`'s own
               -- return value.
               local field_key = fact_key(node)
               if field_key then
                  local narrowed = self:find_var_type(field_key, "check_only")
                  if narrowed then
                     t = narrowed
                  end
                  if node.truthy_read or
                     (node.expected and node.expected.typename == "boolean_context") then
                     local typ = without_nil(self, node, t, true)
                     if typ then
                        node.known = IsFact({ var = field_key, typ = typ, w = node })
                     end
                  end
               end

               if t.needs_compat and self.gen_compat ~= "off" then

                  if node.e1.kind == "variable" and node.e2.kind == "identifier" then
                     local key = node.e1.tk .. "." .. node.e2.tk
                     node.kind = "variable"
                     node.tk = "_tl_" .. node.e1.tk .. "_" .. node.e2.tk
                     self.all_needs_compat[key] = true
                  end
               end

               return t
            end]=====],
  },
  ["narrow-record-field-eq-nil"] = {
    file = "tl.lua",
    note = "teal-language/tl#PENDING: `x.field == nil` / `~= nil` is the same exact test narrow-eq-nil gives a bare variable",
    find = [=====[               elseif self:is_a(ub, ua) or ua.typename == "typevar" then
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
    replace = [=====[               elseif self:is_a(ub, ua) or ua.typename == "typevar" then
                  -- cosmic carried patch (whilp/cosmic#942): comparing a
                  -- variable against nil is an exact type test -- __eq
                  -- never fires with a nil operand -- so it carries an
                  -- IsFact, whose negation narrows, instead of an EqFact,
                  -- whose negation is deliberately information-free.
                  -- cosmic carried patch (teal-language/tl#PENDING): the
                  -- same test on `x.field` narrows the field, keyed the
                  -- same way a truthy read on it is -- but only when the
                  -- field's OWN declared type admits nil. A field
                  -- declared with a plain (non-union) type, compared to
                  -- nil anyway as an uninitialized sentinel (a real
                  -- pattern in this tree), must not narrow to bare
                  -- `nil`: the double negation the early-return shape
                  -- feeds this into resolves straight to the positive
                  -- IsFact (bypassing not_facts's subtract, which is
                  -- what protects a bare variable's own nil-union case),
                  -- and a plain type has no nil member to subtract.
                  local e1_key = fact_key(node.e1)
                  if e1_key and not (node.e1.kind == "variable")
                     and not admits_nil(self, node, ua) then
                     e1_key = nil
                  end
                  if e1_key and rb.typename == "nil" then
                     local f = IsFact({ var = e1_key, typ = rb, w = node })
                     node.known = node.op.op == "==" and f or NotFact({ f1 = f, w = node })
                  elseif node.op.op == "==" and e1_key then
                     node.known = EqFact({ var = e1_key, typ = ub, w = node })
                  end
               elseif self:is_a(ua, ub) or ub.typename == "typevar" then
                  local e2_key = fact_key(node.e2)
                  if e2_key and not (node.e2.kind == "variable")
                     and not admits_nil(self, node, ub) then
                     e2_key = nil
                  end
                  if e2_key and ra.typename == "nil" then
                     local f = IsFact({ var = e2_key, typ = ra, w = node })
                     node.known = node.op.op == "==" and f or NotFact({ f1 = f, w = node })
                  elseif node.op.op == "==" and e2_key then
                     node.known = EqFact({ var = e2_key, typ = ua, w = node })
                  end]=====],
  },
  ["narrow-record-field-assert"] = {
    file = "tl.lua",
    note = "teal-language/tl#PENDING: assert(x.field) narrows the field the same way assert(x) narrows a bare variable",
    find = [=====[         local arg1 = node.e2[1]
         if arg1 and arg1.kind == "variable" and not arg1.known and b.tuple[1] then
            local typ = without_nil(self, arg1, b.tuple[1], true)
            if typ then
               arg1.known = IsFact({ var = arg1.tk, typ = typ, w = arg1 })
            end
         end]=====],
    replace = [=====[         local arg1 = node.e2[1]
         -- cosmic carried patch (teal-language/tl#PENDING): the same
         -- narrow when the argument is `x.field` rather than a bare
         -- variable, keyed the same way a truthy read on it is.
         local arg1_key = arg1 and fact_key(arg1)
         if arg1_key and not arg1.known and b.tuple[1] then
            local typ = without_nil(self, arg1, b.tuple[1], true)
            if typ then
               arg1.known = IsFact({ var = arg1_key, typ = typ, w = arg1 })
            end
         end]=====],
  },
  ["narrow-record-field-assignment"] = {
    file = "tl.lua",
    note = "teal-language/tl#PENDING: a write to `x` or `x.field` drops the field's narrow, invalidating it the same way a bare variable's own write already does",
    find = [=====[               local varnode = node.vars[i]
               local varname = varnode.tk
               local valtype = valtypes.tuple[i]
               local rvar, rval, err = self:check_assignment(varnode, vartype, valtype)]=====],
    replace = [=====[               local varnode = node.vars[i]
               local varname = varnode.tk
               -- cosmic carried patch (teal-language/tl#PENDING): do
               -- not narrow a record field across a write to it, or
               -- to the variable it is read off of -- a new value
               -- may not share the old one's fields. `x = ...` drops
               -- every "x.*" field narrow; `x.field = ...` drops just
               -- that one.
               if varname then
                  self:drop_field_narrows(varname .. ".")
               else
                  local field_key = fact_key(varnode)
                  if field_key then
                     self:drop_field_narrows(field_key)
                  end
               end
               local valtype = valtypes.tuple[i]
               local rvar, rval, err = self:check_assignment(varnode, vartype, valtype)]=====],
  },
  ["narrow-record-field-not-facts"] = {
    file = "tl.lua",
    note = "teal-language/tl#PENDING: a field fact's current type falls back to its base variable's declared field type",
    find = [=====[      not_facts = function(self, fs)
         local ret = {}
         for var, f in pairs(fs) do
            local typ = self:find_var_type(f.var, "check_only")

            if not typ then
               ret[var] = EqFact({ var = var, typ = a_type(f.w, "invalid", {}), w = f.w, no_infer = f.no_infer })
            elseif f.fact == "==" then]=====],
    replace = [=====[      not_facts = function(self, fs)
         local ret = {}
         for var, f in pairs(fs) do
            -- cosmic carried patch (teal-language/tl#PENDING): a field
            -- key's current type is not always a var find_var_type
            -- already knows -- see fact_base_type.
            local typ = self:fact_base_type(f)

            if not typ then
               -- cosmic carried patch (teal-language/tl#PENDING): a
               -- field key that cannot be resolved here has moved
               -- past the scope its fact was built in (see
               -- fact_base_type) -- drop it silently instead of
               -- reporting an unresolvable variable, which a genuine
               -- bare-variable miss still does.
               if not string.find(var, ".", 1, true) then
                  ret[var] = EqFact({ var = var, typ = a_type(f.w, "invalid", {}), w = f.w, no_infer = f.no_infer })
               end
            elseif f.fact == "==" then]=====],
  },
  ["narrow-record-field-eval-fact"] = {
    file = "tl.lua",
    note = "teal-language/tl#PENDING: same fallback as narrow-record-field-not-facts, for the positive-fact path",
    find = [=====[      eval_fact = function(self, f)
         if not f then
            return {}
         elseif f.fact == "is" then
            local typ = self:find_var_type(f.var, "check_only")
            if not typ then
               return { [f.var] = invalid_from(f) }
            end]=====],
    replace = [=====[      eval_fact = function(self, f)
         if not f then
            return {}
         elseif f.fact == "is" then
            -- cosmic carried patch (teal-language/tl#PENDING): see
            -- fact_base_type -- a field key's current type is not
            -- always a var find_var_type already knows.
            local typ = self:fact_base_type(f)
            if not typ then
               -- cosmic carried patch (teal-language/tl#PENDING): see
               -- not_facts -- an unresolvable field key drops
               -- silently rather than reporting an unresolvable
               -- variable.
               if string.find(f.var, ".", 1, true) then
                  return {}
               end
               return { [f.var] = invalid_from(f) }
            end]=====],
  },
}
