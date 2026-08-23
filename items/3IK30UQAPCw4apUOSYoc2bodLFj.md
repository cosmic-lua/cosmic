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

Finding: the round's only build stall was the discarded-fallible-
return rule firing on bare `db:close()` — 11 sites across 2 files
for agent 3 (inventory), its attempt-1 build failure and its
top-ranked friction. 1 of 4 agents hit it (the only sqlite brief).
The check itself was endorsed: "defensible as a design choice (a
swallowed close failure is a real bug class) ... an exec/add/take
result I *did* want to be forced to check" — the cost is that the
shipped docs model the pattern the checker then rejects:

- "the guide.testing/quickstart examples call db:close() bare inside
  assert(...), which reads as the idiom, and only the compiler told
  me plain db:close() at statement level doesn't get a free pass."
- "the fix is pure boilerplate (local _ok, _err = ...) with no way to
  write it once."

Fix direction: a one-line note beside `sqlite.Database.close` in the
module docs (or a gotcha entry) saying close()'s return is fallible-
and-must-be-captured like every other sqlite method — the agent's own
ask. Weakening the check is NOT the fix the evidence supports; the
agent also floated a close_ignoring_errors() escape hatch, which is a
plan-phase question. Re-run proof: the sqlite brief's next journal
shows zero close() sites in the first build failure, or the doc note
quoted.
