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

Finding: four small doc surfaces, each hit by one agent, none a
blocker — batched here as one capture because each is a one-line to
one-paragraph doc fix, separable at plan time if any grows:

1. Shadowed-builtin lint's reserved-name list is discoverable only by
   tripping it. Agent 1's attempt-1 build failure (shadowing `load`):
   "nothing in the quickstart/testing guides warned about a curated
   list of reserved names, so it was discoverable only by tripping
   it. The error message itself was excellent though."
2. fs.find's rendered type snippet omits the array part the prose
   relies on. Agent 4: "the printed Teal record signature doesn't
   show the is {string} component, so a reader skimming just the type
   block could reasonably conclude they need to look elsewhere for
   the path list."
3. cosmic.string's patternless contract doesn't route line-parsers to
   cosmic.re. Agent 2: "a reader skimming for how-do-I-parse-a-log-
   line could easily reach for str.split/str.partition first ... 
   cosmic.re was the right tool but is a separate module a reader has
   to already know to look for."
4. flags.command's single-command example invites re-parsing
   d.parsed. Agent 1 (self-caught, never a build error): "my eyes
   pattern-matched to that shape instead ... a short don't-re-parse-
   d.parsed callout would have saved a re-read."

Also noted in passing (agent 2): the sandbox's fixture-reading rule
lives in guide.make's engine section, not guide.testing where a test
author looks for "where do I put my .log fixture".

Fix direction: each is guide/doc prose at the named site; none earns
an error-site hint on current evidence (each fired once, and 1 and 4
already self-resolve via the error message or the docs' own better
example). Re-run proof: none recurring in the next round's ranked
friction.
