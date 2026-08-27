## Goal

G6 — the defining paths, ratcheted (`docs/goals.md:123-140`), through
this item's parent `3ITVR6Ku`, whose result is "the release lane is
green again because `354c17e08`'s regression is fixed where it lives".
`3ITOUv0w` named the commit; `3ITVR6Ku` cannot state a `## Change` in
whilp/cosmopolitan until something says WHY that commit moved the
number, because the two candidate mechanisms call for opposite fixes.
This slice answers that. It is RESEARCH: its deliverable is a
`## Result` section on this item and exactly one follow-up item, not a
code change and not a PR in either repo.

## Evidence

All facts below measured 2026-08-27 with the commands beside them.

**What is already settled.** `3ITOUv0w` (accepted) attributed the
`codec_base64_roundtrip_64k` regression to cosmos commit `354c17e08`
— median +20.16% over base `07fc94a1c`, trimmed ranges disjoint (base
hi 146.52 µs < candidate lo 171.54 µs), against a 3.2% same-binary
noise floor from eight `gate.tl selfcheck` passes. Its two neighbours
read +0.50% and -0.11% with overlapping ranges. That is not re-measured
here.

**The commit adds code and touches nothing on the base64 path.**
`git show --stat 354c17e08` in a whilp/cosmopolitan checkout prints
`7 files changed, 991 insertions(+)` and no deletions: `tool/net/llua.c`
+650, `tool/lua/test_llua.lua` +268, `tool/net/definitions.lua` +26,
`tool/lua/lcosmo.c` +23, `tool/net/llua.h` +17, `tool/lua/BUILD.mk` +6,
`tool/net/BUILD.mk` +1. The scenario's whole path is C —
`_perf/bench/micro_bench.tl:115-129` calls `cosmic/codec.tl:37,82,83`,
thin wrappers over `cosmo.EncodeBase64` / `cosmo.IsBase64` /
`cosmo.DecodeBase64` — and none of its three sources changed:
`git log --oneline 07fc94a1c..354c17e08 -- net/http/encodebase64.c net/http/decodebase64.c net/http/isbase64.c | wc -l`
→ `0`.

**The one structural change is link position.** `git show 354c17e08 --
tool/lua/BUILD.mk` inserts `o/$(MODE)/tool/net/llua.o` into
`TOOL_LUA_LUA_MODULES` between `ljson.o` and `lsqlite3.o`, so every
object linked after that point shifts by `llua.o`'s size, and the whole
image grows. All three base64 routines are byte-at-a-time scalar loops
that a shift like that can move across an alignment or I-cache
boundary: `IsBase64` (`net/http/isbase64.c:64-79`, 79 lines) walks the
87 KB encoded string one byte per iteration against a 256-byte
`kBase64Alpha` table; `DecodeBase64`
(`net/http/decodebase64.c:56-111`, 111 lines) does the same against a
256-byte `kBase64` table; `EncodeBase64`
(`net/http/encodebase64.c:33-63`, 63 lines) reads three bytes and
writes four per iteration out of a 64-byte `CHARS` literal. Each of
the two decode routines also `malloc`s a 64-87 KB buffer per call and
`DecodeBase64` `realloc`s it down, so image growth moving the heap is a
second layout mechanism this experiment does not distinguish from the
first, and does not need to.

**The released `lua` is `m=rel`, not default mode.** This is the fact
that decides the instrument, and `skills/optimize/cosmopolitan.md`
currently states the opposite (captured as `3ITbbvg7`; that capture
is context, not a blocker — this spec states the corrected fact and
does not depend on the doc being fixed first). In a whilp/cosmopolitan
checkout, `sed -n '28,108p' .github/workflows/release.yml` shows the
x86_64 lane running `make -j$(nproc) m=rel o/rel/tool/lua/lua.dbg`, the
aarch64 lane `make -j$(nproc) m=aarch64-rel o/aarch64-rel/tool/lua/lua.dbg`,
and `Create fat APE binaries` apelinking exactly those two into
`o/fat/bin/lua` — which is the `lua` that `Create cosmos.zip` packs and
that cosmic pins. In `build/config.mk`, default mode (line 12) sets
`ENABLE_FTRACE = 1`, which adds `-DFTRACE` and
`-fno-inline-functions-called-once` (line 492-495) and
`-fpatchable-function-entry=18,16` on x86_64 (line 522) — sixteen bytes
of NOP padding before every function entry and suppressed inlining —
while `m=rel` (line 132) adds only `-DNDEBUG -DDWARFLESS` and `-O2`.
Every function's address, alignment and inlining therefore differs
between the two modes, so a default-mode build cannot test a layout
hypothesis about a rel binary. Both arms here are built `m=rel`.

