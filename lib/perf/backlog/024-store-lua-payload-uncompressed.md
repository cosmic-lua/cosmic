# 24. embedded .lua payload is deflated; every boot pays 29 inflate() calls

- status: open
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
