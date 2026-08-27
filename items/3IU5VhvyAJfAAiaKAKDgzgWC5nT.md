## Goal

G3 — an honest type layer: the source-side workarounds that exist
only because the checker once lacked the landed narrow rules are
gone, and each surviving cast's comment states a reason that is
still true.

## Evidence

Measured 2026-08-27 at main c78504bd:

- `cosmic/fs/types.tl:247-252` (`extend_metatable`): guard
  `type(mt) ~= "table"` then
  `local idx = (mt as {string: any}).__index` with
  `-- cast: metatable<any> is a nominal the checker refuses
  is-dispatch on`. The #1439 entries make `if mt is {string: any}`
  narrow directly, so the cast's own comment is now FALSE — that
  alone earns the retire. `test_metatable_is_table_narrows` pins the
  replacement shape verbatim.
- `cosmic/coverage/init.tl:104-106` (`install_wrappers`): the
  guard-then-typed-local idiom (`create_fn`/`exit_fn` copied from
  `raw_create`/`raw_exit` under the comment "Narrowing does not
  cross into a closure; these typed locals carry it"). The #1442
  chunk-scan rule carries the is-facts into the closures below iff
  `raw_create`/`raw_exit` are assigned nowhere in the file — they
  are declared once and never reassigned (grep at capture), so the
  copies and the now-false comment can go, the closures calling the
  guarded names directly.
- `_tool/benchmark.tl`: the container's capture named it, but a
  grep for the idiom at c78504bd finds nothing — re-verify at pull
  and record "already dissolved" if so.

## Change

One commit: retire the two sites (delete the cast + its guard's
redundant half at fs/types.tl in favor of the pinned is-guard shape;
delete the typed-local copies at coverage/init.tl and update the
comment to name the closure-carry rule), plus whatever the
benchmark.tl re-check finds. Run the touched modules' tests
(`cosmic/fs`, `cosmic/coverage`) and full `--make ci` — the
cold-build lane (`_build/coldbuild_test.tl`) is the real gate here,
since these sources will now REQUIRE the patched checker.

## Non-goals

No new checker entries, no patch-file edits, no behavior change in
either module (the diff is types-and-comments shaped: same runtime
semantics). No cast-baseline increases — `_build/casts_baseline.tl`
rows for the two files may only go DOWN.

## Acceptance

- PULL-TIME GATE first: `git merge-base --is-ancestor c78504bd
  <sha of the tag bin/cosmic.pin names>` holds (c78504bd carries
  &#35;1439; #1442's merge precedes it on main). At refinement the pin
  (2026-08-27-6b88a0d) predates it — the next release + pin bump
  opens this; bounce rather than build if it fails, and never
  dispatch a release to force it.
- `bin/cosmic --make ci` ends `ci: PASS` (includes the cold-build
  proof).
- `grep -n "metatable<any> is a nominal" cosmic/fs/types.tl` → no
  match; `grep -n "does not cross into a closure"
  cosmic/coverage/init.tl` → no match.
- `_build/casts_baseline.tl`'s `cosmic/fs/types.tl` row decreases by
  exactly the retired count.
- `git diff --name-only origin/main` prints exactly the touched
  sources plus `_build/casts_baseline.tl`, and `.cosmic-coverage`
  iff the ratchet asked.

## Enablement

Wall-clock gated on the pin cycle only; the rules, tests and sites
are all landed and named above.