**The APE target exists in every mode.** `tool/lua/BUILD.mk:17-18`
declares `TOOL_LUA_COMS = o/$(MODE)/tool/lua/lua`, and
`build/rules.mk:26` is the `o/$(MODE)/%: o/$(MODE)/%.dbg` rule that
apelinks it, so `make -j$(nproc) m=rel o/rel/tool/lua/lua` yields a
runnable single-arch APE.

**The harness supports every arm.** `_perf/run.tl` takes
`--only SUB` (substring, `:59,268`) and `--out FILE`, and exits
non-zero naming the miss when `--only` matches nothing (`:282-288`).
`_perf/gate.tl selfcheck A.json B.json [--threshold PCT] <run args...>`
(`:34-35`) measures the SAME binary twice and passes run args through.
Defaults are `DEFAULT_SAMPLES = 5` and `DEFAULT_MIN_SAMPLE_SECS = 0.15`
(`_perf/harness.tl:21-22`), used unchanged here as
`skills/optimize/measurement.md` requires for accept/reject decisions.
The runtime a cosmic build embeds onto is whatever sits at
`o/3p/cosmos/lua`, so standing a local build in is one `cp`
(`skills/optimize/cosmopolitan.md`, step 2).

**The tree to hold fixed is `5ef13f40`**, the same commit `3ISlWFiS`,
`3ITHROpY` and `3ITOUv0w` used; `git log -1 --format=%h 5ef13f40` →
`5ef13f40`. It predates `bfe422e9` (#1395), which dropped narrowing an
older runtime still needs. Holding one tree across the arms is what
makes the arms differ only by their runtime.

**The host.** `uname -m` → `x86_64`, `nproc` → `4`. Single-arch x86_64
is what this slice builds; the release is a fat two-arch apelink, so
these binaries are not byte-comparable to the released one. That is
accepted: the question is whether the CHANGE moves the number under the
release's compiler flags, and both sides of every comparison here are
built the same way.

## Change

No source file is changed on `main`, and nothing is committed or pushed
in whilp/cosmopolitan. The deliverable is a `## Result` section on this
item and one follow-up item.

1. **Three local `m=rel` runtimes, one whilp/cosmopolitan checkout.**
   Work in a scratch clone or worktree of whilp/cosmopolitan, detached,
   never on a branch that gets pushed. Build each arm and copy the
   resulting APE somewhere stable before building the next, because
   each build overwrites `o/rel/tool/lua/lua`:

   - **arm A**, the parent: check out `8dd093cea`, run
     `make -j$(nproc) m=rel o/rel/tool/lua/lua`, copy the result to
     `/tmp/lua-A`.
   - **arm B**, the suspect: check out `354c17e08`, same build, copy to
     `/tmp/lua-B`.
   - **arm C**, the link-order control: still at `354c17e08`, edit ONLY
     `tool/lua/BUILD.mk`, moving the single line
     `o/$(MODE)/tool/net/llua.o` from its position between `ljson.o`
     and `lsqlite3.o` to the END of the `TOOL_LUA_LUA_MODULES` list.
     Change nothing else — not `tool/net/BUILD.mk`, not a C file, not a
     compiler flag. Rebuild and copy to `/tmp/lua-C`.

   The first build downloads the cosmocc toolchain into `.cosmocc/` and
   needs a network once; the later two are incremental. `sha256sum
   /tmp/lua-A /tmp/lua-B /tmp/lua-C` must print three distinct digests.
   A repeat means an arm did not rebuild and the result is void, which
   is itself the finding to record.

   **If an arm refuses to build**, record the exact failure verbatim as
   a result and drop that arm, keeping A and B — they are the pair the
   reproduction rests on. Do not edit C sources to make an arm build.

2. **Smoke each runtime before measuring it.** For each arm,
   `/tmp/lua-<X> -e 'local cosmo=require("cosmo") local s=("abc"):rep(21845) local e=cosmo.EncodeBase64(s) assert(cosmo.IsBase64(e)) assert(cosmo.DecodeBase64(e)==s) print("ok")'`
   must print `ok`. An arm that does not is dropped as in (1).

3. **Record each arm's base64 layout.** For each arm, from the same
   build's `o/rel/tool/lua/lua.dbg` (copy it beside the APE before
   rebuilding), run `nm o/rel/tool/lua/lua.dbg` and read off the
   addresses of `IsBase64`, `EncodeBase64` and `DecodeBase64`, and of
   `kBase64Alpha`, `kBase64` and any `CHARS` local symbol if the symbol
   table carries them — record `absent` for any it does not, which is a
   legitimate outcome under `-DDWARFLESS` and decides nothing. Also
   record `size o/rel/tool/lua/lua.dbg` and the APE's byte size from
   `wc -c`. This section is DESCRIPTIVE: it is read alongside the
   timings, and no verdict in (6) depends on it.

