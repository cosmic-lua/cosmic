Imported from whilp/cosmopolitan#262.

## Goal

G6 — the defining paths answer for a release. MODE=rel's code-layout
lottery is now a measured cost on two scenarios across two pins, and
it stands between cosmic and pinning any current cosmos release
cleanly.

## Evidence

The issue's evidence (complete, 2026-08-15): codec_hex_roundtrip_64k
+34-38% on the first MODE=rel pin, isolated interleaved pairs, same
direction every pair; a three-release bisect lands the jump exactly on
the MODE=rel commit; same-commit local rel matches the fat release, so
apelink is exonerated — rel codegen layout itself. Mechanism: removing
the ftrace patchable-function-entry padding lets hot-loop branches
land on 32-byte boundaries (Skylake JCC erratum, uop-cache off for
that chunk).

New since the issue: the 2026-08-21 pins (the first rel-mode cosmos
cosmic consumed after re-pinning) show tar_extract_tree +8% floor in
5/5 interleaved local pairings (board 3IHFD8b4, measured 2026-08-22) —
a second scenario losing the same lottery on a different link. A fix
already exists unmerged: -Wa,-mbranches-within-32B-boundaries for
x86_64 rel, PR'd 2026-08-15 on branch claude/1107-cosmic-yd5vj4 with
the mechanism argument in its commit message.

## Direction

The issue's option 2, which the unmerged PR implements: land the
assembler padding flag for x86_64 rel in whilp/cosmopolitan, cut a
release, bump the pin, and re-run the two known probes
(codec_hex --only pairs per the issue; tar_extract per 3IHFD8b4). If
both recover, the #242 rel wins (json -16%, base64 -16%) come at no
lottery cost; if not, the trade-off ledger decides between options 1
and 3 with complete data.

## Correction, 2026-08-23 — both halves of the Evidence above are stale

Read this before acting on the Direction. Two of its load-bearing claims do not
survive re-checking, and following it as written would merge a draft PR the
repo owner closed with an explicit recommendation against merging.

**1. The "fix already exists unmerged" is a closed, unmerged draft whose own
conclusion is that it should not ship.** whilp/cosmopolitan#263 — the branch
`claude/1107-cosmic-yd5vj4` this item names — was closed 2026-08-15T17:00:47Z
without merging (`pull_request_read whilp/cosmopolitan#263` →
`"state":"closed","draft":true,"merged":false`). Its body reads: "Status after
measurement: mechanically verified, but **NOT a measured win** — hold as a
documented experiment, do not merge on current evidence."

The flag works mechanically — it provably clears every hot branch off the
32-byte boundaries at ~3% binary size — but #263 then measured it and found it
slower. In a second session hours later, byte-identical binaries, same reported
CPU (family 6 / model 85 / stepping 7):

```
                       morning      afternoon
local default          173-182 us   123.7, 123.1 us
local rel (straddled)  196-198 us   122.4, 122.8 us   <- the +34% penalty, gone
local rel (padded)         --       139.8, 141.4 us   <- the padded build LOSES ~14%
release old (default)  146-166 us   132.2, 120.9 us
release new (rel)      197-217 us   124.9, 122.7 us   <- original regression, gone
```

A single unchanged binary swung -38% between sessions. The codec_hex evidence
this item calls "complete, 2026-08-15" is the morning column; the issue gained
an owner comment at 2026-08-15T16:25 carrying the afternoon column, and this
item was written on 2026-08-22 without it. The recorded recommendation on #262
is the opposite of this item's Direction: keep MODE=rel, do NOT ship the flag,
and instead require that a release-gating regression on a single tight-loop
scenario reproduce across separate sessions before it blocks a pin.

**2. The tar_extract_tree half did not reproduce.** Board item 3IHFD8b4 — the
"+8% floor in 5/5 interleaved local pairings" this item cites as the second
scenario — was re-measured on 2026-08-23 in a separate session and host
placement, exactly the standard #262 asked for. It came back negative:

| pair | A (08-17 release) | B (main @3dee6074) | delta |
|---|---|---|---|
| 1 | 8.09 | 8.40 | +3.8% |
| 2 | 7.80 | 8.31 | +6.5% |
| 3 | 7.77 | 8.03 | +3.3% |
| 4 | 7.79 | 10.63 | +36.5% |
| 5 | 9.73 | 8.06 | **-17.2%** |

Direction consistency — the property an interleaved A/B is judged on — breaks in
pair 5, where B runs faster. The A/A self-check on the same host in the same
session put this scenario's noise floor at **±24.2%**
(`perf-selfcheck: nothing exceeded the bar`), and four of the five deltas fall
inside it. The full run, with both binaries' sha256s, is on 3IHFD8b4.

**What this item should become.** Not "land the flag". On the evidence as it now
stands there is one measured scenario (codec_hex) whose regression itself failed
to reproduce in a second session, and a second (tar) that has now failed to
reproduce too. Refinement should either close this as not-planned — #262's
recommendation, keep MODE=rel and change the measurement standard instead — or,
if the hex lottery is still judged worth chasing, re-specify it as a
cross-session re-measurement of codec_hex_roundtrip_64k on the current pins,
mirroring what 3IHFD8b4 did for tar. The missing measurement rule that let both
items be written this way is capture 3IJxKFgy.
  2026-08-23T06:01:41+00:00 ecfe78d4 migrate: the 45 open plan items become backlog
  2026-08-23T04:38:16+00:00 c28f31ab attach 3IHHJn62 under 3HyRcd9F
  2026-08-22T16:01:44+00:00 99a9d943 new 3IHHJn62 cosmopolitan: land the rel-mode 32-byte branch padding — the layout lottery now costs hex (+34-38%) and tar (+8%)

## Outcome (2026-08-23, prioritization review): not planned

The premise is refuted in place: the padding-flag draft PR
(cosmopolitan#263) measured the padded build ~14% SLOWER in a
same-day re-test, and the original codec_hex regression vanished on
byte-identical binaries hours later — host-state drift, not layout.
Owner recommendation on cosmopolitan#262 stands: keep MODE=rel, do
not ship the flag. Superseded by the cross-session measurement rule
(board item 3IJxKFgy); do not re-test the flag without that rule
landing first and a signal that reproduces under it.
