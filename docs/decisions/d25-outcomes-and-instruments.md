# D25 — goals split into ranked outcomes and instruments; ratchets gate, peers are the scoreboard

- **date:** 2026-08
- **context:** goals.md listed seven goals in one flat tier, and three
  structural problems surfaced when the flow system
  (`skills/plan`) tried to work backwards from them. first, G1 (the
  agent-eval harness) was load-bearing far beyond its slot: promise 2
  was "observed through agent evals," G2's ergonomics and G4's
  adoption clause were measured "in G1 transcripts" — so half the
  goals had unmeasurable distances until an unbuilt instrument stood,
  and intake ("work the goal furthest from holding") could not rank
  them. second, the competitive win conditions were universally
  quantified over rivals — "strictly fewer cycles than EVERY baseline
  on EVERY task," "starts faster than CPython" — bars that either
  never converge or hostage a release to someone else's roadmap.
  third, G2 ("contained by default") assumed a Deno-style single
  mediation point; cosmo has none — a script talks to libc directly,
  and enforcement (pledge/unveil, landlock, seccomp) is OS-gated — so
  the goal as written was unreachable on real platforms.
- **decision:** two tiers, stable G-numbers.
  - **outcomes** (what cosmic IS) are ranked by paired comparison —
    each contested pair answers "if only one could hold, which cosmic
    is better?", wins counted, transitivity closing untested pairs —
    and the committed order in goals.md is what intake reads. the
    2026-08 tournament: G3 > G6 > G5 > G2, with G4 a bye
    (nearest-to-holding: finish, don't debate) and G7 dormant. the
    method lives in `skills/plan/decompose.md`; a re-rank is a PR
    that re-runs the contested pairs and records the matches.
  - **rivalry leaves the win conditions.** every open-ended bar
    becomes a ratchet against ourselves — no regression, trending the
    right way, release over release — which is the house move
    (coverage, casts, perf-compare) applied to the goals themselves.
    peer standing (CPython, Node, Go, comparable checkers) is
    published per release as one table: the scoreboard for the stated
    ambition (sustained ratcheting puts and keeps cosmic ahead),
    never a gate.
  - **G2 is rescoped** to platform-enforceable containment: default
    deny where the OS can enforce it, a denial that names the
    capability and the granting flag, containment status always
    queryable, and no portable default-deny promise (recorded as an
    explicit non-goal).
  - **instruments** (how we see and steer) get their own tier, with
    win conditions about the instrument standing, not about the bars
    it measures — those live in the outcomes it feeds. G1 (the eval
    suite) moves there; G8 (the flow system itself) joins it,
    measured by flow health (lead time, WIP adherence, no
    starvation/saturation) plus a cost ratchet: tokens × model tier
    per merged slice, trending down. delegation share is an indicator
    the cost ratchet already rewards, not a gate.
- **consequences:** intake works the ranked outcome list top-down, so
  planning no longer needs the eval harness to exist before it can
  choose; a release can never be hostage to a rival's performance,
  only to our own regression; the peer table must actually be built
  and published for the ambition to be checkable (G6/G1 epics); some
  platforms are honestly uncontained and say so, which is the anchor
  promise applied to the goals file itself; and the flow system is
  accountable in tokens, so "more process" has to pay for itself in
  cheaper merged slices.
