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

Finding: `require` resolution differs between plain-script and
project mode, and the difference is undocumented. 1 of 4 agents hit
it (sitegen, the multi-module brief — the one brief that exercises
imports); it cost two failed guesses and was the agent's top
friction:

- "guide.modules describes script-relative resolution (resolves
  relative to the script's directory, not cwd), which is true for
  plain cosmic script.tl execution, but --check types (and --make,
  run from the project root) actually resolve project-style dotted
  paths (sitegen.frontmatter) against the process's current working
  directory / detected project root, not the file's own directory. I
  only worked this out empirically after two failed guesses. A single
  sentence in guide.modules or the --check help text (for
  project-style paths, run from the project root, or use --modules)
  would have saved two round-trips."

Fix direction: the agent's sentence, in guide.modules and/or --check
help. If --check can detect a dotted require that would resolve from
the project root but not from cwd, an error-site hint beats both.
Re-run proof: the multi-module brief's journal shows first-guess
resolution or the hint quoted.
