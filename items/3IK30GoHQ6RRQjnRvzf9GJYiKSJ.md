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

Finding: every agent's FIRST ci run failed, and every failure was the
fmt or lint stage catching what `--make build`/`--make test` skip.
4 of 4 agents hit it; the docs already warn (quickstart prose, plus
the trailer "note: fmt and lint did not run here" after every
build/test), and three agents quoted the warning while still tripping:

- agent 2 (logstats): "It bit me exactly as predicted: build and test
  were green, then ci failed on formatting I hadn't checked. The tool
  tells you this is possible, but the fix (run ci as the inner loop,
  per the guide) is a discipline change I only adopted after already
  tripping on it once."
- agent 1 (bookmark): first ci failed lint on two unjustified `as`
  casts; "a tree that builds and tests clean can still fail ci ...
  the kind of thing a newcomer skimming past that paragraph would
  trip on."
- agent 4 (sitegen): "a normal build-it, run-it, test-it loop gives
  false confidence that the tree is ci-clean."
- agent 3 (inventory): first ci failed fmt on hand-indented trailing
  "-- cast:" comments.

A trap that fires 4/4 DESPITE its documented warning is the strong
signal: prose does not change behavior here. What already works: the
fmt failure names `cosmic --fix`, and every agent recovered in
exactly one cycle — the cost is now one predictable wasted ci run per
project.

Fix direction (error-site first): move the hint to the moment it can
change behavior — the trailer on a FIRST successful build/test could
actively recommend the inner loop ("run ci before you call it done")
instead of stating what did not run; agent 3 asked for exactly that
("I'd have liked that hint before the first build, not after").
Re-run proof: next round's journals show first ci green, or the
build-trailer hint quoted before the first ci run.
