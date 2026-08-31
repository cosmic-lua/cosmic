## Goal

G2, requirements R1 and R3: `apply` never returns success while
enforcing less than requested without saying, per section, what was
degraded or skipped and why — and the options surface cannot construct
a kernel EINVAL. Fixes the epic's defect 4 (a 5.13–6.1 kernel strips
TRUNCATE/REFER and `apply` still answers as if enforcement were full)
and its footgun (a truthy `{fs = false, sys = false}` from `best_effort`
when NOTHING was enforced, so `if sandbox.apply(p) then` lies).

## Change

Public-surface rework of `cosmic.sandbox` (`init.tl`, measured 335
lines: `wc -l cosmic/sandbox/init.tl`) and `cosmic.sandbox.landlock`
(measured 305 lines: `wc -l cosmic/sandbox/landlock.tl`), with the
semantics recorded as a decision record (R8). Both stay far under the
500-line cap after the additions below.

1. **`landlock.restrict` returns what it enforced.** Signature moves
   from `boolean, string` to `Enforcement | nil, string` where
   `record Enforcement` carries `abi: integer`, `handled: integer` (the
   mask actually handled), `stripped: integer` (rights requested but
   ABI-masked away — `abi_mask` at `cosmic/sandbox/landlock.tl:144`
   (`grep -n "^local function abi_mask" cosmic/sandbox/landlock.tl`) is
   where they drop). In-tree callers, measured just now with
   `grep -rn "landlock\.restrict\|require(\"cosmic\.sandbox\.landlock\")" --include="*.tl"`:
   `init.tl`'s `apply_fs` at `cosmic/sandbox/init.tl:144`
   (`grep -n "^local function apply_fs" cosmic/sandbox/init.tl`) and the
   module's own tests (`cosmic/sandbox/landlock_test.tl`) — both updated
   here.
2. **`apply` returns a per-section report.** `SandboxModule.apply`
   becomes `function(opts: Options): Report | nil, string`;
   `record Report` has `fs: Section` and `sys: Section` (nil when the
   section was not requested); `record Section` has
   `state: string` — `"full"` | `"degraded"` | `"skipped"` —
   `mechanism: string` ("landlock" | "unveil" | "pledge"),
   `abi: integer` (0 where meaningless), `missing: string` (human
   rendering of what was stripped/skipped, "" when full). `"degraded"`
   is landlock reporting `stripped ~= 0`; `"skipped"` is `best_effort`
   passing an unenforceable section. The old `record Availability`
   (`fs: boolean, sys: boolean`, `cosmic/sandbox/init.tl:68-71`) is
   deleted outright, not kept alongside — item 8 below is every
   remaining reference to it.
3. **The footgun dies by contract, with one named carve-out.** When
   every requested section ends `"skipped"`, `apply` returns
   `nil, "sandbox: nothing enforced (…)"` even under `best_effort` — the
   natural `if sandbox.apply(p) then` is then correct. Partial
   enforcement (at least one requested section not `"skipped"`) always
   returns the Report, never this error, regardless of the flag below.

   The one caller that needs the all-skipped case to still succeed
   is `_cli/driver.tl`'s `fence()` (see item 8) — measured, not
   assumed, by reading its 40-line comment block: fence's own doc
   states a host that cannot enforce at all must run the recipe
   **unfenced by design**, softly, and item 3 as originally written
   would turn that into a hard dispatch failure on every host without
   Landlock. The decided fix is a new named opt-in, not a change to
   the general rule and not string-matching the error: add
   `Options.allow_unenforced: boolean` (default false). When true,
   an all-skipped result returns the Report (every requested section's
   `state == "skipped"`) instead of the error — the caller is asserting
   it already tolerates zero enforcement and only wants the per-section
   detail, not a hard stop. Rejected alternatives, and why: gating the
   footgun contract on "more than one section requested" would silently
   revive the footgun for every single-section best_effort caller (the
   more common shape, and the one G2 is written against); matching the
   error string is exactly the fragile-by-construction pattern D24
   argues against for structured failure sites, and this module has no
   structured error record to classify on instead.
4. **`strict`.** `Options.strict: boolean` — any section that would end
   `"degraded"` or `"skipped"` is instead a refusal naming the section
   and the gap. `validate` refuses two combinations, both a kernel-EINVAL-
   shaped self-contradiction rather than a real host state: `strict` with
   `best_effort` (unchanged from the original decision), and `strict`
   with `allow_unenforced` (tolerating an all-skipped result is
   meaningless once `strict` already refuses any single skipped section).
   `validate` also refuses `allow_unenforced = true` without
   `best_effort = true`: `"skipped"` only ever arises from `best_effort`
   passing an unenforceable section (item 2), so `allow_unenforced` alone
   can never have anything to tolerate.
5. **`handled` leaves the facade (R3).** Delete `Options.handled` and
   `plan.for_landlock`'s `handled?` parameter — measured 2026-08-19:
   zero in-tree consumers outside `cosmic/sandbox/` (grep over `*.tl`;
   every hit elsewhere is unrelated prose). `landlock.RestrictOptions.
   handled` STAYS — it is the mechanism-level door and is pinned by
   `test_narrowed_handled_intersects_rule_access`.
6. **`availability()` says what, not just whether.** `Availability`'s
   `fs`/`sys` become small records (`available: boolean`,
   `mechanism: string`, `abi: integer`) instead of two booleans —
   always a non-nil table, so `if sandbox.availability().fs then` no
   longer compiles as a boolean test (item 8 covers every site that
   currently writes it that way). `is_available()` keeps its boolean
   contract.
