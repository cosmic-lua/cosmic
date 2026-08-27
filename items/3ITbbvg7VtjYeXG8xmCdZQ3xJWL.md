## Goal

`skills/optimize/cosmopolitan.md` stops telling a C-layer session that
default build mode is what releases ship. The released `lua` inside
cosmos.zip is `m=rel` (release.yml apelinks `o/rel/.../lua.dbg` +
`o/aarch64-rel/.../lua.dbg` into the fat binary); only `lua-debug` is
default mode — whilp/cosmopolitan's AGENTS.md already says so, and
cosmic's chapter contradicts it.

## Change

Two corrections in `skills/optimize/cosmopolitan.md`:
- the guardrail bullet ("default build mode (`MODE=` empty) is what
  releases ship ... representative"): replace with the truth — released
  `lua` is `m=rel`, `lua-debug` is default mode; a layout-sensitive
  hypothesis (function alignment, I-cache, fetch-block placement) must
  A/B `make m=rel o/rel/tool/lua/lua` on both sides, because default
  mode's `-fpatchable-function-entry=18,16` (16 NOP bytes before every
  entry) and `-fno-inline-functions-called-once` (ftrace hooks,
  build/config.mk) change every function's address, alignment and
  inlining; default mode remains representative for the ordinary "is
  this binding cheaper" question and is where --strace/--ftrace/perf
  live.
- step 1 of the loop: keep the default-mode build as the ordinary
  instrument, add the m=rel spelling for layout-sensitive work.

Evidence: this session's base64 work measured the class directly
(±93% swings on IsBase64 from placement; rel-mode A/B was the
instrument that resolved it, measurement.md already carries
`local rel` rows).

## Non-goals

No change to whilp/cosmopolitan's AGENTS.md (already correct), to
measurement.md (practice already outran the prose there), or to the
loop's structure.

## Acceptance

`--make ci` PASS (docs are linted for length only; this is prose).
The chapter no longer claims default mode ships; the m=rel A/B
spelling appears where layout-sensitive hypotheses are discussed.

## Enablement

None.
