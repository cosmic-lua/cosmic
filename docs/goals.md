# Goals

this document says why cosmic exists, what "good" means here, and how each
goal is measured. goals come in two tiers: **outcomes** — what cosmic IS
when a goal holds — and **instruments** — how we see and steer, orthogonal
to the outcomes they serve. outcomes are ordered, by paired comparison
([D25](decisions/d25-outcomes-and-instruments.md), method in
`skills/work/decompose.md`): each answer is committed on the board as
one `gitboard compare` edge, and the order is DERIVED from those
comparisons rather than asserted anywhere. the list below is that
order written out for a reader, so changing it means re-asking the
contested pairs and landing both — the comparisons and this PR. the
tradeoffs behind these goals are recorded as decisions in
[decisions/](decisions/) — read that before relitigating one.

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

cutting across all three: every solution is the least thing that holds
these promises. complexity is where silent bugs live, weight is work
for every builder, and each module shipped is surface to keep honest —
so surplus generality, speculative structure, and unpruned surface are
defects even when they work. the measured half of this pressure is G9;
the judged half is the reviewer's least-thing check
(`skills/work/review.md`).

### 1. no silent bugs

the anchor promise, at full depth:

- **types never lie.** every stdlib signature admits failure honestly
  (`T | nil, string`); `any` boundaries shrink; the `as` cast count
  trends to zero (see [D5](decisions/d05-upstream-first-teal.md)).
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
driven by the cycles-per-task ratchet (G6) and observed through the
eval instrument (G1), which also keeps the peer comparison honest.

### 3. self-sufficiency

everything you need, nothing you install: one file containing the
runtime, compiler, type checker, formatter, test runner, and
documentation, working offline, on any supported OS.

### payoff: the best tool-building tool

the three promises compound into the product: `--embed`-built
executables that are correct, portable, contained, and fast.

## Outcomes, ranked

every outcome is evaluatable — a goal without a measurement is a wish —
and its win condition is a RATCHET wherever improvement is open-ended:
the gate is against ourselves (no regression, trending the right way,
release over release), never against a rival. where peers are the
scoreboard, a published table records absolute standing; the ambition
is that sustained ratcheting puts and keeps cosmic ahead, and the
table says whether that is true — it never gates. intake
(`skills/work/SKILL.md`) walks the board's derived order top-down;
this list is the prose that says what each outcome MEANS, and nothing
is derived from it.

### G3 — an honest type layer, no escape hatches

every type is checked, none asserted: drive Teal's narrowing and
soundness gaps closed upstream-first (fork-if-blocked, the Cosmopolitan
precedent) until the stdlib needs no `as` casts and no workaround
doctrine. mechanisms that police the gap in the meantime — today, the
per-site `-- cast: <reason>` justification enforced by `--make lint`
— are scaffolding, not goals: each retires when the gap it polices
closes.

- **measured by:** total `as` casts in the tree (`cosmic/` and the
  root-level internals), per release; the size of the narrowing
  doctrine in AGENTS.md.
- **win condition:** zero casts; the scaffolding deleted; the doctrine
  reduced to a footnote.

### G6 — the defining paths, ratcheted

perf is a stated goal only where it defines the product experience:
binary startup, `--check types` latency on a reference project, the
embed build cycle, and agent cycles-per-task on the eval suite (G1).
improvement is driven internally — a per-release ratchet on each path,
enforced by the existing `perf-compare` gate and the eval history —
and everything off the defining paths stays plain non-regression.

- **measured by:** the perf suite's ratchets per release; the peer
  table — the same metrics for CPython, Node, Go, and comparable
  checkers — published with each release.
- **win condition:** every defining-path ratchet holds (no regression,
  trending down across releases) with the peer table current. cosmic
  ahead on every defining path is the ambition the table reports,
  never a gate.

### G5 — adversarial verification

the parsers and codecs that face untrusted input (json, re, url, zip,
sse, compress) are continuously fuzzed; property-based tests cover the
core invariants; the C layer runs under sanitizers in CI.

- **measured by:** fuzzers exist and run on a cadence; findings become
  regression tests.
- **win condition:** a release ships only after a clean fuzz window.

### G9 — the least tree that keeps its promises

the least-thing promise, measured. growth is not forbidden — features
add weight — but it is never free or silent: every increase lands as a
visible, reviewed baseline change in the diff that causes it, and the
trend release over release is flat or down for everything not serving
a promise. the two cadences are deliberate: the public surface
ratchets per PR (surface changes rarely and deserves per-change
scrutiny; a baseline file parallel implementers rarely touch), while
tree size reports per release (line counts change with every PR, and a
per-PR gate there would put one conflict-prone baseline in every
diff).

