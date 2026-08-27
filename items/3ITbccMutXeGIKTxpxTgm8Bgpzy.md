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
   `/tmp/lua-<X> -e 'local s=("abc"):rep(21845) local e=cosmo.EncodeBase64(s) assert(cosmo.IsBase64(e)) assert(cosmo.DecodeBase64(e)==s) print("ok")'`
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
   `gitboard spec @@ID@@ FILE`, run from the `board` worktree. Replace
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
`o/board/items/@@ID@@.md`, inside the `board` worktree
`skills/work/SKILL.md` bootstraps. Every check reads only the
`## Result` section, so it counts what was measured and never what the
spec says. Run all of them from the cosmic repo root.

- The section exists:
  `grep -c '^## Result$' o/board/items/@@ID@@.md`
  → `1`. Today: `0`.
- Every arm was built and hashed, and the runtimes differ:
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep -c '^- runtime '`
  → at least `2` and at most `3`, and
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep '^- runtime ' | awk '{print $4}' | sort -u | wc -l`
  prints the same number. Today: `0`.
- The measured arms are distinguishable cosmic binaries:
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep -c '^- cosmic '`
  → the same number as the `- runtime ` count, and
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep '^- cosmic ' | awk '{print $4}' | sort -u | wc -l`
  prints that number too — a repeated digest means two arms measured
  the same binary and the result is void. Today: `0`.
- The layout evidence is recorded per arm:
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep -c '^- layout .* IsBase64 .* EncodeBase64 .* DecodeBase64 .* text .* ape '`
  → the same number as the `- cosmic ` count. Today: `0`.
- The noise floor is recorded per arm and named once:
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep -c '^- selfcheck '`
  → the same number as the `- cosmic ` count, and
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep -c '^- floor '`
  → `1`. Today: `0` and `0`.
- Nine readings per measured arm, plus the header — counted by first
  cell, so a separator row written either way cannot skew it:
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep -c '^| run \|^| [0-9][0-9] '`
  → nine times the `- cosmic ` count, plus `1` for the header — so `28`
  for three measured arms and `19` for two. Today: `0`.
- The four order statistics the rule reads are recorded per arm:
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep -c '^- stats .* min .* lo .* med .* hi '`
  → the same number as the `- cosmic ` count. Today: `0`.
- One verdict per non-base arm:
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep -c 'SLOWER THAN A\|NOT SEPARATED FROM A'`
  → one less than the `- cosmic ` count. Today: `0`.
- The slice states its mechanism and its follow-up, one line each:
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep -c '^mechanism: \(layout\|not-link-position\|not-reproduced-locally\)$'`
  → `1`, and
  `sed -n '/^## Result$/,$p' o/board/items/@@ID@@.md | grep -c '^follow-up: 3'`
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
