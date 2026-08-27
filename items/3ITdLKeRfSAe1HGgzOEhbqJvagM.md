## Goal

G6 — the defining paths, ratcheted (`docs/goals.md:123-140`), through
this item's parent `3ITVR6Ku`, whose result is "the release lane is
green again because `354c17e08`'s regression is fixed where it lives".
`3ITbccMu` reproduced that regression on local builds and ruled out the
one-line link-order fix. Nothing yet says WHERE inside the base64 path
the 20 µs went, and the two live mechanisms — compiled-code placement
of the scan loops, versus the allocator moving under a bigger image —
call for different fixes. This slice splits the scenario into its three
C calls and says which one moved. It is RESEARCH: its deliverable is a
`## Result` section on this item and exactly one follow-up item, not a
code change and not a PR in either repo.

## Evidence

All facts below measured 2026-08-27 with the commands beside them.

**What `3ITbccMu` settled** (accepted evidence on that item's
`## Result`). Three single-arch x86_64 `m=rel` builds of
whilp/cosmopolitan, measured through cosmic tree `5ef13f40`, nine
isolated round-robin readings each: arm A (`8dd093cea`) min 138.67 /
lo 138.78 / **med 143.88** / hi 147.23 µs; arm B (`354c17e08`) min
161.50 / lo 162.42 / **med 164.37** / hi 172.33 µs; arm C
(`354c17e08` with `llua.o` moved to the end of
`TOOL_LUA_LUA_MODULES`) min 160.81 / lo 161.85 / **med 166.91** / hi
168.47 µs. Noise floor from six `gate.tl selfcheck` passes: **3.7%**.
B is +14.24% over A with trimmed ranges disjoint, and the raw ranges
are disjoint too (A max 153.31 < B min 161.50). Arm C was a NULL
control — `nm` gives B and C identical addresses for every base64
symbol and identical `.text` (2790188) and APE (3000420) sizes — so it
proves only that the `tool/lua/BUILD.mk` reorder is not a fix, and
rules nothing else out. Arm A's addresses DO differ from B's:
`DecodeBase64` `0x43a49c0` → `0x43a7ca0` (`+0x32E0`), `EncodeBase64`
`0x43a4cc0` → `0x43a7fa0`, `IsBase64` `0x43a6a60` → `0x43a9d40`,
`.text` 2777412 → 2790188 (`+12776` bytes).

**The scenario is exactly three C calls, and one of them allocates
nothing.** `_perf/bench/micro_bench.tl:116-129` calls
`codec.encode_base64` then `codec.decode_base64`, which are
`cosmic/codec.tl:37` (`return cosmo.EncodeBase64(data)`) and
`cosmic/codec.tl:82-83` (`if cosmo.IsBase64(str) then return
cosmo.DecodeBase64(str) end`). Of the three, `IsBase64`
(`net/http/isbase64.c:64-79`) is a pure scan: it walks the 87 KB
encoded string one byte at a time against the 256-byte `kBase64Alpha`
table and allocates nothing. `EncodeBase64`
(`net/http/encodebase64.c:33-63`) `malloc`s the ~87 KB output;
`DecodeBase64` (`net/http/decodebase64.c:56-111`) `malloc`s ~66 KB and
`realloc`s it down. So splitting the three apart discriminates the two
live mechanisms directly: a delta on `IsBase64` cannot be the
allocator, and a delta confined to the other two cannot be the scan
loops' code placement.

**The blob is deterministic and reproducible outside the harness.**
`_perf/bench/micro_bench.tl:27-35` builds it as 1024 concatenated
`string.format("record %04d: the quick brown fox jumps over the lazy
dog %d\n", i, i * 37)` lines, which is plain Lua and needs no cosmic
module. Its base64 encoding is 87 KB and its plaintext ~64 KB.

