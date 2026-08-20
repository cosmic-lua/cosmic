Imported from whilp/cosmic#1236.

## Goal

G5 — adversarial verification, extended outward. Sibling of epic #1125, not a
duplicate of it: #1125's outcome is *cosmic's own parsers are fuzzed* and it is
nearly done. This epic's outcome is *a user project can fuzz its own code with
one import*, which is a distribution promise rather than a coverage one, and
also serves the "best tool-building tool" payoff in docs/goals.md.

## Outcome (observable)

A project built by `cosmic --make` can write a fuzz target against its own
parser, run it in the ordinary test gate, get a *minimized* failing input when
it breaks, and re-run that exact input forever after — without pulling in
anything that is not in the binary.

## The design anchor: Go's `go test -fuzz`

The right comparison is not Hypothesis (a library you install) but Go's native
fuzzing (a facility the distribution ships), because that is the posture cosmic
would be adopting. `_fuzz/driver.tl` has already converged on Go's central
design choice independently, which is good evidence the shape is right:

- **Go's dual mode.** A fuzz target runs as an ordinary deterministic unit test
  over its seed corpus during `go test`, and only becomes an evolutionary
  fuzzing loop under the explicit `-fuzz` flag. `_fuzz` does exactly this with
  a fixed default seed and `FUZZ_SEED`/`FUZZ_ITERS`, which is why it rides
  `--make test` and the coverage ratchet instead of living in a nightly job.

Where Go is ahead, and what each gap costs here:

1. **Minimization.** Go shrinks a failing input before reporting it. `_fuzz`
   reports the raw input in base64 — replayable, but for a 512-byte
   `driver.bytes()` blob you still hand-bisect. This is the single largest gap
   and the one users would feel first.
2. **Corpus as committed files.** Go writes each failing input to
   `testdata/fuzz/FuzzXxx/` and it becomes a permanent seed, replayed on every
   subsequent run with no human step. cosmic's equivalent is a seed number in a
   message plus the convention that a human writes regression tests (as #1161
   did, with five). Better discipline, entirely manual. Note the repo already
   has the `testdata/` convention (never embedded) that Go's model needs.
3. **Crash isolation.** Go runs targets in worker processes, so a hard crash,
   OOM, or hang is caught and attributed to the input that caused it. `_fuzz`
   uses `pcall`, which catches Lua errors but not a segfault in a C binding, an
   infinite loop, or memory exhaustion. Since the whole point is fuzzing
   parsers that call into C (`re` is the POSIX ERE binding, `json`, `compress`,
   `zip` likewise), a C-layer crash today kills the run with no attribution.
   `cosmic.child` is the in-box ingredient.
4. **Timeouts.** Go has `-fuzztime`/`-fuzzminimizetime` and per-input hang
   detection. Child 4 (3I7PFJE7, landed) closed most of this: `_fuzz/driver.tl`
   now arms a per-`check()` VM-instruction budget, and `sse`'s hand-rolled
   `Drained.is_bounded` bound was deleted in the same change. What is left is
   the case the VM hook cannot cover — a hang inside a single C call, or any
   hang when the hook slot is taken by the coverage collector — which child 5
   (crash isolation) now also carries a wall-clock timeout for.
5. **Coverage guidance.** Go and libFuzzer keep mutations that reach new code
   paths, which vastly outperforms blind random. `_fuzz` is blind. cosmic is
   unusually well placed here: `cosmic.coverage` is already a public module
   collecting line coverage, so the raw ingredient is in the box. This is the
   most speculative item and should stay last.

Where Go is *behind*, and cosmic should not copy it: `f.Fuzz` accepts only a
fixed set of scalar types (`[]byte`, `string`, the numerics, `bool`, `rune`),
so Go users encode structured inputs into bytes by hand — which is precisely
the workaround `_fuzz/sse_fuzz_test.tl` and `_fuzz/url_fuzz_test.tl` already
perform with length-prefixed strings, and `_fuzz/json_fuzz_test.tl` performs
with a module-level `generated` side channel. Rust's answer (the `arbitrary`
crate deriving structured values from a byte stream) is the better model, and
it composes with minimization rather than fighting it.

## The sequencing insight

`gen: function(): string` returning an opaque string is close to the worst
shape for minimization — it admits only byte-level delta debugging on the
output. Hypothesis's approach is the cheap way out and it fits here: generate a
*choice sequence*, interpret it through generators, then shrink the choice
sequence and re-run the generator. Simplifying the draws tends to simplify the
value, with no per-type shrinker required.

That is why **#1235 (a seedable, non-crypto generator) is the prerequisite for
this whole epic** rather than a side quest. Once generators draw from an
explicit source object, that source can record its draws, and minimization
becomes shrinking of a recorded draw sequence.

## Children (not yet filed — see WIP note)