4. **Three cosmic worktrees, one fixed tree.** From the cosmic
   checkout, make three worktrees detached at **`5ef13f40`**, one per
   arm. In each: `bin/cosmic --make fetch` (this lands the pinned
   cosmos, which is where `zip`/`unzip` come from), then
   `cp /tmp/lua-<X> o/3p/cosmos/lua`, then `bin/cosmic --make build`,
   reading the `build: PASS` verdict line directly and never through a
   pipe. Then `sha256sum o/bin/cosmic` in each: the digests must all
   differ, and a repeat voids the result the same way. Do not edit any
   `.tl` file in any worktree, and do not edit
   `3p/cosmos/cosmos_pin.tl` — the pin stays at `07fc94a1c` in all
   three, because the pin decides nothing once the runtime is
   overwritten and leaving it identical keeps the arms differing by
   exactly one file.

5. **The noise floor, per arm, before any reading.** In each worktree,
   twice:

   ```
   o/bin/cosmic --make run _perf/gate.tl selfcheck \
     o/perf/aa-1.json o/perf/aa-2.json --only codec_base64_roundtrip_64k
   ```

   Record each pass's reported per-scenario delta. `floor` is the
   LARGEST absolute delta any pass on any arm showed.

6. **The readings and the verdict rule — `3ITOUv0w`'s, unchanged.**
   Nine isolated readings per arm, cycling A → B → C → A → … so each
   round samples every arm once; never all of one arm then all of the
   next. Each reading is its own process, run from that arm's worktree
   with the default `--samples`/`--min-secs`:

   ```
   o/bin/cosmic --make run _perf/run.tl --only codec_base64_roundtrip_64k \
     --out o/perf/<arm>-<n>.json
   ```

   Nothing else heavy may run on the machine during the readings.
   Record every reading's µs/op and its reported `±`, in run order.

   For each arm `X`, sort its nine readings ascending as `r1 … r9` and
   take `med(X) = r5`, `lo(X) = r2` (trimmed minimum), `hi(X) = r8`
   (trimmed maximum). Arm `X` reads **SLOWER THAN A** iff all three
   hold: `med(X) > med(A)`; `lo(X) > hi(A)`; and
   `(med(X) - med(A)) / med(A) * 100 > floor`. Otherwise **NOT
   SEPARATED FROM A**. Also record each arm's raw minimum `r1`; it
   decides nothing. Do not change the rule, the reading count or the
   sample settings mid-slice, and do not discard a reading as an
   outlier beyond that trim.