**A raw arm binary can time this with no cosmic build at all.** The
three calls are `cosmo.*`, so `require("cosmo")` under the arm's own
`lua` reaches exactly the C code the scenario reaches, with none of
cosmic's payload in the way. The clock is
`require("unix").clock_gettime(unix.CLOCK_MONOTONIC)`, which returns
`(seconds, nanoseconds)`: run today on arm A,
`/tmp/lua-A -e 'local u=require("unix") local s,ns=u.clock_gettime(u.CLOCK_MONOTONIC) print(s,ns)'`
printed `1522	854955490`. Note that `cosmo` and `unix` are MODULES,
not globals — `/tmp/lua-A -e 'print(cosmo)'` fails with
`attempt to index a nil value (global 'cosmo')`, which is the mistake
`3ITbccMu`'s smoke command made.

**The disassembler is present.** The cosmocc toolchain
`3ITbccMu` downloaded carries
`.cosmocc/2025.12.30-0c0b4c8c8/bin/x86_64-linux-cosmo-objdump`
(`ls .cosmocc/2025.12.30-0c0b4c8c8/bin/ | grep objdump` in the
whilp/cosmopolitan checkout prints it, beside the aarch64 one).

**`perf` is NOT present**, which is why this slice does not use one:
`which perf` prints nothing on this host, and
`/proc/sys/kernel/perf_event_paranoid` is `2`. A spec built on
`perf record -g` could not run here.

**The arms are cheap to rebuild.** One whilp/cosmopolitan checkout,
`make -j$(nproc) m=rel o/rel/tool/lua/lua` at each commit — about ten
minutes cold including the cosmocc download, about ninety seconds for
the second arm — copying the APE and its `.dbg` out between builds.
`3ITbccMu` recorded the digests to check a rebuild against: arm A
runtime `a108f199fc2e37f315e988776c948ffd4e597a689075786abc8ed4a9b6e01296`,
arm B runtime `44fd5c18efbf8e9d4eac5ea9fa23b88cea196ef64995317dc87cfeb62e9115bf`.
A rebuild that reproduces those digests is the same instrument; one
that does not is a different toolchain and must be recorded as such,
which does not void the run because both arms move together.

## Change

No source file is changed on `main`, and nothing is committed or
pushed in whilp/cosmopolitan. The deliverable is a `## Result` section
on this item and one follow-up item.

1. **Two local `m=rel` runtimes.** Only arms A (`8dd093cea`) and B
   (`354c17e08`); arm C is dropped, proven null by `3ITbccMu`. If
   `/tmp/lua-A` and `/tmp/lua-B` still exist from that slice with the
   digests quoted in `## Evidence`, reuse them. Otherwise rebuild in a
   scratch, detached whilp/cosmopolitan checkout with
   `make -j$(nproc) m=rel o/rel/tool/lua/lua` at each commit, copying
   `o/rel/tool/lua/lua` to `/tmp/lua-<X>` and `o/rel/tool/lua/lua.dbg`
   to `/tmp/lua-<X>.dbg` before building the next. Record both APE
   digests either way. They must differ from each other.

2. **The split script, verbatim.** Write exactly this to
   `/tmp/b64split.lua`. Do not change `N`, `SAMPLES`, the warm-up, the
   estimator or the blob; they are this spec's decisions.

   ```lua
   local cosmo = require("cosmo")
   local unix = require("unix")
   local MONO = unix.CLOCK_MONOTONIC
   local N = 500
   local SAMPLES = 7

   local function now_ns()
     local s, ns = unix.clock_gettime(MONO)
     return s * 1000000000 + ns
   end

   local parts = {}
   for i = 1, 1024 do
     parts[i] = string.format(
       "record %04d: the quick brown fox jumps over the lazy dog %d\n",
       i, i * 37)
   end
   local BLOB = table.concat(parts)
   local ENC = cosmo.EncodeBase64(BLOB)
   assert(cosmo.IsBase64(ENC))
   assert(cosmo.DecodeBase64(ENC) == BLOB)

   local function time_call(fn)
     fn(); fn(); fn()
     local best = math.huge
     for _ = 1, SAMPLES do
       collectgarbage("collect")
       local t0 = now_ns()
       for _ = 1, N do fn() end
       local dt = (now_ns() - t0) / N
       if dt < best then best = dt end
     end
     return best / 1000.0
   end

   local enc = time_call(function() return cosmo.EncodeBase64(BLOB) end)
   local isb = time_call(function() return cosmo.IsBase64(ENC) end)
   local dec = time_call(function() return cosmo.DecodeBase64(ENC) end)
   local all = time_call(function()
     local e = cosmo.EncodeBase64(BLOB)
     if cosmo.IsBase64(e) then return cosmo.DecodeBase64(e) end
   end)

   print(string.format(
     "%s encode %.3f is %.3f decode %.3f roundtrip %.3f sum %.3f",
     arg[1] or "?", enc, isb, dec, all, enc + isb + dec))
   ```

   The three `assert`s are the correctness net: an arm whose base64 no
   longer round-trips fails here rather than producing a number.

