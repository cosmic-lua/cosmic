## Evidence

Found while building 3IQgClLo (library latent-nil: cosmic/** sites
outside fs/ and time.tl, cosmic-lua/cosmic#1580), following
`docs/design/nil-flow.md`'s `## Method` to build the throwaway strict
Teal checker and re-run the census.

Spot-checking a single file with `--check types <file>` against a
strict-checker binary built before an edit can resolve a required
`cosmic.*` module's STALE embedded copy from the checker binary
itself, rather than the live file on disk — a real trap for anyone
reproducing the Method by hand and iterating file-by-file. The
workaround the builder used: do a full clean rebuild for the
authoritative before/after scan rather than trusting incremental
per-file binary reuse against a binary built earlier in the same
session.

This is not a defect in cosmic itself — no shipped code is affected —
it's a gap in the Method's own reproduction instructions that will
cost the next session doing a census re-run the same debugging time.

## Change

Add a line to `docs/design/nil-flow.md`'s `## Method` section warning
that a spot-check with `--check types <file>` against an
already-built strict-checker binary can resolve a stale embedded copy
of an edited `cosmic.*` module rather than the live file, and that a
full clean rebuild is the reliable way to get an authoritative
before/after count. Verify the exact mechanism (which build step
embeds what, and the precise repro) at pull time before writing the
final wording — this item's Evidence is a secondhand report from the
builder who hit it, not a verified root cause.