7. **The conclusion is read off this table and nothing else.** Apply
   the rule to B and to C against A, then take the row that matches:

   | B vs A | C vs A | conclusion | follow-up to file |
   |---|---|---|---|
   | SLOWER | NOT SEPARATED | `layout` — the regression is `llua.o`'s link POSITION, not its content; moving one line in `tool/lua/BUILD.mk` restores the base timing | the fix slice in whilp/cosmopolitan, carrying arm C's exact `BUILD.mk` diff and these numbers |
   | SLOWER | SLOWER | `not-link-position` — the slowdown survives an arbitrary link-order perturbation, so it is image growth, heap placement or something the perturbation did not move | a profile slice: `perf record -g` on `o/rel/tool/lua/lua.dbg` for arms A and B on this scenario, comparing where the cycles went |
   | NOT SEPARATED | (either) | `not-reproduced-locally` — the effect does not appear between two single-arch `m=rel` local builds, so it lives in the fat apelink, the release toolchain, or the released-binary instrument | a slice that re-measures the two RELEASED arms on this host with the same rule, to decide whether `3ITOUv0w`'s separation survives a second host before any C change is designed |

   A conclusion of `layout` is a finding about the mechanism, NOT
   permission to land arm C's diff: whether a link-order shuffle is an
   acceptable fix, or whether the base64 loops should instead be made
   layout-insensitive, is a decision for the follow-up's own
   refinement, and this slice does not make it.

8. **Write the result onto this item** with
   `gitboard spec 3ITbccMutXeGIKTxpxTgm8Bgpzy FILE`, run from the `board` worktree. Replace
   the sidecar with the five sections above unchanged plus a sixth,
   `## Result`, appended last — do not delete `## Evidence`. `## Result`
   carries, in this order and in these shapes, because `Acceptance`
   counts them:

   - one line per arm, starting at column 1, spelled exactly
     `- runtime <A|B|C> <64 hex digits>` — the `/tmp/lua-<X>` digest
     from (1);
   - one line per arm, spelled exactly
     `- cosmic <A|B|C> <64 hex digits>` — the `o/bin/cosmic` digest
     from (4);
   - one line per arm, spelled exactly
     `- layout <A|B|C> IsBase64 <addr> EncodeBase64 <addr> DecodeBase64 <addr> text <bytes> ape <bytes>`,
     from (3), each `<addr>` a hex address or `absent`, followed by a
     free-form sentence naming the table symbols found or `absent`;
   - one line per arm, spelled exactly
     `- selfcheck <A|B|C> <pass 1 delta> <pass 2 delta>`, then one line
     spelled exactly `- floor <pct>%` carrying the largest absolute
     delta any pass on any arm showed;
   - the readings as the section's ONLY markdown table, header and rows
     starting at column 1 (`| run | arm | µs/op | ± |`), one row per
     reading, in run order, each row's first cell a two-digit run
     number (`| 01 |`);
   - one line per arm, spelled exactly
     `- stats <A|B|C> min <r1> lo <r2> med <r5> hi <r8>`, in µs;
   - one line per arm other than A, reading
     `B: SLOWER THAN A — med 144.29 → 173.38 µs (+20.16%), trimmed
     ranges disjoint (hi A 146.52 < lo B 171.54), floor 3.2%` or
     `B: NOT SEPARATED FROM A — ...`, with the three numbers the rule
     decided on;
   - one line starting at column 1 spelled exactly
     `mechanism: <layout|not-link-position|not-reproduced-locally>` —
     the (7) row that matched;
   - one line starting at column 1 spelled exactly
     `follow-up: <id>` naming the item filed in (9);
   - one closing paragraph saying what the evidence supports and what
     it does not.

9. **File exactly one follow-up**, with
   `gitboard new "<title>" --parent 3ITVR6Ku --spec-file F`, where F is
   one paragraph of evidence quoting the three arms' medians, the
   trimmed ranges and the floor, and naming the (7) row that chose it.
   Which item to file is the table's last column; file that one and no
   other.

## Non-goals

