-- The unary-minus-double-dash half of the carried tl patch: `tl.generate`'s
-- arity==1 emission branch renders unary `-` tight against its operand
-- (`tight_op[1]["-"]`), with no separating space. When the operand is
-- itself a nested unary `-` node -- `- - -1`, three levels deep -- its
-- own rendered text already starts with `-`, so the two concatenate
-- into `--` with nothing between them. `--` is not two unary-minus
-- tokens: it starts a Lua line comment, so `local d = - - -1` compiles
-- to `local d = ---1`, which discards the rest of the line and
-- evaluates to `nil` instead of `1`. `~` and `#` share `tight_op[1]`
-- but doubling either one lexes back to two separate tokens with no
-- meaning change; `-` is the only member of that table whose doubled
-- form is a DIFFERENT token, which is what makes this case dangerous
-- rather than merely cosmetic.
--
-- `unary-minus-leading-dash-helper` adds `starts_with_dash`, a small
-- walker over an `out`-shaped fragment table (measured at patch time
-- for `- - -1`: each nesting level's own `out` places its operator
-- string at index 1, so a chain of nested unary-minus nodes reads as
-- `{"-", {"-", {"1"}}}` -- walking to the first actual string avoids
-- assuming any fixed nesting depth, the same pattern `concat_output`
-- already uses for this table shape). `unary-minus-space-before-nested-dash`
-- calls it from the arity==1 branch: when the operator is `-` and the
-- child's rendered text would otherwise begin with `-`, the emission
-- forces a separating space, so `- - -1` renders as three distinct
-- unary minus tokens instead of `---1` (a comment). Every other unary
-- `-` -- a literal, a name, a call, at most one level deep -- is
-- unaffected: its operand's rendered text starts with something other
-- than `-`, so `space` stays `""` and cosmic's compiled output is
-- byte-identical to stock tl for the common case.
--
-- The mechanism is _make/patch.tl: each entry is an exact `find`
-- string replaced by an exact `replace` string in one unpacked file,
-- and entry names share one namespace across every file in this
-- directory, applied in sorted-name order.
--
-- Carried, not forked: each anchor must match the pinned source exactly
-- once, so a tl pin bump that moves this code fails the fetch loudly
-- until the patch is re-audited (or dropped, once upstream lands it).
-- Filing this upstream (teal-language/tl) is welcome whenever someone
-- with the access and the time does it, per D21's amendment; it is not
-- a precondition to landing this patch.
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
  ["unary-minus-leading-dash-helper"] = {
    file = "tl.lua",
    note = "no upstream issue filed yet (D21: not a landing gate); helper for unary-minus-space-before-nested-dash",
    find = [=====[      table.insert(out, child)
      out.h = out.h + child.h
   end

   local function concat_output(out)]=====],
    replace = [=====[      table.insert(out, child)
      out.h = out.h + child.h
   end

   -- cosmic carried patch (unary-minus-double-dash): does this
   -- out-shaped fragment table RENDER starting with "-"? Walks to the
   -- first actual string fragment rather than assuming a fixed
   -- nesting depth, since a chain of nested unary-minus nodes nests
   -- one "out" table per level (measured at patch time for "- - -1").
   local function starts_with_dash(t)
      for i = 1, #t do
         local v = t[i]
         if type(v) == "string" then
            if #v > 0 then
               return v:sub(1, 1) == "-"
            end
         else
            if starts_with_dash(v) then
               return true
            end
         end
      end
      return false
   end

   local function concat_output(out)]=====],
  },
  ["unary-minus-space-before-nested-dash"] = {
    file = "tl.lua",
    note = "no upstream issue filed yet (D21: not a landing gate); two nested unary '-' render as '--', which lexes as a Lua comment and corrupts the output",
    find = [=====[               if node.op.arity == 1 then
                  table.insert(out, node.op.op)
                  add_child(out, children[1], space, indent)]=====],
    replace = [=====[               if node.op.arity == 1 then
                  -- cosmic carried patch (unary-minus-double-dash): a
                  -- nested unary-minus operand renders its own leading
                  -- "-", which would otherwise concatenate with this
                  -- node's "-" into "--" -- a Lua line comment, not
                  -- two unary minus tokens. Force the separating space
                  -- tight_op[1] normally omits, exactly when that
                  -- collision would occur.
                  if node.op.op == "-" and starts_with_dash(children[1]) then
                     space = " "
                  end
                  table.insert(out, node.op.op)
                  add_child(out, children[1], space, indent)]=====],
  },
}
