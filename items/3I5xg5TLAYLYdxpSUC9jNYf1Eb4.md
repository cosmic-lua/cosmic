## Goal
G2 — sandbox enforcement reaches the kernel's ceiling and says what it
enforced (specifically requirement R5: "one probe — ABI knowledge lives
in one cached place").

## Change
Three call sites independently ask the kernel for its Landlock ABI
version via the argument-less probe form of
`unix.landlock_create_ruleset()` — `cosmic/sandbox/landlock.tl`'s own
`abi()` (the canonical one, already cached), plus two duplicates in
`cosmic/sandbox/unveil.tl` and `cosmic/quicksand/init.tl` that each
re-run the raw syscall and keep their own separate cache/logic. Make
`cosmic.sandbox.landlock.available()` (already exported, already
cached via `abi_cached`/`abi_probed`) the one place that knowledge
lives; the other two delegate to it and drop their own probing.

1. **`cosmic/sandbox/unveil.tl`**: add
   `local landlock = require("cosmic.sandbox.landlock")` alongside the
   existing `local unix = require("cosmo.unix")` (line 26). Replace the
   `available()` function (currently lines 62–85: the module-level
   `local avail: boolean = nil` cache plus the function body) with a
   version that has no local cache of its own and delegates the LINUX
   branch to `landlock.available()`:

   ```teal
   --- True when unveil is actually enforceable on this host: OpenBSD, or
   --- Linux with Landlock ABI >= 1. Derived, never probed with unveil
   --- itself — `unix.unveil(nil, nil)` is the commit call, so probing it
   --- would lock this very process into a deny-all sandbox. The libc backs
   --- unveil with Landlock on Linux, so it enforces exactly when Landlock
   --- does; everywhere else the raw call deliberately fails open, which is
   --- precisely what this wrapper refuses to pass through. The Linux
   --- answer delegates to cosmic.sandbox.landlock.available(), the one
   --- cached probe every Landlock-availability check shares.
   ---
   --- @return boolean True when unveil can be enforced
   local function available(): boolean
     local host = cosmo.GetHostOs()
     if host == "OPENBSD" then
       return true
     elseif host == "LINUX" then
       return landlock.available()
     end
     return false
   end
   ```

   Delete the now-unused `local avail: boolean = nil` line entirely —
   `landlock.available()` is already memoized, so a second cache here
   is exactly the duplication R5 asks to remove, not a safety margin.
   `unix` stays imported (`allow`/`commit` still call `unix.unveil`
   directly).

2. **`cosmic/quicksand/init.tl`**: add
   `local landlock = require("cosmic.sandbox.landlock")` alongside the
   existing requires (after line 19's `local unix = require("cosmo.unix")`
   is fine). Replace `probe_landlock()` (lines 79–84) with:

   ```teal
   --- Landlock availability, delegated to cosmic.sandbox.landlock's
   --- cached probe — the one place Landlock ABI knowledge lives,
   --- shared with cosmic.sandbox.unveil.
   local function probe_landlock(): boolean
     return landlock.available()
   end
   ```

   Keep the function (rather than inlining `landlock.available()` at
   its one call site, line 146) so it reads consistently with its
   neighbors `probe()` and `probe_ns()`, each a named probe in the
   same list. `capabilities()`'s own top-level `cached` table is
   untouched — this only changes what `probe_landlock()` does when
   `capabilities()` calls it the first time.

3. **`cosmic/sandbox/landlock_test.tl`**: add a regression test that
   keeps the dedup real — a guard against a *new* direct call
   reappearing elsewhere, which is exactly how the tree ended up with
   three copies. Using `cosmic.fs.find(root, {glob = "*.tl", recursive
   = true})` over the `cosmic/` tree (relative to the repo root, which
   the test can locate the same way other sandbox tests locate
   `TEST_BIN`/fixtures — via a path relative to this test file, or
   `os.getenv("TEST_TMPDIR")`'s sibling project checkout, whichever
   this repo's other tree-scanning tests already use), read each file
   with `cosmic.fs.read`, and count lines containing the literal
   substring `unix.landlock_create_ruleset()` (bare, no-arg form —
   `:find(needle, 1, true)`, a substring search, not a pattern).
   Assert the count is exactly 1, and that the one file it appears in
   is `cosmic/sandbox/landlock.tl`. This does not touch
   `cosmic/sandbox/landlock.tl` itself — its own two calls, one bare
   (`unix.landlock_create_ruleset()`, the probe) and one with
   arguments (`unix.landlock_create_ruleset(handled, 0)`, the real
   ruleset creation), are unaffected; only the bare form is counted.

```facts
$ wc -l cosmic/sandbox/unveil.tl cosmic/quicksand/init.tl cosmic/sandbox/landlock.tl cosmic/sandbox/landlock_test.tl cosmic/quicksand/init_test.tl
  145 cosmic/sandbox/unveil.tl
  184 cosmic/quicksand/init.tl
  295 cosmic/sandbox/landlock.tl
  327 cosmic/sandbox/landlock_test.tl
  186 cosmic/quicksand/init_test.tl
 1137 total
$ grep -rn "landlock_create_ruleset()" cosmic/ --include=*.tl | grep -v _test
cosmic/quicksand/init.tl:82:  local abi = unix.landlock_create_ruleset()
cosmic/sandbox/landlock.tl:158:    local v, err = unix.landlock_create_ruleset()
cosmic/sandbox/unveil.tl:79:    local abi = unix.landlock_create_ruleset()
$ grep -rln "landlock_create_ruleset()" cosmic/ --include=*_test.tl
$ grep -n "landlock_create_ruleset" cosmic/sandbox/landlock.tl
158:    local v, err = unix.landlock_create_ruleset()
205:  local rs, cerr = unix.landlock_create_ruleset(handled, 0)
$ grep -rn "cosmic.sandbox" cosmic/quicksand/*.tl
cosmic/quicksand/caps.tl:48:  --- the cosmic.sandbox mechanism shards (pledge, unveil, landlock).
cosmic/quicksand/init.tl:7:--- `cosmic.sandbox` facade (landlock + pledge) for its fs and syscall
cosmic/quicksand/types.tl:8:local sandbox = require("cosmic.sandbox")
cosmic/quicksand/types.tl:51:--- The filesystem policy is cosmic.sandbox's Fs schema (ro/rw/exec
cosmic/quicksand/types.tl:65:--- The system-call policy is cosmic.sandbox's Sys schema (pledge
$ grep -n "^local .* = require" cosmic/sandbox/landlock.tl
24:local unix = require("cosmo.unix")
25:local seal_coverage = require("cosmic._seal_coverage").seal_coverage
```
`cosmic/quicksand/types.tl` already requires `cosmic.sandbox` (the
facade) directly, so a sibling module (`cosmic/quicksand/init.tl`)
requiring `cosmic.sandbox.landlock` (an internal shard, per
`cosmic/doc/visibility.tl`'s one-segment-only public rule — anything
under `cosmic/` may require an internal shard also under `cosmic/`) is
an established, precedented direction. `cosmic/sandbox/landlock.tl`'s
own requires (`cosmo.unix`, `cosmic._seal_coverage`) show it requires
neither `cosmic.sandbox.unveil` nor `cosmic.quicksand` — no cycle is
created in either direction.

## Non-goals
- **Defect 3 (race-free `fs.optional`)** is not touched: this slice
  does not change `present_only`/`effective_fs` in
  `cosmic/sandbox/init.tl`, does not add `IgnoreIfMissing`-style
  per-rule ENOENT tolerance to `landlock.tl`'s `restrict()`, and does
  not touch `cosmic/sandbox/plan.tl`.
- **Defect 4 (honest per-section enforcement report / `strict`
  option)** is not touched: `Availability`'s shape in
  `cosmic/sandbox/init.tl`, `apply()`'s return contract, and the
  `best_effort` truthy-but-nothing-enforced footgun are all unchanged.
- **The ABI drift alarm** (a test that fails when the running kernel's
  Landlock ABI exceeds the highest one `abi_mask` models) is not built
  here — it is a separate item that depends on this one landing first
  (see Enablement).
- **Defect 2 (REFER granted with `rw`)** — already fixed in the tree
  (`WRITE` includes `REFER`, `abi_mask` strips it below ABI 2, and
  `test_rw_grant_allows_rename_within_its_tree` in
  `cosmic/sandbox/landlock_test.tl` exercises it); nothing to do here
  and this slice does not touch that code path.
- No change to `landlock.tl`'s `abi()`/`available()`/`restrict()`
  contracts, return values, or caching mechanism — it is the retained
  canonical source both callers delegate to, and stays exactly as it
  is today.
- No change to the WITH-ARGUMENTS `landlock_create_ruleset(handled, 0)`
  call in `landlock.tl` (the real ruleset creation) — only the two
  duplicate bare-probe call sites move.
- No change to `cosmic.quicksand.types.Capabilities`'s field shape —
  `capabilities().landlock` stays a plain boolean with the same
  semantics.
- No change to `pledge.available()` or its probing — the epic's "three
  uncoordinated Landlock probes" note names exactly `landlock.abi`,
  `unveil.available`, and `quicksand.probe_landlock`; pledge uses a
  different mechanism (`probe(unix.pledge)`) and is out of scope.
- Not the C-layer ceiling work (Phase 2, whilp/cosmopolitan) or the
  `net` section (Phase 3) — epic-level non-goals, unaffected either
  way by this slice.
- Not a portable-default-deny change and not a rewrite of quicksand's
  netns/proxy — epic-level non-goals.

## Acceptance
- `bin/cosmic --make test cosmic/sandbox/unveil_test.tl` passes,
  including the existing `test_available_returns_boolean`.
- `bin/cosmic --make test cosmic/sandbox/landlock_test.tl` passes,
  including the new guard test asserting exactly one bare
  `unix.landlock_create_ruleset()` call site across `cosmic/`, located
  in `cosmic/sandbox/landlock.tl`.
- `bin/cosmic --make test cosmic/quicksand/init_test.tl` passes,
  including the existing `capabilities().landlock` boolean assertion
  (unchanged behavior, now delegated).
- `grep -rn "landlock_create_ruleset()" cosmic/ --include=*.tl | grep -v _test` prints exactly one line (`cosmic/sandbox/landlock.tl:158:...`)
  instead of today's three.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement
Predicted wrong turns and how this spec heads them off:

- **Adding a second cache instead of removing the first.** A literal
  implementer could leave `unveil.tl`'s `local avail` cache in place
  "to be safe" while also delegating to `landlock.available()`,
  producing two caches instead of one — quietly reintroducing the
  thing R5 asks to remove. The Change section states explicitly:
  delete the `avail` local, no cache in this file. `none needed`
  beyond that explicit instruction — the diff is small enough to
  review by eye.
- **A new duplicate probe reappearing later** (this is literally how
  the tree got three copies in the first place: someone needing
  Landlock availability reached for the raw syscall instead of the
  existing wrapper). **Core countermeasure included in this slice**:
  the new guard test in `landlock_test.tl` fails the moment a fourth
  bare `unix.landlock_create_ruleset()` call site appears anywhere
  under `cosmic/`, and the acceptance grep makes the same check
  runnable by hand. No separate enablement item needed — the test
  ships inside this slice's own file set (`landlock_test.tl`, which
  already owns the sibling test asserting `RW` carries `REFER`), not
  bolted on afterward.
- **Scope creep into defect 3/4 while the same files are open.**
  `unveil.tl`/`init.tl`(quicksand) are not files defect 3 or 4 touch
  (those land in `cosmic/sandbox/init.tl` and `cosmic/sandbox/plan.tl`),
  so there is no shared-file temptation; the Non-goals section still
  names both explicitly since `landlock.tl` is common ground all three
  slices read.
- **Sequencing note for later filing**: the epic's future "ABI drift
  alarm" item (a test that fails when the running kernel reports a
  Landlock ABI above the highest one `abi_mask` models) will build on
  the one-probe shape this slice establishes — when that item is filed,
  its own board record should record this one as a prerequisite. This
  slice itself carries no dependency of its own: no blocker, and no
  wait on defect 3, defect 4, or anything else landing first.
