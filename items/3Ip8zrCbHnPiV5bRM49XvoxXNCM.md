## Evidence

Measured 2026-09-03.

    git show origin/main:bin/cosmic.pin | grep url
    url = https://github.com/cosmic-lua/cosmic/releases/download/2026-08-31-a5b36f4/cosmic-lua

    git log -1 --format='%ci %s' 96afd807
    2026-09-03 14:40:03 +0000 tl: curate Env, closing the report_types/loaded slice of the tl surface (#1650)

    GET /repos/cosmic-lua/cosmic/releases  → 2026-09-02-c60dcf1 (prerelease), 2026-09-01-3c80edc, 2026-08-31-cc57a40

The pinned binary's own types do not know the record:

    o/bootstrap/cosmic -e 'local s=io.open("/zip/.types/tl.d.tl"):read("a"); print(s:find("\n  record Env\n") and "present" or "absent")'
    absent

No release carries `96afd807` yet, and today's release run is red on
the perf gate (`33746684991`, `compare against the previous release` —
the lane-repair item, blocked on `c5wU_p1n9`; hence this block). The
consumer item `fuXz_MkSX` reproduces the cold-build failure this pin
gap causes (`unknown type tl.Env` from generation 1). Precedent for
the shape of the change: `git show --stat 54d754f1` (#1595) touched
`bin/cosmic.pin` alone, 2 lines.

## Change

1. Pick the first release whose tag commit contains `96afd807`:
   `gh release list --limit 5`, then for the candidate tag
   `git merge-base --is-ancestor 96afd807 <tag-sha>` (tag is
   `YYYY-MM-DD-<sha7>`, `release.yml:70-75`); a prerelease is fine —
   the current pin is one.
2. `bin/cosmic.pin`: set `url` to
   `https://github.com/cosmic-lua/cosmic/releases/download/<tag>/cosmic-lua`
   and `sha256` to `sha256sum` of that asset, downloaded once with
   `curl -fsSL`. Nothing else in the file.
3. Prove the bump from cold:
   `rm -rf o && bin/cosmic --make fetch && bin/cosmic --make build`,
   then the probe above against the new `o/bootstrap/cosmic` prints
   `present`, and `o/bootstrap/cosmic -e '…' | grep -A3 "record Env"`
   shows `report_types` and `loaded`.
4. `bin/cosmic --make ci` ends `ci: PASS` (`_build/coldbuild_test.tl`
   re-checks the tree under the new pin; `_make/fixpoint_test.tl`
   under `COSMIC_FIXPOINT=1` is the two-build proof).

## Non-goals

No consumer edit: `_teal_ast.tl` / `_teal_engine.tl` are `fuXz_MkSX`,
which this item unblocks. No `3p/tl/tl_pin.tl` change.