7. **R8: the decision record.** Via the `decide` skill: a new record on
   sandbox enforcement-report semantics — degraded is not refused,
   `strict` is how degraded becomes refusal, nothing-enforced is an
   error by default, and `allow_unenforced` is the one named, validated
   escape hatch for a caller (`fence()`) that already documents
   tolerating zero enforcement — citing D7 where it touches the fence's
   posture, and recording the two rejected alternatives from item 3 so
   the choice isn't relitigated. Ships in the same PR.
8. **Every other in-tree touch site, exhaustively measured this pass.**
   Two greps, run fresh against this tree:
   `grep -rn "sandbox\.\(apply\|availability\|Availability\|Report\)" --include="*.tl" | grep -v "^cosmic/sandbox/"`
   and `grep -rn "require(\"cosmic\.sandbox\")" --include="*.tl"`. Full
   result, every hit outside `cosmic/sandbox/`:
   - `_cli/driver.tl:136-153`, `fence()` — three edits, all in this one
     function:
     - line 136-139: add `allow_unenforced = true` to the
       `sandbox.apply({fs = fs_policy, best_effort = true})` call.
     - line 140: `if enforced is sandbox.Availability then` becomes
       `if enforced is sandbox.Report then` (the type itself renamed by
       item 2).
     - line 140-153 restructure: invert to nil-check first (the type is
       `Report | nil, string` now, so this reads the same as every other
       fallible-value site in the tree) —
       ```
       local enforced, err = sandbox.apply({
           fs = fs_policy,
           best_effort = true,
           allow_unenforced = true,
         })
       if enforced == nil then
         return "fence for '" .. verb .. "' failed: " .. (err or "unknown error")
       end
       if enforced.fs.state ~= "full" and os.getenv("COSMIC_FENCE") ~= nil then
         io.stderr:write("fence: unenforceable on this host; '"
           .. verb .. "' runs unfenced\n")
       end
       return nil
       ```
       `enforced.fs` is never nil here — `fs` is the only section
       `fence()` requests, and item 2 makes a requested section's
       `Section` field non-nil. The condition is deliberately
       `~= "full"`, not `== "skipped"`: the OLD boolean `not
       enforced.fs` could only ever catch total non-enforcement,
       because the old `Availability.fs` reported `true` on a degraded
       landlock restrict too (this IS the epic's defect 4, reproduced
       at this exact call site) — so a stripped-ABI kernel ran `fence()`
       silently believing it had full enforcement. Widening the
       condition to also warn on `"degraded"` is the one-word
       consequence of finally being able to tell the two apart here;
       the policy itself is untouched — quiet by default, a stderr line
       only when `COSMIC_FENCE` is explicitly set, dispatch still
       proceeds either way.
   - `_cli/fence_test.tl:61,109,206` (`if not sandbox.availability().fs
     then check.enforce_skip(...)` at 61 and 109, `if
     sandbox.availability().fs then` at 206) — item 6 makes
     `.fs` a non-nil `MechanismInfo` table, so all three become
     `.fs.available`: `if not sandbox.availability().fs.available then`
     (61, 109) and `if sandbox.availability().fs.available then` (206).
     Purely mechanical; no other line in this file names `Availability`
     or reads `.fs`/`.sys` as a boolean
     (`grep -n "availability\|Availability" _cli/fence_test.tl` — only
     these three lines plus the `require` at line 31).
   - `cosmic/quicksand/box/run.tl:116,141` and
     `cosmic/quicksand/box/init.tl:126` (comment only) — confirmed
     genuinely unaffected: both `run.tl` call sites are
     `local ok, err = sandbox.apply({fs = fs})` / `{sys = opts.sys}`
     with no `best_effort`, consumed only as `if not ok then return
     tostring(err) end` — no field access, no type name, and no
     `best_effort` means the all-skipped path (and hence
     `allow_unenforced`) never applies here. Matches the existing
     Non-goals exemption; re-verified, not re-assumed.
   - `_eval/testdata/run_{fail,partial,pass}/contained-task/cmd/copybox/main.tl`
     — each is `sandbox.apply({fs = {rw = {}}})`, but the file's own
     header comment says a fixture check greps for the `require()` +
     `.apply(` text and never compiles or runs it. Confirmed by reading
     the header; untouched by this change.
   - `_cli/driver_test.tl` and `_cli/grants.tl` — both name only
     `sandbox.Fs`, a type this item does not touch. Untouched.

   No other file requires `cosmic.sandbox`
   (`grep -rn "require(\"cosmic\.sandbox\")" --include="*.tl"` lists
   exactly the files above plus `cosmic/sandbox/init.tl`,
   `init_test.tl` and `init_example.tl` themselves).

## Non-goals

- no new enforcement capability: `net` is the R7 slice, gated on the
  cosmopolitan pin; this slice only makes the report able to carry it.
- no change to `landlock.RestrictOptions`, the WRITE/READ masks, or any
  denial — weakening a denial to improve a report is the exact failure
  this epic forbids.
- no change to `fence()`'s policy: an unenforceable host still runs the
  recipe, still unfenced, still only warning when `COSMIC_FENCE` is
  explicitly set. `allow_unenforced` and the broadened warning condition
  in item 8 change what `fence()` can now tell apart (full vs. degraded
  vs. skipped) and what type it reads, never whether it proceeds.
- no changes to `cosmic.quicksand` — its `sandbox.apply` calls in
  `box/run.tl` and the comment in `box/init.tl` are re-confirmed
  unaffected in item 8, not merely carried forward from the prior pass.
