## Evidence

`codec_base64_roundtrip_64k` is +8.35% slower on cosmos
`2026.08.26-fe7c36c4c` (main's pin) than on `2026.08.21-07fc94a1c`
(the published `2026-08-23-d71d7f1` release's pin), and that is the
comparison `release.yml`'s perf gate makes — so this scenario is what
still holds the lane red after `3ISlY5Xl`'s D31 landed.

Confirmed under `3ISlWFiS` on 2026-08-26, in a session and container
independent of `3ISWHyP7`'s original A/B, on cosmic tree `5ef13f40`
with only `3p/cosmos/cosmos_pin.tl` varied. Four alternating isolated
readings per arm (`o/bin/cosmic --make run _perf/run.tl --only
codec_base64_roundtrip_64k`), medians: `07fc94a1c` **191.31 µs**
[185.81, 195.26], `354c17e08` **209.35 µs** [206.45, 214.50],
`fe7c36c4c` **207.28 µs** [204.57, 209.38]. Same-binary noise floor
that session, from six `gate.tl selfcheck` passes: **4.5%**. Ranges
disjoint on both regressing pairs. `3ISWHyP7` measured +7.8% for the
same step on much noisier hardware, so the effect has now reproduced
across sessions at nearly the same size — the bar
`skills/optimize/measurement.md` sets before a finding may block a
pin.

**The range is five commits, not nine.** The `354c17e08` and
`fe7c36c4c` arms are indistinguishable (-0.99%, ranges overlapping,
the later arm nominally faster), so neither of the two cosmos
releases since — four commits,
`git log --oneline 354c17e08..fe7c36c4c` — moved this scenario. The
step arrived at or before `354c17e08`. What remains to bisect is
`07fc94a1c..354c17e08`: five commits, of which three change compiled
code (`354c17e08` adds `tool/net/llua.c`, 650 new lines;
`8dd093cea` edits `third_party/lua/luaencodejsondata.c`;
`5bfcf79d0` reworks `libc/runtime/zipos-open.c`) and two are inert
for compiled output (`8e071ec98` sqlite3 header stubs behind untaken
guards, `bf92718a1` AGENTS.md only).

**The codec itself did not change.** `git log --oneline
07fc94a1c..354c17e08 -- net/http/encodebase64.c net/http/decodebase64.c
net/http/isbase64.c | wc -l` → `0`, and the bindings
(`tool/net/lfuncs.c:913,946,950`, reached from `cosmic/codec.tl:36,77-87`)
are unchanged apart from `354c17e08`'s registration-table entry for the
unrelated `DecodeLua`. So the leading hypothesis is code layout:
added or changed compiled code moved the base64 loops across an
alignment or cache boundary. "Not on the base64 path" does not
dismiss a commit here — layout IS the mechanism under test, so the
JSON-encoder edit and the zipos rework are live candidates.

**What this item is.** Bisect the five commits: build
`o//tool/lua/lua` in a whilp/cosmopolitan checkout at each, stand it
in at `o/3p/cosmos/lua` and rebuild cosmic
(`skills/optimize/cosmopolitan.md` step 2), and read the same
isolated scenario, with a same-binary floor per build. Bisect all
five rather than assuming `354c17e08`: three change the binary, so
landing on `8dd093ce` or `5bfcf79d` is a real outcome. If the answer
is layout, check `EncodeBase64`/`DecodeBase64` alignment in both
binaries (`nm`/`objdump` on `o//tool/lua/lua.dbg`) before reaching
for any source change. A whilp/cosmopolitan checkout builds in this
container class — `make -j$(nproc) o//tool/lua/lua` fetched the
cosmocc toolchain into `.cosmocc/` and ran to completion on
2026-08-26.

Any fix lands in whilp/cosmopolitan and must not move a binding
contract: return shapes, error values and constants at the C boundary
are frozen for cosmic's generated types.
