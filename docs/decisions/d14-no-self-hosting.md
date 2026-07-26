# D14 — no self-hosting: pinned make is permanent

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

