## Goal

No silent bugs, at the C boundary: whilp/cosmopolitan's rework this month
traces almost entirely to perf PRs whose new C code shipped happy-path-only.
The contract gates (annotation coverage, arity ratchet) are strong; nothing
probes new C for signal interruption, error-path cleanup, or adversarial
input at introduction time. A short, checkable introduction bar for new C
binding code would have prevented three of the week's five fix chains.

## Evidence

Every recent fix chain in whilp/cosmopolitan originates in a perf PR:

- #239 (zip bulk bytes in C, Aug 7) spawned TWO fixes six days later:
  #252 (12cceba1) — its new read/write loops treated `rc <= 0` as fatal,
  no EINTR retry; and #251 (d862c0af) — `AppenderAddBytes` raised via
  `luaL_check*` AFTER the staged file buffer was malloc'd, leaking it on a
  wrongly typed option. The fix hoists parsing before any allocation and
  codifies the invariant in a comment; only #251 added a test.
- #243 (sparse-array json, Aug 8) shipped `sparsenull` unbounded: one
  stray huge key ({[1]=1,[2^40]=2}) meant a multi-terabyte encode. #255
  (c3201810) capped it by density six days later, found by a deliberate
  post-hoc audit, not a test or fuzzer.
- #242/#261 (MODE=rel ship, Aug 15): "no reproducible regression" held in
  default-mode local A/Bs; issue #262 (rel codegen regresses
  codec_hex_roundtrip_64k +30-38%) was filed the same afternoon the
  release shipped. Tests never run in rel mode; measure what ships.

## Direction

A checklist with teeth, applied to any PR adding or rewriting C binding
code (AGENTS.md is the docs half; where a rule is mechanically checkable,
a test in the tool/lua suite is the core half):

1. every C I/O loop handles EINTR;
2. no allocation live across a `luaL_check*` (parse options before
   buffers exist — the #251 invariant, stated once, checked everywhere);
3. every caller-controlled expansion carries a bound;
4. every new error path has a test that reaches it;
5. a perf claim for MODE=rel artifacts is measured on a MODE=rel build.
