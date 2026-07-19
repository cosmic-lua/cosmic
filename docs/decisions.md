# Decisions

architecture-decision records for the tradeoffs behind
[goals.md](goals.md). each entry records what was decided, what was
rejected, and why — so future work (human or agent) does not relitigate
them by accident. amending one is allowed; doing so silently is not.

format: context → decision → rejected → consequences. entries are
append-only and numbered; a reversal is a new entry that supersedes the
old one.

---

## D1 — agents are the primary user

- **date:** 2026-07
- **context:** cosmic's goals could optimize for AI coding agents, for
  human script writers, for tool distributors, or for its author alone.
  the agent-usability studies showed the agent experience is measurable
  and improvable in ways that compound.
- **decision:** rank users: agents first, then script-writing
  developers, then tool distributors. when goals conflict, the
  higher-ranked user's experience wins.
- **rejected:** optimizing for the author alone (kept only its spirit:
  adoption is not a goal — see D2); optimizing for broad developer
  adoption.
- **consequences:** docs, error messages, and CLI output are designed
  agent-legible first. the agent-eval harness (G1) is the primary
  instrument of product judgment.

## D2 — quality is the mission; adoption is not

- **date:** 2026-07
- **context:** most projects treat users, stars, or ecosystem growth as
  the scoreboard.
- **decision:** the mission is for cosmic to be very, very good.
  adoption is explicitly not a goal and never justifies or vetoes work.
- **rejected:** popularity as a success metric; compatibility or
  stability concessions made to court users.
- **consequences:** frees D10 (perpetual right to break) and permits
  opinionated defaults like D7 (contained by default).

## D3 — "no silent bugs" is the anchor promise, at full depth

- **date:** 2026-07
- **context:** candidate core promises: no silent bugs, agent
  efficiency, self-sufficiency, best tool-building tool. and "no silent
  bugs" itself has depths: honest types only; plus verified docs; plus
  adversarial testing; plus transfer to user code.
- **decision:** no-silent-bugs ranks first, at full depth (types never
  lie + documented behavior is verified + adversarially verified + the
  promise transfers to user code). agent efficiency second,
  self-sufficiency third, tool-building as the payoff.
- **rejected:** stopping at type-layer honesty; treating correctness
  and efficiency as co-equal.
- **consequences:** the eval win condition gates on zero silent bugs
  before it targets cycle counts (D8). G4 and G5 exist.

## D4 — portability is delegated to Cosmopolitan

- **date:** 2026-07
- **context:** cosmic claims six OSes on two arches, but CI runs on
  ubuntu only — under "documented behavior is verified behavior," an
  unverified claim is a bug. verifying the full matrix means BSD VMs,
  arm runners, and slow CI.
- **decision:** cross-OS portability is Cosmopolitan's promise,
  inherited and trusted. cosmic verifies its own layer on Linux and
  treats cross-OS breakage as an upstream bug. docs phrase the six-OS
  claim as inherited from Cosmopolitan, not verified by cosmic.
- **rejected:** full-matrix CI on every PR; tiered own-CI verification;
  demoting unverified platforms from the README.
- **consequences:** cheap CI; an acknowledged seam in the verification
  story, accepted deliberately. revisit if cross-OS breakage actually
  bites.

## D5 — upstream-first, fork-if-blocked on Teal

- **date:** 2026-07
- **context:** "types never lie" collides with Teal's limitations (no
  flow-narrowing of record unions, casts forced at boundaries). the
  workaround doctrine and cast ratchet are scar tissue. cosmic already
  forks Cosmopolitan and ships its own formatter, so owning tools has
  precedent.
- **decision:** contribute narrowing/soundness fixes to upstream Teal;
  fork only when upstream declines a change the goals require. target:
  zero casts in `lib/`, then the cast ratchet retires (G3).
- **rejected:** living within pinned Teal forever; forking now;
  replacing Teal with an own checker.
- **consequences:** external lead time on upstream review cycles; the
  cast ratchet is explicitly temporary and excluded from the user-facing
  gate verb (G4).

## D6 — the promise transfers via runtime defaults plus ratchets

- **date:** 2026-07
- **context:** the gates protecting cosmic itself (format, coverage
  ratchet, examples, verdict discipline) live in cosmic's Makefile;
  user projects get pieces, not the apparatus.
- **decision:** the binary carries the transfer: a zero-config gate
  verb runs the full suite — format, strict types, tests, examples,
  coverage ratcheting against committed baselines — against any project
  (G4).
