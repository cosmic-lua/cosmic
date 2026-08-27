Two gaps in what the release perf lane actually measures, both found
while verifying `3IVF3HbV` and neither carried by the spec that landed
for it.

## 1. The changed-bench blind spot

`3IVF3HbV`'s landed approach narrows its type-check sweep to
`_perf/run.tl` plus sources the pin does not carry. An edit to an
EXISTING `_perf/bench/*_bench.tl` is carried by the pin, so it never
reaches the lane's baseline run and no type check can see it. The guard
is sound for what it covers; this is the hole it leaves, stated so
nobody rediscovers it as a surprise.

## 2. The release lane measures the pin's `_perf`, not the tree's

`release.yml:173` runs the baseline side against the pinned release's
embedded `_perf`, so the two sides of a release compare can be running
two different scenario definitions. The rename wart documented in
`release.yml:151-155` exists to paper over exactly this.

Measured: making the baseline side use the tree's `_perf` is
mechanically available and cheap today.

    o/perf/prev/cosmic-lua --modules o/_perf/run.tl.run.modules o/_perf/run.lua

parses and loads. Two facts make it work, both verified in the tree:
the flag must precede the script path (`cosmic/searcher.tl:458-475`
stops scanning at the first non-flag), and the three-tier tree searcher
(`cosmic/searcher.tl:374-399`) covers `_perf`'s computed bench requires
by name.

Doing it would make both compare sides use one scenario definition and
dissolve the rename wart.

## Why this is a capture and not a slice

It changes what the baseline number MEANS. Today a release compare
answers "is this binary slower than the last one, as the last one
measured itself"; afterwards it answers "is this binary slower than the
last one, as this tree measures both". Those are different questions and
the second is not obviously the one the gate should ask — a scenario
edit would then move the baseline retroactively, which is the property
the current split deliberately avoids.

So it needs its own argument before it needs an implementation, and the
argument is not one this capture settles.

## Related, do not conflate

`3IVGNOMt` concerns whether `release.yml`'s discarded `selfcheck.json`
A/A pair should be retained, and `3IHHKCyz` proposes deleting the second
run that produces it. Those are about the A/A control; this is about
which `_perf` the baseline arm executes. They touch the same workflow
file and should be read together, but they are not the same question.
