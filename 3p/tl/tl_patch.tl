-- The carried patch riding 3p/tl/tl_pin.tl (see _make/patch.tl for the
-- mechanism). Three edits teach the checker that a plain variable's nil
-- union narrows through the guards Lua programmers actually write:
--
-- - narrow-truthiness: `if r then` / `if not r then return end`. Lua
--   has no falsy tables, so for a union of nil with non-boolean
--   members, truthy means exactly "r is not nil" — the edit stamps the
--   same IsFact the fact machinery already uses for `is` guards. Unions
--   containing boolean/any/unknown are skipped: `false` is
--   truthy-unsafe.
-- - narrow-assert: `assert(x)` applies the same fact — assert already
--   forwards its argument's facts to the following statements; the
--   edit gives a bare variable argument one.
-- - narrow-eq-nil: `x == nil` / `x ~= nil` is an exact type test
--   (`__eq` never fires with a nil operand), so it carries an IsFact —
--   whose negation narrows — instead of an EqFact, whose negation is
--   deliberately information-free. Sound for boolean unions too, which
--   truthiness cannot narrow.
--
-- Carried, not forked: each anchor must match the pinned tl.lua exactly
-- once, so a tl pin bump that moves this code fails the fetch loudly
-- until the patch is re-audited (or dropped, once upstream lands it).
return {
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
         -- variable read. Same union rules as the boolean-context edit:
         -- unions containing boolean/any/unknown are skipped.
         local arg1 = node.e2[1]
         if arg1 and arg1.kind == "variable" and not arg1.known and b.tuple[1] then
            local rt = b.tuple[1]
            if rt.typename == "nominal" then
               rt = self:resolve_nominal(rt)
            end
            if rt.typename == "union" then
               local has_nil, safe, members = false, true, {}
               for _, m in ipairs(rt.types) do
                  local rm = m
                  if rm.typename == "nominal" then
                     rm = self:resolve_nominal(rm)
                  end
                  if rm.typename == "nil" then
                     has_nil = true
                  else
                     if rm.typename == "boolean" or rm.typename == "any" or
                        rm.typename == "unknown" or rm.typename == "boolean_context" then
                        safe = false
                     end
                     table.insert(members, m)
                  end
               end
               if has_nil and safe and #members > 0 then
                  local typ = #members == 1 and members[1] or unite(arg1, members)
                  arg1.known = IsFact({ var = arg1.tk, typ = typ, w = arg1 })
               end
            end
         end
         self:apply_facts(node, node.e2[1].known)
         return r
      end,]=====],
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
            -- read in boolean context carries a truthiness fact. Lua has
            -- no falsy tables, so for a union of nil with non-boolean
            -- members, truthy exactly means "not nil": the positive
            -- branch narrows to the members, and the negated
            -- early-return shape narrows below the guard. Unions
            -- containing boolean (or any/unknown) are skipped -- false
            -- is truthy-unsafe.
            do
               local rt = t
               if rt.typename == "nominal" then
                  rt = self:resolve_nominal(rt)
               end
               if node.expected and node.expected.typename == "boolean_context" and
                  rt.typename == "union" then
                  local has_nil, safe, members = false, true, {}
                  for _, m in ipairs(rt.types) do
                     local rm = m
                     if rm.typename == "nominal" then
                        rm = self:resolve_nominal(rm)
                     end
                     if rm.typename == "nil" then
                        has_nil = true
                     else
                        if rm.typename == "boolean" or rm.typename == "any" or
                           rm.typename == "unknown" or rm.typename == "boolean_context" then
                           safe = false
                        end
                        table.insert(members, m)
                     end
                  end
                  if has_nil and safe and #members > 0 then
                     local typ = #members == 1 and members[1] or unite(node, members)
                     node.known = IsFact({ var = node.tk, typ = typ, w = node })
                  end
               end
            end

            return t]=====],
  },
}
