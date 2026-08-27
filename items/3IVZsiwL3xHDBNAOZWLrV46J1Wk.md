## Goal

G3 — an honest type layer, no escape hatches (parent `3HyRcW05`). The
closure-carry patch traded a soundness win for a regression in the code
AROUND an anonymous closure: defining a lambda now widens, in the
ENCLOSING continuation, every narrow on a name assigned anywhere in the
file. Keep the win, give the continuation back what stock tl gave it.

## Problem, measured

Measured 2026-08-27 against tl pin `v0.24.8`
(`3p/tl/tl_pin.tl`, sha `8d7a143f…f022`) and `bin/cosmic.pin`
`2026-08-27-555873e`.

**The regression.** `/tmp/probe.tl`:

```
local function pick(): string | integer
  return "x"
end
local v = pick()
v = pick()
if not (v is string) then return end
local cb = function(): integer return 1 end
print(cb())
print(v:upper())
```

The assignment precedes the guard, so the narrow at `v:upper()` is
sound, and `cb` neither reads nor assigns `v`.

    $ o/bootstrap/cosmic --check types /tmp/probe.tl
    /tmp/probe.tl:9:9: error: cannot index key 'upper' in variable 'v' of type string | integer
    $ o/bin/cosmic --check types /tmp/probe.tl
    /tmp/probe.tl:9:9: error: cannot index key 'upper' in variable 'v' of type string | integer

Both reject: the pinned release already carries these entries, so the
pinned/tree pair does not isolate the regression. The pair that does is
stock-vs-patched at the tl.lua level. Reproduced by extracting the
pristine `tl.lua` from the digest-verified archive
(`tar xzf o/3p/tl/v0.24.8.tar.gz --strip-components=1 tl-0.24.8/tl.lua`),
applying each patch file's `tl.lua` entries to it with a 20-line
`gsub` driver, and type-checking through `tl.check_string` under
`o/3p/cosmos/lua`:

| checker                                          | probe |
|--------------------------------------------------|-------|
| pristine `tl.lua`                                 | CLEAN |
| pristine + `narrow.tl` + `ast_cache.tl` (20 entries) | CLEAN |
| pristine + all three patch files (30 entries)     | error: `cannot index key 'upper' in variable 'v' of type string \| integer` |

So it is a REGRESSION the `closure-*` group introduced, not a stock
behaviour and not a consequence of the narrowing patch.

**Two sites regress, not seven.** The item was filed naming all seven
function-boundary entries. Measured: five of them called stock
`self:widen_all_unions()` with NO node, which widens every narrow in
every scope — so under stock the enclosing continuation already lost
its narrows there, and the patched form is strictly MORE permissive.
Only `["function"]` and `["macroexp"]` passed their own node in stock.
The same guard-then-closure-then-use shape, one closure form per file,
checked as above:

| closure form (the statement between the guard and the use) | stock | tree |
|---|---|---|
| `local cb = function(): integer return 1 end` | CLEAN | error |
| `f: function(): integer = macroexp(): integer return 1 end` in a record body | CLEAN | error |
| `cb = function(): integer return 1 end` (assignment rvalue) | error | error |
| `local function lf(): integer return 1 end` | error | error |
| `global function gf(): integer return 1 end` | error | error |
| `function R.f(): integer return 1 end` | error | error |
| `local macroexp lm(): integer return 1 end` | error | error |

`closure-fn-rvalue`, `closure-global-function`, `closure-local-function`,
`closure-local-macroexp` and `closure-record-function` are therefore NOT
regressions and are out of scope — which also dissolves decision 1 of
the previous Enablement note, since `closure-fn-rvalue` (the inline site
with no `after` hook) is exactly one of the five.

**The tree's extra strictness is incidental, not a soundness rule.**
The same hazard one line away is accepted by the tree today. Two files,
same indirect assignment, differing only in whether a lambda sits
between the guard and the call:

```
local v = pick()
local function setter() v = 2 end
if not (v is string) then return end
setter()                       -- i: no lambda
print(v:upper())
```
```
local v = pick()
local function setter() v = 2 end
if not (v is string) then return end
local cb = function() setter() end
cb()                           -- j: a lambda in between
print(v:upper())
```

| source | stock | tree |
|---|---|---|
| i (no lambda) | CLEAN | CLEAN |
| j (lambda in between) | CLEAN | error |

Both are unsound at runtime and the checker catches neither in general;
the lambda boundary just happens to widen in case j. Removing that
accident closes no hole the tree otherwise closes.

## Change

Two files. The checker change is patch DATA only.

### 1. `3p/tl/tl_patch/closure.tl`

Measured: `wc -l < 3p/tl/tl_patch/closure.tl` is 207 on `origin/main`
(293 lines of headroom under the 500-line cap) and
`grep -c '^  \["closure-' 3p/tl/tl_patch/closure.tl` is 10. This adds
about 95 lines and three entries, to roughly 300 lines and 13 entries.

The boundary answers two questions with one scan, and they want
different scopes:

- what the closure BODY may rely on — the closure runs at an unknown
  later time, so the scan scope is the CHUNK ROOT. Unchanged.
- what the enclosing CONTINUATION after the definition may rely on —
  straight-line code, so only an assignment inside the closure's OWN
  body can invalidate a narrow there. This is what stock did at the two
  anonymous sites and what the patch dropped.

Both are served by widening against the chunk root for the body and
restoring, after the closure's subtree is checked, the narrows an
own-body scan would have kept.

**Where the restore is written.** Every mutation `widen_all_unions`
makes lands on ONE scope table: `widen_in_scope(n, var)`
(`o/3p/tl/tl.lua`, `function TypeChecker:widen_in_scope`) edits
`self.st[n]` in place only when `n == #self.st`, and for `n ~= top`
calls `self:add_var(nil, var, t, nil, "widen")`, whose first act is
`local scope = self.st[#self.st]`. So one snapshot of that scope's
per-name state covers all three of its exits — restore-in-place,
delete, and the non-top widen shadow — and the snapshot holds the scope
TABLE, not its index, because the stack has moved by the time the
restore runs.

Add one entry, `closure-continuation-carry`, whose `find` is the single
line

    "   function TypeChecker:add_global(node, varname, valtype, is_assigning)"

and whose `replace` is a comment plus these two methods, verbatim,
followed by that same line:

```lua
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
```

Rewrite the `replace` of the two existing anonymous entries (their
`find` anchors do not move) so the widen call becomes

    node.carried_narrows = self:widen_for_closure(node)

in `closure-anon-function` and in `closure-anon-macroexp`, each keeping
one `-- cosmic carried patch:` comment saying the body widens against
the chunk root while the continuation keeps what the body cannot
invalidate.

Add two entries hanging the restore on the `after` hook both sites
already have. `closure-restore-function` anchors on

```
            self:end_function_scope(node)

            return wrap_generic_if_typeargs(node.typeargs, a_function(node, {
               min_arity = self.feat_arity and node.min_arity or 0,
               args = args,
               rets = self.get_rets(rets),
            }))
```

and `closure-restore-macroexp` on the same block with no blank line
after `end_function_scope` and `rets = rets,` in place of
`rets = self.get_rets(rets),`. Each inserts, directly after
`self:end_function_scope(node)`, a `-- cosmic carried patch:` comment
and

```lua
            self:restore_carried_narrows(node.carried_narrows)
            node.carried_narrows = nil
```

All five anchors were counted as fixed substrings over the pristine
`tl.lua`: each occurs exactly once, and no two overlap, so the
sorted-name application order is immaterial.

Amend the file header comment: the paragraph that today explains the
chunk-root scan gains the body-versus-continuation split, and says that
the five named-function sites keep the widen-everything continuation
behaviour stock had, because only the two anonymous sites regressed.

### 2. `cosmic/teal_closure_test.tl`

