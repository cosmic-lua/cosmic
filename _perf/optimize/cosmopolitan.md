# Optimizing the cosmopolitan layer

chapter of `_perf/OPTIMIZE.md` — read that first. this file makes
C-layer optimization as mechanical as the cosmic-layer loop: you edit C
in a whilp/cosmopolitan checkout, rebuild a `lua` binary locally in
seconds, stand it in as the runtime a cosmic build embeds onto, and
judge it with the same scenarios and the same compare gate. no release,
no pin bump, no CI round-trip until the change has already proven itself.

## what lives in this layer

- the `cosmo.*` C bindings: `tool/net/*.c` (ljson, lsqlite3, lre,
  lpath, lfuncs, largon2, lfetch, ...) and `tool/lua/lcosmo.c`
- the Lua 5.4 interpreter itself: `third_party/lua/`
- the libc every syscall wrapper goes through: `libc/`
- the APE loader and zip filesystem that dominate `startup_*`
  scenarios: `ape/`, `libc/runtime/`, `libc/zipos/`

every cosmic scenario exercises this layer; a scenario whose cosmic
wrapper is already thin (see `finding.md`, "when the wrapper is already
thin") is measuring almost nothing else.

## prerequisites

- a checkout of whilp/cosmopolitan (any path; `~/cosmopolitan` in the
  examples below). Linux + GNU make, x86_64 or aarch64.
- the first build downloads the cosmocc toolchain into `.cosmocc/`
  (network needed once); after that everything is hermetic.

## the loop

```bash
COSMO=~/cosmopolitan   # your checkout
BENCH=$(ls _perf/bench/*_bench.tl | sed 's|/|.|g;s|\.tl$||')
```

1. **build the UNMODIFIED local binary** (cold: a few minutes; warm
   after a one-file edit: ~2 seconds):

   ```bash
   make -C $COSMO -j$(nproc) o//tool/lua/lua
   ```

2. **wrap it in the cosmic payload and baseline it.** never judge a C
   change against the pinned release binary — pin vs local differs by
   toolchain and commit drift. A/B two local builds that differ only by
   your change:

   The wrapping is one copy, and there is no verb for it because it
   needs none: a cosmic is its payload embedded onto a RUNTIME, and the
   runtime a build uses is whatever sits at `o/3p/cosmos/lua` — the
   place `--make fetch` unpacks the pinned one. Put your build there
   and the next `--make build` embeds onto it.

   ```bash
   # keep the pinned runtime, then stand yours in its place
   cp o/3p/cosmos/lua o/3p/cosmos/lua.pinned
   cp $COSMO/o/tool/lua/lua o/3p/cosmos/lua
   bin/cosmic --make build          # o/bin/cosmic now runs on YOUR lua

   BIN=o/bin/cosmic
   $BIN --make run _perf/run.tl --out o/perf/baseline.json $BENCH
   ```

   `cp o/3p/cosmos/lua.pinned o/3p/cosmos/lua && bin/cosmic --make
   build` puts it back; so does `--make clean && --make fetch`. Check
   which one you are holding before you trust a number — that is the
   measurement-identity trap in `measurement.md`, and this procedure
   walks straight into it.

3. **hypothesis, then the smallest C diff that tests it** — one
   hypothesis per commit, exactly like the cosmic layer. pick from the
   open `perf`-labeled issues in whilp/cosmopolitan or find your own
   (below).

4. **gate 1 — correctness:**

   ```bash
   make -C $COSMO -j$(nproc) o//tool/lua/test   # upstream binding tests, <1s warm
   ```

   this also enforces the `definitions.lua` annotation ratchet: every
   binding must keep its `@param`/`@return` annotations in sync (cosmic
   generates its Teal types from them — AGENTS.md "Type Generation").
   scenario `check()`s are the second correctness net: a C change that
   breaks output fails `perf` itself in step 5. for anything touching a
   binding's behavior, also smoke the affected cosmic module directly:
   `o/bin/cosmic -e '...'`.

5. **gate 2 — performance:**

   ```bash
   make -C $COSMO -j$(nproc) o//tool/lua/lua
   # re-embed onto the new lua, measure, compare
   cp $COSMO/o/tool/lua/lua o/3p/cosmos/lua
   bin/cosmic --make build
   $BIN --make run _perf/run.tl --out o/perf/current.json $BENCH
   $BIN --make run _perf/gate.tl compare o/perf/baseline.json o/perf/current.json \
     o/perf/selfb.json $BENCH
   ```

6. **decide** with the same rules as the main loop: target scenario
   improved beyond its noise bar and nothing else regressed → keep;
   otherwise revert and record the failed hypothesis on the backlog
   issue. NOTE: a C edit relinks the whole binary, so function addresses
   shift and unrelated fixed-overhead microbenchmarks
   (`hash_sha256_small`, `startup_run_*`, `net_ip_*`) routinely trip the
   regression bar on layout noise alone — this is the single most common
   false alarm at this layer. Do NOT revert a real JSON/sqlite/etc. win
   over it. Confirm with `gate.lua selfcheck` on the same binary (an A/A
   control): if the flagged scenario swings as much
   comparing the modified binary to itself, it is noise, not your change
   (entry 21 hit exactly this). `optimize/measurement.md` has the
   playbook.

7. **land it** (see below) and close the backlog issue (comment the
   result) when it lands.

## landing a C-layer win

the pinned binary only changes through a release, so shipping is a
two-repo dance — but only AFTER the local loop already proved the win:

1. PR the C change to whilp/cosmopolitan (its AGENTS.md has the repo's
   own conventions). quote the local `perf-compare` numbers in the PR.
2. once merged, the release workflow publishes a new cosmos release
   tagged `YYYY.MM.DD-<sha>` with a `cosmos.zip` + SHA256SUMS.
3. in cosmic: bump `3p/cosmos/cosmos_pin.tl` (version + sha256). there is
   no separate regen step — `_types/gentype.tl` is a pure library with
   no `is_main` entry, so `--make run` on it is a no-op; every graph
   verb (`--make build`, `--make ci`, ...) runs `_types/types_gen.tl`
   first and it regenerates `o/_types/types_gen` from the new pin (see
   AGENTS.md "Type Generation"). so: `bin/cosmic --make build`, fix any
   wrapper breakage, `--make ci`, and a `gate.tl compare` against a
   baseline taken on the OLD pin — this final compare is the end-to-end
   confirmation, quoted in the bump commit.

## finding C-layer opportunities

- **work the backlog first**: `gh issue list --repo whilp/cosmopolitan
  --label perf --state open` and pick one.
- **thin-wrapper scenarios with cpu/wall ≈ 1.0** — the time is inside
  one C call. read that binding's source in `tool/net/`.
- **`startup_*` scenarios** — nothing in cosmic moves them anymore
  (backlog entries 3 and 4 took the cosmic-side wins); the remaining
  floor is APE loader + zipos + Lua boot, all C.
- **decompose with the raw binary.** `$COSMO/o/tool/lua/lua -e '...'`
  boots the same runtime without cosmic's ~6MB zip payload; the gap
  between it and `startup_run_lua` splits payload cost from boot floor.
- **trace, don't guess.** default-mode cosmopolitan binaries have
  built-in tracing: `o/bin/cosmic --strace script.lua` logs
  every syscall, `--ftrace` logs every C function call — both are
  cheap ways to see where a scenario's non-CPU time goes or spot
  redundant syscalls. for CPU profiles, `$COSMO/o/tool/lua/lua.dbg`
  is a plain ELF with symbols, so Linux `perf record -g` /
  `perf report` work on it directly.
- **count call shapes from `--strace`.** pipe the trace through
  `grep -o '[a-z_]*(' | sort | uniq -c | sort -rn` to turn thousands
  of lines into a histogram; anomalies jump out (29 `inflate()` calls
  per cosmic boot became entry 24). grepping the trace for a
  filename or call name then answers "who and why".
- **compare cosmo's `--strace` with kernel `strace -c`.** they see
  different worlds: `--strace` logs cosmopolitan's userspace view
  (including zipos file ops that never hit the kernel), while
  `strace -c` counts real syscalls. the diff localizes cost — cosmic
  boot shows 35 zipos openats userspace-side but only ~10 kernel
  openats (zipos serves from the mapped binary: CPU, not I/O), and
  kernel-side revealed ~195 rt_sigprocmask calls invisible in the
  userspace trace (entry 27). when strace can't exec an APE
  directly, wrap it: `strace -c -f sh -c '<cmd>'` and subtract the
  shell's own footprint.
- **look for the fast path that already exists in libc.** before
  designing a C optimization, search cosmopolitan for one already
  implemented but unreachable from Lua — the posix_spawn/vfork case
  (entry 26) was found by reading `libc/proc/` after `child_spawn`'s
  cpu/wall said "kernel time". the C library's own doc comments
  often name the exact problem you're measuring.
- **allocation-heavy bindings** — a scenario with high `alloc` whose
  wrapper is thin is allocating inside the binding; look for
  `lua_newtable` where `lua_createtable(L, narr, nrec)` fits (entry
  21), per-element string pushes that could batch, etc.

## guardrails specific to this layer

- binding contracts are frozen at the C boundary too: return shapes,
  error values (`nil, err` vs `-1` vs raised error), and constants are
  what `definitions.lua` documents and what cosmic's generated types
  encode. a contract change is a separate, deliberate commit with a
  cosmic-side type regen — never part of an optimization.
- keep the fork mergeable: whilp/cosmopolitan tracks upstream
  jart/cosmopolitan. prefer surgical diffs in the files listed above;
  don't reformat or restructure around them.
- measure both binaries in the same tree state. `--make build`
  re-embeds the CURRENT cosmic payload — so if you edit cosmic-side
  `.tl` files between baseline and compare, you are no longer measuring
  your C change alone. Only the runtime under `o/3p/cosmos/lua` should
  differ between the two.
- default build mode (`MODE=` empty) is what releases ship (-O2 with
  ftrace hooks and SYSDEBUG, same as the pin), so relative comparisons
  between two default-mode local builds are representative. don't
  baseline in one MODE and compare in another.
