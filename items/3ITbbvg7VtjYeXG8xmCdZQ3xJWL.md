`skills/optimize/cosmopolitan.md` tells a C-layer session that the local
default build mode is what releases ship, and it is not. Two places say
it: step 6 ("a C edit relinks the whole binary…") is fine, but the
guardrail bullet reads "default build mode (`MODE=` empty) is what
releases ship (-O2 with ftrace hooks and SYSDEBUG, same as the pin), so
relative comparisons between two default-mode local builds are
representative", and step 1 tells the session to build
`o//tool/lua/lua` with no mode. The released `lua` inside `cosmos.zip`
is `m=rel`: `sed -n '28,108p' .github/workflows/release.yml` in a
whilp/cosmopolitan checkout shows the x86_64 lane running
`make -j$(nproc) m=rel o/rel/tool/lua/lua.dbg` and the aarch64 lane
`make -j$(nproc) m=aarch64-rel o/aarch64-rel/tool/lua/lua.dbg`, and the
`Create fat APE binaries` step apelinks exactly those two `.dbg` files
into `o/fat/bin/lua`, which is what `Create cosmos.zip` packs. Only
`lua-debug` is built from the default-mode `o/x86_64/…` and
`o/aarch64/…` objects — whilp/cosmopolitan's own AGENTS.md says so
("The RELEASE `lua` ships as `MODE=rel` … which is why `--strace` /
`--ftrace` live on the released `lua-debug`"), so the two documents
contradict each other and cosmic's is the wrong one.

The difference is not cosmetic for layout work. In
`build/config.mk`, default mode (`ifeq ($(MODE),)`, line 12) sets
`ENABLE_FTRACE = 1`, which at line 492 adds `-DFTRACE` and
`-fno-inline-functions-called-once`, and at line 522 adds
`-fpatchable-function-entry=18,16` on x86_64 — sixteen bytes of NOP
padding before every function entry, plus suppressed inlining. `m=rel`
(line 132) sets only `-DNDEBUG -DDWARFLESS` and `-O2`. So every
function's address, alignment and inlining differ between the two
modes: a default-mode build is not a representative instrument for any
hypothesis about code layout, function alignment or I-cache behaviour,
which is the class of hypothesis the C-layer chapter most often
carries. It is still fine for the ordinary "is this binding cheaper"
question, which is what the bullet was probably written for.

The fix is a correction in `skills/optimize/cosmopolitan.md`: say that
the released `lua` is `m=rel` and `lua-debug` is default mode, tell a
layout-sensitive hypothesis to A/B `make -j$(nproc) m=rel
o/rel/tool/lua/lua` on both sides, and keep default mode where
`--strace`/`--ftrace`/`perf` are wanted. `skills/optimize/measurement.md`
already records `local rel (straddled)` and `local rel (padded)` rows
alongside `local default`, so the practice has already outrun the prose.
