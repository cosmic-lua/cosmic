## Evidence

Found while refining 3IVDirCO, which was split out of 3IUBNQZZ over
"there is no accumulated cross-window A/A history anywhere in the
tree". That premise is half wrong, and the half that is wrong points
the other way from 3IHHKCyz's stated Direction.

**Every release measures a full-suite same-binary A/A pair and
publishes only one half of it.** `release.yml`'s "measure the release"
step runs the suite twice against the SAME binary in the SAME job on
the SAME runner:

```
sed -n '126,132p' .github/workflows/release.yml
```

→ `o/bin/cosmic --make run _perf/run.tl --out o/perf/perf.json`
followed by `--out o/perf/selfcheck.json`.

On a CLEAN release the second file is never read: `_perf/gate.tl`
calls `opts.measure(opts.selfcheck_b)` only on the escalation path,
after a flagged regression persists through the retry
(`_perf/gate.tl:200-205`). So on the common path `perf.json` and
`selfcheck.json` are two independent full-suite readings of one binary
on one runner — a genuine A/A control pair — and only `perf.json`
survives the job:

```
sed -n '225,234p' .github/workflows/release.yml   # upload-artifact path list
grep -n 'perf_src=\|cp "$perf_src"\|release/perf.json' .github/workflows/release.yml
```

→ the artifact list and the `gh release create` argument list
(`.github/workflows/release.yml:234,317,332,347`) name `perf.json` and
never `selfcheck.json`. The A/A half is discarded when the job ends.

**Retaining it needs no new mechanism and no committed state.**
`perf.json` is already a published release asset — 15,531 bytes on
`2026-08-27-cb39b65` and 15,519 on `2026-08-27-afad5b5`
(`curl -sS "https://api.github.com/repos/whilp/cosmic/releases?per_page=2"`,
`.assets[].size`) against a 10,510,001-byte `cosmic-lua` in the same
release. `_perf/baseline.tl` already fetches any named asset from the
previous release (`--asset NAME`, default `perf.json`; `release.yml`
already passes `--asset cosmic-lua` and `--asset size.json`), so the
retrieval half exists. The change is the artifact path list, one
`find`/guard variable, one `cp`, and one argument to `gh release
create`.

**The tension to settle.** 3IHHKCyz (backlog) reads the same second
run as pure waste and its Direction is to "drop the redundant
selfcheck pre-measure" — correct on the premise that nothing consumes
it as a gate INPUT, which this item does not dispute. What it misses
is that the file is the project's only free same-binary control pair,
measured on a labelled runner with `meta.bin_sha` recorded, and that
3IU0GxoA spent two probe brackets (40 + 9 + 7 launches) and three
review rounds establishing cross-session facts that an archive of
these pairs would have made readable. Whichever way this is settled,
the two items must be settled together: executing 3IHHKCyz as written
deletes the data this one proposes to keep.

**What this is NOT.** Not a derived noise floor and not a new gate
input. Deriving a per-scenario floor from cross-RELEASE A/A spreads
would measure runner-to-runner variance — the 20-33% class 3IU0GxoA
recorded — and both 3IU0GxoA's "What this does NOT license" paragraph
and 3IUBNQZZ's Non-goals forbid widening `codec_base64_roundtrip_64k`'s
bar on that evidence; D31 separately rejected a committed per-scenario
noise profile as premature under D27. The value proposed here is
EVIDENCE retention only: no gate reads the asset, no floor is derived
from it, nothing is committed to the repo.

Measured 2026-08-27, tree at `267c2a4d`, binary
`145057b9fe905bb866fa3c03818265e4284a3bcd8367b76d9d5254f3c32a0900`.
