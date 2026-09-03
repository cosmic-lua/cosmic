## Evidence

Re-run 2026-09-03 against `origin/main` (`96afd807`):

    git show origin/main:docs/design/cast-sites.tsv | awk -F'\t' '$3=="record union after guard"{print $1":"$2}'
    _make/generate.tl:99
    _make/stage.tl:183
    _perf/bench/micro_bench.tl:192
    cosmic/check.tl:298
    cosmic/quicksand/box/run.tl:254
    cosmic/quicksand/proxy.tl:141

The tsv's sixth row (`cosmic/quicksand/proxy.tl:141`) is OUT of scope:
the outcome's Evidence section lists only the first 5 for this class
and states `cosmic/quicksand/proxy.tl:141` "closes with respec 6sv6" —
that site belongs to `6sv6_jVN5` ("cosmopolitan: the 10 function-shape
casts are overloaded bindings — split the annotations in
definitions.lua"), not here.

The 5 in scope:

    _make/generate.tl:99
      local it = (into as fs.Stat):modify_time() -- cast: same
    _make/stage.tl:183
      local sel = v.select as Selection -- cast: a graph verb always has one
    _perf/bench/micro_bench.tl:192
      return (a as ip.Addr):format()
    cosmic/check.tl:298
      local status = (wr as proc.WaitResult).status -- cast: record union after guard
    cosmic/quicksand/box/run.tl:254
      local handle = h as proxy.ProxyHandle -- cast: record union after guard (die)

`_build/casts_baseline.tl` rows this lowers (each of these 5 files'
ENTIRE count is this one cast — all five drop to 0, once the sites
close):

    grep -F -e '"_make/generate.tl"' -e '"_make/stage.tl"' -e '"_perf/bench/micro_bench.tl"' \
      -e '"cosmic/check.tl"' -e '"cosmic/quicksand/box/run.tl"' _build/casts_baseline.tl
    ["_make/generate.tl"] = 1,
    ["_make/stage.tl"] = 1,
    ["_perf/bench/micro_bench.tl"] = 1,
    ["cosmic/check.tl"] = 3,
    ["cosmic/quicksand/box/run.tl"] = 1,

(`cosmic/check.tl` carries 3 casts total; only line 298 is this class —
it goes 3→2, not to 0.)

**The gap is a checker gap, already documented and already carrying its
own negative canary.** `docs/design/casts.md`'s "record union after
guard" section: "a guard on `v.select` narrows nothing, and the
documented workaround is to copy the field to a local... it lands in
tl." `cosmic/teal_test.tl:156-179` (`test_hint_index_through_nil_union`)
is that exact case, committed as a standing regression test asserting
the CURRENT (missing) behavior:

    local record Inner
      x: integer
    end
    local record Outer
      sub: Inner | nil
    end
    local function use(o: Outer): integer
      if o.sub then
        return o.sub.x    -- still "cannot index ... | nil" today
      end
      return 0
    end

    assert(msg:find("cannot index", 1, true) and msg:find("| nil", 1, true), ...)
    assert(hint:find("do not narrow", 1, true), ...)

That test is this change's canary: once record-field narrowing lands,
`o.sub.x` inside `if o.sub then` no longer errors, so this test's own
assertions flip from "still errors, with this hint" to "checks clean."

## Change

**This item writes and lands the checker patch only. It does NOT
delete any of the 5 casts above** — see Non-goals; the cold-build rule
(CLAUDE.md) is why.

1. **Fetch and locate the anchor.** `bin/cosmic --make fetch` unpacks
   the pinned tl source to `o/3p/tl/tl.tl`. Find the checker's guard/is
   narrowing machinery — the same code the existing `narrow-eq-nil`,
   `narrow-truthiness` and `narrow-or-guard` entries in
   `3p/tl/tl_patch/narrow.tl` already touch (read those three for the
   `IsFact`/guard-fact shape tl already tracks per-variable) — and the
   place a guard's fact is keyed, today, by bare variable name.

2. **Write a new `3p/tl/tl_patch/narrow.tl` entry**, in the same
   `find`/`replace`/`note` shape as every entry in that file (worked
   example, `narrow-and-operand`, `3p/tl/tl_patch/narrow.tl:28-32`):

   ```teal
   ["narrow-record-field"] = {
     file = "tl.lua",
     note = "<upstream issue ref>: a guard on `x.field` narrows the field's nil union at the use, invalidated by any assignment to `x.field` or to `x`",
     find = [=====[<exact tl.lua snippet, from the fetched o/3p/tl/tl.tl>]=====],
     replace = [=====[<the same snippet plus the cosmic carried-patch comment and the fix>]=====],
   },
   ```

   The fact to add: a guard on `x.field` (`if x.field then`,
   `assert(x.field)`, `x.field == nil`/`~= nil`, the same shapes
   `narrow-truthiness`/`narrow-eq-nil`/`narrow-assert` already cover for
   bare variables) narrows `x.field`'s nil union at reads of `x.field`
   after the guard, within the same scope those entries already narrow
   in. Invalidation: any assignment to `x.field` (or to `x` itself)
   drops the fact, the same rule a bare variable's fact already follows
   — do not narrow across an intervening write. `find` must match the
   pinned `o/3p/tl/tl.tl` EXACTLY once (D21's exactness rule); if it
   does not, the anchor moved or the mechanism needs a different hook —
   report that rather than force a near-match.

3. **Flip the canary.** `cosmic/teal_test.tl:159-179`
   (`test_hint_index_through_nil_union`) currently asserts the un-narrowed
   error. Once the patch narrows `o.sub.x`, rewrite this test to the
   `test_narrowing_canary` shape just above it (line 73): assert
   `result.ok` and that the snippet's `return o.sub.x` typechecks
   clean, with a comment naming this as the record-field-narrowing
   canary (replacing `test_hint_index_through_nil_union`, which no
   longer produces an error to hint about — if a *different* record-field
   nil-union pattern still fails to narrow, keep a trimmed version of
   this test for that residual case instead of deleting it outright).

4. **Open the upstream issue.** Per D21's maturity clause ("each
   carried patch is debt with a written-down maturity date: it must be
   submitted upstream"): open an issue against `teal-language/tl`
   describing the gap (guard-on-a-record-field does not narrow the
   field), referencing `docs/design/casts.md`'s "record union after
   guard" section and the 5 sites above as motivating cases. Record its
   number in the patch entry's `note` field, matching this file's
   existing convention (`whilp/cosmic#942`, `whilp/cosmic#1065`) or the
   direct-upstream-reference convention used in
   `3p/tl/tl_patch/for_control_var.tl` ("Upstream teal-language/tl#1058").

Gate with `bin/cosmic --make ci`, including the flipped canary.

## Non-goals

**Do not delete any of the 5 casts in this PR.** CLAUDE.md's cold-build
rule: a new patch entry is exactly "a source that needs the tree's own
checker" — `_build/coldbuild_test.tl` type-checks generation 1 with
`bin/cosmic.pin`'s CURRENT release checker, which does not carry this
new entry yet, so code relying on it fails only a cold build. Land the
patch and its canary first; deleting the 5 casts is separate follow-on
work that must wait for a `bin/cosmic.pin` bump to a release built from
a tree carrying this patch (a release cut after this PR merges,
pinned in its own item) and, when filed, must carry a `blocked_by`
edge on that pin-bump item.