Measured: `wc -l < cosmic/teal_closure_test.tl` is 256 on `origin/main`
(244 lines of headroom) with 10 `test_*` functions. Add five, in the
file's existing style — the `checks` helper, a comment above each, and
the call on the line after its `end`; about 110 lines, to roughly 366.

Each source is the guard-then-closure-then-use shape above. The five,
with the verdict each asserts:

1. `test_a_lambda_does_not_widen_the_enclosing_continuation` — the
   probe source. Asserts clean. Fails without the change.
2. `test_a_record_macroexp_does_not_widen_the_continuation` — the same
   with `f: function(): integer = macroexp(): integer return 1 end` in
   a record body. Asserts clean. Fails without the change.
3. `test_a_lambda_that_assigns_still_widens_the_continuation` — body
   `local cb = function() v = pick() end`. Asserts an error: the
   own-body scan still widens.
4. `test_an_escaped_lambda_child_does_not_keep_an_upvalue_narrow` — the
   anonymous twin of the existing
   `test_an_escaped_child_does_not_keep_an_upvalue_narrow` (`local child
   = function(): string return v end` inside an anonymous parent, the
   child returned, `v = 2` after). Asserts an error. This is the test
   that exercises the CHANGED site with the soundness shape the named
   version pins at an unchanged one.
5. `test_a_named_function_still_widens_the_continuation` — body `local
   function lf(): integer return 1 end`. Asserts an error, pinning that
   the five non-anonymous sites are untouched.

## Non-goals

Do not touch the five non-regressing boundary entries —
`closure-fn-rvalue`, `closure-global-function`, `closure-local-function`,
`closure-local-macroexp`, `closure-record-function`. Their stock form
widened the continuation too; making them keep narrows would be a new
behaviour beyond stock, not a regression fix, and it belongs to its own
item.

