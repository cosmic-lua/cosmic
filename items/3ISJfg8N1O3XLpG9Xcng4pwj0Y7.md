Nothing in `--check lint` refuses a file under `cosmic/**` that requires
an internal root tree (`_cli`, `_make`, `_tool`, `_build`, `_perf`,
`_docs`, `_fuzz`). The strip floor is `cosmic/**` — anything a STRIPPED
artifact must still boot with has to live there (AGENTS.md, "Repository
Layout") — so such a require is a build-breaking mistake, and today it is
prose only.

`_cli/visibility.tl` polices the OPPOSITE direction: `check_shard_require`
(`:23-40`) reports an outside file requiring a `cosmic.*` shard, and
exempts `^cosmic/` outright. Measured 2026-08-26 at main `b4ad036b`:
`grep -rn 'require("_' cosmic/ | wc -l` is 1 — `cosmic/coverage/init_test.tl:15`
requires `_tool.coverage.report` — so the rule is honoured everywhere but
one test file, which is what makes a lint cheap to add now (a `*_test.tl`
exemption, or that one require re-homed).

Evidence it is worth gating rather than restating: item 3IOCco6e
(`cosmic.test`, the in-process runner) had to spend an Acceptance command
(`grep -c 'require("_' cosmic/test.tl` prints 0) closing this one wrong
turn for one file, because there was no gate to cite. Every future slice
that adds a `cosmic/**` file pays the same tax or skips the check.