- **No code change on `main`, no commit or push in whilp/cosmopolitan,
  and no PR in either repo.** Arm C's `BUILD.mk` edit lives in a scratch
  checkout and is recorded as a diff in `## Result`, never landed —
  however obvious the answer looks once the numbers are in. Landing it
  is the follow-up's, and (7) says why.
- **Do not build or measure in default mode.** Both the `-DFTRACE`
  padding and the suppressed inlining make it a different program;
  `## Evidence` has the line numbers. Every arm is `m=rel`.
- **Do not mix a local build against a released one.** All three arms
  are local `m=rel` builds from one checkout with one toolchain, per
  `skills/optimize/cosmopolitan.md` step 2.
- **Do not change the verdict rule, the reading count, or the sample
  settings mid-slice**, and do not discard a reading as an outlier
  beyond the trim in (6). If B and C both read NOT SEPARATED, that is
  the third row of (7) and it is a result, not a failed run to repeat
  on a quieter host.
- **Do not re-measure the released arms** or re-run `3ITOUv0w`'s
  bisect. Its attribution is accepted and is this slice's premise.
- **Do not move a binding contract.** Nothing here edits
  `tool/net/definitions.lua`, a return shape, an error value or a
  constant — the freeze in both repos' AGENTS.md — and arm C is a link
  ORDER change, which touches none of them.
- **Do not weaken, rename, resize or remove any scenario or its
  `check()`**, `codec_base64_roundtrip_64k` first among them, and do
  not pass `--samples`/`--min-secs` overrides. The `optimize` skill's
  standing rule.
- **Do not commit a pin change.** `3p/cosmos/cosmos_pin.tl` is not
  edited in any worktree, and `bin/cosmic.pin` is `3ISVlHT6`'s.
- **Do not commit any `o/perf/*.json`**, and do not commit the
  worktrees.
- **Do not `gitboard unblock` anything**, do not touch `3ISVlHT6`, and
  do not end `3ITVR6Ku` — it stays open as this slice's parent until
  its fix lands.
- **Do not dispatch `release.yml`** in either repo, with or without
  `perf_gate: false`. It publishes outward; it is a human's call.
- **Do not fix `skills/optimize/cosmopolitan.md`.** The mode error is
  captured as `3ITbbvg7` and is that item's to correct; this spec
  states the right fact and needs nothing from the doc.

## Acceptance

A research slice has no PR, so acceptance is the recorded evidence plus
commands a reviewer re-runs. The sidecar this slice rewrites is
`o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md`, inside the `board` worktree
`skills/work/SKILL.md` bootstraps. Every check reads only the
`## Result` section, so it counts what was measured and never what the
spec says. Run all of them from the cosmic repo root.

- The section exists:
  `grep -c '^## Result$' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md`
  → `1`. Today: `0`.
- Every arm was built and hashed, and the runtimes differ:
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep -c '^- runtime '`
  → at least `2` and at most `3`, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep '^- runtime ' | awk '{print $4}' | sort -u | wc -l`
  prints the same number. Today: `0`.
- The measured arms are distinguishable cosmic binaries:
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep -c '^- cosmic '`
  → the same number as the `- runtime ` count, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep '^- cosmic ' | awk '{print $4}' | sort -u | wc -l`
  prints that number too — a repeated digest means two arms measured
  the same binary and the result is void. Today: `0`.
- The layout evidence is recorded per arm:
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep -c '^- layout .* IsBase64 .* EncodeBase64 .* DecodeBase64 .* text .* ape '`
  → the same number as the `- cosmic ` count. Today: `0`.
- The noise floor is recorded per arm and named once:
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep -c '^- selfcheck '`
  → the same number as the `- cosmic ` count, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep -c '^- floor '`
  → `1`. Today: `0` and `0`.
- Nine readings per measured arm, plus the header — counted by first
  cell, so a separator row written either way cannot skew it:
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep -c '^| run \|^| [0-9][0-9] '`
  → nine times the `- cosmic ` count, plus `1` for the header — so `28`
  for three measured arms and `19` for two. Today: `0`.
