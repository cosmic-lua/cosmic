## Goal

G6 — the defining paths, ratcheted. Every release already measures a
full-suite same-binary A/A control pair, on one runner, in one job,
with `meta.bin_sha` recorded on both halves — and throws half of it
away when the job ends. This publishes that half as a release asset, so
the project accumulates the one longitudinal record of its own
measurement noise that costs nothing to produce.

The value is EVIDENCE RETENTION and nothing else: no gate reads the new
asset, no floor is derived from it, and nothing is committed to the
repo.

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

## Evidence, completed 2026-08-27 against `origin/main`

The capture above establishes the waste and the retrieval half. Three
facts complete the picture for an implementer.

**1. `selfcheck.json` IS passed to the gate, and is still unread on a
clean run.** `release.yml:174-176` hands it to `gate.tl compare` as the
third positional, which `_perf/gate.tl` binds as `selfcheck_b`. But
`gate_inner` returns 0 right after pass 1 when nothing flags, and
`opts.measure(opts.selfcheck_b)` sits below that on the escalation
path. So on the common path the file is written by the measure step,
named on a command line, and never opened.

**2. What gets published therefore has two possible provenances**, and
both are valid A/A halves of the same binary:

- clean run: the second full-suite reading from the measure step;
- escalated run: that file OVERWRITTEN by `opts.measure`, which
  re-measures the same binary later in the same job.

Either way it is a same-binary, same-runner, same-job reading with its
own `meta.bin_sha` and `meta.timestamp`. The asset needs no flag
distinguishing them, but the header comment should say it, because a
reader comparing gaps between the two halves will otherwise wonder why
some are minutes apart and some are not.

**3. `size.json` is the worked precedent for every edit below.** It is
a small JSON asset produced in the same job, uploaded in the same
artifact, and published by the same `gh release create`, and
`release.yml:205-207` records the reasoning: "baseline.tl's own
--asset flag picks it, so that finds perf.json finds size.json." The
four sites are `release.yml:233` (artifact path list), `:319`
(`size_src=$(find ...)`), `:334` (`cp`), and `:347` (the create
argument list) — plus the `:323` guard that refuses an empty `_src`.

## Change

One file, `.github/workflows/release.yml`, four edits plus a guard,
each mirroring `size.json`'s existing treatment exactly. Re-locate each
site by its `size.json` neighbour rather than by the line numbers
above, which move.

1. **Artifact path list** (`:231-234`): add `o/perf/selfcheck.json`
   beside `o/perf/perf.json`.
2. **Source discovery** (beside `size_src=`): add
   `selfcheck_src=$(find artifacts -type f -name selfcheck.json | head -1)`.
3. **The guard** (the `if [ -z "$cosmic_src" ] || …` chain): add
   `[ -z "$selfcheck_src" ]` as another disjunct, so a missing file
   fails the release rather than publishing a partial asset set — which
   is the property that chain exists for.
4. **Stage it** (beside `cp "$size_src" release/size.json`): add
   `cp "$selfcheck_src" release/selfcheck.json`.
5. **Publish it** (the `gh release create` argument list): add
   `release/selfcheck.json` beside `release/perf.json`.

