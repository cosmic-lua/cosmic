# Optimizing the cosmopolitan layer

chapter of the `optimize` skill (`SKILL.md` in this directory) — read
that first. this file makes C-layer optimization as mechanical as the
cosmic-layer loop: you edit C
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
   $BIN --make run _perf/run.tl --out o/perf/baseline.json
   ```

   `cp o/3p/cosmos/lua.pinned o/3p/cosmos/lua && bin/cosmic --make
   build` puts it back; so does `--make clean && --make fetch`. Check
   which one you are holding before you trust a number — that is the
   measurement-identity trap in `measurement.md`, and this procedure
   walks straight into it. Three sharp edges, each found the hard way:

   - **a failed `--make build` leaves the previous `o/bin/cosmic` in
     place.** the swap itself is reliable — the payload generator
     re-stages `base` from `o/3p/cosmos/lua` on every build — but a
     build that fails before assembly (a generate error, a compile
     error) changes nothing, and the stale binary measures happily.
     read the `build: PASS` verdict or the exit status directly; a
     pipe (`--make build | tail`) returns the pipe's status, the same
     laundering AGENTS.md warns about for `ci`.
   - **`--version` cannot identify the runtime.** the stamp's cosmos
     half is read from `3p/cosmos/cosmos_pin.tl` at embed time, so a
     binary embedded onto your local build still reports the pin's
     version. hash the binary instead (`sha256sum o/bin/cosmic`) and
     expect it to differ between baseline and current. every results
     file records the hash as `meta.bin_sha`, and the compare gate
     refuses a compare whose two sides hashed the same binary — that
     refusal is the backstop for this whole class, so treat it as a
     stale-binary diagnosis, not an obstacle.
   - **tree and runtime must agree on the `cosmo.*` surface.** the
     type generator's MODULES list (`_types/gentype.tl`) is ratcheted
     against the runtime's embedded `definitions.lua` in both
     directions, so standing in a runtime whose defs lack a module the
     tree lists (or the reverse) fails the build by design. when your
     checkout changes the surface itself, validate with
     `GENTYPE_DEFS=$COSMO/tool/net/definitions.lua` (AGENTS.md "Type
     Generation") rather than time-traveling the tree.

3. **hypothesis, then the smallest C diff that tests it** — one
   hypothesis per commit, exactly like the cosmic layer. pick from the
   board's open C-layer hypotheses (items carrying
   `--repo whilp/cosmopolitan`) or find your own (below).

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
   $BIN --make run _perf/run.tl --out o/perf/current.json
   $BIN --make run _perf/gate.tl compare o/perf/baseline.json o/perf/current.json \
     o/perf/selfb.json
   ```

6. **decide** with the same rules as the main loop: target scenario
   improved beyond its noise bar and nothing else regressed → keep;
   otherwise revert and record the failed hypothesis on its board
   item. NOTE: a C edit relinks the whole binary, so function addresses
   shift and unrelated fixed-overhead microbenchmarks
   (`hash_sha256_small`, `startup_run_*`, `net_ip_*`) routinely trip the
   regression bar on layout noise alone — this is the single most common
   false alarm at this layer. Do NOT revert a real JSON/sqlite/etc. win
   over it, even when the flag survives the gate's built-in triage: the
   decision procedure is `measurement.md`, "when a flag survives
   triage" — isolated `--only` re-measurement on both binaries.

7. **land it** (see below) and end the board item (append the result
   to its spec) when it lands.

## the interleave, when the effect is smaller than the bar

a single baseline-vs-current compare cannot resolve an effect below
the ~10% noise bar, and single runs taken minutes apart drift with the
host. the instrument for a suspected 3-8% effect is the
interleaved A/B: alternate WHOLE build+measure cycles so slow host
drift hits both sides equally, then judge by direction-consistency
across pairs, not by any one pair's magnitude.

```bash
# A = unmodified local build (stashed at step 2), B = your change
for i in 1 2 3 4; do
  cp /path/to/lua.unmodified o/3p/cosmos/lua
  bin/cosmic --make build >/dev/null || exit 1
  o/bin/cosmic --make run _perf/run.tl --only <target> \
    --out o/perf/A$i.json _perf.bench.<module>
  cp $COSMO/o/tool/lua/lua o/3p/cosmos/lua
  bin/cosmic --make build >/dev/null || exit 1
  o/bin/cosmic --make run _perf/run.tl --only <target> \
    --out o/perf/B$i.json _perf.bench.<module>
done
```

read it as pairs: B faster than its adjacent A in all (or all but one)
of four pairs is a real effect; deltas bouncing sign are not. quote the
per-pair numbers in the commit — they are more convincing than one
compare line, because they carry their own control. the full-suite
`gate.tl compare` still runs before the commit (it is what checks the
OTHER 38 scenarios); the interleave is how the target's win itself is
established when it lives under the bar.

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

- **work the backlog first**: the board's open C-layer hypotheses
  (see SKILL.md, "the hypothesis backlog") and pick one.
- **thin-wrapper scenarios with cpu/wall ≈ 1.0** — the time is inside
  one C call. read that binding's source in `tool/net/`.
- **`startup_*` scenarios** — the cosmic layer above them is already
  minimal; the floor is APE loader + zipos + Lua boot, all C.
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
  of lines into a histogram; anomalies jump out — dozens of
  `inflate()` calls at boot point at a deflated payload. grepping the
  trace for a filename or call name then answers "who and why".
- **compare cosmo's `--strace` with kernel `strace -c`.** they see
  different worlds: `--strace` logs cosmopolitan's userspace view —
  including zipos file ops that never hit the kernel (zipos serves
  from the mapped binary: CPU, not I/O) — while `strace -c` counts
  real syscalls, including libc-issued ones invisible in the userspace
  trace. a call class inflated on one side only tells you which layer
  to read. when strace can't exec an APE directly, wrap it:
  `strace -c -f sh -c '<cmd>'` and subtract the shell's own footprint.
- **look for the fast path that already exists in libc.** before
  designing a C optimization, search cosmopolitan for one already
  implemented but unreachable from Lua — when a scenario's cpu/wall
  says "kernel time", read the neighboring libc source
  (`libc/proc/`, `libc/calls/`, ...) for a cheaper primitive the
  binding doesn't use. the C library's own doc comments often name
  the exact problem you're measuring.
- **allocation-heavy bindings** — a scenario with high `alloc` whose
  wrapper is thin is allocating inside the binding; look for
  `lua_newtable` where `lua_createtable(L, narr, nrec)` fits,
  per-element string pushes that could batch, etc.

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