Named here in intended landing order; the checklist gets real issue numbers on
a later refinement pass.

1. **Blocked by #1235** — seedable source; driver hands each property its own,
   replacing the seeded `math.random` global.
2. Draw-recording source: the source records its draw sequence and can replay
   one, which is the substrate for minimization.
3. Minimization: shrink the recorded draw sequence, re-running the generator;
   the failure message reports the minimized input.
4. Per-input timeout and step budget in the driver; `sse`'s hand-rolled
   `Drained.is_bounded` bound is deleted in favor of it.
5. Crash isolation via `cosmic.child`, so a C-layer fault is attributed to its
   input instead of killing the run.
6. Corpus persistence under `testdata/`, replayed before generated inputs.
7. Discard accounting (Hypothesis's `assume()` and its health check). Live
   motivation: `url`'s `format_fixpoint` returns true on an unparseable input,
   so a generator that drifted to 90% unparseable would still report 256
   passing iterations and prove nearly nothing.
8. The publishing move itself: placement, `--docs` entry, examples, and the
   public-module-surface baseline from #1145.
9. Optional, last, speculative: coverage-guided mutation over
   `cosmic.coverage`.

## The placement decision this epic must settle

`cosmic/**` is the strip floor, so a public `cosmic.fuzz` ships in every user
artifact — weight that cuts against G9. `cosmic.check` is precedent for a
test-oriented public module; `_tool/` (embedded in the cosmic binary, never in
user artifacts) is the alternative and is the right answer only if this stays a
gate for cosmic itself. Since the stated outcome is user projects fuzzing their
own code, `cosmic.fuzz` is the presumed answer, but the G9 cost is real and
should be paid deliberately, with a decision record if it is contested.

## Non-goals

- Not a rewrite of the six existing `_fuzz/*_fuzz_test.tl` properties. They
  migrate onto the published API as it stabilizes; their properties and the
  found-bug protocol from #1125 are unchanged.
- Does not supersede #1125 or #1134 (scheduled deep-fuzz). This epic is the
  library; those are cosmic's own use of it.
- No public API is frozen before minimization exists — the `Options` contract
  is expected to move, and publishing it early is the thing this epic must not
  do.

## Enablement / WIP note

`work:plan` is at or over its limit of 12 non-exempt issues at filing time (29
open `work:plan`, of which 6 are epics and 10 are findings). Epics are exempt,
so this card is filed now; its children are deliberately NOT filed yet, because
they would be refused at the limit and would crowd out refinement capacity.
Decomposition is a later planner pass, per `decompose.md` ("a goal does not
decompose in one sitting").

## Refinement pass, 2026-08-19

Child 1 has LANDED: 3I1iGY7Z (PR #1277) shipped
`cosmic.rand.insecure_source(seed)` returning a private-state `Source`
(`int`, `float`) — the blocker on this epic is satisfied and the
`blocked_by` edge is now historical. What it deliberately did not do:
`_fuzz/driver.tl` still seeds global `math.random` (measured at
`bff1007`), so the driver migration leads child 2.

Children 2 and 4 are filed to the ready bar as captures awaiting a plan
slot (both carry attach notes): 3I7PCerj (draw-recording source; the
driver drops `math.random`, inputs become choice sequences — the
minimization substrate) and 3I7PFJE7 (per-input VM-instruction budget,
mechanism pre-verified against the pinned binary; sse's hand-rolled
bound deleted). Child 3 (shrinking) is specced next AFTER 2 lands —
its shape depends on the recorded-draw structure 2 commits to. The
placement decision (`cosmic.fuzz` vs `_tool`) stays open and is not
needed before child 3; it must be settled (decision record if
contested) before child 8, the publishing move.

## Refinement pass, 2026-08-20

Child 4 (3I7PFJE7) LANDED: the per-`check()` VM-instruction budget is
in `_fuzz/driver.tl`, and `_fuzz/sse_fuzz_test.tl`'s hand-rolled
`Drained.is_bounded` bound is gone — item 4 above (§"Timeouts") is
corrected accordingly rather than left citing deleted code.

Child 5 (3IAXDNwC, crash isolation) is now driven to the ready bar.
Its own spec carries the settled design (three spikes: `cosmic.child`'s
`Result` already distinguishes signal/timeout/exit with no changes
needed; a bare re-exec of the compiled test file is ~50x cheaper than
`--make test`'s re-invocation; the re-exec argv is exactly `{arg[-1],
arg[0]}`) — isolation lands as the driver's unconditional default per
PROPERTY (one child process per `driver.run` call, iteration-level
bisection only on an actual crash), not per iteration and not behind an
opt-in flag, so no `*_fuzz_test.tl` file changes. That settles the open
"opt-in vs. default" question this epic's spec posed for child 5: the
earlier framing measured the wrong granularity.
