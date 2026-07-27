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

- **amended 2026-07:** the decision stands — make remains the graph
  executor and cosmic does not re-implement staleness, parallelism or
  the jobserver — but two of the sentences above stopped being true.

  **It is not a second pinned binary.** D13's amendment put the engine
  inside the cosmic release, so cosmic extracts its own make from its
  own zip. The consequence "the build keeps a second pinned binary
  forever" is retired: there is one pin, and make arrives with it.

  **Sandbox enforcement is no longer make's.** The context above lists
  `.PLEDGE`/`.UNVEIL`/`.ENV`/`.SANDBOXED` among make's remaining roles;
  none of them appear in `embed/cosmic.mk`, which sets `SHELL` and
  nothing else. A recipe line is argv run by cosmic — a closed verb
  vocabulary, metacharacters refused rather than interpreted — and its
  grants are DERIVED from the shape of that argv rather than declared
  beside the rule. That is strictly stronger than the directives it
  replaced, because a rule cannot over-declare its way out of a fence
  it never writes; and it moves the boundary from make syntax, which
  D13 called a reviewed boundary held small by ratchets, into typed
  code with tests.

  What make means here is now exactly the first half of the endgame
  sentence: a job-execution system and a dependency graph. Nothing
  else.