- The four order statistics the rule reads are recorded per arm:
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep -c '^- stats .* min .* lo .* med .* hi '`
  → the same number as the `- cosmic ` count. Today: `0`.
- One verdict per non-base arm:
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep -c 'SLOWER THAN A\|NOT SEPARATED FROM A'`
  → one less than the `- cosmic ` count. Today: `0`.
- The slice states its mechanism and its follow-up, one line each:
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep -c '^mechanism: \(layout\|not-link-position\|not-reproduced-locally\)$'`
  → `1`, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITbccMutXeGIKTxpxTgm8Bgpzy.md | grep -c '^follow-up: 3'`
  → `1`. Today: `0` and `0`.
- The follow-up exists, is parented here, and quotes the numbers:
  `o/board/o/bin/gitboard show <the id on the follow-up line>` prints a
  spec whose evidence names the three medians, the trimmed ranges and
  the floor, and whose `parent:` is `3ITVR6Ku`'s full id.
- The build-mode fact the instrument rests on re-runs true, in a
  whilp/cosmopolitan checkout after `git fetch origin --tags`:
  `grep -c 'm=rel o/rel/tool/lua/lua.dbg' .github/workflows/release.yml`
  → `1`, and `sed -n '132,135p' build/config.mk` prints the `rel` block
  with `-DNDEBUG -DDWARFLESS`, and `sed -n '520,523p' build/config.mk`
  prints `-fpatchable-function-entry=18,16` inside the ftrace guard.
- The commit facts re-run true, same checkout:
  `git show --stat 354c17e08 | tail -1` names `7 files changed, 991
  insertions(+)`, and
  `git log --oneline 07fc94a1c..354c17e08 -- net/http/encodebase64.c net/http/decodebase64.c net/http/isbase64.c | wc -l`
  → `0`.
- The tree fact re-runs true, in the cosmic checkout:
  `git show 5ef13f40:3p/cosmos/cosmos_pin.tl | grep version` prints
  `version = "2026.08.21-07fc94a1c"`.
- Nothing was changed in the tree to get the numbers: in the cosmic
  checkout `git status --short` prints nothing and `git diff
  --name-only HEAD` prints nothing — no source change, no pin change,
  no `o/perf/*.json`, no committed worktree.
- Arm C was never committed: in the scratch whilp/cosmopolitan checkout
  the arms were built in, `git status --short` prints nothing (the
  `BUILD.mk` edit reverted after the build) and `git log -1 --format=%H`
  prints `354c17e087f7c9b8f58c051deb2e00b83bd08334`.

## Enablement

`none needed` — every instrument exists and each half has been
exercised end to end.

- The pin-swap A/B procedure and the `o/3p/cosmos/lua` stand-in are
  `skills/optimize/cosmopolitan.md` step 2, with its three sharp edges
  (read the build verdict, never trust `--version`, hash the binary).
  `3ISWHyP7`, `3ISlWFiS`, `3ITHROpY` and `3ITOUv0w` each ran the
  worktree-per-arm half on this exact tree commit and scenario.
- The reading and noise-floor commands are `_perf/run.tl`'s
  `--only`/`--out` and `_perf/gate.tl`'s `selfcheck`, both cited by
  line under `## Evidence`. The rule in (6) is `3ITOUv0w`'s, arithmetic
  over numbers those two commands print.
- Building whilp/cosmopolitan is that repo's own documented one-liner
  (`AGENTS.md`, "Building"): Linux + GNU make, the first build fetching
  cosmocc into `.cosmocc/` with a network, incremental afterwards. The
  `m=rel` variant is the release workflow's own command, quoted in
  `## Evidence`.
- The one doc a session would otherwise trust and be misled by is
  `skills/optimize/cosmopolitan.md`'s claim that default mode is what
  releases ship. It is captured as `3ITbbvg7`, and `## Evidence`
  states the corrected fact with its line numbers, so this slice does
  not wait on that item.

