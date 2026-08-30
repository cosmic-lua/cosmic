Evidence (re-review of PR #1552, 2026-08-30): the docs-style
standard's banned history constructions ("used to", "previously",
issue/PR references in comments) are enforced by nothing —
`--make lint`/`--make ci` never read comment prose — so a violation
landed in the same wave that consulted the skill: `_make/clean.tl`'s
new `kept_detail` doc comment says the old string "used to run", the
exact construction the skill bans by name. AGENTS.md's own
countermeasure principle prefers a gate in core over a doc. The
change: a lint check over doc comments (`---` lines) for the skill's
banned-phrase list (start minimal: "used to", "previously", bare
`#<digits>` issue refs; measure current violation counts across the
tree first — if legacy hits are numerous, land as a ratchet rather
than a hard fail, following the coverage ratchet's shape). Fix or
grandfather the measured existing hits in the same PR so the gate is
green at birth; pin with tests in the lint's test seam;
mutation-verify.