3. **The readings: NINE per arm, round-robin.** Cycle A → B → A → B → …
   so each round samples both arms; never all of one arm then the
   other. Each reading is its own process:
   `/tmp/lua-<X> /tmp/b64split.lua <X>`. Nothing else heavy may run on
   the machine during the readings. Record all four numbers from every
   reading, in run order.

4. **The verdict rule — `3ITbccMu`'s, per column.** For each of the
   four columns (`encode`, `is`, `decode`, `roundtrip`) and each arm,
   sort that arm's nine values ascending as `r1 … r9` and take
   `med = r5`, `lo = r2`, `hi = r8`. A column reads **MOVED** iff all
   three hold: `med(B) > med(A)`; `lo(B) > hi(A)`; and
   `(med(B) - med(A)) / med(A) * 100 > 3.7` — the floor `3.7%` is
   `3ITbccMu`'s, carried over rather than re-measured, because this
   instrument's own repeatability is exercised by the seven-sample
   minimum inside every reading. Otherwise **NOT MOVED**. Do not change
   the rule, the reading count or the script mid-slice, and do not
   discard a reading as an outlier beyond that trim.

5. **The conclusion is read off this table and nothing else.** Apply
   (4) to each of `encode`, `is` and `decode`, then take the first row
   that matches, reading top to bottom:

   | `roundtrip` | `is` | other two | conclusion | follow-up to file |
   |---|---|---|---|---|
   | NOT MOVED | (any) | (any) | `not-in-this-instrument` — the raw-lua split does not see the regression the cosmic harness sees, so the delta is not in these three calls as called here | a slice that re-cuts the instrument, naming what the cosmic harness does that this script does not (payload, zipos, the Teal wrapper frames) |
   | MOVED | MOVED | both MOVED | `broad` — every part moved, including the one that allocates nothing, so it is a whole-image effect rather than one loop | a slice that tests image size directly: pad arm A's `.text` by `llua.o`'s size with dead code and see whether A alone moves to B's timing |
   | MOVED | MOVED | neither or one | `scan-loop-layout` — the pure-scan, zero-allocation call moved, so it is compiled-code placement | a slice that reads `IsBase64`'s disassembly in both arms and tests an alignment intervention on it |
   | MOVED | NOT MOVED | at least one MOVED | `allocation-path` — only the allocating calls moved, so it is the heap or the allocator under a bigger image, not the scan loops | a slice that instruments `malloc`/`realloc` placement across the two arms rather than the base64 code |
   | MOVED | NOT MOVED | neither | `unattributed` — the whole moved but no part did, which the sum line should already have flagged | a slice that re-cuts the instrument, as the first row |

   A conclusion here names a mechanism, NOT a fix: which intervention
   to make in whilp/cosmopolitan is the follow-up's own refinement, and
   this slice does not choose one.

