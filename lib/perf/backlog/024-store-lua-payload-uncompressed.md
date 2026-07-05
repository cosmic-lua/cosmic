# 24. embedded .lua payload is deflated; every boot pays 29 inflate() calls

- status: done (2026-07-05) — selective store (shape 2) landed
- layer: cosmic (packaging — lib/cosmic/cook.mk zip flags)
- scenario: startup_run_lua, startup_run_teal

- evidence: `o/bin/cosmic --strace -e 'print("hi")'` shows 29
  `inflate()` calls at boot — every embedded `.lua` module the CLI
  loads (14 modules, ~44KB source total, plus /zip/main.lua and
  .args) is DEFLATE-compressed in the zip payload, so zipos
  decompresses it on every single invocation. The `$(cosmos_zip_bin)
  -qr` calls in lib/cosmic/cook.mk use the default compression.
- probe already measured (2026-07-05, shell-loop timing, treat as
  scouting not accept/reject): rebuilt the identical payload with
  `-0` (store) into a copy of the cosmos lua binary — inflate count
  drops to 0, boot went ~7.6ms -> ~7.0ms per invocation over 30 runs
  (~7%), binary size 6.6MB -> 8.4MB (+28%).
- hypothesis: store (don't deflate) the boot-critical payload. Two
  shapes to evaluate with the real scenarios:
  1. store everything (`-0`): simplest, +1.8MB binary.
  2. selective: store `.lua/` (what boot actually reads) and keep
     `.docs`/`skills`/`.tl` deflated — most of the win, a fraction
     of the size cost (the big compressible mass is tl.lua at
     ~700KB source, which is lazy-loaded since entry 3 — decide
     with data whether it stays deflated).
- also worth checking in the same round: `zipcopy`/release artifacts
  (cosmic-lua release builds embed the same way), and whether
  `embed.run()`-produced executables should follow suit for their
  own startup.
- correctness constraints: none behavioral — zipos serves stored and
  deflated entries identically; `bin/make ci` plus the startup
  scenarios' checks cover it. The tradeoff is purely size vs boot
  time, so quote both in the decision.
- risk: low for correctness; the real question is whether the size
  cost is acceptable — make the call with `perf-compare` numbers
  from the real harness (the probe above is shell-loop scouting).

- outcome (2026-07-05): shipped shape 2 (selective store). A
  `pack-cosmic` canned recipe in lib/cosmic/cook.mk stores the
  boot-critical payload uncompressed — `.lua/cosmic/*` (via `-qr0`),
  plus `main.lua` and `.args` (via `-qj0`) — and keeps everything
  else deflated (`.lua .tl .docs sys skills -x '.lua/cosmic/*'`),
  which leaves the big compressible masses compressed: tl.lua
  (435KB, lazy-loaded since entry 3), .docs/index.lua (648KB), and
  the .lua/types/*.d.tl declarations. lib/perf/cook.mk's `perf-bin`
  uses the same recipe so local cosmopolitan-layer measurements
  match the release packaging.
- results:
  - `--strace -e 'print(1)'` boot inflate() calls: 29 -> 0 (a strict
    syscall reduction, deterministic — not a timing probe).
  - binary size: 6,697,667 -> 6,960,395 bytes (+262KB, +3.9%) — far
    cheaper than shape 1's +28% because tl.lua/.docs/types stay
    deflated.
  - controlled A/B, both binaries assimilated to native ELF, 1800
    `-e 'print(1)'` runs each in alternating 150-run blocks (pstdev
    0.03-0.06ms): 3.267ms -> 2.936ms, -10.1% median (-11.1% min).
  - full `bin/make perf-compare` (default samples): 0 regressions,
    32/32 ok; startup rows moved -2.2% (run_lua), -6.8% (run_teal),
    -4.7% (compile_teal) but within their noise bars.
- harness note: the `startup_*` scenarios cannot resolve this win.
  They spawn the cosmic binary from inside cosmic, so cpu/wall sits
  at ~0.07-0.20 — ~80-93% of the measured wall time is the parent's
  fork/exec of a ~20MB process, not the child's boot CPU where the
  inflate() work lives. The controlled A/B above uses a tiny parent
  (python subprocess), which is why the child-boot delta is visible
  there. A future harness finding: a startup scenario with a
  minimal-footprint spawner would give the gate resolution on
  boot-CPU wins like this one.
- correctness verified: `bin/make ci` green; `unzip -t` reports no
  errors; the self-modifying welcome marker still works (welcome.tl
  appends `.cosmic/welcome-shown` via `czip.open(self,"a")` — the
  appender walks every central-dir entry's local header, and all
  512 entries remain valid under the multi-pass store/deflate/exclude
  build; welcome_test.tl passes).
- follow-up: `embed.run()`-built executables had the same problem
  (they force-deflated every embedded file, so the produced app
  inflate()d its own .lua at each launch) — now fixed, see entry 028.
  The release-artifact path was not separately re-checked (it builds
  via the same cosmic_bin recipe, so it inherits the change).
