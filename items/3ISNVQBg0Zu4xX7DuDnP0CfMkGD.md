## Goal

G3 — an honest type layer whose boundary is checkable: D30 licenses a
library throw or exit only where no caller could receive the value,
and demands a `-- throws:`/`-- exits:` justification at every site —
"the enforcement lint is filed to follow, the way `-- assert:`'s did"
(D30, consequences). This slice is that lint: `throw-justify` and
`exit-justify`, mirrors of `assert-justify`, plus the six markers the
D30 census missed because it grepped `os.exit(` and the quicksand
post-fork children exit through `unix.exit(`.

## Evidence

Re-measured 2026-08-26 against main `8f34339e`; every cited line read:

- **The grammar**: D30 (`docs/decisions/d30-throw-exit-boundaries.md`)
  — trailing `-- throws: <why>` on an `error(` line, `-- exits: <why>`
  on an exit line, or either on the line directly above; "the same
  grammar contract as `-- cast:` and `-- assert:`". Module-level
  exemptions, stated in the record: `cosmic/check.tl` (D23) and
  `cosmic/rand.tl` (D22) "carry no per-site comments".
- **The pattern to mirror**: `_cli/assert_lint.tl` (273 lines) —
  token-exact via `tl.lex`, `is_library_source` scopes to `cosmic/**`
  minus `_test`/`_example`, one diagnostic per line via a seen-set,
  and the shared marker reader `_tool/lint.tl:54` (`is_justified`,
  pattern `%-%- <marker>: %S`, trailing or line directly above).
  Marker words `throws`/`exits` contain no pattern-magic characters.
- **Wiring**: `_cli/lint.tl` composes the rules at `:408–414` and
  re-exports each; the file is 466 lines — +10 for two loops, two
  record fields, two table entries stays under the 500 cap.
- **All 19 D30 sites are justified today** (verified by grep for the
  markers: searcher ×6, teal ×1, coverage ×1, hash ×3, child ×2,
  box/run ×5, init ×1 — trailing or line-above).
- **The census hole**: six `unix.exit(` sites carry no marker —
  `cosmic/quicksand/proxy.tl:135,152,159,161` (the forked proxy child:
  setup-failure exits and the success exit), `proxy/serve.tl:404` (the
  forked per-connection handler child), `quicksand/init.tl:127` (the
  forked userns probe child). Each read at the line: all are
  post-fork children — D30's process-boundary shape, licensed, just
  unmarked. D30's shape rules are the decision; its site lists are
  census context, so marking six more conforming sites needs no
  amendment.
- **No other exit spelling exists**: `grep -rn "\.exit(" cosmic/`
  (tests/examples excluded) finds only `os.exit(` and `unix.exit(`
  receivers; coverage's `os_mod["exit"]` wrapper is a string index the
  lexer never reads as a call.
- **The guide**: `docs/guides/lint.md` (311 lines) documents each rule;
  `## assert-justify` at `:65` is the section shape to follow.

## Change

1. **`_cli/throw_lint.tl`** (new) — one rule pair, the shape of
   `assert_lint.check_assert_justification`:
   - `throw-justify`: an `error` identifier token (not preceded by `.`
     or `:`) followed by `(`, in library source, must satisfy
     `is_justified(lines, y, "throws")`.
   - `exit-justify`: an `exit` identifier token preceded by `.` whose
     receiver token is the identifier `os` or `unix`, followed by `(`,
     must satisfy `is_justified(lines, y, "exits")`.
   - Scope: copy `is_library_source` (cosmic/** minus tests/examples);
     skip `cosmic/check.tl` and `cosmic/rand.tl` entirely — the
     module-level licences D30 records (cite D23/D22 in the comment).
   - One diagnostic per line per rule (seen-set). Teaching messages in
     assert-justify's voice: name D30's licence ("only where no caller
     could receive the value"), the marker to write, and the honest
     alternative (`nil, err`), pointing at `cosmic --docs guide.lint`.
2. **`_cli/lint.tl`** — wire both checks into `lint_file` beside the
   assert rules; re-export them in the record and table as the others
   are.
3. **`_cli/throw_lint_test.tl`** (new) — fixture-source tests in
   `assert_lint_test.tl`'s style: an unjustified `error(` is flagged;
   a trailing `-- throws:` passes; a line-above marker passes; a bare
   `-- throws:` with no reason fails; `os.exit(` and `unix.exit(`
   flagged without `-- exits:` and pass with it; a mismatched marker
   (`-- exits:` on an `error(` line) is flagged; `e.error(` and a
   string containing `error(` are not; a `fixture_test.tl` path is out
   of scope; the check.tl/rand.tl exemption (pass paths
   `cosmic/check.tl`, `cosmic/rand.tl` with a bare throw).
4. **The six markers** — `-- exits: forked child; …` in D30's grammar,
   trailing (or line above where 90 columns demand):
   `cosmic/quicksand/proxy.tl` ×4, `cosmic/quicksand/proxy/serve.tl`
   ×1, `cosmic/quicksand/init.tl` ×1. Comments only; no behavior
   change.
5. **`docs/guides/lint.md`** — a `## throw-justify / exit-justify`
   section after assert-justify: the D30 rule in one paragraph, the
   two marker words, the exemption pair, and "write the argument, not
   a restatement" carried over.

## Non-goals

- **No D30 amendment** — the record licenses shapes; the six new
  markers instantiate a shape it already names. (If review disagrees,
  the amendment is its own decide-skill slice.)
- **No new exemption**: check.tl and rand.tl only, exactly as D30
  states. `_cli/`, `_make/`, `_tool/`, `_build/`, `cmd/` stay out of
  scope, as with assert-justify.
- **No marker-orphan detection** (a `-- throws:` with no throw under
  it) — that is 3IPFx8zM's class, filed.
- **No behavior change at any exit site** — markers are comments.
- **No alias chasing**: `local e = os.exit` or a renamed receiver is
  invisible to this rule, as `assert = check.must` would be to
  assert-justify; the lint is a convention gate, not a sandbox.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c "throw-justify\|exit-justify" _cli/throw_lint.tl` ≥ 2
  (today the file does not exist).
- `grep -c "throw_lint" _cli/lint.tl` ≥ 2 (today 0).
- `grep -c -- "-- exits:" cosmic/quicksand/proxy.tl` prints 4,
  `cosmic/quicksand/proxy/serve.tl` 1, `cosmic/quicksand/init.tl` 1
  (today 0, 0, 0).
- `bin/cosmic --make test _cli/throw_lint_test.tl` ends
  `test: PASS (1 file)`.
- Negative proof, from the built binary: a scratch file
  `cosmic/tmp_probe.tl`-shaped source with a bare `error("x")` fed
  through `o/bin/cosmic --check lint` fails naming `throw-justify`
  (delete the probe after; the test file pins the same fact
  hermetically).
- `wc -l _cli/lint.tl` ≤ 500.
- `git diff --name-only origin/main` lists exactly:
  `_cli/lint.tl`, `_cli/throw_lint.tl`, `_cli/throw_lint_test.tl`,
  `cosmic/quicksand/init.tl`, `cosmic/quicksand/proxy.tl`,
  `cosmic/quicksand/proxy/serve.tl`, `docs/guides/lint.md`.

## Enablement

none needed. The rule is a token-walk copy of
`_cli/assert_lint.tl`'s justification half over two new call shapes;
the marker reader (`_tool/lint.tl` `is_justified`) is shared, not
copied; no checker-facing shape is new (the walk mirrors code already
in tree, so 3IRRqpQi's probe rule is satisfied by construction).