6. **Record the disassembly of whichever call carries the delta**, and
   only that one — or of `IsBase64` when the row is `broad`, and of
   none when `roundtrip` is NOT MOVED. For each arm, with
   `<COSMOCC>/bin/x86_64-linux-cosmo-objdump -d /tmp/lua-<X>.dbg`,
   record that function's start address, its byte length (next symbol's
   address minus its own), its start address modulo 64, and the
   address modulo 64 of the target of its innermost backward branch —
   the loop head. Six numbers per arm. This section is DESCRIPTIVE: no
   verdict in (5) depends on it.

7. **Write the result onto this item** with
   `gitboard spec 3ITdLKeR FILE`, run from the `board` worktree.
   Replace the sidecar with the five sections above unchanged plus a
   sixth, `## Result`, appended last — do not delete `## Evidence`.
   `## Result` carries, in this order and in these shapes, because
   `Acceptance` counts them:

   - one line per arm, starting at column 1, spelled exactly
     `- runtime <A|B> <64 hex digits>` — the `/tmp/lua-<X>` digest from
     (1);
   - the readings as the section's ONLY markdown table, header and rows
     starting at column 1
     (`| run | arm | encode | is | decode | roundtrip |`), one row per
     reading, in run order, each row's first cell a two-digit run
     number (`| 01 |`), all four values in µs;
   - one line per arm per column, spelled exactly
     `- stats <A|B> <encode|is|decode|roundtrip> min <r1> lo <r2> med <r5> hi <r8>`,
     in µs — eight lines;
   - one line per column, spelled exactly
     `encode: MOVED — med 41.20 → 47.90 µs (+16.26%), trimmed ranges
     disjoint (hi A 42.10 < lo B 47.30), floor 3.7%` or
     `encode: NOT MOVED — ...`, with the three numbers the rule decided
     on — four lines, one each for `encode`, `is`, `decode` and
     `roundtrip`;
   - one line per arm, spelled exactly
     `- disasm <A|B> <function> start <hex> len <bytes> start%64 <n> loop%64 <n>`
     from (6), or the single line `- disasm none` when (6) says to
     record none;
   - one line starting at column 1 spelled exactly
     `mechanism: <not-in-this-instrument|broad|scan-loop-layout|allocation-path|unattributed>`
     — the (5) row that matched;
   - one line starting at column 1 spelled exactly
     `follow-up: <id>` naming the item filed in (8);
   - one closing paragraph saying what the evidence supports and what
     it does not, including whether the three parts' sum tracks the
     measured `roundtrip` on each arm.

8. **File exactly one follow-up**, with
   `gitboard new "<title>" --parent 3ITVR6Ku --spec-file F`, where F is
   one paragraph of evidence quoting both arms' per-column medians, the
   trimmed ranges and the floor, and naming the (5) row that chose it.
   Which item to file is the table's last column; file that one and no
   other. If the host it would run on lacks a tool that item needs,
   say so in that paragraph rather than filing a spec that cannot run —
   which is what `3ITbccMu` did about `perf`.

## Non-goals

- **No code change on `main`, no commit or push in whilp/cosmopolitan,
  and no PR in either repo.** The script lives at `/tmp/b64split.lua`
  and is never added to the tree; whether a per-call split belongs in
  `_perf` at all is a separate question this slice does not answer.
- **Do not build or measure in default mode.** The `-DFTRACE` padding
  (`build/config.mk:492-495,522`) and the suppressed inlining make it a
  different program from the released `m=rel` one. Both arms are
  `m=rel`, as `3ITbccMu`'s `## Evidence` establishes.
- **Do not measure arm C or rebuild it.** `3ITbccMu` proved it
  layout-identical to arm B; re-measuring it spends readings on a
  settled question.
- **Do not use a released `cosmos.zip` binary as an arm**, and do not
  mix a local build against a released one.
- **Do not build cosmic at all.** This slice measures the raw arm
  `lua` binaries; no cosmic worktree, no `--make fetch`, no
  `--make build`, no `o/3p/cosmos/lua` swap. The end-to-end number is
  `3ITbccMu`'s and is not re-measured here.
