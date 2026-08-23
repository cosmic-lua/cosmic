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

The round's keep-it list — what the journals PRAISED, filed so a
future change that would regress one of these has the evidence in
reach:

- --docs as a complete offline reference: "cosmic --docs sqlite gave
  me a complete, accurate reference (including the exact nil-vs-error
  contract for query_one) in one call, and I wrote the whole storage
  layer against it without a single does-this-method-exist trial"
  (agent 3).
- Error messages naming file:line, the problem, and the fix or fix
  command: "Zero time spent searching for what an error meant"
  (agent 3); "the error message itself was excellent — named the
  file/line and explained the why" (agent 1, on the shadowing lint).
- cosmic --fix closing the fmt loop: used by every agent that hit a
  fmt failure, correct on first use each time, suggested by the
  failure itself.
- Position-is-the-manifest: "zero configuration: no manifest, no
  build file to keep in sync, just cmd/inventory/main.tl →
  o/bin/inventory ... exactly as documented" (agent 3); held for
  agent 4's four-module tree on first read.
- sqlite.open(":memory:") plus check.must/check.equal for tests
  (agent 3); the warm rebuild loop fast enough that "iterating was
  never annoying" (agent 3).

No action; this is the baseline the next round compares against.
