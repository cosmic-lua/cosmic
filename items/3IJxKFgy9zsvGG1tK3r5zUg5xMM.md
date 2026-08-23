Enablement evidence found while refining 3IHFD8b4 on 2026-08-23.

`skills/optimize/measurement.md` (105 lines) warns that the report's `±%` is
within-run spread and understates cross-run variance — "a scenario can read ±2%
across the 5 samples of one invocation yet swing 10-15% between two separate
invocations" (`:13-20`). It stops there. What it does NOT carry is the stronger
finding whilp/cosmopolitan#262 and #263 established and explicitly recommended
adopting: the swing has a **cross-session host-state term** that no amount of
interleaving *within* one session can control.

The evidence, from #263's PR body: at one commit, byte-identical binaries, the
same reported CPU (family 6 / model 85 / stepping 7), measured hours apart in
the same container —

```
                       morning      afternoon
local default          173-182 us   123.7, 123.1 us
local rel (straddled)  196-198 us   122.4, 122.8 us   <- +34% penalty gone
local rel (padded)         --       139.8, 141.4 us   <- erratum-immune build LOSES 14%
release old (default)  146-166 us   132.2, 120.9 us
release new (rel)      197-217 us   124.9, 122.7 us   <- original regression gone
```

A single unchanged binary swung -38% between sessions. The morning's +34-38%
codec_hex regression had reproduced across **seven** interleaved isolated pairs
on two independent build lineages, and was still not real in the sense that
mattered. The microcode register is virtualized in the container, so mitigation
state is unobservable from inside; the container evidently moved host placement.

The recommendation recorded on #262 was: "add a measurement-discipline rule
instead of a build flag: a release-gating regression on a single tight-loop
scenario needs reproduction across separate sessions (ideally days apart /
different host placements) before it blocks a pin." Nobody landed it. `grep -n
-i 'host state\|host-state\|across sessions\|separate session\|placement'
skills/optimize/*.md` prints nothing across all three chapters (622 lines).

**The cost of the gap, observed.** Board item 3IHFD8b4 was written on
2026-08-22 asserting a tar_extract_tree regression from a single session's
five interleaved pairings — the exact verdict shape #262 says is insufficient —
and its `Direction` then instructed a session to merge whilp/cosmopolitan#263,
a draft PR that was closed unmerged on 2026-08-15 with the conclusion "NOT a
measured win... do not merge on current evidence". Refining that item cost a
full pass of re-reading two GitHub issues and a closed PR to discover the
premise was refuted. A rule in measurement.md would have stopped the item being
written that way.

Suggested shape (a slice, once placed): one bullet in
`skills/optimize/measurement.md` stating the cross-session rule and citing the
table above, plus whatever `skills/optimize/SKILL.md` needs so the loop's
accept/reject step reads it. Per `enable.md`'s ordering this is skills-tier
because it is about how a session runs the measurement, not about the tree —
core cannot encode "come back tomorrow". Non-goals should wall the build-flag
question: this is the process rule #262 recommended *instead of* the flag, and
landing it must not be read as reopening #263.
