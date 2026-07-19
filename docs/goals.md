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

## Who cosmic is for

anyone — human or AI agent — who wants to write and distribute
command-line software. one audience, seen through two lenses:

- **agents are worth enabling in their own right.** an agent dropped
  into a bare sandbox with only the cosmic binary is a real and growing
  builder of software, and cosmic should be the best runtime it could
  find there.
- **agents are the measuring instrument.** a runtime whose docs, error
  messages, and gates a fresh agent can navigate without outside help is
  navigable by anyone. agent evals make "good for the builder"
  cheaply and repeatably observable — that is their role.

the two lenses see the same frictions: a change that helped agents at
humans' expense would be wrong, and is also unlikely to exist.

tool distributors — people whose end product is a `cosmic
--embed`-built executable — are the downstream beneficiaries of all of
it.

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

### 2. efficiency

a builder given only the cosmic binary completes real tasks with
strictly less work — fewer cycles, fewer errors, less friction — than
on Python, Node, or Go. the claim is about anyone building; it is
observed conveniently and continuously through agent evals (G1).

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

### G3 — an honest type layer, no escape hatches

every type is checked, none asserted: drive Teal's narrowing and
soundness gaps closed upstream-first (fork-if-blocked, the Cosmopolitan
precedent) until the stdlib needs no `as` casts and no workaround
doctrine. mechanisms that police the gap in the meantime — today, the
cast pin in `lib/build/casts.txt` — are scaffolding, not goals: each
retires when the gap it polices closes.

- **measured by:** total `as` casts in `lib/`, per release; the size of
  the narrowing doctrine in AGENTS.md.
- **win condition:** zero casts; the scaffolding deleted; the doctrine
  reduced to a footnote.

### G4 — zero-config project gates

one built-in verb runs the full no-silent-bugs apparatus against any
user project with zero configuration: format gate, type check
(warnings-as-errors), tests, example verification, and coverage
ratcheting against a committed baseline. user projects inherit exactly
the discipline cosmic applies to itself. (only durable gates transfer —
scaffolding that polices a temporary toolchain gap, like the cast pin,
does not; see G3.)

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
