
## Goal

G2 — sandbox enforcement reaches the kernel's ceiling and says what it
enforced (epic `3I1IfJ228vyPoO9rhbHhc6RjxJB`), Phase 1 defect 1: a
narrowed `handled` (a public field on `sandbox.Options` and
`landlock.RestrictOptions`) must never produce a kernel `EINVAL` —
today it does, on the very first rule whose access exceeds it.

## Change

In `cosmic/sandbox/landlock.tl`, function `restrict` (Teal function
starting at line 191), the per-rule access mask is computed against
the ABI mask only, never against the actual `handled` set the ruleset
was created with:

```facts
$ sed -n '203,204p' /home/user/cosmic/cosmic/sandbox/landlock.tl
  local mask = abi_mask(abi_version)
  local handled = (opts.handled or ALL) & mask
$ sed -n '218p' /home/user/cosmic/cosmic/sandbox/landlock.tl
    local access = (rule.access or 0) & mask
```

Per `landlock_add_rule(2)`, a rule's access must be a subset of the
`handled_access_fs` the ruleset was created with (`handled`, line 204,
passed to `landlock_create_ruleset` at line 205) — not merely a subset
of what this kernel's ABI can express (`mask`). When a caller narrows
`handled` below `mask` (e.g. `handled = landlock.READ`) and a rule
still requests wider access (e.g. `access = landlock.RW`), line 218
masks that access only down to `mask`, so it stays wider than
`handled` and `unix.landlock_add_rule` returns `EINVAL`, surfaced by
`restrict` as `"landlock: add_rule(%q): EINVAL"`.

Fix: change line 218 from

```teal
    local access = (rule.access or 0) & mask
```

to

```teal
    local access = (rule.access or 0) & handled
```

`handled` (line 204) is already `(opts.handled or ALL) & mask`, so it
is always a subset of `mask` — masking by `handled` instead of `mask`
is strictly more correct and never changes behavior for any existing
caller that leaves `opts.handled` unset, because in that case
`handled == ALL & mask == mask` exactly (`ALL`'s bits are a superset
of everything `abi_mask` ever sets). Add a short comment directly
above the changed line explaining why (mirroring the existing
`FILE_BITS` comment two lines below it):

```teal
    -- A rule's access must be a subset of `handled`, or
    -- landlock_add_rule(2) returns EINVAL — intersect against the
    -- actual handled set (not just the ABI mask) so a caller that
    -- narrows `handled` gets exactly that access, never a kernel error.
    local access = (rule.access or 0) & handled
```