- **rejected:** teaching-only (docs show how to assemble gates);
  scaffolding-only (`cosmic new` stamps then drifts).
- **consequences:** user projects and eval agents inherit cosmic's own
  discipline from one command; the gate verb becomes stable-in-practice
  because everything depends on it (in tension with D10 — resolved by
  pinning, as D10 prescribes).

## D7 — contained by default

- **date:** 2026-07
- **context:** cosmic has deep sandboxing machinery (pledge, unveil,
  landlock, quicksand, the `sandbox` facade), all opt-in from inside
  the script. self-sandboxing protects against bugs, not against
  generated or untrusted code that simply doesn't call it. the primary
  user runs code nobody wrote.
- **decision:** scripts run under a restrictive default policy;
  capabilities are granted explicitly by the operator
  (`--allow-net`-style). the denial message names the capability and
  the exact grant — the denial experience is part of the interface
  (G2).
- **rejected:** sandbox-as-library (status quo); paved-path idiom
  without enforcement; operator-side opt-in policy files as the
  ceiling.
- **consequences:** a deliberate compatibility break for existing
  scripts (permitted by D10). **open question:** on platforms where
  Cosmopolitan cannot enforce containment, fail closed or warn-and-run?
  must be decided before G2 ships; leaning fail-closed per D3.

## D8 — eval win condition: correctness gates, then efficiency

- **date:** 2026-07
- **context:** the harness (G1) yields absolute scores (silent bugs,
  errors) and relative ones (cycles vs Python/Node/Go). absolute and
  relative bars fail differently.
- **decision:** hard gate first: zero silent bugs across the suite.
  standing target second: strictly fewer cycles than every baseline on
  the same tasks. both numbers stated per release.
- **rejected:** correctness-only; efficiency-only; a blended composite
  score (easy to trend, easy to game, hard to interpret).
- **consequences:** cosmic can be "losing" to Python on cycles and
  still refuse a change that introduces silent-bug risk.

## D9 — batteries include serving; not urgently

- **date:** 2026-07
- **context:** the stdlib has an HTTP client, sockets, poll, and SSE
  parsing, but no server or concurrency model. upstream cosmopolitan
  had redbean; the fork was slimmed to the C core.
- **decision:** the battery test is "should a cosmic-built binary do
  this without shelling out or vendoring C" — which includes an HTTP(S)
  server and a concurrency story. direction, not deadline (G7).
- **rejected:** scripts-and-CLIs-only scope; letting eval findings
  alone set scope; freezing the surface.
- **consequences:** `net`/`poll`/`shm` designs should not paint the
  server story into a corner; no near-term delivery pressure.

## D10 — perpetual right to break

- **date:** 2026-07
- **context:** daily date-versioned releases, no semver, no
  compatibility promise — increasingly load-bearing as user projects
  couple to `cosmic.*` signatures via G4.
- **decision:** no stability promise. cosmic may break anything in any
  release; changelogs note breakage; users pin a release binary they
  trust. honest types make breakage loud at typecheck time, which is
  the safety mechanism.
- **rejected:** migration tooling as a requirement for breakage; a
  declared stable core; semver and a 1.0.
- **consequences:** maximum evolution speed. agents — the primary user
  — refit code cheaply, making this cheaper than it looks. pinning is
  the user's responsibility and the documented idiom.

## D11 — sequencing: harness first

- **date:** 2026-07
- **context:** five substantial commitments (G1 harness, G2
  containment, G3 casts-to-zero, G4 gates, G7 servers) cannot land at
  once.
- **decision:** build the measurement before the features: G1 first,
  then G2, then G4, with G3 running underneath on upstream lead time
  and G7 trailing. **held with low conviction** — reorder freely if
  reality argues, but record the reordering here.
- **rejected (weakly):** containment-first (deepest break first);
  gates-first (cheapest win first); teal-first (longest lead time
  first).
- **consequences:** sandbox ergonomics, gate usability, and Teal
  friction all get measured through the harness instead of argued
  about.

## D12 — goals and decisions are separate documents

- **date:** 2026-07
- **context:** the goals content divides into aspirations (mission,
  promises, measurable goals) and settled tradeoffs. tradeoffs are the
  part most at risk of accidental relitigation.
- **decision:** `docs/goals.md` for mission/promises/goals with win
  conditions; this file for ADR-style decisions, append-only, one entry
  per future decision.
- **rejected:** one combined file; root-level GOALS.md; folding into
  AGENTS.md.
- **consequences:** the decision log can grow without bloating the
  goals statement; goals stay short enough to actually be read.
