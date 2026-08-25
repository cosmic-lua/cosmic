G5's win condition is "a release ships only after a clean fuzz
window", and today the release does not look: release.yml contains
no reference to fuzz (measured 2026-08-25: `grep -n fuzz
.github/workflows/release.yml` is empty), and the documented posture
is that a red fuzz run "fails loudly but never blocks or delays a
release". The change: the release workflow checks the most recent
completed deep-fuzz run covering its window and refuses (or demotes
to prerelease) when it is red or absent, with the failure naming the
run it read. The current never-blocks posture was deliberate, so
this likely earns a decision record (the `decide` skill) recording
the flip and its bounds — e.g. a stale-green window, or fuzz
infrastructure breakage, must fail loud rather than silently waving
the release through.
