## Goal

The narrow-pack-n checker patch (PR #1409, merged 2026-08-26) reaches
builders only through the trust root's pin: a release built from a
main that carries it, then `bin/cosmic.pin` moved to that release.
This item is that bump. It unblocks 3ISPGV8z (retire the coverage
pack-n cast) and every future cast retire that needs the patched
checker, per the cold-build rule 3ISKgfS6 established: a `cosmic/**`
change needing the NEW checker fails generation 1 under the old pin.

## Evidence

Measured 2026-08-26 against main `8f34339e`:

- **The pin**: `bin/cosmic.pin` — two plain lines, `url = https://
  github.com/whilp/cosmic/releases/download/<tag>/cosmic-lua` and
  `sha256 = <hex>`, read by `bin/cosmic` with sed; the header comment
  says bump both together. Today: tag `2026-08-15-c497c04`.
- **The patch commit to carry**: `1ca3f7ff` ("tl patch: pack's
  mixed-arity fallback keeps n as integer (#1409)"). A release tag
  embeds its short sha (`YYYY-MM-DD-<short-sha>`), so eligibility is
  `git merge-base --is-ancestor 1ca3f7ff <release-sha>`.
- **Release cadence risk, measured**: the latest release is
  `2026-08-23-d71d7f1` (prerelease) — the daily 06:00 UTC cron has
  produced nothing for three days, so "wait for tomorrow's release"
  may not be enough. release.yml supports `workflow_dispatch` (cron
  runs default to prerelease; a real one passes `prerelease: false`).
- **Prerelease precedent**: the current pin (`2026-08-15-c497c04`)
  and the pin bump convention — check `git log -- bin/cosmic.pin`
  at pull for whether past bumps chose prereleases; the release list
  shows every recent tag as prerelease, so a prerelease target is
  acceptable unless that history says otherwise.
- **The discriminating probe** (validated reasoning, from 3ISKgfS6's
  refinement): under the OLD checker, `table.pack(1, "a")` erases and
  `.n` is `any`, so `local s: string = table.pack(1, "a").n` PASSES
  (an `any` assigns anywhere); under the patched checker `.n` is
  `integer`, so the same line is a type ERROR. The new pin is proven
  by the REFUSAL.

## Change

1. **Wait for or trigger the release.** If no release tagged
   2026-08-27 or later exists, dispatch release.yml (cron default,
   prerelease) or wait for the 06:00 UTC cron. Verify eligibility:
   the tag's sha has `1ca3f7ff` as an ancestor. If the release lane
   turns out red, that repair is its own item — file it and block
   this one on it rather than debugging inside this slice.
2. **Bump `bin/cosmic.pin`**: new `url` (the tag's `cosmic-lua`
   asset) and `sha256` (compute from the downloaded asset; never copy
   from a third party). Only those two lines change.
3. **Cold-start proof**: `rm -f o/bin/cosmic && bin/cosmic --make
   fetch && bin/cosmic --make ci` — the trust root re-fetches the new
   pin, verifies the sha, and the whole gate converges under it.
4. **Checker proof**: write the probe to scratch —
   `local t = table.pack(1, "a")` then
   `local s: string = t.n` — and run the PINNED binary's
   `--check types` on it BEFORE the tree build overwrites
   `o/bin/cosmic`: the run must FAIL naming the integer/string
   mismatch. Record the command and output in the PR body.
5. **PR** with the pin diff only; on land, `gitboard unblock`/land
   flow clears 3ISPGV8z's blocker.

## Non-goals

- **No 3p pin changes** (`3p/cosmos/cosmos_pin.tl`, `3p/tl/*_pin.tl`)
  — the cosmos pin moved in #1395 and the tl patch rides the cosmic
  release, not a tl pin.
- **No cast edits** — 3ISPGV8z retires the coverage cast after this
  lands.
- **No release.yml changes**, and no debugging of a red release lane
  inside this slice (file it, block on it).
- **No `--baseline` regen of any ratchet** — a pin bump that moves a
  ratchet is a finding to raise, not to absorb.

## Acceptance

Run from the repo root:

- `grep -c "2026-08-15-c497c04" bin/cosmic.pin` prints 0 (today 2 —
  url and nothing else carry it; re-measure at pull) and the new tag
  dates 2026-08-27 or later with `1ca3f7ff` an ancestor of its sha.
- `sha256sum` of the downloaded asset matches the pin's second line.
- `rm -f o/bin/cosmic && bin/cosmic --make fetch && bin/cosmic --make
  ci` ends `ci: PASS` (cold start under the new pin).
- The probe transcript in the PR body shows the PINNED release
  refusing `local s: string = table.pack(1, "a").n`.
- `git diff --name-only origin/main` lists exactly `bin/cosmic.pin`.

## Enablement

Wall-clock gated: workable only once an eligible release exists
(first cron after 2026-08-26, or a manual dispatch). Everything else
is stated above; the probe's discriminating direction (new checker =
refusal) is the one fact a puller must not invert.
