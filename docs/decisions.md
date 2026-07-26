# Decisions

architecture-decision records for the tradeoffs behind
[goals.md](goals.md). each entry records what was decided, what was
rejected, and why — so future work (human or agent) does not relitigate
them by accident. amending one is allowed; doing so silently is not.

format: context → decision → rejected → consequences. entries are
append-only and numbered; a reversal is a new entry that supersedes the
old one.

---

## D1 — builders of command-line software are the user; agents are the lens

- **date:** 2026-07
- **context:** cosmic's goals could optimize for AI coding agents, for
  human script writers, for tool distributors, or for its author alone.
  the agent-usability studies showed the agent experience is measurable
  and improvable in ways that compound — and that the frictions agents
  hit are the same frictions humans hit.
- **decision:** the user is anyone — human or agent — who writes and
  distributes command-line software. agents matter twice: as a real
  audience worth enabling in their own right, and as the measuring
  instrument, because an interface a fresh agent can navigate from a
  bare sandbox is navigable by anyone. a change that served agents at
  humans' expense would be wrong (and the studies suggest such changes
  barely exist — the lenses see the same frictions).
- **rejected:** optimizing for agents specifically, humans be damned;
  optimizing for the author alone (kept only its spirit: adoption is
  not a goal — see D2); optimizing for broad developer adoption.
- **consequences:** docs, error messages, and CLI output are designed
  to be legible without outside context. the agent-eval harness (G1)
  is the primary instrument of product judgment, measuring on behalf of
  every builder.

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
  promise transfers to user code). efficiency second (observed through
  agent evals), self-sufficiency third, tool-building as the payoff.
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
  workaround doctrine and per-cast justification are scar tissue. cosmic
  already
  forks Cosmopolitan and ships its own formatter, so owning tools has
  precedent.
- **decision:** contribute narrowing/soundness fixes to upstream Teal;
  fork only when upstream declines a change the goals require. target:
  zero casts in `lib/`, then the cast scaffolding retires (G3).
- **rejected:** living within pinned Teal forever; forking now;
  replacing Teal with an own checker.
- **consequences:** external lead time on upstream review cycles; the
  cast scaffolding is explicitly temporary and excluded from the
  user-facing gate verb (G4).

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
  generated or untrusted code that simply doesn't call it — and
  generated code is a first-class workload here.
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
- **consequences:** maximum evolution speed. agents — a first-class
  user — refit code cheaply, making this cheaper than it looks. pinning
  is the user's responsibility and the documented idiom.

## D11 — sequencing: harness first

- **date:** 2026-07
- **context:** five substantial commitments (G1 harness, G2
  containment, G3 honest types, G4 gates, G7 servers) cannot land at
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

## D13 — the build's trust root is two pinned artifacts behind one committed fetcher

- **date:** 2026-07
- **context:** the #756 arc converged the build on "make as the pinned
  job graph, cosmic as the only build logic": every recipe is a single
  argv under a sha-pinned bootstrap, `SHELL` is poisoned globally with
  per-rule exceptions, sandbox annotations and per-rule env clamps
  document and (where opted in) enforce each rule's access. that
  discipline is only as strong as what the build ultimately trusts.
- **decision:** the chain, stated once: **kernel → committed `bin/make`
  → two sha-pinned artifacts → everything else.** `bin/make` is POSIX
  sh with one job — obtain the pinned bootstrap cosmic (release pinned
  in `cook.mk`), which then extracts the pinned landlock-make from
  `cosmos.zip` (release pinned in `3p/cosmos/cosmos.pin.tl`); it is the
  sole provisioner of both, and re-provisions on pin bumps. everything
  downstream — staged 3p, compiled tree, the cosmic binary, every gate —
  runs under those two artifacts. deliberately **outside** the root,
  enumerated: host `sh`/`curl`/`sha256sum` (and `od`/`sed`) for the
  first fetch; host `git` for version stamping; the digest-pinned CI
  container image. each link has a gate: the sha checks in `bin/make`
  refuse a wrong artifact; the makefile ratchet tests enumerate the
  real-shell exceptions and host-exec grants and statically scan recipe
  text for shell metacharacters; the sandbox canary plus the enforce
  lane prove enforcement works; the offline lane proves no undeclared
  network; the reproducible lane proves double-build determinism; the
  env-clamp fixture proves the `.ENV` clamp holds against a hostile
  caller environment.
- **rejected:** vendoring the binaries into git (the sha pin already
  fixes the bytes; vendoring adds repo weight, not trust); trusting any
  host toolchain beyond the first fetch (host make, cc, lua — where
  host variance lives); collapsing to a single artifact by shipping
  make inside the cosmic release binary (entangles the two release
  cycles for no reduction in what must be trusted — one fetcher, two
  pins is the achievable minimum).
- **consequences:** `bin/make` is the only place host variance can bite
  and the only committed shell that is not a per-rule exception; new
  binaries enter the build only through pin bumps; the ratchets keep
  the exception sets from regrowing silently. supply-chain review
  reduces to: read `bin/make`, audit two shas, trust the kernel.

## D14 — no self-hosting: pinned make is permanent

- **date:** 2026-07
- **context:** with all build logic in `.tl` under the bootstrap,
  make's remaining roles are the graph itself — pattern rules,
  `.SECONDEXPANSION`, the module `foreach`/`eval` expansion, staleness,
  the jobserver — plus sandbox enforcement (`.PLEDGE`/`.UNVEIL`/
  `.ENV`/`.SANDBOXED` in landlock-make). a cosmic-native graph executor
  would close the loop and make cosmic fully self-hosting.
- **decision:** pinned cosmo-make (the landlock-make maintained next
  door in whilp/cosmopolitan) is a **permanent component, not a
  waypoint**. the endgame shrinks what make *means* — a job-execution
  system and dependency graph, nothing else — and that is the end
  state. build capabilities arrive as landlock-make features upstream
  plus cosmic-side adoption, both pinned.
- **rejected:** a cosmic-native graph executor (re-implementing
  staleness, parallelism, and the jobserver is high-risk scar tissue
  with no user-facing payoff — cosmic's mission is user tooling, and
  `--make` project scaffolding already covers users); driving the
  build from a cosmic script that shells out to make as a library.
- **consequences:** the build keeps a second pinned binary forever
  (priced into D13); graph-level features go through an upstream
  release cycle rather than a tree edit; make syntax remains a
  reviewed boundary, held small by the no-shell default and the
  ratchets.
