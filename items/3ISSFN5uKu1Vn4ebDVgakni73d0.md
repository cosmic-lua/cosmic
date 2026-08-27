## Wrong turn, recorded

Bounced from `check` on 2026-08-26 after PR #1416's `build` lane went
red. The spec asserted, and was wrong:

> The cold-build rule does not bind — no new patch entry is involved;
> the narrowing that admits the cast-free spelling is already in the
> pin's successor and in the tree's own checker.

"In the pin's SUCCESSOR" is the whole problem. `bin/cosmic.pin` still
names `2026-08-15-c497c04`, which predates `narrow-or-fallback`, and
a cold build's generation 1 compiles the tree with THAT checker. From
the failing job (run 32995853861, job 98264755312):

```
cosmic: tree build failed; running pinned release
  .../releases/download/2026-08-15-c497c04/cosmic-lua
_cli/build/init_test.tl:73:14: error: cannot index key 'match' in
  variable 'lua' of type string | nil
_cli/build/init_test.tl:144:18: error: ... 'written' ...
_cli/build/init_test.tl:168:18: error: ... 'written' ...
build: FAIL (536 files)
```

`--make ci` passed on the same commit because it CONVERGES — it
builds first and re-execs into what it built, so the tree's own
patched checker judged the change. That is exactly the blind spot
`3ISKgfS6` recorded, reproduced here on a slice whose spec had
declared the rule inapplicable.

**A correction to the recorded rule, worth carrying forward.**
`3ISKgfS6` states it as "every `cosmic/**` source in a tl-patch slice
must type-check under BOTH the pinned checker and the patched one".
The failing file here is `_cli/build/init_test.tl` — not under
`cosmic/**`. Generation 1 compiles the WHOLE tree under the pin, so
the rule is tree-wide: ANY source that needs the new checker fails a
cold build until the pin carries it. Filed as `3ISnyPb7`.

## What this item now waits on

`3ISVlHT6` (pin bump to the first release carrying the narrow-*
patches), mirrored in `blocked_by` — the same blocker `3ISPGV8z`
already carries for the pack-n cast. Once the pin moves, this slice is
unchanged and ready as written below; nothing about the change itself
was wrong.

PR #1416 is closed. Its diff (three cast pairs removed, one baseline
row dropped) is reproducible in minutes from the Change section, and
reopening a stale branch after a pin bump would carry a diff nobody
reviewed against the new base.

---

## Goal
G3 — an honest type layer, no escape hatches. The parent container
(3ISJI4Lg) enumerates four checker gaps that left casts behind; this
slice retires gap (2)'s three casts, which the carried
`narrow-or-fallback` patch already made unnecessary.

## Change
Delete the three `-- cast: or fallback does not narrow` casts in
`_cli/build/init_test.tl` and their comment lines, then regenerate the
casts floor.

Measured 2026-08-26 against `main` `ec794d44`:

- `grep -rn "or fallback does not narrow" --include=*.tl . | grep -v "^./o/"`
  returns exactly 3 lines, all in `_cli/build/init_test.tl`, at lines
  72, 144 and 169 (the comment; the cast is on the line below each).
- `wc -l < _cli/build/init_test.tl` is 260 — 240 lines of headroom
  under the 500-line cap; this change only removes lines.
- `grep -n '_cli/build/init_test.tl' _build/casts_baseline.tl` is
  `3:  ["_cli/build/init_test.tl"] = 3,` — one row, count 3.

The three sites are two spellings of the same shape:

```teal
  -- cast: or fallback does not narrow
  local lua = (fs.read(out) or "") as string      -- lines 72-73
  -- cast: or fallback does not narrow
  local written = (fs.read(out) or "") as string  -- lines 144-145, 169-170
```

Replace each two-line pair with the single cast-free line, keeping the
same local name and indentation:

```teal
  local lua = fs.read(out) or ""
  local written = fs.read(out) or ""
```

Then rewrite the committed floor with the command the ratchet's failure
message prints — `bin/cosmic --make run _build/casts.tl --baseline` —
and commit the result. `_build/casts.tl`'s `main` writes only files that
still hold casts, so the `_cli/build/init_test.tl` row is REMOVED from
`_build/casts_baseline.tl` rather than set to 0; that is the expected
diff, and no other row should move. Verified 2026-08-26: the regen
produced exactly that one-line baseline deletion.

## Non-goals
- Do NOT touch `3p/tl/tl_patch.tl` or `_make/patch.tl`: no new patch
  entry is involved.
- Do NOT bump `bin/cosmic.pin` here. That is `3ISVlHT6`, this item's
  blocker; a slice that bumped the pin AND consumed it would hide
  which half broke.
- Do NOT retire the parent's other three gaps (`pack.n`, closure
  carry-through, `metatable<any>`) — separate items under 3ISJI4Lg.
- Do NOT add or change tests in `cosmic/teal_narrowing_test.tl`.
- Do NOT edit any other row of `_build/casts_baseline.tl` by hand, and
  do NOT weaken the casts ratchet in `_build/casts.tl` or
  `_build/casts_test.tl`.
- Do NOT change the assertions, test names, or behaviour of
  `_cli/build/init_test.tl`; only the two-line cast pairs move.

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS`.
- **`bin/cosmic --make clean && bin/cosmic --make build` ends
  `build: PASS`.** This is the check the last attempt lacked: it starts
  from the pin, so it is what proves the cold-build rule is satisfied.
  A green `--make ci` alone does NOT, because `ci` converges into the
  tree's own checker.
- `bin/cosmic --make test _cli/build/init_test.tl` passes.
- `grep -c "cast:" _cli/build/init_test.tl` prints `0` (today: `3`).
- `grep -c "_cli/build/init_test.tl" _build/casts_baseline.tl` prints
  `0` (today: `1`).
- `git diff --stat origin/main` touches exactly two files:
  `_cli/build/init_test.tl` and `_build/casts_baseline.tl`.

## Enablement
Blocked by `3ISVlHT6` (pin bump), mirrored in `blocked_by`: until the
trust root names a release whose checker carries `narrow-or-fallback`,
a cold build's generation 1 refuses the cast-free spelling and no
amount of care in this diff changes that.

Beyond the blocker, the countermeasure this bounce is evidence for is
`3ISnyPb7`: the cold-build rule needs to be enforced rather than
remembered — the `build` lane catches it only after a PR is open, and
`--make ci`'s convergence actively hides it. Two specs in a row have
now asserted the rule did not apply to them.

## Re-measured at refinement, 2026-08-27

The wait is over: `3ISVlHT6` landed as `d8584916` and
`bin/cosmic.pin` now names `2026-08-27-afad5b5`, whose release binary
carries the full tl patch set. Verified directly against the pinned
artifact, not inferred: the `cosmic-lua` asset downloaded from that
release (sha256 `9f81e916…`, matching the pin) accepts the exact
cast-free spelling this slice lands —
`local lua = (fs.read("x") or "")` then `lua:match(...)` →
`Type check passed`. So generation 1 of a cold build now compiles the
cast-free file, and the `build` lane failure that bounced PR #1416
cannot recur for this reason. The Change, Non-goals and Acceptance
below stand as written; re-run the Change section's three measured
greps at pull as usual (main has moved to `d8584916` since they were
taken, but the three sites and the baseline row are untouched by
everything landed since).