6. **Rewrite the comment block above the "measure the release" step** —
   REWRITE, not append. The block's existing sentence, "run twice — once
   for the record, once so the compare step below has an A/A self-check
   to separate a real regression from noise", is the stale claim
   `3IHHKCyz` filed against: the gate never reads that file's
   pre-measured content, it overwrites it. Leaving it in place and
   adding prose beside it produces a block that contradicts itself, and
   the block is this change's whole non-mechanical payload.

   The rewritten block must state, in one voice and without
   contradiction:

   - both readings are published, so each release retains its own
     same-binary A/A control — two full-suite measurements of one binary
     on one runner in one job — and a release runner's noise floor can
     be read after the fact;
   - on a CLEAN run the published pair is the measure step's two
     readings;
   - on an ESCALATED run the gate OVERWRITES `selfcheck.json` with its
     own control measurement of the same binary and reads THAT as a
     triage control (`_perf/gate.tl`'s `controls`, D31), so a published
     pair's halves may be minutes or tens of minutes apart;
   - publishing adds no gate input: nothing reads the RELEASED asset.

   Do not write a flat "nothing gates on the second half". It is false
   on an escalated run under one reading and makes "both readings are
   published" false under the other — the escalated case has to be
   named, not generalised away. Write it to the house standard
   (`skills/docs-style/SKILL.md`) — no item ids, no PR numbers, no
   dates.

## Review, 2026-08-27 (request changes on PR #1464 at `9fed7ebd`)

The five mechanical edits were correct and verified independently: the
guard refuses with `selfcheck_src` empty and passes with it set, the
`gh release create` argv carries nine assets in order with
`release/selfcheck.json` between `perf.json` and `compare.txt`, the file
round-trips a YAML parse, both edited `run:` bodies pass `bash -n`, the
three-dot diff is one file, `git diff -- _perf` is empty, and
`bin/cosmic --make ci` ends `ci: PASS (5 stages)` at that head with CI
green on all five lanes.

The gap was the comment, and it was this spec's fault: Change #6 above
originally asked only that a comment be APPENDED, while this item's own
Evidence quoted `3IHHKCyz` identifying the sentence already there as
stale. A spec that knows a neighbouring sentence is wrong must ask for
it to be reconciled. Change #6 is rewritten above to do that.

One tree fact this spec inherited from `3IHHKCyz` and should not carry
forward: `3IHHKCyz`'s Direction says "`_build/workflows_test.tl` already
greps this step's shape". It does not. That test covers container
digest pinning, `--privileged`, and the non-root builder identity, per
job; it names no release asset and no measure step. So
`--make test _build/workflows_test.tl` passing is not evidence about
any edit in this change, and the Acceptance section's real proofs are
the `bash -n`, guard-reconstruction and argv checks.

## Non-goals

- **No gate reads the new asset**, now or as part of this change. No
  `_perf/**` file is touched at all: not `gate.tl`, not `compare.tl`,
  not `run.tl`, not `baseline.tl`. `baseline.tl` already accepts
  `--asset NAME` and needs no edit to be able to fetch it later.
- **No derived noise floor, and no bar of any kind moves.**
  `DEFAULT_THRESHOLD_PCT` stays `10.0`, `TRIAGE_K` stays `2.0`, and
  `codec_base64_roundtrip_64k` keeps its floor. Deriving a per-scenario
  floor from cross-RELEASE A/A spreads would measure runner-to-runner
  variance — the 20-33% class 3IU0GxoA recorded — and both that item's
  "What this does NOT license" paragraph and D31's rejection of a
  committed per-scenario noise profile as premature under D27 forbid
  it. This item retains evidence; it does not consume it.
- **Nothing is committed to the repo.** `o/perf/*.json` stays build
  output and stays uncommitted (AGENTS.md).
- **No second measure run, and no change to the existing two.** The
  A/A pair this publishes is the one the workflow already takes.
- **No change to `3IHHKCyz`'s diff or scope**, and no execution of it.
  That item's Direction is to drop the second measure run as redundant;
  it is recorded as blocked on this one so the deletion cannot land
  first and remove the data. Settling the tension is board work, not
  this diff's.
- No change to the `peers` job, the compare step, or the size lane.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _build/workflows_test.tl` ends `test: PASS` —
  the ratchet over the workflow files themselves.
- **The five sites are each present and each mirrors `size.json`.**
  For each of `selfcheck.json` / `selfcheck_src` / `release/selfcheck.json`,
  `grep -n` the workflow and quote the hit beside its `size` counterpart,
  showing they sit in the same construct.
  `grep -c 'selfcheck_src' .github/workflows/release.yml` → `3` (the
  assignment, the guard disjunct, the `cp`).
- **The shell still parses.** Extract each edited `run:` block's script
  body and run `bash -n` on it; report PARSE OK. The blocks are
  single-quoted `bash -c` strings, so a stray quote is the failure mode
  this catches and nothing else will.
- **The guard actually refuses.** Reconstruct the guard chain with
  `selfcheck_src` empty and the others set, run it under `bash`, and
  show it exits non-zero. A guard that cannot fail is not a guard, and
  this is the one edit whose mistake would publish a partial asset set
  silently.
- **`_perf` is untouched.**
  `git diff origin/main...HEAD --name-only` → exactly
  `.github/workflows/release.yml` and nothing else. Use the THREE-dot
  form: the two-dot form prints main's forward progress on a stale
  checkout and has produced false clean readings in this repo before.
- **No bar moved**, checked rather than assumed:
  `git diff origin/main...HEAD -- _perf` is empty.

## Enablement

None needed. Every edit has a worked precedent in the same file
(`size.json`, Evidence 3), the second measure run already exists and
already writes the file, and the retrieval half (`baseline.tl
--asset NAME`) is already built and already used twice in this
workflow. Nothing has to land first.

The one judgment the implementer should not have to make is recorded
above: the published file's provenance differs between a clean and an
escalated run, and that is expected rather than a bug to normalise
away.
