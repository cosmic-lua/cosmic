## Evidence

Found while building 3I1Rvbva (coverage --baseline: refuse a bad
rewrite instead of clamping a good one, cosmic-lua/cosmic#1576), which
deleted `_tool/coverage/baseline.tl`'s never-raise clamp so a row can
now raise back on regen, not just lower. That PR's own scope was
`baseline.tl` + `baseline_test.tl` only; two other spots still describe
the pre-clamp-removal one-way behavior and are now stale:

- `_make/policy.tl`'s `write_baseline` prints `"... row(s) lowered; a
  floor only moves up by hand — see cosmic/coverage/SENSITIVITY.md"`
  after every successful `--baseline` write. That claim is false since
  #1576: a floor can now raise automatically on regen, and the message
  doesn't mention raises at all.
- `cosmic/coverage/SENSITIVITY.md` (around lines 50-52) documents the
  old one-way clamp ("A rewrite lowers only the rows this machine
  measures... and leaves every other row exactly as committed"), which
  is no longer accurate post-#1576.

## Change

Update `_make/policy.tl`'s `write_baseline` message and the relevant
section of `cosmic/coverage/SENSITIVITY.md` to describe the current
behavior: a `--baseline` regen writes the honest measurement in both
directions (raises and lowers), narrated either way, guarded by the
corpus breadth check that refuses when more than half the floor's rows
would drop. Re-verify exact wording and line numbers against the
current tree at pull time (#1576 lands first).
