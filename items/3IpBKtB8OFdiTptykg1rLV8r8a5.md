## Evidence

Re-run 2026-09-03 against `origin/main` (`96afd807`):

    git show origin/main:docs/design/cast-sites.tsv | awk -F'\t' '$3=="pcall return shape"{print $1":"$2}'
    cosmic/_teal_engine.tl:256
    cosmic/shm.tl:146
    cosmic/shm.tl:171
    cosmic/sqlite/extras.tl:63
    cosmic/sqlite/extras.tl:106

5 sites, matching the outcome's Evidence section verbatim:

    cosmic/_teal_engine.tl:256
      local result = result_or_err as TlResult
    cosmic/shm.tl:146
        local ok, err = pcall(raw.write, raw, off, data, write_count) as (boolean, any)
    cosmic/shm.tl:171
        local ok, err = pcall(raw.store, raw, word_index, value) as (boolean, any)
    cosmic/sqlite/extras.tl:63
          return false, (verdict as string) or "transaction failed"
    cosmic/sqlite/extras.tl:106
          return false, (verdict as string) or "savepoint failed"

(`_teal_engine.tl:256` and the two `extras.tl` sites read the SECOND
`pcall` return — the raised error on failure or the callee's own return
on success — after their own `pcall(...)` call a few lines above; all
five are the same shape: `pcall` types both slots `any` because the
checker has no way to know the protected function's own signature.)

`_build/casts_baseline.tl` rows this lowers:

    grep -F -e '"cosmic/_teal_engine.tl"' -e '"cosmic/shm.tl"' -e '"cosmic/sqlite/extras.tl"' _build/casts_baseline.tl
    ["cosmic/_teal_engine.tl"] = 5,
    ["cosmic/shm.tl"] = 2,
    ["cosmic/sqlite/extras.tl"] = 2,

`shm.tl` (2 casts, both this class) and `sqlite/extras.tl` (2 casts,
both this class) drop to 0; `_teal_engine.tl` carries 5 casts total and
only 1 is this class (the other 4 are the `tl compiler surface` class,
already closed by `lT1A_fWo4`) — it goes 5→4.

**The gap, per `docs/design/casts.md`'s "pcall return shape" section**:
"`pcall` is a checker special case, not an ordinary function: tl knows
the callee's type at the call site and could type the success arm from
it, leaving the failure arm as the error type." tl's checker already
special-cases a small closed set of builtin calls by name in a
special-function table — this repo's own carried patch extends that
SAME table for `error` and `os.exit`
(`3p/tl/tl_patch/narrow.tl`, entry `narrow-exit-special`,
`find`/`replace` on the table entry right before `["rawget"]`). `pcall`
is very likely already an entry in that table upstream (its current
`(boolean, any...)` typing has to come from somewhere), so this is a
matter of finding and extending pcall's EXISTING special-case handler,
not adding a wholly new hook — confirm which, once `o/3p/tl/tl.tl` is
on disk (step 1 below), before assuming a new hook is needed.

No canary for this gap exists yet in `cosmic/teal_test.tl` (searched:
no `pcall` reference there today) — this change adds the first one.

## Change

**This item writes and lands the checker patch only. It does NOT
delete any of the 5 casts above** — see Non-goals; the cold-build rule
(CLAUDE.md) is why.

1. **Fetch and locate the anchor.** `bin/cosmic --make fetch` unpacks
   the pinned tl source to `o/3p/tl/tl.tl`. Find `pcall`'s entry in the
   checker's special-function table (search for `"pcall"` — the same
   table `3p/tl/tl_patch/narrow.tl`'s `narrow-exit-special` entry
   patches for `error`/`os.exit`/`rawget`) and read how it currently
   types the call node's returns.

2. **Write a new `3p/tl/tl_patch/narrow.tl` entry**, in the same
   `find`/`replace`/`note` shape as every entry in that file (worked
   example, `narrow-and-operand`, `3p/tl/tl_patch/narrow.tl:28-32`):

   ```teal
   ["narrow-pcall-return"] = {
     file = "tl.lua",
     note = "<upstream issue ref>: pcall(f, ...) types its success return from f's own signature instead of `any`",
     find = [=====[<exact tl.lua snippet around pcall's special-case handler, from the fetched o/3p/tl/tl.tl>]=====],
     replace = [=====[<the same snippet plus the cosmic carried-patch comment and the fix>]=====],
   },
   ```

   The fact to add: when `pcall`'s first argument is a function value
   whose type the checker already knows at the call site (a plain
   function reference like `pcall(raw.write, ...)`, not a value only
   known as `any`), type the call node's return as
   `(boolean, <f's first return type>)` on success — leaving slot 1 as
   `boolean` per the runtime contract, and the FAILURE arm (when slot 1
   is `false`) as the type `pcall` raises, which Lua leaves untyped
   (the raised value can be anything `error()` was given) — so slot 2's
   declared type across both arms is honestly a union of `f`'s first
   return type and whatever type failure carries; a caller narrows by
   checking `ok` first, same as today. Where `f`'s type is not known at
   the call site (an `any`-typed first argument, or `f` computed
   dynamically), fall back to today's `(boolean, any)` — do not weaken
   that case. `find` must match the pinned `o/3p/tl/tl.tl` exactly once
   (D21's exactness rule); if it does not, report the mismatch rather
   than force a near-match.

3. **Add the canary.** In `cosmic/teal_test.tl`, following the shape of
   `test_narrowing_canary` (line 73) and this file's `first_hinted_error`
   helper: a snippet that calls `pcall` on a function with a known
   signature and reads the success return WITHOUT a cast, asserting
   `result.ok`; a second case (or a second assertion in the same test)
   confirming `pcall` on an `any`-typed callable still types `(boolean,
   any)` — the two sites above where `pcall`'s target is a struct method
   (`raw.write`, `raw.store`, `raw:...`) are good source material for
   the positive case's shape.

4. **Open the upstream issue.** Per D21's maturity clause: open an
   issue against `teal-language/tl` describing the gap (`pcall`'s
   return typing ignores the callee's own signature), referencing
   `docs/design/casts.md`'s "pcall return shape" section and the 5
   sites above. Record its number in the patch entry's `note` field,
   matching this file's existing convention (`whilp/cosmic#942`,
   `whilp/cosmic#1065`) or the direct-upstream-reference convention in
   `3p/tl/tl_patch/for_control_var.tl` ("Upstream teal-language/tl#1058").

Gate with `bin/cosmic --make ci`, including the new canary.

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
