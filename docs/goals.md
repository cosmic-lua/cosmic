# Goals

this document says why cosmic exists, what "good" means here, and how each
goal is measured. the tradeoffs behind these goals are recorded as
decisions in [decisions.md](decisions.md) — read that before relitigating
one.

## Mission

cosmic exists to be very, very good: the best runtime there is for
building correct, self-contained software. that is the whole mission.
adoption, popularity, and ecosystem growth are explicitly not goals — if
cosmic is excellent and three people use it, it has succeeded.

## Users, ranked

when goals conflict, the experience of the higher-ranked user wins:

1. **AI coding agents.** an agent dropped into a bare sandbox with only
   the cosmic binary should ship correct software with fewer cycles than
   on any other runtime. docs, error messages, and gates are
   agent-legible first.
2. **script-writing developers.** anyone who wants typed, portable,
   single-file scripts and tools.
3. **tool distributors.** people whose end product is a
   `cosmic --embed`-built executable.

humans benefit from agent-first design incidentally, and that is fine.

## Promises, ranked

these are the claims cosmic makes, in priority order. the first is the
anchor; the others serve it and are served by it.

### 1. no silent bugs

the anchor promise, at full depth:

- **types never lie.** every stdlib signature admits failure honestly
  (`T | nil, string`); `any` boundaries shrink; the `as` cast count
  trends to zero (see [decisions.md D5](decisions.md)).
- **documented behavior is verified behavior.** every documented claim is
  executable — examples run as tests, coverage ratchets, gates end in
  machine-readable verdicts. a doc statement that is not CI-verified is
  a bug.
- **adversarially verified.** the promise holds against inputs nobody
  wrote a test for: fuzzing the parsers (json, re, url, zip, sse),
  property-based tests, sanitizers at the C layer.
- **the promise transfers to user code.** a user project that passes
  cosmic's gates inherits the property — the gates are strong enough
  that passing them means something.

### 2. agent efficiency

an agent given only the cosmic binary completes real tasks in strictly
fewer cycles (tool calls, tokens, wall-clock) than the same agent given
Python, Node, or Go.

### 3. self-sufficiency

everything you need, nothing you install: one file containing the
runtime, compiler, type checker, formatter, test runner, and
documentation, working offline, on any supported OS.

### payoff: the best tool-building tool

the three promises compound into the product: `--embed`-built
executables that are correct, portable, contained, and fast.

## Goals and how they are measured

every goal here is evaluatable. a goal without a measurement is a wish.

### G1 — standing agent-eval harness with baselines

the clean-room agent studies ([agent-usability.md](agent-usability.md))
become a maintained, versioned suite: fixed tasks, fresh agents, scored
on silent bugs, checker-caught errors, and cycles — run on a cadence
with tracked history, and run against Python/Node/Go sandboxes on the
same tasks.

- **measured by:** the harness's own scores, per release.
- **win condition:** (hard gate) zero silent bugs across the suite;
  (standing target) strictly fewer agent cycles than every baseline
  runtime on every task.
- **status:** not started. sequenced first — build the instrument
  before the features it will measure (held with low conviction; see
  [decisions.md D11](decisions.md)).

### G2 — contained by default

scripts run under a restrictive default policy unless the operator
grants capabilities explicitly (`--allow-net`-style). the sandboxing
stack (pledge/unveil/landlock/quicksand) stops being a library the
script may call and becomes a boundary the script cannot decline. the
denial experience is part of the interface: a blocked script fails with
a message that names the capability and the exact flag to grant it.

- **measured by:** default-deny is the shipped behavior; every eval-suite
  task runs contained; an agent hitting a denial recovers in one step
  (observable in G1 transcripts).
- **win condition:** no eval task is failed or slowed by containment
  ergonomics, while default-deny holds.
- **status:** not started. this is a deliberate compatibility break.

### G3 — casts to zero

drive Teal's narrowing and soundness gaps closed upstream-first
(fork-if-blocked, the Cosmopolitan precedent) until `lib/` needs zero
`as` casts. the cast ratchet (`lib/build/casts.txt`) is scar tissue,
not a goal: when the count reaches zero, the ratchet retires.

- **measured by:** the cast ratchet's total, per release.
- **win condition:** zero casts; ratchet deleted; the narrowing
  doctrine in AGENTS.md shrinks to a footnote.

### G4 — zero-config project gates

one built-in verb runs the full no-silent-bugs apparatus against any
user project with zero configuration: format gate, type check
(warnings-as-errors), tests, example verification, and coverage
ratcheting against a committed baseline. user projects inherit exactly
the discipline cosmic applies to itself. (the cast ratchet is excluded —
it retires with G3.)

- **measured by:** a scaffolded project gets a meaningful `PASS`/`FAIL`
  verdict from one command with no setup; the eval suite's project
  tasks use it.
- **win condition:** the verb exists, is the documented default idiom,
  and G1 agents adopt it unprompted.

### G5 — adversarial verification

the parsers and codecs that face untrusted input (json, re, url, zip,
sse, compress) are continuously fuzzed; property-based tests cover the
core invariants; the C layer runs under sanitizers in CI.

- **measured by:** fuzzers exist and run on a cadence; findings become
  regression tests.
- **win condition:** a release ships only after a clean fuzz window.

### G6 — competitive on the defining paths

perf is a stated goal only where it defines the product experience:
binary startup, `--check-types` latency on a reference project, and the
embed build cycle — with bars set relative to peers (starts faster than
CPython; typechecks faster than comparable checkers on comparable
code). everything else stays non-regression, enforced by the existing
`perf-compare` gate.

- **measured by:** the headline metrics in the perf suite, compared
  against peer runtimes, per release.
- **win condition:** the stated relative bars hold.

### G7 — a server and concurrency story (later)

batteries include serving: the test for a battery is "should a
cosmic-built binary be able to do this without shelling out or
vendoring C" — which includes an HTTP(S) server and a real concurrency
model, since single-file portable services are a natural payoff of
`--embed`. deliberately not urgent; direction, not deadline.

- **measured by:** not yet. when this activates, it gets eval tasks and
  win conditions like everything else.

## Non-goals

- **adoption.** see mission.
- **API stability.** cosmic keeps a perpetual right to break. releases
  are date-versioned; changelogs note breakage; users pin a release
  binary they trust. honest types make breakage loud, which is the
  point ([decisions.md D10](decisions.md)).
- **cross-OS verification.** portability across six OSes and two arches
  is Cosmopolitan's promise, inherited and trusted; cosmic verifies its
  own layer on Linux and treats cross-OS breakage as an upstream bug
  ([decisions.md D4](decisions.md)).
