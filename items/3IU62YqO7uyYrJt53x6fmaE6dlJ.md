## Goal

G4, under the tree-migration container (3IOCdooE): put a release
carrying the D29 compile seam behind `bin/cosmic.pin`, so build
generation 1 — and every cold build — type-checks a runner-mode test
file with its tail. Nothing in the migration can land until this does.

## Evidence (measured 2026-08-27 against origin/main at cb39b65d)

- **The pin predates the seam.** `bin/cosmic.pin` names
  `2026-08-27-6b88a0d`; the seam merged as #1446 at 04:40Z the same
  day, after that release was cut.
- **This is exactly the cold-build rule's staging case** (AGENTS.md):
  build generation 1 compiles the WHOLE tree with the pinned
  release's checker, so a source needing the tree's own checker
  passes a converged `--make ci` and fails a cold build.
- **`_build/coldbuild_test.tl` catches it, as designed.** It runs
  `BOOTSTRAP --check types --include-dir . --include-dir
  <generated-types> <every tree source>` — the CLI `--check types`
  path #1446 taught the seam. Trial: delete the 43 self-call lines
  under `_build/**`, then `o/bin/cosmic --make test _build` →
  `test: FAIL (1 of 12 files)`, with
  `_build/workflows_test.tl:115:1: warning: unused function
  test_the_image_is_pinned_by_digest` and coldbuild's own message
  naming the remedy: "Stage the change behind a release + pin bump".
- **The release exists or is imminent**: release.yml runs daily at
  06:00 UTC and #1446 merged at 04:40Z, so the next release carries
  it. Confirm before bumping — the release the pin names must contain
  the seam, not merely postdate the merge.

## Change

`bin/cosmic.pin`: set `url` to a `cosmic-lua` release that contains
#1446's seam, and `sha256` to that artifact's digest. Both lines
together — the file is read by `bin/cosmic` with sed and stays two
plain lines. Nothing else in the repo changes.

Verify the chosen release actually carries the seam before bumping:
download it, and confirm a runner-mode file checks clean under it —

```
printf '\nlocal function test_probe()\n  assert(1 == 1)\nend\n' > /tmp/probe_test.tl
<the-release-binary> --check types /tmp/probe_test.tl
```

must print `Type check passed`, where the current pin's binary emits
`unused function test_probe`.

## Non-goals

No migration edits — deleting self-call lines is the batch children's
work, and none of it belongs in this diff. No other pin
(`3p/cosmos/cosmos_pin.tl`, `3p/tl/tl_pin.tl`) moves. No change to
`bin/cosmic` itself, to the release workflow, or to
`_build/coldbuild_test.tl`.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`, run from a tree with no
  `o/` so the pinned binary is the one that bootstraps.
- `bin/cosmic --make test _build/coldbuild_test.tl` passes.
- `grep -c . bin/cosmic.pin` is unchanged from main and the file still
  carries exactly one `url = ` and one `sha256 = ` line
  (`grep -c '^url = ' bin/cosmic.pin` → 1, `grep -c '^sha256 = '
  bin/cosmic.pin` → 1).
- The probe above prints `Type check passed` under the newly pinned
  binary.

## Enablement

none needed — #1446 has merged, the release cadence is daily and
documented in AGENTS.md, and the failure this fixes was measured in
this pass.
