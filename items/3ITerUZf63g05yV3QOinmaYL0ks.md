## Goal

G6 — the defining paths, ratcheted (`docs/goals.md:123-140`), through
this item's parent `3ITVR6Ku`, whose result is "the release lane is
green again because `354c17e08`'s regression is fixed where it lives".
`3ITdLKeR` localized that regression to `IsBase64`'s scan loop
straddling a 64-byte instruction fetch block. This slice moves the loop
off the boundary in whilp/cosmopolitan and measures whether that
recovers the timing. Its deliverable is a `## Result` section on this
item and, if the timing recovers, one PR in whilp/cosmopolitan.

## Evidence

All facts below measured 2026-08-27 with the commands beside them.

**What `3ITdLKeR` settled** (evidence on that item's `## Result`).
Splitting `codec_base64_roundtrip_64k` into its three C calls and
timing each on two local `m=rel` arms — A = `8dd093cea`, B =
`354c17e08` — nine isolated round-robin readings apiece against a 3.7%
floor: `IsBase64` **med 27.137 → 52.445 µs, +93.26%**, trimmed ranges
disjoint (hi A 27.251 < lo B 52.238); `EncodeBase64` +0.57% and
`DecodeBase64` -0.44%, both NOT MOVED with overlapping ranges; the
roundtrip +16.13% (med 136.680 → 158.725 µs). The 25.3 µs `IsBase64`
gains is the whole 22.0 µs the roundtrip loses, and `IsBase64`
allocates nothing, so the allocator is excluded.

**The mechanism, from `objdump -d` on both `lua.dbg` files.**
`IsBase64` has IDENTICAL instruction bytes in both arms — same
167-byte body, same instructions in the same order, differing only in
two absolute operands — so this is placement, not codegen. The hot
loop is the alphabet scan: `add $0x1,%rbx` at `+0x30` through the
`jne` back to it at `+0x46`, twenty-four bytes.

- arm A: entry `0x43a6a60` (`& 0x3F` = 32), loop `0x43a6a90`-`0x43a6aa7`
  (`& 0x3F` = 16) — inside the single fetch block
  `0x43a6a80`-`0x43a6abf`.
- arm B: entry `0x43a9d40` (`& 0x3F` = 0), loop
  `0x43a9d70`-`0x43a9d87` (`& 0x3F` = 48) — straddling the boundary at
  `0x43a9d80`.

**Two levers are already ruled out, by build rather than by argument.**
Both were tried in the arm-B checkout on 2026-08-27 and both left the
disassembly bit-identical, loop still at `+0x30`:

- `forcealign(64)` on the ENTRY — this is what whilp/cosmopolitan PR
  #280 (draft) does to all three base64 functions. Arm B's entry is
  ALREADY 64-byte aligned and arm B is the slow one, so pinning the
  entry to 64 reproduces the slow layout rather than the fast one. The
  interleave recorded on `3ITbywUB` found the same thing empirically
  ("recovers nothing on the measuring host").
- `-falign-loops=64`, and then `-falign-functions=64 -falign-loops=64`
  together, added as `o/$(MODE)/net/http/isbase64.o: private CFLAGS +=`
  in `net/http/BUILD.mk`. The flags reached the compiler — the build
  log line for `isbase64.c` carries `-O2 -falign-functions=64
  -falign-loops=64` — and GCC emitted exactly the same seven-byte
  `nopl` at `+0x29` for 16-byte alignment and nothing more. Note the
  `-fno-align-*` set in `build/config.mk:229-232,247-250,266-269,301-304,315-318`
  is NOT the cause: those blocks are all inside `tiny`-family `MODE`
  guards and do not apply to `rel`. The flag route simply does not move
  this loop.

**The per-object flag idiom exists and is used here already.**
`net/http/BUILD.mk:38-56` carries two `private CFLAGS +=` blocks with
their reasons in comments (`-Os` for the ip-classifier objects, `-O3`
for `formathttpdatetime.o` "because we're dividing by constants"), and
`build/definitions.mk:216-220` gives the assembly order
`DEFAULT_CFLAGS CONFIG_CFLAGS CFLAGS OVERRIDE_CFLAGS`, so a per-object
`CFLAGS` addition is last-but-one and nothing in `rel` contradicts it.
That idiom is available if a later lever needs it; the flags themselves
are what failed, not the plumbing.

**Rebuilding an arm is one file's recompile.** After the first build,
`rm -f o/rel/net/http/isbase64.o && make -j$(nproc) m=rel
o/rel/tool/lua/lua` relinks in about ninety seconds. Deleting the
object is REQUIRED when only `BUILD.mk` changed: make does not treat
`BUILD.mk` as a prerequisite of the `.o`, and the first probe above
silently measured a stale object because of it.

**The instrument is `3ITdLKeR`'s** `/tmp/b64split.lua`, whose `is`
column is the one that matters here. It needs only the arm binaries —
no cosmic build, no `o/3p/cosmos/lua` swap. `perf` is absent on this
host (`which perf` prints nothing).

**The arms to rebuild against.** arm A runtime
`a108f199fc2e37f315e988776c948ffd4e597a689075786abc8ed4a9b6e01296`,
arm B runtime
`44fd5c18efbf8e9d4eac5ea9fa23b88cea196ef64995317dc87cfeb62e9115bf`.

## Change

1. **Arm B and arm A as they are.** In a scratch, detached
   whilp/cosmopolitan checkout at `354c17e08`, keep the existing
   `/tmp/lua-B` and `/tmp/lua-B.dbg` as the unmodified baseline; keep
   `/tmp/lua-A`/`.dbg` for reference only. Rebuild either only if it is
   missing, with `make -j$(nproc) m=rel o/rel/tool/lua/lua`, and record
   the digests either way.

2. **Arm D, the intervention.** Still at `354c17e08`, edit ONLY
   `net/http/isbase64.c`: immediately before the alphabet-scan `while`
   loop (`net/http/isbase64.c:71`, `while (p < pe && (kBase64Alpha[*p & 255] & mask))`), insert

   ```c
   asm volatile(".balign 64");
   ```

   with a comment above it saying that the loop's throughput depends on
   fitting one 64-byte fetch block, that its entry alignment is not the
   lever (`3ITdLKeR`), and that the padding executes once per call
   against an 87 KB scan. Change nothing else — not the other two
   base64 files, not `BUILD.mk`, not a compiler flag, not the loop
   body. Then `rm -f o/rel/net/http/isbase64.o && make -j$(nproc) m=rel
   o/rel/tool/lua/lua`, copy the APE to `/tmp/lua-D` and the `.dbg` to
   `/tmp/lua-D.dbg`.

3. **Verify the loop actually moved, BEFORE timing anything.** With
   `<COSMOCC>/bin/x86_64-linux-cosmo-objdump -d /tmp/lua-D.dbg`, read
   `IsBase64`'s entry address, the scan loop's address (the
   `add $0x1,%rbx` that the later `jne` targets) and that address
   `& 0x3F`, and the loop's byte length up to and including that `jne`.
   The loop reads MOVED iff `loop_address & 0x3F` plus the loop length
   is at most 64 — that is, the loop lies inside one 64-byte block.

   **If the loop did NOT move**, that is the result: record the three
   levers now ruled out (the two in `## Evidence` plus this one) with
   their disassembly, skip (4) and (5) entirely, and file the follow-up
   in (6) that the `not-moved` row names. Do not try a fourth lever —
   choosing one is a `plan` decision, and this spec fixes exactly one.

4. **Correctness, before performance.** `make -j$(nproc)
   o//tool/lua/test` in the same checkout, read directly and never
   through a pipe — the repo's stated gate
   (whilp/cosmopolitan `AGENTS.md`, "Conventions"). It builds default
   mode, so it is a cold build the first time. Also smoke arm D:
   `/tmp/lua-D -e 'local cosmo=require("cosmo") local s=("abc"):rep(21845) local e=cosmo.EncodeBase64(s) assert(cosmo.IsBase64(e)) assert(cosmo.DecodeBase64(e)==s) print("ok")'`
   must print `ok`.

5. **The readings: NINE per arm, round-robin, B and D only.** Cycle
   B → D → B → D → …; each reading is its own process,
   `/tmp/lua-<X> /tmp/b64split.lua <X>`, with `/tmp/b64split.lua` the
   script `3ITdLKeR`'s `## Change` (2) fixes verbatim — do not edit it.
   Nothing else heavy may run on the machine during the readings.
   Record all four columns from every reading, in run order.

   Apply `3ITdLKeR`'s rule to the `is` and `roundtrip` columns: sort
   each arm's nine values as `r1 … r9`, take `med = r5`, `lo = r2`,
   `hi = r8`. A column reads **RECOVERED** iff `med(D) < med(B)`,
   `hi(D) < lo(B)`, and `(med(B) - med(D)) / med(B) * 100 > 3.7`.
   Otherwise **NOT RECOVERED**. Do not change the rule, the reading
   count or the script mid-slice.

   Also state, as prose and deciding nothing, how `med(D)`'s `is`
   column compares with the 27.137 µs `3ITdLKeR` measured for arm A —
   whether the intervention reached the fast arm's timing, fell short,
   or passed it.

6. **The conclusion is read off this table and nothing else.**

   | loop moved | `is` | conclusion | what to do |
   |---|---|---|---|
   | no | — | `no-lever` — inline `.balign` did not move the loop either | file a slice for the next lever, naming all three ruled out; open no PR |
   | yes | RECOVERED | `confirmed` — fetch-block straddling is the cause and pinning the loop fixes it | open the PR in (7), then file nothing |
   | yes | NOT RECOVERED | `moved-not-fixed` — the loop no longer straddles and the timing did not follow, so straddling is not the whole cause | file a slice that returns to mechanism, carrying this negative; open no PR |

7. **Only on `confirmed`, open ONE PR in whilp/cosmopolitan** carrying
   the `net/http/isbase64.c` diff and nothing else, its body quoting
   the before/after `is` medians, both trimmed ranges, the floor, and
   the before/after loop addresses and `& 0x3F` values from (3). Say in
   it that PR #280 aligns the entry rather than the loop and is
   superseded by this — do not close #280 yourself; that is its
   author's call. Hand this item over with
   `gitboard move 3ITerUZf check --pr N`.

8. **Write the result onto this item** with
   `gitboard spec 3ITerUZf FILE`, run from the `board` worktree, in
   every case including `no-lever`. Replace the sidecar with the five
   sections above unchanged plus a sixth, `## Result`, appended last —
   do not delete `## Evidence`. `## Result` carries, in this order and
   in these shapes, because `Acceptance` counts them:

   - one line per arm built or reused, starting at column 1, spelled
     exactly `- runtime <B|D> <64 hex digits>`;
   - one line per arm, spelled exactly
     `- disasm <B|D> IsBase64 start <hex> loop <hex> loop%64 <n> looplen <bytes>`,
     from (3);
   - one line spelled exactly `- loop <moved|not-moved>`;
   - when the loop moved: one line spelled exactly
     `- tests o//tool/lua/test <PASS|FAIL>` and one spelled exactly
     `- smoke D <ok|FAIL>`, from (4);
   - when the loop moved: the readings as the section's ONLY markdown
     table, header and rows starting at column 1
     (`| run | arm | encode | is | decode | roundtrip |`), one row per
     reading in run order, each row's first cell a two-digit run
     number;
   - when the loop moved: one line per arm per column, spelled exactly
     `- stats <B|D> <is|roundtrip> min <r1> lo <r2> med <r5> hi <r8>`
     — four lines;
   - when the loop moved: one line per column, spelled exactly
     `is: RECOVERED — med 52.445 → 27.900 µs (-46.80%), trimmed ranges
     disjoint (hi D 28.100 < lo B 52.238), floor 3.7%` or
     `is: NOT RECOVERED — ...`, and the same for `roundtrip` — two
     lines;
   - one line starting at column 1 spelled exactly
     `mechanism: <no-lever|confirmed|moved-not-fixed>`;
   - one line starting at column 1 spelled exactly `pr: <N>` on
     `confirmed`, or `pr: none` otherwise;
   - one line starting at column 1 spelled exactly
     `follow-up: <id>` on `no-lever` or `moved-not-fixed`, or
     `follow-up: none` on `confirmed`;
   - one closing paragraph saying what the evidence supports and what
     it does not.

## Non-goals

- **Do not touch `net/http/encodebase64.c` or
  `net/http/decodebase64.c`.** `3ITdLKeR` measured both NOT MOVED;
  changing them widens the diff past its evidence.
- **Do not merge, close, rebase or push to whilp/cosmopolitan PR
  #280.** Superseding it is said in this slice's PR body and decided by
  its author.
- **Do not move a binding contract.** `IsBase64`'s signature, its
  return value, its `tool/net/definitions.lua` entry and the
  `kBase64Alpha` table are all unchanged; an alignment directive
  touches none of them. The freeze is in both repos' AGENTS.md.
- **Do not change the loop body, the table, or the algorithm.** A
  word-at-a-time or SIMD rewrite of the scan is a different and larger
  change; if this slice ends `no-lever` or `moved-not-fixed`, that
  rewrite is what its follow-up should consider, and it is not
  smuggled in here.
- **Do not retry a flag-based lever.** `## Evidence` records
  `-falign-loops=64` and `-falign-functions=64` reaching the compiler
  and changing nothing; re-running them spends a build on a settled
  question.
- **Do not build or measure in default mode**, and do not use a
  released `cosmos.zip` binary as an arm. Both arms are local
  single-arch `m=rel`.
- **Do not build cosmic**, do not edit `3p/cosmos/cosmos_pin.tl`, and
  do not bump `bin/cosmic.pin`. The end-to-end confirmation is a later
  item's, after a release carries the fix.
- **Do not edit `/tmp/b64split.lua`**, and do not change the reading
  count or the rule when a column comes out close.
- **Do not `gitboard unblock` anything**, do not touch `3ISVlHT6` or
  `3ITbywUB`, do not end `3ITVR6Ku`, and do not give `3ITbccMu` or
  `3ITdLKeR` a verdict.
- **Do not dispatch `release.yml`** in either repo, with or without
  `perf_gate: false`. It publishes outward; it is a human's call.

## Acceptance

The sidecar this slice rewrites is
`o/board/items/3ITerUZf63g05yV3QOinmaYL0ks.md`, inside the `board`
worktree `skills/work/SKILL.md` bootstraps. Every check reads only the
`## Result` section. Run all of them from the cosmic repo root.

- The section exists:
  `grep -c '^## Result$' o/board/items/3ITerUZf63g05yV3QOinmaYL0ks.md`
  → `1`. Today: `0`.
- Two distinct arms:
  `sed -n '/^## Result$/,$p' o/board/items/3ITerUZf63g05yV3QOinmaYL0ks.md | grep -c '^- runtime '`
  → `2`, and the same lines' `awk '{print $4}' | sort -u | wc -l` → `2`.
  Today: `0`.
- The disassembly is recorded for both arms and the loop verdict once:
  `sed -n '/^## Result$/,$p' o/board/items/3ITerUZf63g05yV3QOinmaYL0ks.md | grep -c '^- disasm [BD] IsBase64 start .* loop .* loop%64 .* looplen '`
  → `2`, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITerUZf63g05yV3QOinmaYL0ks.md | grep -c '^- loop \(moved\|not-moved\)$'`
  → `1`. Today: `0` and `0`.
- The mechanism and the two disposition lines are each stated once:
  `sed -n '/^## Result$/,$p' o/board/items/3ITerUZf63g05yV3QOinmaYL0ks.md | grep -c '^mechanism: \(no-lever\|confirmed\|moved-not-fixed\)$'`
  → `1`;
  `... | grep -c '^pr: \([0-9]\+\|none\)$'` → `1`;
  `... | grep -c '^follow-up: \(3[A-Za-z0-9]\+\|none\)$'` → `1`.
  Today: `0`, `0`, `0`.
- **When and only when `- loop moved` is present**, all of these hold,
  and when `- loop not-moved` is present each must be `0`:
  `sed -n '/^## Result$/,$p' o/board/items/3ITerUZf63g05yV3QOinmaYL0ks.md | grep -c '^| run \|^| [0-9][0-9] '`
  → `19`;
  `... | grep -c '^- stats [BD] \(is\|roundtrip\) min .* lo .* med .* hi '`
  → `4`;
  `... | grep -c '^\(is\|roundtrip\): \(RECOVERED\|NOT RECOVERED\) '`
  → `2`;
  `... | grep -c '^- tests o//tool/lua/test PASS$'` → `1`;
  `... | grep -c '^- smoke D ok$'` → `1`.
- **When and only when `mechanism: confirmed`**, the PR exists, carries
  exactly one file, and is this item's: `mcp__github__pull_request_read`
  `get_files` on the number in the `pr:` line lists exactly
  `net/http/isbase64.c`, and the item's `pr` field
  (`o/board/o/bin/gitboard show 3ITerUZf`) is that same number.
- **When `mechanism:` is not `confirmed`**, no PR was opened: the
  `pr: none` line above, and `o/board/o/bin/gitboard show 3ITerUZf`
  shows no `pr` field.
- The ruled-out levers re-run true, in a whilp/cosmopolitan checkout
  after `git fetch origin --tags`, confirming they were not silently
  re-enabled:
  `grep -c 'falign' net/http/BUILD.mk` → `0`, and
  `sed -n '132,135p' build/config.mk` prints the `rel` block with
  `-DNDEBUG -DDWARFLESS` and no `-fno-align-*`.
- The mechanism facts this slice starts from re-run true, same
  checkout: `grep -c 'malloc\|realloc\|calloc' net/http/isbase64.c` →
  `0`, and `grep -n 'while (p < pe' net/http/isbase64.c` names the
  scan loop.
- Nothing was left changed to get the numbers: in the cosmic checkout
  `git status --short` prints nothing; in the whilp/cosmopolitan
  checkout `git status --short` prints nothing (arm D's edit either
  committed onto the PR branch or reverted).

## Enablement

`none needed` — every instrument was exercised end to end on
2026-08-27, and the two levers most likely to waste a session are
already ruled out by build rather than by argument.

- Both arms exist with recorded digests, and the rebuild command,
  its cost and its one sharp edge (delete the `.o` when only
  `BUILD.mk` changed) are in `## Evidence`, each found by running it.
- `/tmp/b64split.lua` is `3ITdLKeR`'s, run eighteen times there; its
  three `assert`s are the correctness net on every reading.
- `objdump` is present in the cosmocc toolchain the arm build
  downloaded, with its path in `3ITdLKeR`'s `## Evidence`, and the
  loop it must find is named by address and by instruction in
  `## Evidence` above.
- The `.balign` lever is the one that cannot silently no-op the way
  the two flag levers did: it is an assembler directive in the
  instruction stream, so (3) reads its effect straight out of the
  disassembly before a single timing is taken — which is why (3)
  comes before (4) and (5) rather than after.
- The correctness gate is whilp/cosmopolitan's own documented one
  (`AGENTS.md`, "Conventions": `make -j$(nproc) o//tool/lua/test`),
  and it is a default-mode build, so its first run is cold — budget
  for that rather than being surprised by it.

The judgements a literal-minded session could get wrong are each
walled: measuring before checking the disassembly (`Change` (3) is
ordered first and says what to do when the loop did not move), reading
a stale object after a `BUILD.mk`-only edit (`## Evidence` names it),
retrying `forcealign(64)` or `-falign-loops` (`## Evidence` and
`Non-goals`), widening to the other two base64 files or to an
algorithmic rewrite (`Non-goals`), and opening a PR on a negative
result (`Change` (6) and (7), and the `pr: none` acceptance check).
