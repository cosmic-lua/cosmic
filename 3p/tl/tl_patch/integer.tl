-- The integer-strict group of the carried tl patch: a prototype rule
-- for a `number`-declared local, gated off by default. It is not
-- enabled for this tree, and this entry covers only the
-- narrowed_declaration laundering handled below -- a tree-wide census
-- of every other place a number-declared value can reach an
-- integer-typed slot unchecked is separate, larger work this patch
-- does not attempt.
--
-- Stock tl's `narrowed_declaration` re-narrows a local's flow-tracked
-- type to its initializer's inferred type whenever that is narrower
-- than the declared one, so `local n: number = 3` tracks `n` as
-- `integer` (from the literal `3`), not as the declared `number` --
-- before any `integer`-slot comparison ever sees it. That laundering
-- is what let `local j: integer = n` and `take(n)` (an
-- `integer`-parameter call) pass unchecked: by the time either use
-- runs its `is_a(number, integer)` check, the operand has already
-- been relabelled `integer`. This entry skips the re-narrowing for
-- exactly that one case -- a `number`-declared local whose narrowed
-- type is `integer` -- so the operand reaches every downstream use
-- honestly, at its declared width, and stock `is_a` already refuses
-- `number` where `integer` is required. No new comparison rule or
-- error message is needed.
--
-- Gated behind the COSMIC_INTEGER_STRICT=1 environment variable, read
-- once per local declaration at check time, so an ungated `--make ci`
-- (and every ordinary type check) is byte-for-byte unaffected.
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
-- file, so the shipped checker answers at exit 0 with nothing logged --
-- `cosmic --docs guide.checking` lays the three forms side by side.
return {
  ["integer-strict-declaration"] = {
    file = "tl.lua",
    note = "prototype: a number-declared local's width survives an integer-literal initializer; gated, not enabled",
    find = [=====[                     t = self:infer_at(w, infertype)
                     self:add_var(w, var.tk, t, "const", "narrowed_declaration")
                  end
               end]=====],
    replace = [=====[                     -- cosmic carried patch (prototype: gated,
                     -- not enabled -- see 3p/tl/tl_patch/cast.tl for the
                     -- sibling pattern): a `number`-declared local's
                     -- DECLARED width must not be erasable just because
                     -- its current initializer happens to be an integer
                     -- literal -- that is what let `local n: number = 3;
                     -- local j: integer = n` and `take(n)` (an
                     -- `integer`-parameter call) pass unchecked. Skipping
                     -- narrowed_declaration's add_var call here leaves n
                     -- tracked at its DECLARED type, so every downstream
                     -- use hits stock is_a(number, integer) honestly --
                     -- no new comparison rule needed.
                     local declared_t = t
                     t = self:infer_at(w, infertype)
                     if not (os.getenv("COSMIC_INTEGER_STRICT") == "1" and
                        declared_t.typename == "number" and t.typename == "integer") then
                        self:add_var(w, var.tk, t, "const", "narrowed_declaration")
                     end
                  end
               end]=====],
  },
}
