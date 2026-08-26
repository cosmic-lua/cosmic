## Goal

G6 — the defining paths, ratcheted (`docs/goals.md:123-140`), whose
measured half is "the existing `perf-compare` gate".
`codec_base64_roundtrip_64k` is the one scenario holding that gate
red: every scheduled `release.yml` run since `2026-08-23-d71d7f1`
(runs `32699814015`, `32818853162`, `32940138465`) failed at the
`compare against the previous release` step, so nothing publishes,
and `3ISVlHT6`'s pin bump has no release to point at. Naming the
commit that moved it is the prerequisite to fixing it. This slice is
RESEARCH: it produces recorded evidence and the follow-up it implies,
not a code change and not a PR.

(This item is parented under G3 — an honest type layer. That
mis-parenting is inherited from `3ISlWFiS`, is captured as
`3IT8rb3B`, and is not this slice's to fix.)

## Evidence

All facts below measured 2026-08-26 with the commands beside them.

**The effect, confirmed across sessions.** `3ISlWFiS` measured, on
cosmic tree `5ef13f40` with only `3p/cosmos/cosmos_pin.tl` varied,
four alternating isolated readings per arm: `07fc94a1c` median
**191.31 µs** [185.81, 195.26], `354c17e08` **209.35 µs** [206.45,
214.50], `fe7c36c4c` **207.28 µs** [204.57, 209.38]; same-binary
noise floor from six `gate.tl selfcheck` passes **4.5%**. A→C is
**+8.35%** with disjoint ranges. `3ISWHyP7` had measured +7.8% for
the same step in an earlier session on noisier hardware. That is the
cross-session reproduction `skills/optimize/measurement.md` demands
before a finding blocks a pin.

**The range is five commits.** B→C in that run was NOT REPRODUCED
(-0.99%, ranges overlapping), so the step arrived at or before
`354c17e08` and the four cosmos commits since are ruled out by
measurement. `git log --oneline 07fc94a1c..354c17e08` in a
whilp/cosmopolitan checkout prints exactly five, oldest last:

| # | commit | subject | files changed (`git show --stat`) |
|---|---|---|---|
| 1 | `bf92718a1` | AGENTS.md: the perf backlog lives on cosmic's work board (#269) | `AGENTS.md` only |
| 2 | `8e071ec98` | sqlite3: stub the two headers mkdeps cannot resolve (#270) | `third_party/sqlite3/BUILD.mk`, two new `.h` |
| 3 | `5bfcf79d0` | zipos: recycle the stored-member handle through a lock-free slot array (#272) | `libc/runtime/zipos-open.c` +62/-9, `zipos.internal.h`, tests |
| 4 | `8dd093cea` | EncodeJson: a float always encodes carrying a `.` or an exponent (#273) | `third_party/lua/luaencodejsondata.c` +11/-1, `definitions.lua`, tests |
| 5 | `354c17e08` | DecodeLua: a Lua-literal data parser in C, beside the JSON one (#274) | `tool/net/llua.c` +650 new, `tool/lua/lcosmo.c` +23, `definitions.lua` |

**The codec itself did not change.**
`git log --oneline 07fc94a1c..354c17e08 -- net/http/encodebase64.c net/http/decodebase64.c net/http/isbase64.c | wc -l`
→ `0`. The scenario's whole path is C: `_perf/bench/micro_bench.tl:116`
calls `cosmic/codec.tl:37,82,83`, which are thin wrappers over
`cosmo.EncodeBase64` / `cosmo.IsBase64` / `cosmo.DecodeBase64`. So
code layout — added or changed compiled code moving the base64 loops
across an alignment or cache boundary — is the leading hypothesis,
and "not on the base64 path" dismisses no commit here.

**Every commit in the range has a published cosmos release, so the
bisect needs no local C build at all.** This is the fact that shapes
the slice. Run in a whilp/cosmopolitan checkout after
`git fetch origin --tags`:

```
for c in 07fc94a1c bf92718a1 8e071ec98 5bfcf79d0 8dd093cea 354c17e08; do
  echo -n "$c -> "; git tag --list "*$c" | tr '\n' ' '; echo
done
```

prints, today, one `YYYY.MM.DD-<sha>` tag per commit (plus its
`cosmocc-` sibling, which is the toolchain and not used here):

| commit | cosmos release tag |
|---|---|
| `07fc94a1c` | `2026.08.21-07fc94a1c` |
| `bf92718a1` | `2026.08.23-bf92718a1` |
| `8e071ec98` | `2026.08.23-8e071ec98` |
| `5bfcf79d0` | `2026.08.24-5bfcf79d0` |
| `8dd093cea` | `2026.08.24-8dd093cea` |
| `354c17e08` | `2026.08.24-354c17e08` |

Each publishes a `cosmos.zip` at
`https://github.com/whilp/cosmopolitan/releases/download/<tag>/cosmos.zip`
beside a first-party `SHA256SUMS`, which is exactly what
`3p/cosmos/cosmos_pin.tl` names — so every arm of this bisect is a
two-line pin edit and a `--make fetch`, the same instrument that
produced the confirmed numbers.

**Why a local `make o//tool/lua/lua` is the WRONG instrument here.**
whilp/cosmopolitan's `.github/workflows/release.yml` builds the
shipped `lua` at `m=rel` (`:42` x86_64, `:53` aarch64) and apelinks
the two into one fat binary (`:62-64`). A local
`make -j$(nproc) o//tool/lua/lua` is default mode (ftrace padding,
SYSDEBUG, DWARF) and single-arch. Since layout IS the hypothesis
under test, an instrument that changes layout wholesale cannot be
trusted to carry the effect. The released artifacts are the only
binaries the +8.35% has ever been measured on.

**Two pins are already known, first-party, from our own history**, so
two arms need no sha computed:

- `git show 5ef13f40:3p/cosmos/cosmos_pin.tl` → version
  `2026.08.21-07fc94a1c`, sha
  `03e5286bce12d1080f00cdd1f2a72f634b6b0b7c0ce4e2287205d63221ef6f03`
- `git show origin/main:3p/cosmos/cosmos_pin.tl` → version
  `2026.08.26-fe7c36c4c`, sha
  `1b54fceb616831aa155da03b5f26865a1d180f02908a82e56dd022fcd87c5d17`

**The tree to hold fixed is `5ef13f40`.** `bfe422e9` ("cosmos:
consume the exact contracts", #1395) edited `cosmic/fs/path.tl` and
`cosmic/time.tl` to drop narrowing the newer `definitions.lua` makes
unnecessary, so `origin/main`'s tree is not guaranteed to type-check
against a runtime from before it. `5ef13f40` predates it and is
proven to build against both ends of this span: `3ISlWFiS` got
`build: PASS (515 files, 1 binary)` on that tree against
`07fc94a1c`, `354c17e08` and `fe7c36c4c`. `_types/gentype.tl:35`'s
MODULES list is byte-identical at `5ef13f40` and at `origin/main`
(`git show <rev>:_types/gentype.tl | grep -n '^local MODULES'`), so
the module-surface ratchet is not what differs.

**The harness supports every arm.** `_perf/run.tl` takes `--only SUB`
(substring, `:59,268`) and `--out FILE`, and exits non-zero naming
the miss when `--only` matches nothing (`:282-286`).
`_perf/gate.tl selfcheck A.json B.json [--threshold PCT] <run args...>`
(`:34-35,210`) measures the SAME binary twice and passes run args
through — the same-binary noise floor this slice needs. Defaults are
`DEFAULT_SAMPLES = 5` and `DEFAULT_MIN_SAMPLE_SECS = 0.15`
(`_perf/harness.tl:21-22`). The scenario is
`_perf/bench/micro_bench.tl:116-129`; its `check()` verifies the
round trip returns `BLOB`.

**A pin unpacks its runtime where it can be hashed.** `--make fetch`
unpacks cosmos beside the pin into `o/3p/cosmos/`, so
`sha256sum o/3p/cosmos/lua` names the actual runtime an arm will
embed onto — without unzipping anything by hand, and without
`--version`, which stamps the pin at embed time rather than the
runtime (`skills/optimize/cosmopolitan.md`, step 2's second sharp
edge).

## Change

No source file changes anywhere. The deliverable is recorded evidence
and one follow-up item.

1. **Six scratch worktrees, one fixed tree.** From the cosmic
   checkout, make six worktrees detached at **`5ef13f40`**, one per
   release tag in the table above. In each, edit ONLY the `version`
   and `platforms["*"].sha` lines of `3p/cosmos/cosmos_pin.tl`.
   Obtain each sha first-party: download the tag's `cosmos.zip`,
   `sha256sum` it, and cross-check that digest against the same
   release's `SHA256SUMS` asset. If the two disagree, stop and record
   that as the result — never write a sha from anywhere else. The two
   pins listed under `## Evidence` are already first-party and may be
   used as-is.

2. **Fetch every arm and hash its runtime.** In each worktree run
   `bin/cosmic --make fetch`, then `sha256sum o/3p/cosmos/lua`. Record
   all six digests. This step is cheap — no build — and it is what
   decides how many arms get measured.

3. **Collapse the inert commits.** Walk the six arms in commit order,
   `07fc94a1c` first. An arm whose `o/3p/cosmos/lua` digest is
   byte-identical to its immediate predecessor's cannot have moved
   anything: drop it and attribute its commit to the surviving arm
   before it. Call the surviving arms after `07fc94a1c` the
   CANDIDATES. Record every digest and every collapse in the result,
   including the case where nothing collapses.

4. **Choose the arms to measure, capped at four.**
   - If there are **three or fewer candidates**: measure `07fc94a1c`
     plus every candidate.
   - If there are **four or more candidates**: measure exactly three —
     `07fc94a1c`, the middle candidate (index `ceil(n/2)` in commit
     order, 1-based), and `354c17e08`.

   Never measure more than four arms in this slice; a surviving range
   is what the follow-up in (8) is for.

5. **Build the measured arms.** In each measured worktree,
   `bin/cosmic --make build`, reading the `build: PASS` verdict line
   directly and never through a pipe. Then `sha256sum o/bin/cosmic`:
   the measured arms' digests must all differ, and a repeat means two
   arms measured the same binary and the result is void.

   **If an arm refuses to build**, record the exact failure verbatim
   as a result and drop that arm, keeping `07fc94a1c` and
   `354c17e08` — they are the pair the whole finding rests on. Do NOT
   edit the tree to make an arm build, and do NOT substitute another
   tree commit: either makes this a different experiment.

6. **The noise floor, per measured arm, first.** In each measured
   worktree, twice:

   ```
   o/bin/cosmic --make run _perf/gate.tl selfcheck \
     o/perf/aa-1.json o/perf/aa-2.json --only codec_base64_roundtrip_64k
   ```

   Record each pass's reported per-scenario delta. `floor` is the
   LARGEST absolute delta any pass on any arm showed.

7. **The readings.** Four isolated readings per measured arm,
   ALTERNATING round-robin across arms — never all of one arm then
   all of the next — each its own process:

   ```
   o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k \
     --out o/perf/<tag>-<n>.json
   ```

   Use the default `--samples`/`--min-secs`. Nothing else heavy may
   run on the machine during the readings. Record every reading's
   µs/op and its reported `±`, in run order.

   **The verdict rule, and no other.** Let `med(X)` be an arm's median
   of its four readings. For each measured arm `X` after `07fc94a1c`,
   the step is **REPRODUCED at X** iff all three hold:

   - `med(X) > med(07fc94a1c)`;
   - the two arms' four-reading ranges do not overlap;
   - `(med(X) - med(07fc94a1c)) / med(07fc94a1c) * 100 > floor`.

   Otherwise **NOT REPRODUCED at X**. State each arm's verdict with
   the three numbers that decided it. The step lands at the EARLIEST
   arm in commit order that reads REPRODUCED; the answer is that
   arm's commit together with every commit collapsed into it in (3)
   and every unmeasured commit between it and the previous measured
   arm.

8. **Write the result onto this item** with
   `gitboard spec 3ITHROpY FILE`, run from the `board` worktree.
   Replace the sidecar with these five sections unchanged plus a
   sixth, `## Result`, appended last — do not delete `## Evidence`, a
   result that erases what it was measured against cannot be re-read.
   `## Result` carries, in this order and in these shapes, because
   `Acceptance` counts them:

   - one line per FETCHED arm, starting at column 1, spelled exactly
     `- runtime <tag> <64 hex digits>` — the `o/3p/cosmos/lua` digest
     from (2);
   - one line per MEASURED arm, spelled exactly
     `- cosmic <tag> <64 hex digits>` — the `o/bin/cosmic` digest
     from (5);
   - the collapse from (3) in prose, naming which commits collapsed
     into which arm, or saying plainly that none did — prose, not a
     table, because the readings table is the only table `Acceptance`
     expects to find here;
   - one line per MEASURED arm, spelled exactly
     `- selfcheck <tag> <pass 1 delta> <pass 2 delta>`, then one line
     spelled exactly `- floor <pct>%` carrying the largest absolute
     delta any pass on any arm showed;
   - the readings as the section's ONLY markdown table, header and
     rows starting at column 1 (`| run | arm | µs/op | ± |`), one row
     per reading, in run order, each row's first cell a two-digit run
     number (`| 01 |`);
   - one line per measured arm after `07fc94a1c`, reading
     `<tag>: REPRODUCED — med 191.31 → 209.35 µs (+9.44%), ranges
     disjoint, floor 4.5%` or `<tag>: NOT REPRODUCED — ...`, with the
     three numbers the rule decided on;
   - one line starting at column 1 spelled exactly
     `moved-by: <commit-or-range>` — a single commit sha when the
     bisect landed on one, or `<sha>..<sha>` when a range survives;
   - one line starting at column 1 spelled exactly
     `follow-up: <id>` naming the item filed in (9);
   - one closing paragraph saying what the evidence supports and what
     it does not.

9. **File exactly one follow-up**, with
   `gitboard new "<title>" --parent 3HyRcW05 --spec-file F`, where F
   is one paragraph of evidence quoting the medians and the floor:

   - **a single commit identified** → file the fix: read that commit's
     diff, test the layout hypothesis against it, and land any fix in
     whilp/cosmopolitan without moving a binding contract.
   - **a range survives** (the cap in (4) split it, or an arm was
     dropped in (5)) → file the next bisect slice, naming the
     surviving range and its commit count.
   - **nothing reads REPRODUCED at any arm** → file that: the step
     did not reproduce on this hardware at all, which contradicts
     `3ISlWFiS` and is itself the finding.

## Non-goals

- **No code change anywhere, and no PR.** This is a research slice:
  its deliverable is the `## Result` section and the one follow-up
  item. Nothing lands on `main`, nothing lands in
  whilp/cosmopolitan — a fix is the follow-up's, not this slice's,
  however obvious the answer looks once the commit is named.
- **Do not build whilp/cosmopolitan locally for the arms.** The
  released `cosmos.zip` binaries are the instrument; a default-mode
  single-arch local build is a different build configuration and
  cannot be trusted against a layout hypothesis (see `## Evidence`).
- **Do not weaken, rename, resize or remove any scenario or its
  `check()`**, `codec_base64_roundtrip_64k` first among them, and do
  not pass `--samples`/`--min-secs` overrides to make readings
  cheaper. The `optimize` skill's standing rule.
- **Do not commit a pin change.** Every pin edit lives in a scratch
  worktree and is never committed or pushed. `3p/cosmos/cosmos_pin.tl`
  on `main` is untouched, and `bin/cosmic.pin` is `3ISVlHT6`'s.
- **Do not commit any `o/perf/*.json`**, and do not commit the
  worktrees.
- **Do not change the cosmic tree in any arm.** Only the two pin lines
  differ between worktrees; `5ef13f40` is the tree for all of them.
- **Do not `gitboard unblock` anything**, and do not touch
  `3ISVlHT6`. Whether its edges still bind is judged from the
  recorded result, by the reviewer.
- **Do not dispatch `release.yml`** in either repo, with or without
  `perf_gate: false`. It publishes outward; it is a human's call.
- **Do not touch `_perf/gate.tl`, `_perf/compare.tl`,
  `_perf/run.tl`, `_perf/harness.tl` or their tests.** D31 landed
  there in `ef963bab`; a measurement pass is not the place to revisit
  it.

## Acceptance

A research slice has no PR, so acceptance is the recorded evidence
plus commands a reviewer re-runs. The sidecar this slice rewrites is
`o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md`, inside the `board`
worktree `skills/work/SKILL.md` bootstraps. Every check reads only the
`## Result` section, so it counts what was measured and never what the
spec says. Run all of them from the cosmic repo root.

- The section exists:
  `grep -c '^## Result$' o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md`
  → `1`. Today: `0`.
- Every arm was fetched and its runtime hashed:
  `sed -n '/^## Result$/,$p' o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md | grep -c '^- runtime '`
  → `6`. Today: `0`.
- The measured arms are distinguishable binaries:
  `sed -n '/^## Result$/,$p' o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md | grep -c '^- cosmic '`
  → at least `2` and at most `4`, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md | grep '^- cosmic ' | awk '{print $3}' | sort -u | wc -l`
  prints the same number — a repeated digest means two arms measured
  the same binary and the result is void. Today: `0`.
- The noise floor is recorded per arm and named once:
  `sed -n '/^## Result$/,$p' o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md | grep -c '^- selfcheck '`
  → the same number as the `- cosmic ` count, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md | grep -c '^- floor '`
  → `1`. Today: `0` and `0`.
- One unindented table row per reading, plus its header — counted by
  first cell, so a separator row written either way cannot skew it:
  `sed -n '/^## Result$/,$p' o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md | grep -c '^| run \|^| [0-9][0-9] '`
  → four times the `- cosmic ` count, plus `1` for the header — so
  `9` for two measured arms, `13` for three, `17` for four. Today: `0`.
- One verdict word per measured arm after the base:
  `sed -n '/^## Result$/,$p' o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md | grep -c 'REPRODUCED'`
  → one less than the `- cosmic ` count. Today: `0`.
- The bisect states its answer and its follow-up, one line each:
  `sed -n '/^## Result$/,$p' o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md | grep -c '^moved-by: '`
  → `1`, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITHROpYatfTyy9DH2AHFHO8G7X.md | grep -c '^follow-up: 3'`
  → `1`. Today: `0` and `0`.
- The follow-up exists and quotes the numbers:
  `o/board/o/bin/gitboard show <the id on the follow-up line>` prints
  a spec whose `## Evidence` names the medians and the floor from
  `## Result`.
- The range facts the result rests on re-run true, in a
  whilp/cosmopolitan checkout after `git fetch origin --tags`:
  `git log --oneline 07fc94a1c..354c17e08 | wc -l` → `5`, and
  `git tag --list '*8dd093cea'` names `2026.08.24-8dd093cea`.
- The tree facts re-run true, in the cosmic checkout:
  `git show 5ef13f40:3p/cosmos/cosmos_pin.tl | grep version` prints
  `version = "2026.08.21-07fc94a1c"`.
- Nothing was changed in the tree to get the numbers:
  `git status --short` prints nothing, and `git diff --name-only HEAD`
  prints nothing — no source change, no pin change, no
  `o/perf/*.json`, no committed worktree. On a checkout level with
  `origin/main`, `git diff --name-only origin/main` also prints
  nothing.

## Enablement

`none needed` — every instrument this slice uses exists and was
exercised on 2026-08-26.

- The pin-swap A/B procedure is `skills/optimize/cosmopolitan.md`
  step 2 and its three sharp edges (read the build verdict, never
  trust `--version`, hash the binary). `3ISWHyP7` and `3ISlWFiS` both
  ran it on this exact tree commit and scenario, `3ISlWFiS` across
  three arms in one session — so four arms is a known-feasible size.
- The reading and noise-floor commands are `_perf/run.tl`'s
  `--only`/`--out` and `_perf/gate.tl`'s `selfcheck`, both cited by
  line under `## Evidence`.
- The release tags every arm needs are published and were listed
  today with the `git tag --list` loop above; no build of
  whilp/cosmopolitan is required, so the cosmocc toolchain download
  is not on this slice's path at all.
- The decision rule in (7) is arithmetic over numbers those two
  commands print; nothing has to be judged.

The judgements a literal-minded session could get wrong are each
walled: measuring a locally-built `lua` instead of the released one
(`Non-goals`, with the `m=rel`-versus-default evidence behind it),
editing the tree or swapping tree commits to make an arm build
(`Change` (5) states the exact fallback), and fixing the commit once
it is named (`Non-goals`, first bullet).

## Result

Measured 2026-08-26, in a session and container independent of both
`3ISWHyP7`'s and `3ISlWFiS`'s. All six release arms fetched and all
four chosen arms built — `build: PASS (515 files, 1 binary)` for each,
exit status read directly, never through a pipe. The bisect narrowed
the range from five commits to three with certainty, and then could
NOT name one, because this host was too noisy for the verdict rule's
disjoint-ranges condition. Both halves are recorded below.

**Every arm's runtime, hashed after `--make fetch`** (`sha256sum
o/3p/cosmos/lua`), in commit order:

- runtime 2026.08.21-07fc94a1c b5323f3068efd6cb664a0d56d521bd1109429f9f7f4e866c6cb830634a092c1b
- runtime 2026.08.23-bf92718a1 b5323f3068efd6cb664a0d56d521bd1109429f9f7f4e866c6cb830634a092c1b
- runtime 2026.08.23-8e071ec98 b5323f3068efd6cb664a0d56d521bd1109429f9f7f4e866c6cb830634a092c1b
- runtime 2026.08.24-5bfcf79d0 fdea2794cd65987987ec387b7b0db87bfbfc56eb93ae30ad03a551266858b385
- runtime 2026.08.24-8dd093cea dbe0fb8f4695c91c2510f9e817faa1d27c863af3592f37d413c3681a78973ddd
- runtime 2026.08.24-354c17e08 6dcc7958bd8f27dd0ce5cab0ee130d41e07d3afec30e07912261ee43757a5c95

Each `cosmos.zip` was downloaded, `sha256sum`'d, and its digest matched
against the same release's first-party `SHA256SUMS` asset before the
pin was written; all six agreed, and the base tag's digest
`03e5286bce...` is byte-identical to the one our own `5ef13f40` pin
already carried.

**The collapse: two of the five commits are inert, provably.** The
first three arms ship a byte-identical `lua`, so `bf92718a1`
(AGENTS.md only) and `8e071ec98` (sqlite3 header stubs behind untaken
guards) changed no compiled byte and cannot have moved anything; they
collapse into the `07fc94a1c` arm and were not measured. The remaining
three arms each ship a distinct runtime, so `5bfcf79d0`, `8dd093cea`
and `354c17e08` are the candidates. This also shows the release builds
are byte-reproducible for identical compiled input, which is what makes
the collapse a proof rather than an inference.

**The four measured arms** (`sha256sum o/bin/cosmic`), all distinct:

- cosmic 2026.08.21-07fc94a1c d8492168eace15f18e5d56b8949144d947e58b9dad1c4ada6401eea98e035b44
- cosmic 2026.08.24-5bfcf79d0 5794751f0b29fed9c6867bc0d6cf64f02101012f216e78d0af11519ac4ee894a
- cosmic 2026.08.24-8dd093cea 4cba7dfedf45a3774b907048c35ff47630a510460405d72b099dd3f6ecbd05ad
- cosmic 2026.08.24-354c17e08 940f21bb25c2537f890bd49230c6b5eccf4231a277ade43f2b6d523e9f9eee7c

Two of those digests are byte-identical to `3ISlWFiS`'s arms A and B
(`d8492168...` and `940f21bb...`), rebuilt here from the same tree
commit and the same pins in a different session and container. The
instrument is therefore reproducible across sessions, and any
difference in the numbers below is the host, not the binaries.

**The noise floor.** Two `gate.tl selfcheck --only
codec_base64_roundtrip_64k` passes per arm, each a same-binary A/A;
all eight printed `perf-selfcheck: nothing exceeded the bar — the
machine is quiet at this threshold`:

- selfcheck 2026.08.21-07fc94a1c -1.4% -0.1%
- selfcheck 2026.08.24-5bfcf79d0 +4.5% -5.1%
- selfcheck 2026.08.24-8dd093cea -0.1% +0.8%
- selfcheck 2026.08.24-354c17e08 +2.9% +6.5%
- floor 6.5%

That floor is materially worse than the 4.5% `3ISlWFiS` measured, and
one selfcheck sample reported a within-run spread of ±37.8%. This host
is fast but not quiet.

**The readings.** Four per arm, round-robin in the order
`07fc94a1c`, `5bfcf79d0`, `8dd093cea`, `354c17e08`, each its own
process, default `--samples`/`--min-secs`:

| run | arm | µs/op | ± |
|---|---|---|---|
| 01 | 2026.08.21-07fc94a1c | 139.06 | 9.8% |
| 02 | 2026.08.24-5bfcf79d0 | 149.94 | 10.2% |
| 03 | 2026.08.24-8dd093cea | 163.72 | 15.6% |
| 04 | 2026.08.24-354c17e08 | 185.09 | 10.3% |
| 05 | 2026.08.21-07fc94a1c | 145.24 | 10.7% |
| 06 | 2026.08.24-5bfcf79d0 | 141.92 | 3.8% |
| 07 | 2026.08.24-8dd093cea | 141.29 | 6.2% |
| 08 | 2026.08.24-354c17e08 | 167.03 | 7.8% |
| 09 | 2026.08.21-07fc94a1c | 141.61 | 14.5% |
| 10 | 2026.08.24-5bfcf79d0 | 137.29 | 3.8% |
| 11 | 2026.08.24-8dd093cea | 179.72 | 10.6% |
| 12 | 2026.08.24-354c17e08 | 189.64 | 22.5% |
| 13 | 2026.08.21-07fc94a1c | 174.27 | 12.5% |
| 14 | 2026.08.24-5bfcf79d0 | 151.11 | 6.3% |
| 15 | 2026.08.24-8dd093cea | 153.78 | 10.4% |
| 16 | 2026.08.24-354c17e08 | 175.48 | 12.4% |

Medians and ranges: `07fc94a1c` 143.43 µs [139.06, 174.27];
`5bfcf79d0` 145.93 µs [137.29, 151.11]; `8dd093cea` 158.75 µs
[141.29, 179.72]; `354c17e08` 180.28 µs [167.03, 189.64].

**The verdicts**, by the rule in `Change` (7) and nothing else:

- 2026.08.24-5bfcf79d0: NOT REPRODUCED — med 143.43 → 145.93 µs
  (+1.75%), ranges overlap, floor 6.5%; the delta is under the floor
  as well, so this pair fails two of three conditions.
- 2026.08.24-8dd093cea: NOT REPRODUCED — med 143.43 → 158.75 µs
  (+10.69%), ranges overlap, floor 6.5%; only the disjointness
  condition fails.
- 2026.08.24-354c17e08: NOT REPRODUCED — med 143.43 → 180.28 µs
  (+25.70%), ranges overlap, floor 6.5%; only the disjointness
  condition fails.

moved-by: 8e071ec98..354c17e08
follow-up: 3ITOUv0wv6OVH7bkh0RmgzmoDcl

**What this supports.** Two of the five commits are eliminated for
good, by byte-identity rather than by measurement, so the range is now
the three commits `git log --oneline 8e071ec98..354c17e08` prints:
`5bfcf79d0`, `8dd093cea`, `354c17e08`. The pin-swap instrument is
confirmed reproducible across sessions at the binary level. And the
medians rise monotonically across the three candidates, with
`354c17e08` — the 650-line `tool/net/llua.c` addition — sitting
+25.70% above the base, far past this run's floor.

**What this does not support.** It does not name the commit. Under the
verdict rule this slice was given, every pair reads NOT REPRODUCED,
because the base arm's own four readings spanned 139.06 to 174.27 µs —
a 25% internal swing, one reading (run 13) far off the other three —
and that single range overlaps every other arm. Two of three
conditions hold for `354c17e08` and the direction agrees with
`3ISlWFiS`'s confirmed +8.35%, but agreement is not the rule, and the
rule is what this slice was to apply. Nothing here weakens
`3ISlWFiS`'s finding: that was a separate, quieter measurement whose
own ranges were disjoint, and its conclusion stands untouched.

**Why no rule was changed to rescue it.** Discarding run 13, widening
the reading count, or restating the disjointness condition would each
have produced a clean answer, and each is a decision the spec encodes
rather than a fact it records — `plan`'s to make, not a measuring
session's. So the numbers are reported as the rule reads them, and
`3ITOUv0w` carries the noise-robust instrument the next pass needs,
starting from three candidates instead of five.

**The block edge stands.** `3ISVlHT6`'s wait on this item was recorded
because no release can publish while `codec_base64_roundtrip_64k`
holds the gate red. That is still true: the scenario still fails, the
commit is still unnamed, and the fix is still ahead of the pin bump.