- **measured by:** a per-PR ratchet on the public module surface
  (committed baseline of public names); a per-release size report
  (source lines and file count per tree, binary size, AGENTS.md
  doctrine size) published and compared release over release alongside
  the perf history (G6's release-asset pattern).
- **win condition:** the surface ratchet holds; the size report ships
  with every release with growth named in the diffs that caused it;
  doctrine size trends down (shared with G3); pruning work is opened
  from the report's numbers, not from taste.

### G2 — contained where the platform can enforce it

originally "contained by default" on the Deno model — but that
architecture does not transfer: cosmo has no single mediation point a
policy can interpose (a script talks to libc directly; there is no
V8-isolate boundary), so a portable default-deny is not viable and is
explicitly not promised. what cosmic promises instead: the sandbox
stays the one door (one call, fail-closed), the default posture is
deny on platforms whose OS can enforce it (pledge/unveil, landlock,
seccomp), the denial experience names the capability and the exact
flag to grant it, and a script can always ask whether it is actually
contained — an unenforcing platform is honest, never silently
unprotected.

- **measured by:** eval-suite tasks run contained on enforcing
  platforms; an agent hitting a denial recovers in one step
  (observable in G1 transcripts); containment status is queryable.
- **win condition:** on enforcing platforms, default-deny holds with no
  eval task failed or slowed by containment ergonomics; elsewhere the
  posture is reported truthfully.

### G4 — zero-config project gates (near holding)

one built-in verb runs the full no-silent-bugs apparatus against any
user project with zero configuration: format gate, type check
(warnings-as-errors), tests, example verification, and coverage
ratcheting against a committed baseline. user projects inherit exactly
the discipline cosmic applies to itself. (only durable gates transfer —
scaffolding that polices a temporary toolchain gap, like cast
justification, does not; see G3.) the verb exists and is the
documented idiom today; this goal took a bye in the comparisons as
nearest-to-holding — finish it, don't debate it.

- **measured by:** a scaffolded project gets a meaningful `PASS`/`FAIL`
  verdict from one command with no setup; the eval suite's project
  tasks use it.
- **win condition:** G1 agents adopt it unprompted.

### G7 — a server and concurrency story (later)

batteries include serving: the test for a battery is "should a
cosmic-built binary be able to do this without shelling out or
vendoring C" — which includes an HTTP(S) server and a real concurrency
model, since single-file portable services are a natural payoff of
`--embed`. deliberately not urgent; direction, not deadline; it sits
at the bottom of the order until activated.

- **measured by:** not yet. when this activates, it is compared into
  the order and gets eval tasks and win conditions like everything
  else.

## Instruments

instruments are how we see and steer. they carry win conditions about
the instrument STANDING — the bars it enforces live in the outcomes it
measures. an instrument is judged by whether outcomes move and what
the movement costs.

### G1 — the agent-eval instrument

the clean-room agent studies ([agent-usability.md](agent-usability.md),
`skills/agent-eval`) become a maintained, versioned suite: fixed
tasks, fresh agents, scored on silent bugs, checker-caught errors, and
cycles — run on a cadence with tracked history, and run against
Python/Node/Go sandboxes on the same tasks. its numbers feed the
outcomes: cycles-per-task and the peer table (G6), containment
ergonomics (G2), gate adoption (G4).

- **measured by:** the suite runs per release; history tracked; peer
  baselines current.
- **win condition:** the instrument stands — versioned suite,
  per-release cadence, tracked history, peer baselines — and zero
  silent bugs across the suite is the one hard gate the instrument
  itself enforces on every run.

### G8 — the flow system

the system of work (`skills/work`, the board on the `board` branch):
sophisticated models decompose these goals into ready work, less
sophisticated models implement it, and a sophisticated model's review
is the final gate. its job is to make the outcomes above move and to
say what the movement costs.

- **measured by:** flow health per release — ready→merged lead time,
  WIP-limit adherence, no column starved or saturated for a whole
  release — and the cost ratchet: tokens × model tier per merged
  slice, tracked and trending down. the measurement is currently
  UNBUILT for the file-based board: every transition is a commit on
  the `board` branch, so `git log` holds the flow record, but nothing
  reads it yet — the label-era `stats` tool measured GitHub timelines,
  which no longer carry the board.
- **win condition:** the board runs the repo's work with flow health
  holding and cost per merged slice ratcheting down. delegation share
  (how much lands implemented by less sophisticated models) is an
  indicator the cost ratchet already rewards, not a gate.

## Non-goals

- **adoption.** see mission.
- **API stability.** cosmic keeps a perpetual right to break. releases
  are date-versioned; changelogs note breakage; users pin a release
  binary they trust. honest types make breakage loud, which is the
  point ([D10](decisions/d10-right-to-break.md)).
- **cross-OS verification.** portability across six OSes and two arches
  is Cosmopolitan's promise, inherited and trusted; cosmic verifies its
  own layer on Linux and treats cross-OS breakage as an upstream bug
  ([D4](decisions/d04-portability-via-cosmopolitan.md)).
- **portable default-deny.** containment is promised only where the OS
  can enforce it (G2); pretending otherwise would be a silent bug in
  the goals themselves.