The judgements a literal-minded session could get wrong are each
walled: building default mode because the skill says so (`## Evidence`
and `Non-goals`, with the config.mk line numbers behind both), landing
arm C's diff once it looks like the answer (`Change` (7) and the first
`Non-goals` bullet), softening the rule when an arm fails to separate
(`Change` (6) and (7)'s third row), and reaching for a released binary
as one of the arms (`Non-goals`).

## Result

Measured 2026-08-27 on one host (`uname -m` → `x86_64`,
`Intel(R) Xeon(R) Processor @ 2.80GHz`, `nproc` → `4`), following
`## Change` (1)-(7) with one correction noted at the end.

- runtime A a108f199fc2e37f315e988776c948ffd4e597a689075786abc8ed4a9b6e01296
- runtime B 44fd5c18efbf8e9d4eac5ea9fa23b88cea196ef64995317dc87cfeb62e9115bf
- runtime C fdb21a6ee2f0f8e52f53ad19d4379913af6fb2250178812b5e923d3c8e6da215
- cosmic A 9d81999474055f1066f35422c250a1b44ccc21190839c2cf0987d2b753440044
- cosmic B f1ab6b39a24f0a49f01a7a3043d46cfafbbbe4ad1969dcce4bce3f8c0fd9dc95
- cosmic C 884f59a41692ba8fe0c7a23c8377fb069d6cc15092cf42ce73720822b034a72a

All three runtimes built `m=rel` from one whilp/cosmopolitan worktree
with cosmocc `2025.12.30-0c0b4c8c8`, all three `bin/cosmic --make build`
runs read `build: PASS (515 files, 1 binary)`, and all six digests
differ. Each runtime passed the smoke in (2) printing `ok`.

- layout A IsBase64 0x43a6a60 EncodeBase64 0x43a4cc0 DecodeBase64 0x43a49c0 text 2777412 ape 2987717 — `kBase64` at `0x444cd20` and `kBase64Alpha` at `0x444dda0`; no `CHARS` symbol (it is a string literal, not an object), so `absent` for that one.
- layout B IsBase64 0x43a9d40 EncodeBase64 0x43a7fa0 DecodeBase64 0x43a7ca0 text 2790188 ape 3000420 — `kBase64` at `0x4450040` and `kBase64Alpha` at `0x44510c0`; `CHARS` absent for the same reason.
- layout C IsBase64 0x43a9d40 EncodeBase64 0x43a7fa0 DecodeBase64 0x43a7ca0 text 2790188 ape 3000420 — `kBase64` at `0x4450040` and `kBase64Alpha` at `0x44510c0`; `CHARS` absent for the same reason.

Arms B and C are identical in every one of those numbers while their
binaries differ (`- runtime` digests above), and arm A differs from
both: `DecodeBase64` moved `0x43a49c0` → `0x43a7ca0`, `+0x32E0`, and
`.text` grew 2777412 → 2790188, `+12776` bytes.

- selfcheck A -3.5% -0.8%
- selfcheck B +0.0% +0.2%
- selfcheck C -1.5% -3.7%
- floor 3.7%

| run | arm | µs/op | ± |
|---|---|---|---|
| 01 | A | 138.78 | 4.3% |
| 02 | B | 162.42 | 1.8% |
| 03 | C | 161.85 | 6.4% |
| 04 | A | 144.84 | 35.0% |
| 05 | B | 164.35 | 2.9% |
| 06 | C | 167.62 | 32.7% |
| 07 | A | 138.87 | 1.5% |
| 08 | B | 178.06 | 2.8% |
| 09 | C | 170.17 | 7.3% |
| 10 | A | 138.67 | 3.5% |
| 11 | B | 165.71 | 5.7% |
| 12 | C | 160.81 | 1.2% |
| 13 | A | 153.31 | 14.8% |
| 14 | B | 167.84 | 8.1% |
| 15 | C | 166.77 | 3.4% |
| 16 | A | 143.88 | 13.4% |
| 17 | B | 164.37 | 2.7% |
| 18 | C | 166.91 | 5.5% |
| 19 | A | 143.80 | 3.7% |
| 20 | B | 162.82 | 7.4% |
| 21 | C | 164.37 | 25.9% |
| 22 | A | 144.21 | 4.3% |
| 23 | B | 161.50 | 4.7% |
| 24 | C | 167.26 | 10.2% |
| 25 | A | 147.23 | 6.6% |
| 26 | B | 172.33 | 5.4% |
| 27 | C | 168.47 | 9.8% |

- stats A min 138.67 lo 138.78 med 143.88 hi 147.23
- stats B min 161.50 lo 162.42 med 164.37 hi 172.33
- stats C min 160.81 lo 161.85 med 166.91 hi 168.47

B: SLOWER THAN A — med 143.88 → 164.37 µs (+14.24%), trimmed ranges disjoint (hi A 147.23 < lo B 162.42), floor 3.7%

C: SLOWER THAN A — med 143.88 → 166.91 µs (+16.00%), trimmed ranges disjoint (hi A 147.23 < lo C 161.85), floor 3.7%

mechanism: not-link-position

follow-up: 3ITdLKeRfSAe1HGgzOEhbqJvagM

What this supports. `354c17e08` really does cost this scenario about
20 µs, and it does so on locally built single-arch `m=rel` binaries —
the first time the regression has been reproduced anywhere other than
the released fat artifacts. The separation is not marginal: both
candidate arms clear all three conditions of (6), and their RAW
nine-reading ranges are disjoint from A's too (A max 153.31 < C min
160.81 < B min 161.50), which the rule does not require. The
measurement-identity traps are closed — six distinct digests, three
`build: PASS` lines read directly, one cosmic tree at `5ef13f40` across
all three arms with no `.tl` edit and no pin edit, and the readings
taken round-robin so host drift hits every arm equally. This also
retires the possibility that `3ITOUv0w`'s attribution was an artifact
of the release toolchain or of the fat apelink: it is not.