Do not touch `closure-assigned-scan`, `closure-global-widen` or
`closure-root`: they are not boundary sites. In particular scope 1 stays
always-assigned inside `widen_all_unions` — a global's narrow still
drops for every closure BODY and at every loop site, which is what
`3IVL3BLT` (PR #1467) bought and `3IVQJa0b` (PR #1473) describes.

Do not touch the `["label"]` site — a narrow at a label must hold for
every goto path.

Do not change what a closure BODY sees. The chunk-root scan and the
rejected nearest-enclosing-body scope both stay as they are.

Do not memoize `assigned_anywhere` and do not restructure its scan for
speed. Measured and refuted 2026-08-27: 2925 calls costing 1.11 s of a
27.0 s `tl.process` run over 60 modules (4.1%); a per-`(root, name)`
memo recovers 1.3 percentage points and a one-pass assigned-names set
2.3, against a ±2 s run-to-run spread. Re-measure before reopening it.

Do not drop any `-- cast:` or `check.must` in the tree that the
regression forced. A source that only type-checks under the new rule
stages behind a release and a `bin/cosmic.pin` bump (see Enablement);
it must not land in this PR.

No new decision record. D21 already prices a carried patch as debt with
a re-audit at every pin bump, and the rule this change states lives in
`closure.tl`'s header comment, which is the place `skills/decide` sends
a rule a comment can carry.

## Acceptance

Run from the repo root.

- `bin/cosmic --make fetch` succeeds; every entry's `find` still matches
  exactly once. (`fetch.repair` in `_make/fetch.tl` re-applies patches
  from the on-disk archive with no network, so `bin/cosmic --make build`
  also re-derives `o/3p/tl/tl.lua` in a fenced run.)
- The derived file, never the patch data, carries the change. After a
  build, each of these prints the stated number, where the second
  column is what the same command prints on `origin/main` today:

  | command (`… o/3p/tl/tl.lua`) | after | today |
  |---|---|---|
  | `grep -c 'function TypeChecker:widen_for_closure'` | 1 | 0 |
  | `grep -c 'function TypeChecker:restore_carried_narrows'` | 1 | 0 |
  | `grep -cF 'self:restore_carried_narrows(node.carried_narrows)'` | 2 | 0 |
  | `grep -cF 'node.carried_narrows = self:widen_for_closure(node)'` | 2 | 0 |
  | `grep -c 'cosmic carried patch'` | 27 | 23 |

  and `grep -c '^  \["closure-' 3p/tl/tl_patch/closure.tl` is 13 (10
  today).
- **The reverse-apply proof, as a pinned-versus-tree pair.** The pinned
  release predates these entries, so it IS the without-the-patch
  checker. Write the probe of "Problem, measured" to `/tmp/probe.tl` and
  run both binaries:

      o/bootstrap/cosmic --check types /tmp/probe.tl   # still the error above
      o/bin/cosmic --check types /tmp/probe.tl         # Type check passed: /tmp/probe.tl

  The same pair on the source of test 2 must flip the same way, and on
  the sources of tests 3, 4 and 5 must report the error under BOTH — a
  test that passes under the pinned binary as well proves nothing about
  the entries and is a soundness net, not evidence.
- `bin/cosmic --make test cosmic/teal_closure_test.tl` passes, all 15
  tests, ending `all closure carry tests passed`. The 10 tests already
  there keep their assertions unchanged.
- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _build/coldbuild_test.tl` passes.
- `git diff origin/main...HEAD --name-only` (THREE-dot; the two-dot form
  is a known recurring defect, `3IVHIoAx`) lists exactly
  `3p/tl/tl_patch/closure.tl` and `cosmic/teal_closure_test.tl`.

## Enablement

None needed for the three decisions the previous pass left open: all
three are settled above from the tree, by prototyping the exact entry
set against the pristine `tl.lua` and re-running every pinned source.

1. **Where each site hangs the restore** — only two sites regress, and
   both `["function"]` and `["macroexp"]` already have an `after` hook
   that calls `self:end_function_scope(node)`. `closure-fn-rvalue`, the
   inline site with no hook, is out of scope because it is not a
   regression.
2. **The exact restore operation** — one scope table takes every
   mutation, so the snapshot is `vars[name]` (the record reference plus
   `t`, `specialized_from`, `is_specialized`, because the top-scope exit
   mutates the record in place), `narrows[name]` and `widens[name]`.
   That covers all three exits.
3. **Intermediate-scope upvalue narrows** — they restore the same way,
   and `test_an_escaped_child_does_not_keep_an_upvalue_narrow` does not
   forbid it: that test is about what the closure BODY sees, and the
   restore only reaches the continuation. Measured on the anonymous twin
   of that test, which is the variant that reaches a changed site: it
   stays an error under the prototype, while the continuation INSIDE the
   same parent, after the child definition, goes clean — matching stock.

**Verified, not predicted.** The five entries above were built against
the pristine `tl.lua` and run over 32 probe sources: the 10 sources of
`cosmic/teal_closure_test.tl` keep every verdict they have today, the
three regression shapes flip to clean, and no soundness shape flips. The
whole tree is unaffected: `tl.check_string` over all 480 `.tl` files
under `cosmic _cli _make _tool _build _docs _types cmd`, comparing the
tree's derived checker against the prototype, produced byte-identical
diagnostics (769 diagnostics, 0 differing lines).

**Landing order.** `3IVQJa0b` (PR #1473, in `check`) edits the same
header paragraph of `3p/tl/tl_patch/closure.tl` and appends to
`cosmic/teal_closure_test.tl`, and its new header sentence says a
global's narrow drops "at loop entry as well as at a function boundary
— the same soundness argument", which this change qualifies for the two
anonymous sites' continuation. Land #1473 first and write this header
amendment on top of it; mirrored in `blocked_by`.

**Cold-build rule.** A patch DATA change: `o/3p/tl/tl.lua` is re-derived
by any graph verb, but generation 1 still compiles the whole tree with
the PINNED checker. The change only ACCEPTS more than today — proved by
the 480-file sweep — so no tree source can start failing generation 1
and no pin bump is needed. What must not land in the same PR is any tree
source that only type-checks under the new rule.
