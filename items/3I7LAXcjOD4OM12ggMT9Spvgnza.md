## Goal

G2 — contained where the platform can enforce it, via the sandbox epic's
R4: missing paths are tolerated at open time, never pre-checked. The
pre-check is a TOCTOU (a path vanishing between check and open still
kills the whole restrict) and dangling symlinks pass it then fail the
open.

## Change

Move `optional` from a pre-filter to the open itself. Measured
2026-08-19 at `f420391`:

1. **`cosmic/sandbox/landlock.tl`** (295 lines): `record Rule` (line 86)
   gains `--- Skip this rule when its path is absent at open time.`
   `optional: boolean`. In `restrict()` (line 191), the rule-open
   failure branch (lines 223–227, `pfd, perr = unix.open(...)`): capture
   the third return (`cosmo.unix` returns `nil, err, errno`), and when
   `rule.optional` and `errno.is_code(eno, "ENOENT")`, skip this rule
   and continue; every other error still fails as today.
2. **`cosmic/sandbox/plan.tl`** (85 lines): `for_landlock` (line 62)
   stamps `optional = fs.optional or nil` onto every rule it builds
   (`add_rules` output, lines 28–44) — the flag rides the rule, and the
   module keeps its "no syscalls, no side effects" comment true (line
   51, which currently points at the facade's filtering; reword it to
   point at the open).
3. **`cosmic/sandbox/init.tl`** (360 lines): delete `present_only`
   (lines ~126–138) and `effective_fs` (~140–150) outright; `apply`
   (line 320) passes `opts.fs` to `apply_fs` unfiltered. In
   `apply_fs_unveil` (lines 154–167), the same tolerance for the
   OpenBSD path: when `fs.optional` and `unveil.allow(p, perm)` fails
   with ENOENT, skip that path; other errors still fail.
4. **Tests** (`cosmic/sandbox/landlock_test.tl`, 353 lines / 147
   headroom; `init_test.tl`): an optional policy naming one absent path
   and one present one restricts successfully; a NON-optional policy
   naming an absent path still fails naming the path; a dangling
   symlink under `optional` is skipped (the case the pre-check got
   wrong). Existing tests already skip cleanly where landlock is
   unavailable (this repo's sandboxed CI kernel returns ENOSYS,
   measured); CI's ubuntu runners exercise the real paths.

## Non-goals

- `_cli/grants.tl`'s own presence filter (lines ~249–255) stays — it
  encodes grant-shape judgment, not this mechanism; deleting it is its
  own follow-up once this lands.
- no change to the `Fs` record's public shape: `optional: boolean`
  keeps its name and meaning; only WHERE it acts moves.
- no report/strict changes — that is the sibling R1 slice.

## Acceptance

- `bin/cosmic --make test cosmic/sandbox/landlock_test.tl cosmic/sandbox/init_test.tl`
  ends `test: PASS (2 files)`.
- `git grep -c "present_only\|effective_fs" -- cosmic/` prints nothing.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed — every touched line is named from measurement; the errno
narrowing idiom (`errno.is_code`) is the stdlib's documented pattern.