- **Do not change the script, the reading count, the sample settings
  or the rule mid-slice**, and do not discard a reading as an outlier
  beyond the trim in (4). Every row of (5) is a result, including the
  two that say the instrument missed.
- **Do not move a binding contract.** Nothing here edits
  `tool/net/definitions.lua`, a return shape, an error value or a
  constant — the freeze in both repos' AGENTS.md.
- **Do not weaken, rename, resize or remove any scenario or its
  `check()`**, `codec_base64_roundtrip_64k` first among them.
- **Do not commit a pin change.** `3p/cosmos/cosmos_pin.tl` is not
  edited anywhere, and `bin/cosmic.pin` is `3ISVlHT6`'s.
- **Do not `gitboard unblock` anything**, do not touch `3ISVlHT6`, do
  not end `3ITVR6Ku`, and do not give `3ITbccMu` a verdict.
- **Do not dispatch `release.yml`** in either repo, with or without
  `perf_gate: false`. It publishes outward; it is a human's call.
- **Do not fix `skills/optimize/cosmopolitan.md`.** Its build-mode
  error is `3ITbbvg7`'s to correct.

## Acceptance

A research slice has no PR, so acceptance is the recorded evidence plus
commands a reviewer re-runs. The sidecar this slice rewrites is
`o/board/items/3ITdLKeRfSAe1HGgzOEhbqJvagM.md`, inside the `board`
worktree `skills/work/SKILL.md` bootstraps. Every check reads only the
`## Result` section, so it counts what was measured and never what the
spec says. Run all of them from the cosmic repo root.

- The section exists:
  `grep -c '^## Result$' o/board/items/3ITdLKeRfSAe1HGgzOEhbqJvagM.md`
  → `1`. Today: `0`.
- Two distinct arms were built and hashed:
  `sed -n '/^## Result$/,$p' o/board/items/3ITdLKeRfSAe1HGgzOEhbqJvagM.md | grep -c '^- runtime '`
  → `2`, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITdLKeRfSAe1HGgzOEhbqJvagM.md | grep '^- runtime ' | awk '{print $4}' | sort -u | wc -l`
  → `2`. Today: `0`.
- Nine readings per arm, plus the header — counted by first cell, so a
  separator row written either way cannot skew it:
  `sed -n '/^## Result$/,$p' o/board/items/3ITdLKeRfSAe1HGgzOEhbqJvagM.md | grep -c '^| run \|^| [0-9][0-9] '`
  → `19`. Today: `0`.
- The order statistics are recorded for both arms across all four
  columns:
  `sed -n '/^## Result$/,$p' o/board/items/3ITdLKeRfSAe1HGgzOEhbqJvagM.md | grep -c '^- stats [AB] \(encode\|is\|decode\|roundtrip\) min .* lo .* med .* hi '`
  → `8`. Today: `0`.
- One verdict per column, and no column is missing:
  `sed -n '/^## Result$/,$p' o/board/items/3ITdLKeRfSAe1HGgzOEhbqJvagM.md | grep -c '^\(encode\|is\|decode\|roundtrip\): \(MOVED\|NOT MOVED\) '`
  → `4`. Today: `0`.
- The disassembly is recorded, or explicitly recorded as none:
  `sed -n '/^## Result$/,$p' o/board/items/3ITdLKeRfSAe1HGgzOEhbqJvagM.md | grep -c '^- disasm '`
  → `2` when (6) called for a function and `1` when it called for none.
  Today: `0`.
- The slice states its mechanism and its follow-up, one line each:
  `sed -n '/^## Result$/,$p' o/board/items/3ITdLKeRfSAe1HGgzOEhbqJvagM.md | grep -c '^mechanism: \(not-in-this-instrument\|broad\|scan-loop-layout\|allocation-path\|unattributed\)$'`
  → `1`, and
  `sed -n '/^## Result$/,$p' o/board/items/3ITdLKeRfSAe1HGgzOEhbqJvagM.md | grep -c '^follow-up: 3'`
  → `1`. Today: `0` and `0`.
- The follow-up exists, is parented under `3ITVR6Ku`, and quotes the
  numbers: `o/board/o/bin/gitboard show <the id on the follow-up line>`
  prints a spec whose evidence names both arms' per-column medians, the
  trimmed ranges and the floor, and whose `parent:` is
  `3ITVR6Ku8HQUosVXVzbpdRmldKf`.
- The script the numbers came from is the one this spec fixes:
  `grep -c 'local N = 500' /tmp/b64split.lua` → `1`,
  `grep -c 'local SAMPLES = 7' /tmp/b64split.lua` → `1`, and
  `grep -c 'collectgarbage("collect")' /tmp/b64split.lua` → `1`.
- The scenario facts the split rests on re-run true, in the cosmic
  checkout:
  `sed -n '29,32p' _perf/bench/micro_bench.tl | grep -c 'the quick brown fox jumps over the lazy dog'`
  → `1`, and `sed -n '37p;82p;83p' cosmic/codec.tl` prints the three
  `cosmo.EncodeBase64` / `cosmo.IsBase64` / `cosmo.DecodeBase64` lines.
- `IsBase64` still allocates nothing, in a whilp/cosmopolitan checkout
  after `git fetch origin --tags`:
  `grep -c 'malloc\|realloc\|calloc' net/http/isbase64.c` → `0`, while
  `grep -c 'malloc' net/http/encodebase64.c` → `1` and
  `grep -c 'malloc\|realloc' net/http/decodebase64.c` → `2`.
- Nothing was changed in either tree to get the numbers: in the cosmic
  checkout `git status --short` prints nothing and `git diff
  --name-only HEAD` prints nothing; in the whilp/cosmopolitan checkout
  the arms were built in, `git status --short` prints nothing.

## Enablement

`none needed` — every instrument this slice uses was exercised
end to end by `3ITbccMu` on 2026-08-27, and the one tool that would
have blocked it is designed out rather than waited on.

- Building both arms `m=rel` is `3ITbccMu`'s `## Change` (1), run in
  full: the cosmocc download, the two builds, and the copy-out between
  them all completed, and both digests are recorded in `## Evidence`
  for a rebuild to check itself against.
