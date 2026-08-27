## Goal

G3, under the tl-patch gaps container (3ISJI4Lg). The
patch-DIRECTORY mechanism (PR #1424, main `6b88a0db`, merged
2026-08-27) reaches builders only through the trust root's pin: a
release built from a main that carries it, then `bin/cosmic.pin`
moved to that release. This is that bump, and it is the wall holding
3ITo9Inv (the `tl_patch.tl` split) and, behind it, the three queued
patch items — 4 open items in all.

## Evidence

Measured 2026-08-27 from the repo root at main `6b88a0db`.

- **The pin today.** `bin/cosmic.pin` is two plain lines read by
  `bin/cosmic` with sed — `url = .../releases/download/<tag>/cosmic-lua`
  and `sha256 = <hex>`; the header comment says bump both together.
  `grep -c "2026-08-27-afad5b5" bin/cosmic.pin` → `1`. The last bump
  was `d8584916` (`git log --oneline -1 -- bin/cosmic.pin`).
- **Eligibility.** A release tag embeds its short sha
  (`YYYY-MM-DD-<short-sha>`), so the test is
  `git merge-base --is-ancestor 6b88a0db <release-sha>`. Today's pin
  fails it: `git merge-base --is-ancestor 6b88a0db afad5b5e` returns
  non-zero, because `afad5b5e` (#1420) precedes `6b88a0db` (#1424) on
  main.
- **No eligible release exists yet.** The newest release is
  `2026-08-27-afad5b5`, published 2026-08-27T01:43:37Z — before #1424
  merged. The daily `release.yml` cron (`0 6` UTC) should produce an
  eligible one; a cron run publishes a prerelease, and every recent
  release in the list is a prerelease, so a prerelease target is the
  precedent, not an exception.
- **Why the PINNED binary is what matters.** A cold build's generation
  1 fetches with the pinned release, using the `_make` engine embedded
  in that binary rather than the tree's sources
  (`bin/cosmic`'s header: "cosmic --make extracts its own build engine
  from its own zip"). The pinned release carries
  `_make/patch.lua` in its zip
  (`o/3p/cosmos/unzip -l o/bootstrap/cosmic | grep _make/patch`), and
  that copy is what decides whether a `<stem>_patch/` directory is
  seen at all.
- **The discriminating probe, measured.** Against the CURRENT pin,
  `o/3p/cosmos/unzip -p o/bootstrap/cosmic _make/patch.lua
  | grep -c 'paths_of_pin\|read_all'` → `0`, while
  `... | grep -c 'of_pin'` → `2` (the old single-file `of_pin`). #1424
  renames that resolver to `paths_of_pin` and adds `read_all`, so a
  non-zero first count is the proof the new pin carries the mechanism.
  `o/bootstrap/cosmic` is the downloaded pin itself, written by
  `bin/cosmic` on a cold start.
- **Release-lane health.** The lane was green for afad5b5's cycle.

## Change

1. **Confirm an eligible release exists.** List releases; take the
   newest tag whose sha has `6b88a0db` as an ancestor
   (`git fetch origin && git merge-base --is-ancestor 6b88a0db <sha>`).
   If none exists yet, this slice is not workable: bounce it back to
   `plan` rather than waiting inside the claim. Dispatching
   `release.yml` early is a human's call, never this item's.
2. **Bump `bin/cosmic.pin`** — the `url` line to that tag's
   `cosmic-lua` asset and the `sha256` line to the digest computed
   from the asset you downloaded (`sha256sum`), never copied from a
   third party. Those two lines are the whole diff.
3. **Cold-start proof.** `rm -f o/bin/cosmic o/bootstrap/cosmic &&
   bin/cosmic --make fetch && bin/cosmic --make ci` — the trust root
   re-fetches the new pin, verifies the sha, and the gate converges
   under it.
4. **Mechanism proof.** Run the probe above against the freshly
   downloaded `o/bootstrap/cosmic` and record the command with its
   output in the PR body. It must now print a non-zero count where it
   printed `0` before the bump.
5. **PR** carrying the pin diff only, with both transcripts in the
   description.

## Non-goals

- **No 3p pin changes** (`3p/cosmos/cosmos_pin.tl`,
  `3p/tl/tl_pin.tl`). The cosmos pin bump is its own item (3ITnbooy);
  the patch mechanism rides the cosmic release, not a tl pin.
- **Do NOT split `3p/tl/tl_patch.tl` or create `3p/tl/tl_patch/`** —
  that is 3ITo9Inv, which this bump unblocks. This diff touches no
  file under `3p/`.
- **No `release.yml` changes**, and no debugging of a red release lane
  inside this slice: file it as its own item and block this one on it.
- **No `--baseline` regen of any ratchet.** A pin bump that moves a
  ratchet floor is a finding to raise, not to absorb.
- **No `_make/patch.tl` or `_make/fetch.tl` edits.** The mechanism is
  frozen by #1424; this slice only moves the pin that carries it.

## Acceptance

Run from the repo root.

- `git merge-base --is-ancestor 6b88a0db $(git rev-parse <new-tag>)`
  exits 0 — the pinned release carries the mechanism.
- `grep -c "2026-08-27-afad5b5" bin/cosmic.pin` → `0` (today `1`).
- `sha256sum` of the downloaded `cosmic-lua` asset equals the pin's
  `sha256` line.
- `rm -f o/bin/cosmic o/bootstrap/cosmic && bin/cosmic --make fetch
  && bin/cosmic --make ci` ends `ci: PASS`.
- `o/3p/cosmos/unzip -p o/bootstrap/cosmic _make/patch.lua | grep -c
  'paths_of_pin'` → at least `1` (today `0`).
- `git diff --name-only origin/main` lists exactly `bin/cosmic.pin`.

## Enablement

Wall-clock gated, and that is the only gate: no eligible release
existed at 2026-08-27T02:50Z (newest `2026-08-27-afad5b5`, published
01:43:37Z, before #1424 merged), and the daily cron fires at 06:00Z.
No blocker item is recorded, because there is nothing on the board to
land — a puller who finds no eligible release bounces this to `plan`
per Change step 1. Everything else is stated above; the probe's
discriminating direction (new pin = a NON-ZERO `paths_of_pin` count)
is the one fact a puller must not invert.
