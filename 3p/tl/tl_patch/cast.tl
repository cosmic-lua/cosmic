-- The cast-legality group of the carried tl patch: a prototype rule
-- for `x as T`, gated off by default. It is not enabled for this tree
-- -- see docs/dev/explanation/cast-legality.md for the census it produced and
-- what enabling it would cost.
--
-- Stock tl's `as` performs no relation check at all: it discards the
-- operand's static type and returns the target type unconditionally,
-- so `"hi" as integer` and a cast between two unrelated records both
-- type-check clean. The prototype rule: `x as T` is legal only when
-- x's static type is one the checker cannot see into -- `any`, a
-- userdata record (declared `is userdata` in a `.d.tl` or elsewhere),
-- or a type variable bound by the enclosing generic. Every other cast
-- either asserts a relation the checker could instead verify, or
-- contradicts one it already knows, so it is refused. Both halves are
-- improvements over the status quo, not a tightening of an existing
-- check -- nothing here is refused today.
--
-- Gated behind the COSMIC_CAST_LEGALITY=1 environment variable, read
-- once per cast at check time, so an ungated `--make ci` (and every
-- ordinary type check) is byte-for-byte unaffected. Set it before
-- invoking the checker to see the rule's refusals; the Method section
-- of docs/dev/explanation/cast-legality.md has the exact command that built the
-- census from them.
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
-- `cosmic --docs howto.narrow-nil` lays the three forms side by side.
return {
  ["cast-legality"] = {
    file = "tl.lua",
    note = "prototype: `as` legal only from an opaque operand type; gated, not enabled",
    find = [=====[            elseif node.op.op == "as" then
               local ok, err = ensure_not_abstract(ra)
               if not ok then
                  return self.errs:invalid_at(node.e1, err)
               end
               return gb
]=====],
    replace = [=====[            elseif node.op.op == "as" then
               local ok, err = ensure_not_abstract(ra)
               if not ok then
                  return self.errs:invalid_at(node.e1, err)
               end
               -- cosmic carried patch (cast-legality prototype, gated
               -- off by default -- see docs/dev/explanation/cast-legality.md):
               -- `x as T` is legal only when x's static type is one
               -- the checker cannot see into. Everything else is
               -- either a redundant cast (the operand already relates
               -- to the target) or an outright lie (it does not), and
               -- both are accepted silently by stock tl.
               if os.getenv("COSMIC_CAST_LEGALITY") == "1" then
                  local opaque = ra.typename == "any"
                  or ua.typename == "typevar"
                  or (ra.typename == "record" and ra.is_userdata)
                  if not opaque then
                     -- node's own y/x is the `as` token's position (set at
                     -- parse time, tl.lua's parse_expression), the same
                     -- line _cli.lint.cast_lines and cast-sites.tsv key on
                     -- -- reporting here instead of node.e1 keeps the
                     -- census joinable by (file, line) with no drift.
                     return self.errs:invalid_at(node,
                     "cast-legality: 'as' operand is %s, a type the checker " ..
                     "can see into -- only 'any', a userdata record, or a " ..
                     "generic type variable may be cast", ra)
                  end
               end
               return gb
]=====],
  },
}