- The clock, the module-not-global calling convention and the
  disassembler are each verified in `## Evidence` with the command that
  verified them, on arm A, today.
- The script in `Change` (2) was extracted from this spec and executed
  once on arm A during this refinement, to prove it runs rather than to
  measure anything: `/tmp/lua-A /tmp/b64split.lua A` printed
  `A encode 46.181 is 27.126 decode 58.830 roundtrip 131.361 sum
  132.137`. Two things that reading establishes, neither of them a
  result: the three `assert`s pass, and the parts account for the whole
  — `sum` tracks the measured `roundtrip` within 0.6% on that arm, so
  a split that fails to add up later is a signal about the arm and not
  about the instrument. One reading on one arm decides nothing under
  (4), which needs nine on each.
- `perf` is absent on this host, so `3ITbccMu`'s prescribed
  `perf record -g` follow-up was deliberately not filed as written.
  This slice reaches the same question — where did the time go —
  through a split that needs only the arm binaries, and step (8) tells
  its own follow-up to apply the same test before filing.
- No cosmic build is on this slice's path at all, which removes the
  `o/3p/cosmos/lua` swap and its three sharp edges
  (`skills/optimize/cosmopolitan.md`, step 2) from the things that can
  go wrong.

The judgements a literal-minded session could get wrong are each
walled: indexing `cosmo` as a global (`## Evidence` shows the failure
and the fix, and the script in `Change` (2) requires it), rebuilding in
default mode because `skills/optimize/cosmopolitan.md` says releases
ship that way (`Non-goals`, with the config.mk line numbers), measuring
arm C or a released binary (`Non-goals`), tuning `N`, `SAMPLES` or the
estimator when a column comes out noisy (`Change` (2) and (4) fix
them), and choosing a fix once a mechanism is named (`Change` (5)'s
closing sentence).
