whilp/cosmopolitan PR #281 (`IsBase64: pin the alphabet scan to a
fetch block, not the entry`) is accepted on the board and green in CI
(check `build` success on head `d8185fc9`, one file, `net/http/isbase64.c`,
+9 lines, `mergeable_state: clean`), but whether it should land is a
question its own body puts to the repository owner rather than
answering: "at the current merge base this diff is a no-op, and it is
your call whether it is worth landing ... Leaving it open rather than
deciding for you."

The facts behind that question, all from `3ITerUZf`'s `## Result`.
Against `354c17e08` the diff recovers the whole regression —
`IsBase64` med 52.767 to 27.135 microseconds (-48.58%, trimmed ranges
disjoint, hi D 27.258 < lo B 52.238, floor 3.7%) and the round trip
160.569 to 133.758 (-16.70%). But master has advanced to `886741e0`,
whose five intervening commits (#275-#279, none touching `net/http/`)
happen to land the loop favourably on their own: unaided `IsBase64`
reads 26.979 microseconds there against 27.137 on the pre-regression
`8dd093cea`, and the diff moves it +1.47% with overlapping ranges —
a no-op within noise. So the change is a durability measure that
removes a demonstrated 93% placement lottery from a hot path, not a
fix for a live regression.

The argument against landing is on the PR too, and is not weak: it is
still a lottery ticket, just a free one. The same shift that helped
`IsBase64` made `DecodeBase64` about 14% slower on master (59.2 to
67.4 microseconds versus `8dd093cea`), which this diff does not touch,
so pinning one loop and not the other is arbitrary. The fork's stated
convention is surgical diffs kept mergeable with upstream, and an
inline `asm volatile(".balign 64")` in `net/http/` is a step away from
that. The three options the PR offers its author are: land it, close
it, or extend the same treatment to `DecodeBase64`'s loop with its own
before/after measurement.

A second consequence worth the owner's eye: on the measuring host
`886741e0` reads +4.8% on the round trip against the pre-regression
build (143.3 versus 136.7 microseconds), not the +21% the release
compare step recorded for `354c17e08`. A release built from current
master may therefore pass the perf compare with nothing merged at all,
which would make both of `3ITbywUB`'s options unnecessary. Single
host, single-arch `m=rel`; the released binary is a fat two-arch
apelink whose layout differs again, so that is a reason to let the
lane run and read the result, not a prediction.

Nothing on the board can decide this: it is a judgment about what the
fork should carry, and merging to `whilp/cosmopolitan` master triggers
the release workflow, which publishes outward. This item ends when the
owner says land, close, or extend, at which point `3ITerUZf` unblocks
and its `land` either merges #281 or the item is re-verdicted.

## Decision (2026-08-27)

The owner directed the session to resolve this blocker and proceed
("that blocker should be resolved", in-session instruction): **land
PR #281**. The durability argument carries — nine lines remove a
demonstrated 93% placement lottery from a hot path, measure as
harmless at the merge base, and move no contract. The DecodeBase64
extension stays open as its own question: the observed ~14% shift on
master versus `8dd093cea` is real evidence for a follow-up
measurement, not something this decision forecloses.