What this does NOT support, and the honest weakness of this run. Arm C
was meant to be an arbitrary layout perturbation, and it was a NULL
one. Moving `o/$(MODE)/tool/net/llua.o` within `TOOL_LUA_LUA_MODULES`
left every base64 address, the `.text` size and the APE size
bit-for-bit identical to arm B, so the arm perturbed nothing that could
have mattered and its +16.00% is a restatement of B's +14.24%, not
independent evidence. The `mechanism:` line above is therefore true in
the narrow sense the (7) table's condition tests — that one-line
`tool/lua/BUILD.mk` reorder is not a fix, and nobody should spend
another session on it — and it must NOT be read as "layout is ruled
out". Layout remains wide open: arm A's base64 routines sit at
different addresses and different 64-byte offsets from arm B's
(`DecodeBase64` and `EncodeBase64` are 64-byte aligned in A and
32-byte-offset in B; `IsBase64` is the reverse), and this run
distinguishes that from image growth, heap placement and everything
else not at all. Designing a control that actually shifts compiled
code is the next refinement's job, not this slice's, which is why (7)'s
prescribed follow-up — find where the time went before designing
another control — is the right one regardless of how weakly the row was
reached.

One departure from `## Change`, recorded rather than hidden. Step (2)'s
smoke command indexed a global `cosmo`, which does not exist: the
binding surface is a module, so the command was run as
`/tmp/lua-<X> -e 'local cosmo=require("cosmo") local s=("abc"):rep(21845) local e=cosmo.EncodeBase64(s) assert(cosmo.IsBase64(e)) assert(cosmo.DecodeBase64(e)==s) print("ok")'`
and step (2) above has been corrected in place to match. Nothing else in
the spec was changed, and no other command was altered. Two further
notes for whoever re-runs this: the readings were driven from a shell
loop whose field extraction was wrong, so the µs and ± in the table
above were read back out of the `o/perf/r-*.json` files each run wrote
(`results[1].wall_ns / 1000` and `results[1].spread_pct`) rather than
off the console — the same numbers from the same runs, by a different
path; and the follow-up filed is (7) row two's item in purpose but not
in instrument, because `perf` is not installed on this host (`which
perf` → nothing) and a spec built on `perf record -g` could not have
passed its own enablement check. The follow-up says so and names the
profiler-free split it uses instead.
