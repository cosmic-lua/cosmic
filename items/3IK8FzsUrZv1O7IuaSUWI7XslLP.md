Research pass: 2026-08-23, per skills/optimize ("running a research
pass"), driven by four round-1 agents (full-suite baseline read, cosmic
sweep, C-layer/startup sweep, literal-vs-json probe) plus a round-2
verification pass. Tree at main 0fb444d6-equivalent; binary o/bin/cosmic
built from it. All probe numbers below are SCOUTING numbers (os.clock/
shell loops, medians of 3+), not the _perf gate; accept/reject stays
with the harness.

## Problem
~1ms of cosmic'\''s 2.3ms startup is the Lua-side boot chain, and
cosmo --strace of an empty script shows 15 boot modules each opened
TWICE from /zip back-to-back (33 total /zip opens, 0 failed): the
stock Lua file searcher probes each path template with fopen/fclose
via package.searchpath, then luaL_loadfilex reopens the winner. A
zipos open costs ~7-9µs (see the zipos capture). Rel-binary A/B
(2000 iters ×2): searchpath+loadfile 22.4-22.5µs vs bare loadfile
13.0-14.4µs → 8.1-9.5µs probe overhead per hit. Bonus: package.path
carries a DUPLICATED /zip/?.lua;/zip/?/init.lua pair — prepended by
the embed wrapper (cosmic/embed/init.tl:180) and spliced again by
cmd/cosmic/main.tl:13-14.

## Change (hypothesis)
Cosmic-layer: replace the /zip package.path prepend (embed wrapper
init.tl:179-184 and cmd/cosmic/main.tl:12-14) with a zip SEARCHER
inserted ahead of the default file searcher that calls
loadfile(template) directly per template — loadfile returns nil,err
on a miss, so the load attempt IS the probe; a hit costs one zipos
open, a miss stays an index lookup. The wrapper'\''s own entry load
already uses this exact pattern (init.tl:182: assert(loadfile(
"/zip/main.user.lua"))). Keep the /zip templates IN package.path
(searcher short-circuits ahead of them) so path introspection stays
truthful. Dedupe the duplicated pair. Expected: 15 hits × ~8.8µs ≈
130µs/exec, ~5.7% of startup_run_lua, ~13% of the Lua-side chain —
compounding across every --make child and every user artifact.
Separate mechanical follow-up: the in-project variant — searcher.tl:
249 readable() via io.open double-opens every tree hit.

## Constraints
Resolution order is contractual: manifest tree searcher (insert-at-2,
searcher.tl:361) outranks /zip, /zip outranks ./?.lua, the cosmic .tl
searcher stays last (pinned by cosmic/tl_loader_test.tl); installing
the zip searcher before install_argv_manifest preserves this.
package.path readers survive because templates stay in the path
(_cli/require_hints.tl:20, cosmic/teal.tl:20 searchpath("tl", …)).
Miss-path error lines shaped like "no file '\''/zip/<rel>.lua'\''" keep
require'\''s aggregate familiar. cosmic/embed_test.tl:250 asserts the
wrapper'\''s prepend — update deliberately.

## Risk
Low-medium: boot-path change affects every artifact and fails loudly;
converge/fixpoint machinery re-checks it. The path-dedupe half is
near-zero risk. Ambition: small and mechanical, high leverage.
