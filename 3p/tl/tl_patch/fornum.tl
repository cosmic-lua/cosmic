-- The fornum-shadow-* pair: makes generated Lua load under Lua 5.5,
-- whose numeric `for` binds a CONST control variable --
--
--     lua5.5 -e 'for i=1,2 do i=i+1 end'   --> attempt to assign to
--                                              const variable 'i'
--     lua5.4 -e 'for i=1,2 do i=i+1 end'   --> runs fine
--
-- -- while the pinned checker (0.24.8) type-checks `i = i + 1` inside
-- `for i = 1, 3` cleanly and the generator emits it verbatim, so a
-- Teal program that reassigns its numeric-for control variable
-- compiles to Lua that 5.4 runs and 5.5 refuses to load. Generic
-- `for-in` is NOT affected -- 5.5 accepts assignment to its control
-- variables, identically to 5.4 -- so this patch touches `fornum`
-- alone and leaves `forin` untouched.
--
-- The fix: when a numeric-for body assigns its control variable, give
-- the generated loop its own mutable copy by injecting a shadowing
-- `local i = i` as the first statement of the body. The loop header's
-- own binding (5.5's const one) is never assigned again; every read
-- and write in the body resolves to the shadow instead, which is a
-- plain local and free to reassign on both versions. This is
-- semantically inert on 5.4 -- shadowing a value with itself changes
-- no behavior -- and it is exactly what upstream did for `for-in` in
-- teal-language/tl#1058 (a checker fact marks the node, the generator
-- reads it and injects the local); upstream has never needed the
-- numeric-for twin, since nothing before Lua 5.5 made that variable
-- const, so there is no upstream fix to wait on and this patch is
-- carried indefinitely, not in flight.
--
-- Unconditional injection was rejected: a numeric-for loop that never
-- assigns its control variable must generate BYTE-IDENTICAL output to
-- an unpatched compiler, so the shadow is emitted only when the body
-- actually wrote to the variable.
--
-- `fornum-shadow-check` (the checker half) answers the "did it assign"
-- question the generator cannot ask on its own: `TypeChecker:find_var`
-- already flips `has_been_written_to` on the control variable's own
-- entry for every lvalue use inside the body (an assignment to a
-- SHADOWING inner `local i` targets that inner variable instead and
-- never touches this flag, which is correct -- such a body never
-- reassigns the loop's own binding). The fornum scope is still on top
-- of `self.st` when `after` runs (before `end_scope_and_none_type`
-- pops it), so the flag is read there and recorded on the node as
-- `node.fornum_modifies_control_var` for the generator to see --
-- `before_statements` and `after` share the node object as their only
-- channel, the same one `if_widens` and `block_returns` use elsewhere
-- in this same cbs table.
--
-- `fornum-shadow-emit` (the generator half) emits the shadow right
-- after " do" and before the body's own rendered statements -- inside
-- the same `do ... end` block, so it plainly IS the body's first
-- statement, textually and semantically, without needing to splice
-- into the body's own already-rendered child. It is a plain
-- `table.insert` of a literal string, exactly how neighbouring
-- fornum/forin code emits "for", " =", "," and " do" themselves: no
-- source node backs it, so there is no `y`/`h` line-tracking pair to
-- get right and no risk of corrupting the source map that HAS one
-- (the `{ y = node.yend, h = 0, [1] = "end" }` a few lines down is a
-- different case -- that pseudo-node's own `y` positions the `end`
-- keyword on the loop's closing line, which our injected text does
-- not need since it always sits on the same line as "do").
--
-- The mechanism is _make/patch.tl: each entry is an exact `find`
-- string replaced by an exact `replace` string in one unpacked file,
-- and entry names share one namespace across every file in this
-- directory, applied in sorted-name order.
--
-- Carried, not forked: each anchor must match the pinned source exactly
-- once, so a tl pin bump that moves this code fails the fetch loudly
-- until the patch is re-audited (or dropped, once upstream lands it).
--
-- Probing an entry: reverse it with `_make.patch`'s `reverse`, which loads
-- the de-patched copy into `package.loaded`, the table `require` reads
-- before any searcher. A modified copy placed on `package.path` is ignored
-- instead: the binary's own `/zip` searcher outranks the file searcher, so
-- such a probe measures the shipped checker and reports a confident wrong
-- answer with nothing logged. A third form is inert for a third reason:
-- `cosmic --check types` on a file that preloads `tl` never runs that
-- file, so the shipped checker answers at exit 0 with nothing logged —
-- `cosmic --docs guide.checking` lays the three forms side by side.
return {
  ["fornum-shadow-check"] = {
    file = "tl.lua",
    note = "Lua 5.5's const for-control var: record whether fornum's body assigns it",
    find = [=====[            self:add_var(node.var, node.var.tk, a_type(node.var, typename, {}))
         end,
         after = end_scope_and_none_type,
      },]=====],
    replace = [=====[            self:add_var(node.var, node.var.tk, a_type(node.var, typename, {}))
         end,
         -- cosmic carried patch: Lua 5.5 makes the numeric-for control
         -- variable const, so a body that assigns it (legal on 5.4)
         -- fails to load there. `find_var` already flips
         -- `has_been_written_to` on the variable for every lvalue use
         -- in the body; read it here, before `end_scope_and_none_type`
         -- pops the fornum scope that holds it, and hand the fact to
         -- the generator (fornum-shadow-emit) on the node -- the only
         -- channel `before_statements` and `after` share.
         after = function(self, node, children)
            local scope = self.st[#self.st]
            local var = scope.vars[node.var.tk]
            if var and var.has_been_written_to then
               node.fornum_modifies_control_var = true
            end
            return end_scope_and_none_type(self, node, children)
         end,
      },]=====],
  },
  ["fornum-shadow-emit"] = {
    file = "tl.lua",
    note = "Lua 5.5's const for-control var: shadow it when the body reassigns it",
    find = [=====[            table.insert(out, " do")
            add_child(out, children[5], " ")]=====],
    replace = [=====[            table.insert(out, " do")
            -- cosmic carried patch: only when fornum-shadow-check
            -- marked the body as reassigning its control variable --
            -- an unmarked loop emits exactly what stock tl always has,
            -- byte for byte. The shadow is the body's first statement,
            -- inside the same do/end as everything after it; every
            -- read and write in the body resolves to this plain local
            -- instead of the (5.5: const) loop header binding, which
            -- is never assigned again. Inert on 5.4: shadowing a value
            -- with itself changes nothing a running program can see.
            if node.fornum_modifies_control_var then
               table.insert(out, " local " .. node.var.tk .. " = " .. node.var.tk .. ";")
            end
            add_child(out, children[5], " ")]=====],
  },
}