No other line in `restrict`, and no other file, needs to change: the
doc comment on `Rule.access` (lines 82–83, "must be a subset of the
call's `handled` mask") already states the post-fix contract; today's
code just doesn't honor it.

### Regression test

Add a new test function to `cosmic/sandbox/landlock_test.tl`
(currently 276 lines, 7 test functions, ending at line 276 with
`test_rw_grant_allows_rename_within_its_tree()`), appended after the
existing last test, following the same live-subprocess-with-soft-skip
shape every other enforcement test in this file already uses
(`check.enforce_skip` / `check.enforced`, `child.start` +
`h:wait()`, plain-text `:find(..., 1, true)`):

```teal
-- Options.handled narrows which access categories the ruleset
-- controls; a rule's access must be intersected against the ACTUAL
-- handled set, not just the ABI mask, or a rule requesting more than
-- `handled` grants exceeds handled_access_fs and landlock_add_rule(2)
-- returns EINVAL. Enforcement is irreversible, so the live check runs
-- in a subprocess.
local function test_narrowed_handled_intersects_rule_access()
  if not landlock.available() then
    check.enforce_skip("landlock unavailable (kernel lacks landlock)")
    return
  end
  local dir = fs.join(tmpdir, "narrowed-handled")
  assert(fs.make_dirs(dir))

  local script = fs.join(tmpdir, "landlock_narrowed_handled.lua")
  assert(fs.write(script, string.format([[
local ll = require("cosmic.sandbox.landlock")
local ok, err = ll.restrict{
  handled = ll.READ,
  rules = { { path = %q, access = ll.RW } },
}
if not ok then
  io.write("restrict-failed: " .. tostring(err) .. "\n")
  os.exit(0)
end
io.write("restrict-ok\n")
]], dir)))

  local h = check.must(child.start({cosmic, script}))
  local __r1 = check.must(h:wait())
  local ok, out = __r1.ok, __r1.stdout
  if not ok then
    check.enforce_skip("landlock restrict blocked (subprocess died before enforcing)", true)
    return
  end
  if out:find("restrict-failed", 1, true) then
    -- The EINVAL this test pins came from add_rule when a rule's
    -- access exceeded a narrowed handled set; that regression is a
    -- hard failure. Anything else (create_ruleset / restrict_self
    -- blocked by an outer sandbox) is a strict skip.
    assert(not out:find("add_rule(", 1, true),
      "a rule wider than a narrowed handled must not EINVAL: " .. out)
    check.enforce_skip("landlock restrict blocked: " .. out, true)
    return
  end
  assert(out:find("restrict-ok", 1, true),
    "restrict must succeed when a rule's access exceeds handled: " .. out)
  check.enforced("landlock handled/rule-access intersection")
end
test_narrowed_handled_intersects_rule_access()
```

`tmpdir`, `cosmic`, `fs`, `child`, `check`, and `landlock` are already
bound at the top of this file (lines 2–8); no new `require` is needed.

```facts
$ wc -l /home/user/cosmic/cosmic/sandbox/landlock.tl
291 /home/user/cosmic/cosmic/sandbox/landlock.tl
$ wc -l /home/user/cosmic/cosmic/sandbox/landlock_test.tl
276 /home/user/cosmic/cosmic/sandbox/landlock_test.tl
$ grep -c "^local function test_" /home/user/cosmic/cosmic/sandbox/landlock_test.tl
7
$ grep -n "handled" /home/user/cosmic/cosmic/sandbox/landlock_test.tl
34:  -- ABI 3, `ALL` picked it up as handled, and `RW` did not -- so a
39:  -- REFER is the same shape one ABI earlier: handled by ALL, and
```

The last fact shows `handled` appears only in two explanatory comments
today — no existing test in this file passes a narrowed `handled` to
`landlock.restrict` at all, matching the epic's own note that the bug
is "unhit in-tree only because nothing currently passes a narrowed
handled."

```facts
$ cd /home/user/cosmic && o/bin/cosmic --make test cosmic/sandbox/landlock_test.tl 2>&1 | tail -4
1 checks: 1 passed
wall: 6ms  slowest: cosmic/sandbox/landlock_test.tl (6ms)
test: PASS (1 file)
note: fmt and lint did not run here — `cosmic --make ci` is the whole gate
```

That run (7 test functions, all soft-skipping their live assertions)
is the pre-change baseline on this dev host — `uname -a` here reports
`Linux ... 6.18.5-fc-v20`, and `landlock.available()` on this host
returns `false` (`landlock_create_ruleset: ENOSYS`), so the new test's
live assertions will also soft-skip here, exactly like the other six
enforcement tests in this file; they run for real under CI's
`COSMIC_ENFORCE=1` enforce lane on a landlock-capable kernel, same as
every other test in this file.

## Non-goals

- Phase 1 defect 2 (`REFER` handled but never granted): out of scope,
  and on inspection appears **already fixed** in the current tree —
  `WRITE` (`cosmic/sandbox/landlock.tl` line 76) already ORs in
  `REFER`, and `landlock_test.tl` already has a passing
  `test_rw_grant_allows_rename_within_its_tree` (line 217) covering
  cross-directory rename inside one `rw` grant. Do not re-touch the
  `WRITE`/`RW`/`ALL` mask constants (lines 73–78) in this slice.
- Phase 1 defect 3 (`fs.optional` TOCTOU pre-check in
  `cosmic/sandbox/init.tl`'s `present_only`/`effective_fs`): untouched.
  Do not change `cosmic/sandbox/init.tl` at all in this slice.
- Phase 1 defect 4 (silent ABI downgrade reported as full enforcement;
  truthy `{fs=false,sys=false}` under `best_effort`): untouched. Do
  not change `Availability`, `apply`'s return shape, or add a
  `strict` option in this slice.
- No "handled field decision" (whether `handled` should be removed
  from `sandbox.Options` per R3's "on the table" note) — this slice
  makes the existing field behave correctly, it does not decide
  whether the field should exist.
- No change to `abi_mask`, `FILE_BITS`, or any other constant in
  `cosmic/sandbox/landlock.tl` besides the one line named above.
- No change to `cosmic/sandbox/plan.tl` — it never sets `opts.handled`
  narrower than default today, so it needs no change for this fix to
  take effect the moment a caller (present or future) does narrow it.
- Phase 2 (the C-layer kernel ceiling: `libc/calls/landlock.h`,
  `lunix.c`, ABI 4–9 bindings in whilp/cosmopolitan) and Phase 3 (the
  `net` section, quicksand consuming it, TSYNC, docs) are untouched —
  this slice makes no C/kernel-binding change of any kind.

## Acceptance

- `bin/cosmic --make test cosmic/sandbox/landlock_test.tl` passes,
  reporting **8** test functions (up from the current 7 shown in the
  facts block above), including the new
  `test_narrowed_handled_intersects_rule_access`.
- `grep -c "^local function test_" cosmic/sandbox/landlock_test.tl`
  prints `8`.
- `grep -n "local access = (rule.access or 0) & handled"
  cosmic/sandbox/landlock.tl` matches exactly one line.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed. The fix is a one-line intersection using a value
(`handled`) already computed two lines above the change; the
existing doc comment on `Rule.access` (lines 82–83) already states
the correct contract, and the existing test file already establishes
the exact live-subprocess-with-soft-skip pattern the new test follows
line for line — there is no convention here for a literal-minded
implementer to miss, and no ambiguity about the target line or the
one-character-class fix (`mask` → `handled`).
