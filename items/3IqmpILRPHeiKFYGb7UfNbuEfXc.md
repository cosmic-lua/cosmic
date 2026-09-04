## Evidence

Found by the fresh-context review of PR #1687 (D44: the perf compare
moved off the release into `perf.yml`; releases no longer carry
`perf.json`). Two sites still describe the old shape, both outside
that PR's enumerated edit list and walled there (`_perf/baseline.tl`'s
behaviour was frozen for the move):

```
$ grep -n 'perf.json' _perf/baseline.tl
16:--- "perf.json"). Its asset is downloaded to --out.
67:local DEFAULT_ASSET < const > = "perf.json"      # re-measure: the line may sit at 67 or 80
80:      help = "release asset name to fetch (default perf.json)"},
$ grep -n 'release lane' _perf/compare_test.tl
245:-- The release lane's json_decode_large flag ...
```

Every caller passes `--asset` explicitly (`perf.yml` and `release.yml`:
`--asset cosmic-lua`, `--asset size.json`), so the default is
unreachable in the tree and names an asset no release publishes
since D44. Re-measure both greps at pickup; line numbers move.

## Change

1. `_perf/baseline.tl`: the default `--asset` becomes `cosmic-lua`
   (the one asset every release carries and the perf lane's actual
   baseline), in the constant, the flag's help text, and the header
   comment's "(default …)" — three sites, one string. No caller
   changes (all pass `--asset`); `_perf/baseline_test.tl`'s
   `pick_baseline` fixtures are on literal names and are unchanged
   unless one asserts the default, in which case that assertion moves
   to the new string.
2. `_perf/compare_test.tl:245` (re-measure): reword the comment so it
   names the perf lane, not the release lane, keeping the scenario
   and the number it pins.

Wall: `_perf/baseline.tl`'s verdict lines (`perf-baseline: OK|SKIP|FAIL`)
and `pick_baseline`'s selection rule are unchanged. Gate: `bin/cosmic
--make ci` ends `ci: PASS`.

## Non-goals

No change to `perf.yml`, `release.yml`, or any compare rule.
