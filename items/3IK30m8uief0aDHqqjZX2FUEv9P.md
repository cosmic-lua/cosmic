Round: 2026-08-23 clean-room agent eval (skills/agent-eval). Four
Sonnet agents, fully isolated (leak probe returned NONE), one binary
each: a working-tree build at head 98dde1f, ci PASS before the round.
Briefs: bookmark (JSON CLI; flags/fs/json), logstats (log analyzer;
string/re/testdata), inventory (SQLite CRUD), sitegen (multi-module
generator). Results: 4/4 built, tested and green, all four artifacts
verified by hand; first build took 2/1/2/1 attempts, green ci 2/2/2/2.
Prior rounds for comparison: June 2026 worst case ~17 error cycles on
the sqlite brief (docs/agent-usability.md); early-August rounds
converged to 1/1/1/1 first-build attempts on the original brief set.

Finding: module COMPOSITION is discoverable only module-by-module.
2 of 4 agents independently asked for one page mapping "a typical CLI
tool" to the module set it composes; `guide.recipes` appears to be
exactly that page, but nothing early routes a newcomer to it.

- agent 1 (bookmark), top friction: "No single here's-the-stdlib-API-
  surface cheat sheet — I had to pull --docs for fs, json, flags,
  proc, child, check individually ... no one page listing the modules
  a typical CLI-with-JSON-storage tool needs."
- agent 2 (logstats): "guide.recipes (mentioned at the bottom of the
  quickstart) sounds like it might cover exactly this (a CLI
  skeleton) ... worth flagging that a newcomer might not realize
  guide.recipes is the answer to how-do-these-modules-compose until
  well after they've already reinvented the composition."

Fix direction: surface `guide.recipes` early — name it in --help
and on the quickstart's first screen rather than its last line; the
guide itself may already be sufficient content-wise. Re-run proof: a
journal citing guide.recipes during initial exploration instead of
listing per-module doc lookups as friction.
