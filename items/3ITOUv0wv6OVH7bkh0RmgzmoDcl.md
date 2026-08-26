## Goal

G6 — the defining paths, ratcheted (`docs/goals.md:123-140`), whose
measured half is "the existing `perf-compare` gate".
`codec_base64_roundtrip_64k` is the one scenario holding that gate red:
every scheduled `release.yml` run since `2026-08-23-d71d7f1` has failed
at the `compare against the previous release` step with the `release`
job skipped, so nothing publishes and `3ISVlHT6`'s pin bump has no
release to point at. `3ITHROpY` cut the range from five cosmos commits
to three; this slice names which of the three moved it. It is RESEARCH:
its deliverable is recorded evidence and one follow-up item, not a code
change and not a PR.

(This item is parented under G3 — an honest type layer. That
mis-parenting is inherited from `3ISlWFiS` via `3ITHROpY`, is captured
as `3IT8rb3B`, and is not this slice's to fix.)

## Evidence

All facts below measured 2026-08-26 with the commands beside them.

**Why this item exists.** `3ITHROpY` ran the bisect and could not name
a commit: its verdict rule required the two arms' raw four-reading
min/max ranges to be disjoint, and the BASE arm's own four readings
spanned 139.06 to 174.27 µs — a 25% internal swing driven by one
reading — so that single range overlapped every other arm and all three
pairs read NOT REPRODUCED. The medians still rose monotonically
(143.43 → 145.93 → 158.75 → 180.28 µs) and `354c17e08` sat +25.70%
over the base, far past that run's 6.5% noise floor. `3ITHROpY`
correctly refused to change its own rule mid-slice. Choosing the
replacement rule is this refinement's job, and `## Change` (6) states
it. The instrument is unchanged in every other respect, so the numbers
this slice produces are directly comparable with `3ITHROpY`'s.

**Two of the five commits are already eliminated, by byte-identity
rather than by measurement**, and are not re-measured here. The `lua`
runtime inside the published `cosmos.zip` is identical across
`2026.08.21-07fc94a1c`, `2026.08.23-bf92718a1` and
`2026.08.23-8e071ec98` — sha256
`b5323f3068efd6cb664a0d56d521bd1109429f9f7f4e866c6cb830634a092c1b`
for all three, from `sha256sum o/3p/cosmos/lua` after `--make fetch`
on each pin (`3ITHROpY`'s `## Result`) — so `bf92718a1` (AGENTS.md
only) and `8e071ec98` (sqlite3 header stubs behind untaken guards)
changed no compiled byte.

**The three surviving candidates**, from
`git log --oneline 8e071ec98..354c17e08` in a whilp/cosmopolitan
checkout after `git fetch origin --tags` (prints exactly 3, oldest
last):

| # | commit | subject | shape |
|---|---|---|---|
| 1 | `5bfcf79d0` | zipos: recycle the stored-member handle through a lock-free slot array (#272) | `libc/runtime/zipos-open.c` +62/-9 |
| 2 | `8dd093cea` | EncodeJson: a float always encodes carrying a `.` or an exponent (#273) | `third_party/lua/luaencodejsondata.c` +11/-1 |
| 3 | `354c17e08` | DecodeLua: a Lua-literal data parser in C, beside the JSON one (#274) | `tool/net/llua.c` +650 new |

The codec itself did not change anywhere in the range:
`git log --oneline 07fc94a1c..354c17e08 -- net/http/encodebase64.c net/http/decodebase64.c net/http/isbase64.c | wc -l`
→ `0`. The scenario's whole path is C:
`_perf/bench/micro_bench.tl:116-129` calls `cosmic/codec.tl:37,82,83`,
thin wrappers over `cosmo.EncodeBase64` / `cosmo.IsBase64` /
`cosmo.DecodeBase64`. So code layout — added or changed compiled code
moving the base64 loops across an alignment or cache boundary — is the
leading hypothesis, and "not on the base64 path" dismisses no
candidate.

**Every arm's pin is first-party and already resolved**, so no arm
needs a sha computed or a `cosmos.zip` hashed by hand. Each line below
is the `cosmos.zip` entry of that release's own `SHA256SUMS` asset,
read today with
`curl -sSL https://github.com/whilp/cosmopolitan/releases/download/<tag>/SHA256SUMS | grep cosmos.zip`:

| arm | tag | `platforms["*"].sha` |
|---|---|---|
| base | `2026.08.21-07fc94a1c` | `03e5286bce12d1080f00cdd1f2a72f634b6b0b7c0ce4e2287205d63221ef6f03` |
| c1 | `2026.08.24-5bfcf79d0` | `e47340c8aaefca87060c4bb058fec5959cf55bf8029eb3c175a892f27121085e` |
| c2 | `2026.08.24-8dd093cea` | `73972083d7cd90b65cf24b3c82d378be51314a8bb323b474bf7f6443a91c3419` |
| c3 | `2026.08.24-354c17e08` | `eae5513bc5283b684e51e6524080985505836f76c5a398f0c8c5ee68cedde380` |

The base row is byte-identical to the sha `3ITHROpY` recorded and to
the one `git show 5ef13f40:3p/cosmos/cosmos_pin.tl` already carries,
which cross-validates the other three rows' provenance.

**The tree to hold fixed is `5ef13f40`**, the same commit `3ISlWFiS`
and `3ITHROpY` used. `git log -1 --format=%h 5ef13f40` →
`5ef13f40`. It predates `bfe422e9` (#1395), which dropped narrowing
that a runtime from before it still needs, so `origin/main`'s tree is
not guaranteed to type-check against the older arms; and holding the
same tree is what makes these readings comparable with `3ITHROpY`'s.
`3ITHROpY` rebuilt two of `3ISlWFiS`'s arms byte-for-byte from it
(`o/bin/cosmic` `d8492168…` and `940f21bb…`), so the instrument is
reproducible across sessions and containers.

**The harness supports every arm.** `_perf/run.tl` takes
`--only SUB` (substring, `:59,268`) and `--out FILE`, and exits
non-zero naming the miss when `--only` matches nothing (`:282-288`).
`_perf/gate.tl selfcheck A.json B.json [--threshold PCT] <run args...>`
(`:34-35`) measures the SAME binary twice and passes run args through.
Defaults are `DEFAULT_SAMPLES = 5` and `DEFAULT_MIN_SAMPLE_SECS = 0.15`
(`_perf/harness.tl:21-22`); this slice uses them unchanged, as
`skills/optimize/measurement.md` requires for accept/reject decisions.
`--make fetch` unpacks cosmos beside the pin into `o/3p/cosmos/`, so
`sha256sum o/3p/cosmos/lua` names the runtime an arm embeds without
unzipping by hand and without `--version`, which stamps the pin rather
than the runtime.

**Cost, from `3ITHROpY`'s run.** It completed six fetches, four builds,
eight selfcheck passes and sixteen readings inside one session (board
commits `93a6e8df` 22:47:57Z → `e62e0079` 23:00:27Z). This slice runs
four fetches, four builds, eight selfcheck passes and thirty-six
readings — a little over twice the readings, comfortably one session.

## Change

No source file changes anywhere. The deliverable is a `## Result`
section on this item and one follow-up item.

1. **Four scratch worktrees, one fixed tree.** From the cosmic
   checkout, make four worktrees detached at **`5ef13f40`**, one per
   row of the pin table in `## Evidence`. In each, edit ONLY the
   `version` and `platforms["*"].sha` lines of
   `3p/cosmos/cosmos_pin.tl`, to that row's tag and sha verbatim. Do
   not compute a sha from anywhere else; if `--make fetch` rejects one,
   record the refusal verbatim as the result and stop.

2. **Fetch and hash each runtime.** In each worktree run
   `bin/cosmic --make fetch`, then `sha256sum o/3p/cosmos/lua`. Record
   all four digests. The four must differ; a repeat means two arms
   resolved the same runtime and the result is void, which is itself
   the finding to record.

3. **Build each arm.** In each worktree, `bin/cosmic --make build`,
   reading the `build: PASS` verdict line directly and never through a
   pipe. Then `sha256sum o/bin/cosmic`: the four digests must all
   differ, and a repeat voids the result the same way.

   **If an arm refuses to build**, record the exact failure verbatim
   as a result and drop that arm, keeping the base `07fc94a1c` and
   `354c17e08` — they are the pair the whole finding rests on. Do NOT
   edit the tree to make an arm build, and do NOT substitute another
   tree commit: either makes this a different experiment. A dropped
   arm leaves a range, which is what the follow-up in (9) covers.

4. **The noise floor, per arm, before any reading.** In each worktree,
   twice:

   ```
   o/bin/cosmic --make run _perf/gate.tl selfcheck \
     o/perf/aa-1.json o/perf/aa-2.json --only codec_base64_roundtrip_64k
   ```

   Record each pass's reported per-scenario delta. `floor` is the
   LARGEST absolute delta any pass on any arm showed.

5. **The readings: NINE per arm, round-robin.** Nine isolated readings
   per arm, cycling base → c1 → c2 → c3 → base → … so each round
   samples every arm once — never all of one arm then all of the next.
   Each reading is its own process:

   ```
   o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k \
     --out o/perf/<tag>-<n>.json
   ```

   Use the default `--samples`/`--min-secs`. Nothing else heavy may run
   on the machine during the readings. Record every reading's µs/op and
   its reported `±`, in run order.

   Nine, not four, is the change that answers `3ITHROpY`'s failure: it
   is the smallest odd count that leaves a seven-reading body after the
   trim in (6) discards one reading from each tail.

6. **The verdict rule, and no other.** For each arm `X`, sort its nine
   readings ascending as `r1 … r9` and take:

   - `med(X) = r5` — the median;
   - `lo(X) = r2` — the trimmed minimum, discarding the single fastest;
   - `hi(X) = r8` — the trimmed maximum, discarding the single slowest.

   A candidate arm `X` reads **REPRODUCED** iff all three hold:

   - `med(X) > med(base)`;
   - `lo(X) > hi(base)` — the two arms' TRIMMED ranges are disjoint;
   - `(med(X) - med(base)) / med(base) * 100 > floor`.

   Otherwise **NOT REPRODUCED at X**. State each candidate's verdict
   with the three numbers that decided it. This is `3ITHROpY`'s rule
   with exactly one condition hardened: disjointness is judged on the
   trimmed range, so a single outlier reading in either arm can no
   longer veto a separation. Nothing else about the instrument moved.

   Also record each arm's raw minimum `r1` in the readings summary. It
   decides NOTHING — timing noise is one-sided, so the minimum is the
   least-contaminated estimate and is worth carrying to the next pass,
   but the three conditions above are the whole rule.

   **The answer** is the EARLIEST candidate in commit order
   (`5bfcf79d0`, then `8dd093cea`, then `354c17e08`) that reads
   REPRODUCED — that arm's single commit, because all three candidates
   are measured and no unmeasured commit lies between them. A later
   candidate also reading REPRODUCED is additional movement after the
   step, not ambiguity: say so in prose and leave the answer at the
   earliest. If an arm was dropped in (3), the answer is the range from
   the last NOT REPRODUCED arm to the earliest REPRODUCED one.

7. **If no candidate reads REPRODUCED**, that is the result: record it
   with the same three numbers per arm, set `moved-by:` to
   `8e071ec98..354c17e08`, and file the escalation described in (9).
   Do not re-run the readings hoping for a quieter host, do not widen
   the reading count, and do not restate the rule — each is a decision
   this spec encodes, and changing one mid-slice is what `plan` exists
   to prevent.

8. **Write the result onto this item** with
   `gitboard spec 3ITOUv0w FILE`, run from the `board` worktree.
   Replace the sidecar with the five sections above unchanged plus a
   sixth, `## Result`, appended last — do not delete `## Evidence`, a
   result that erases what it was measured against cannot be re-read.
   `## Result` carries, in this order and in these shapes, because
   `Acceptance` counts them:

   - one line per arm, starting at column 1, spelled exactly
     `- runtime <tag> <64 hex digits>` — the `o/3p/cosmos/lua` digest
     from (2);
   - one line per arm, spelled exactly
     `- cosmic <tag> <64 hex digits>` — the `o/bin/cosmic` digest
     from (3);
   - one line per arm, spelled exactly
     `- selfcheck <tag> <pass 1 delta> <pass 2 delta>`, then one line
     spelled exactly `- floor <pct>%` carrying the largest absolute
     delta any pass on any arm showed;
   - the readings as the section's ONLY markdown table, header and rows
     starting at column 1 (`| run | arm | µs/op | ± |`), one row per
     reading, in run order, each row's first cell a two-digit run
     number (`| 01 |`);
   - one line per arm, spelled exactly
     `- stats <tag> min <r1> lo <r2> med <r5> hi <r8>`, in µs;
   - one line per CANDIDATE arm, reading
     `<tag>: REPRODUCED — med 143.43 → 180.28 µs (+25.70%), trimmed
     ranges disjoint (hi base 145.24 < lo X 167.03), floor 6.5%` or
     `<tag>: NOT REPRODUCED — ...`, with the three numbers the rule
     decided on;
   - one line starting at column 1 spelled exactly
     `moved-by: <commit-or-range>` — a single commit sha when the
     bisect landed on one, or `<sha>..<sha>` when a range survives;
   - one line starting at column 1 spelled exactly
     `follow-up: <id>` naming the item filed in (9);
   - one closing paragraph saying what the evidence supports and what
     it does not.

9. **File exactly one follow-up**, with
   `gitboard new "<title>" --parent 3HyRcW05 --spec-file F`, where F is
   one paragraph of evidence quoting the medians, the trimmed ranges
   and the floor:

   - **a single commit identified** → file the fix: read that commit's
     diff, test the layout hypothesis against it, and land any fix in
     whilp/cosmopolitan without moving a binding contract.
   - **a range survives** (an arm was dropped in (3)) → file the next
     bisect slice, naming the surviving range and its commit count.
   - **nothing reads REPRODUCED** → file the escalation: the trimmed
     rule did not separate the three candidates on this host either, so
     the next pass needs a different instrument (a quieter host, or a
     scenario shaped so the effect is not swamped), and the fix cannot
     be attributed until it does.

## Non-goals

- **No code change anywhere, and no PR.** This is a research slice: its
  deliverable is the `## Result` section and the one follow-up item.
  Nothing lands on `main`, nothing lands in whilp/cosmopolitan — a fix
  is the follow-up's, not this slice's, however obvious the answer
  looks once the commit is named.
- **Do not re-measure `bf92718a1` or `8e071ec98`.** They are eliminated
  by byte-identical runtimes, which is a proof and not a sample; adding
  them back spends readings on a settled question.
- **Do not change the verdict rule, the reading count, or the sample
  settings mid-slice**, and do not discard a reading as an outlier
  beyond the trim (6) specifies. If the rule again fails to separate,
  (7) is what to do.
- **Do not build whilp/cosmopolitan locally for the arms.** The
  released `cosmos.zip` binaries are the instrument; a default-mode
  single-arch local build is a different build configuration and cannot
  be trusted against a layout hypothesis.
- **Do not weaken, rename, resize or remove any scenario or its
  `check()`**, `codec_base64_roundtrip_64k` first among them, and do
  not pass `--samples`/`--min-secs` overrides. The `optimize` skill's
  standing rule.
- **Do not commit a pin change.** Every pin edit lives in a scratch
  worktree and is never committed or pushed. `3p/cosmos/cosmos_pin.tl`
  on `main` is untouched, and `bin/cosmic.pin` is `3ISVlHT6`'s.
- **Do not commit any `o/perf/*.json`**, and do not commit the
  worktrees.
- **Do not change the cosmic tree in any arm.** Only the two pin lines
  differ between worktrees; `5ef13f40` is the tree for all of them.
- **Do not `gitboard unblock` anything**, and do not touch `3ISVlHT6`.
  Whether its edges still bind is judged from the recorded result, by
  the reviewer.
- **Do not dispatch `release.yml`** in either repo, with or without
  `perf_gate: false`. It publishes outward; it is a human's call.
- **Do not touch `_perf/gate.tl`, `_perf/compare.tl`, `_perf/run.tl`,
  `_perf/harness.tl` or their tests.**
  [D31](../../docs/decisions/d31-gate-noise-from-every-control-pair.md)
  landed there in `ef963bab`; a measurement pass is not the place to
  revisit it.

## Acceptance

A research slice has no PR, so acceptance is the recorded evidence plus
commands a reviewer re-runs. The sidecar this slice rewrites is
`o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md`, inside the `board`
worktree `skills/work/SKILL.md` bootstraps. Every check reads only the
`## Result` section, so it counts what was measured and never what the
spec says. Run all of them from the cosmic repo root.

- The section exists:
  `grep -c '^## Result$' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md`
  → `1`. Today: `0`.
- Every arm was fetched and its runtime hashed, and the runtimes differ:
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep -c '^- runtime '`
  → at least `2` and at most `4`, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep '^- runtime ' | awk '{print $3}' | sort -u | wc -l`
  prints the same number. Today: `0`.
- The measured arms are distinguishable binaries:
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep -c '^- cosmic '`
  → the same number as the `- runtime ` count, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep '^- cosmic ' | awk '{print $3}' | sort -u | wc -l`
  prints that number too — a repeated digest means two arms measured
  the same binary and the result is void. Today: `0`.
- The noise floor is recorded per arm and named once:
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep -c '^- selfcheck '`
  → the same number as the `- cosmic ` count, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep -c '^- floor '`
  → `1`. Today: `0` and `0`.
- Nine readings per measured arm, plus the header — counted by first
  cell, so a separator row written either way cannot skew it:
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep -c '^| run \|^| [0-9][0-9] '`
  → nine times the `- cosmic ` count, plus `1` for the header — so
  `37` for four measured arms, `28` for three, `19` for two. Today: `0`.
- The four order statistics the rule reads are recorded per arm:
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep -c '^- stats .* min .* lo .* med .* hi '`
  → the same number as the `- cosmic ` count. Today: `0`.
- One verdict word per candidate arm:
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep -c 'REPRODUCED'`
  → one less than the `- cosmic ` count. Today: `0`.
- The bisect states its answer and its follow-up, one line each:
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep -c '^moved-by: '`
  → `1`, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITOUv0wv6OVH7bkh0RmgzmoDcl.md | grep -c '^follow-up: 3'`
  → `1`. Today: `0` and `0`.
- The follow-up exists and quotes the numbers:
  `o/board/o/bin/gitboard show <the id on the follow-up line>` prints a
  spec whose `## Evidence` names the medians, the trimmed ranges and
  the floor from `## Result`.
- The range facts the result rests on re-run true, in a
  whilp/cosmopolitan checkout after `git fetch origin --tags`:
  `git log --oneline 8e071ec98..354c17e08 | wc -l` → `3`, and
  `git tag --list '*8dd093cea'` names `2026.08.24-8dd093cea`.
- Each arm's pin sha is the release's own:
  `curl -sSL https://github.com/whilp/cosmopolitan/releases/download/2026.08.24-354c17e08/SHA256SUMS | grep cosmos.zip`
  prints `eae5513bc5283b684e51e6524080985505836f76c5a398f0c8c5ee68cedde380`.
- The tree facts re-run true, in the cosmic checkout:
  `git show 5ef13f40:3p/cosmos/cosmos_pin.tl | grep version` prints
  `version = "2026.08.21-07fc94a1c"`.
- Nothing was changed in the tree to get the numbers:
  `git status --short` prints nothing, and `git diff --name-only HEAD`
  prints nothing — no source change, no pin change, no `o/perf/*.json`,
  no committed worktree. On a checkout level with `origin/main`,
  `git diff --name-only origin/main` also prints nothing.

## Enablement

`none needed` — every instrument this slice uses exists and was
exercised end to end on 2026-08-26 by `3ITHROpY`, which ran the same
procedure at four arms and a smaller reading count.

- The pin-swap A/B procedure is `skills/optimize/cosmopolitan.md`
  step 2 and its three sharp edges (read the build verdict, never trust
  `--version`, hash the binary). `3ISWHyP7`, `3ISlWFiS` and `3ITHROpY`
  each ran it on this exact tree commit and scenario.
- The reading and noise-floor commands are `_perf/run.tl`'s
  `--only`/`--out` and `_perf/gate.tl`'s `selfcheck`, both cited by
  line under `## Evidence`.
- All four release tags are published and all four `cosmos.zip` shas
  are recorded above from first-party `SHA256SUMS`, so no build of
  whilp/cosmopolitan is required and the cosmocc toolchain download is
  not on this slice's path.
- The rule in (6) is arithmetic over numbers those two commands print;
  nothing has to be judged. The one thing it asks that `3ITHROpY` did
  not is sorting nine readings and reading off `r1`, `r2`, `r5`, `r8`.

The judgements a literal-minded session could get wrong are each
walled: measuring a locally-built `lua` instead of the released one
(`Non-goals`, with the `m=rel`-versus-default evidence behind it in
`3ITHROpY`), editing the tree or swapping tree commits to make an arm
build (`Change` (3) states the exact fallback), softening the rule when
it again fails to separate (`Change` (7) and `Non-goals`), and fixing
the commit once it is named (`Non-goals`, first bullet).

## Result

Measured 2026-08-26, in a session and container independent of
`3ISWHyP7`'s, `3ISlWFiS`'s and `3ITHROpY`'s. All four arms fetched and
built — `build: PASS (515 files, 1 binary)` for each, exit status read
directly, never through a pipe. The bisect answers: the step is at
`354c17e08`, alone, with the other two candidates flat.

**Every arm's runtime, hashed after `--make fetch`** (`sha256sum
o/3p/cosmos/lua`), in commit order — all four distinct:

- runtime 2026.08.21-07fc94a1c b5323f3068efd6cb664a0d56d521bd1109429f9f7f4e866c6cb830634a092c1b
- runtime 2026.08.24-5bfcf79d0 fdea2794cd65987987ec387b7b0db87bfbfc56eb93ae30ad03a551266858b385
- runtime 2026.08.24-8dd093cea dbe0fb8f4695c91c2510f9e817faa1d27c863af3592f37d413c3681a78973ddd
- runtime 2026.08.24-354c17e08 6dcc7958bd8f27dd0ce5cab0ee130d41e07d3afec30e07912261ee43757a5c95

All four are byte-identical to the digests `3ITHROpY` recorded. The
base arm needed no pin edit at all: `5ef13f40`'s committed
`3p/cosmos/cosmos_pin.tl` already carries tag `2026.08.21-07fc94a1c`
and sha `03e5286bce…`, so `git status --short` in that worktree printed
nothing, which cross-validates the three shas taken from the other
releases' first-party `SHA256SUMS`.

**The four measured arms** (`sha256sum o/bin/cosmic`), all distinct:

- cosmic 2026.08.21-07fc94a1c d8492168eace15f18e5d56b8949144d947e58b9dad1c4ada6401eea98e035b44
- cosmic 2026.08.24-5bfcf79d0 5794751f0b29fed9c6867bc0d6cf64f02101012f216e78d0af11519ac4ee894a
- cosmic 2026.08.24-8dd093cea 4cba7dfedf45a3774b907048c35ff47630a510460405d72b099dd3f6ecbd05ad
- cosmic 2026.08.24-354c17e08 940f21bb25c2537f890bd49230c6b5eccf4231a277ade43f2b6d523e9f9eee7c

All four are byte-identical to `3ITHROpY`'s, and two of them to
`3ISlWFiS`'s before that. Three sessions in three containers have now
rebuilt these arms to the same bytes, so the instrument is
reproducible and any difference in the numbers below is the host.

**The noise floor.** Two `gate.tl selfcheck --only
codec_base64_roundtrip_64k` passes per arm, each a same-binary A/A; all
eight printed `perf-selfcheck: nothing exceeded the bar — the machine
is quiet at this threshold`:

- selfcheck 2026.08.21-07fc94a1c -0.6% -0.9%
- selfcheck 2026.08.24-5bfcf79d0 -0.3% -3.2%
- selfcheck 2026.08.24-8dd093cea +2.5% +1.9%
- selfcheck 2026.08.24-354c17e08 +0.7% +1.3%
- floor 3.2%

This host is materially quieter than `3ITHROpY`'s, whose floor was
6.5%, and quieter than `3ISlWFiS`'s 4.5%.

**The readings.** Nine per arm, round-robin in the order `07fc94a1c`,
`5bfcf79d0`, `8dd093cea`, `354c17e08`, each its own process, default
`--samples`/`--min-secs`:

| 01 | 2026.08.21-07fc94a1c | 142.57 | 2.5% |
| 02 | 2026.08.24-5bfcf79d0 | 144.41 | 2.2% |
| 03 | 2026.08.24-8dd093cea | 144.13 | 4.4% |
| 04 | 2026.08.24-354c17e08 | 174.67 | 5.1% |
| 05 | 2026.08.21-07fc94a1c | 146.52 | 5.4% |
| 06 | 2026.08.24-5bfcf79d0 | 141.69 | 3.8% |
| 07 | 2026.08.24-8dd093cea | 143.70 | 1.5% |
| 08 | 2026.08.24-354c17e08 | 170.41 | 2.9% |
| 09 | 2026.08.21-07fc94a1c | 143.72 | 38.4% |
| 10 | 2026.08.24-5bfcf79d0 | 148.03 | 1.7% |
| 11 | 2026.08.24-8dd093cea | 143.42 | 2.3% |
| 12 | 2026.08.24-354c17e08 | 173.14 | 21.1% |
| 13 | 2026.08.21-07fc94a1c | 145.69 | 8.9% |
| 14 | 2026.08.24-5bfcf79d0 | 162.05 | 11.0% |
| 15 | 2026.08.24-8dd093cea | 146.11 | 8.1% |
| 16 | 2026.08.24-354c17e08 | 171.54 | 4.0% |
| 17 | 2026.08.21-07fc94a1c | 144.29 | 2.5% |
| 18 | 2026.08.24-5bfcf79d0 | 145.42 | 3.3% |
| 19 | 2026.08.24-8dd093cea | 143.71 | 3.4% |
| 20 | 2026.08.24-354c17e08 | 178.32 | 22.1% |
| 21 | 2026.08.21-07fc94a1c | 149.19 | 4.4% |
| 22 | 2026.08.24-5bfcf79d0 | 149.49 | 9.2% |
| 23 | 2026.08.24-8dd093cea | 147.06 | 8.4% |
| 24 | 2026.08.24-354c17e08 | 173.03 | 3.2% |
| 25 | 2026.08.21-07fc94a1c | 143.50 | 2.1% |
| 26 | 2026.08.24-5bfcf79d0 | 145.01 | 7.8% |
| 27 | 2026.08.24-8dd093cea | 140.06 | 2.2% |
| 28 | 2026.08.24-354c17e08 | 176.14 | 4.8% |
| 29 | 2026.08.21-07fc94a1c | 145.72 | 4.9% |
| 30 | 2026.08.24-5bfcf79d0 | 143.06 | 3.0% |
| 31 | 2026.08.24-8dd093cea | 145.52 | 2.4% |
| 32 | 2026.08.24-354c17e08 | 175.10 | 3.2% |
| 33 | 2026.08.21-07fc94a1c | 141.61 | 6.7% |
| 34 | 2026.08.24-5bfcf79d0 | 143.56 | 5.0% |
| 35 | 2026.08.24-8dd093cea | 144.62 | 1.8% |
| 36 | 2026.08.24-354c17e08 | 173.38 | 1.7% |
The four order statistics the rule reads, per arm, in µs — `min` is
reported as evidence for any later pass and decides nothing:

- stats 2026.08.21-07fc94a1c min 141.61 lo 142.57 med 144.29 hi 146.52
- stats 2026.08.24-5bfcf79d0 min 141.69 lo 143.06 med 145.01 hi 149.49
- stats 2026.08.24-8dd093cea min 140.06 lo 143.42 med 144.13 hi 146.11
- stats 2026.08.24-354c17e08 min 170.41 lo 171.54 med 173.38 hi 176.14

**The verdicts**, by the rule in `Change` (6) and nothing else:

- 2026.08.24-5bfcf79d0: NOT REPRODUCED — med 144.29 → 145.01 µs
  (+0.50%), trimmed ranges overlap (hi base 146.52 > lo X 143.06),
  floor 3.2%; the delta is under the floor as well, so this arm fails
  two of three conditions.
- 2026.08.24-8dd093cea: NOT REPRODUCED — med 144.29 → 144.13 µs
  (-0.11%), trimmed ranges overlap (hi base 146.52 > lo X 143.42),
  floor 3.2%; the median is BELOW the base, so all three conditions
  fail.
- 2026.08.24-354c17e08: REPRODUCED — med 144.29 → 173.38 µs (+20.16%),
  trimmed ranges disjoint (hi base 146.52 < lo X 171.54), floor 3.2%.

moved-by: 354c17e08
follow-up: 3ITVR6Ku8HQUosVXVzbpdRmldKf

**What this supports.** The step is `354c17e08` — "DecodeLua: a
Lua-literal data parser in C, beside the JSON one (#274)" — and only
that commit. It is the earliest candidate to clear the rule and the
only one; all three candidates were measured, so no unmeasured commit
lies between them and no range survives. The two arms before it are
flat to within half a percent of the base, in opposite directions,
which is what a null result looks like. The separation is not marginal:
`354c17e08`'s slowest reading of nine (178.32 µs) and the base's
fastest (141.61 µs) are 26% apart, so the RAW nine-reading ranges are
disjoint too ([141.61, 149.19] against [170.41, 178.32]) and the
un-trimmed rule `3ITHROpY` was given would have returned the same
answer on this host. The trim was not what decided it; the quieter host
was. And +20.16% sits beside the +21.0% the release gate itself
recorded for this scenario on 2026-08-24, quoted in D31 — two
instruments, one number.

**What this does not support.** It does not say WHY. The base64 sources
are untouched across the whole range
(`git log --oneline 07fc94a1c..354c17e08 -- net/http/encodebase64.c net/http/decodebase64.c net/http/isbase64.c | wc -l`
→ `0`), so code layout — 650 new lines of compiled C moving the base64
loops across an alignment or cache boundary — remains a hypothesis this
slice tested nothing about. It is also a measurement on one host: the
+20.16% magnitude is this container's, and the four sessions on record
put the effect anywhere from +7.8% to +25.70%. What has now reproduced
four times is the direction and the attribution, not the size.
`3ITVR6Ku` carries the fix, with the layout hypothesis and the
local-build A/B rule that testing it requires.

**The block edge stands.** `3ISVlHT6`'s wait was recorded because no
release can publish while `codec_base64_roundtrip_64k` holds the gate
red. That is still true — the scenario still fails and the fix is still
ahead of the pin bump — but the blocker is now a named commit with a
filed item rather than an open question.
