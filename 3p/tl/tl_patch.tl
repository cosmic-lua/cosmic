-- The carried patch riding 3p/tl/tl_pin.tl (see _make/patch.tl for the
-- mechanism). One edit: teach the checker that truthiness narrows a
-- union of nil with non-boolean members. Lua has no falsy tables, so
-- for `local r: Rec | nil`, `if r then` (and the early-return shape
-- `if not r then return end`) means exactly "r is not nil" — the fact
-- machinery already narrows `is` guards this way; the edit stamps the
-- same IsFact on a plain variable read in boolean context. Unions
-- containing boolean/any/unknown are skipped: `false` is truthy-unsafe.
-- Carried, not forked: the anchor must match the pinned tl.lua exactly
-- once, so a tl pin bump that moves this code fails the fetch loudly
-- until the patch is re-audited (or dropped, once upstream lands it).
return {
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
