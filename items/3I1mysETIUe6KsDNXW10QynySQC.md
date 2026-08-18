Imported from whilp/cosmic#1237.


## Goal

G4 — "a gate's PASS means something" — and the ready bar that G8 measures. An
`## Acceptance` command is the definition of done: the implementer runs it, the
reviewer re-runs it, and both quote its verdict line. That contract only holds
if the command is safe and meaningful to run **literally, verbatim, from the
repo root**. Two acceptance commands on the board are neither, and in both cases
the defect they hid was found by a reviewer typing the command exactly as
written.

Filed as mandated by the `request changes` verdict on PR #1209 (issue #1179).

## The wrong turn

Issue #1179's acceptance reads:

```
bin/cosmic --make run _eval/score.tl _eval/testdata/run_pass
```

A relative path pointing at a **committed** directory. Both halves are defects:

1. **The relative path is the input shape the implementation gets wrong, and no
   test can see it.** `_eval/checks/support.tl:56-63` builds argv[0] as
   `fs.join(workspace, bin_rel)` while also passing `{cwd = workspace}`;
   `cosmic/child/init.tl:383-385` chdirs in the child before exec, so a relative
   workspace resolves argv[0] as `//` → ENOENT.
   Measured at PR #1209 head `66cc670`: the acceptance command verbatim ends
   `eval: FAIL (json-cli, module-tests, sqlite-indexer, child-tcp)` with 35
   fabricated findings, while the same fixture through `$PWD/...` ends
   `eval: PASS`. Every test passes because `score_test.tl:17` and
   `checks_test.tl:27` build paths from `TEST_TMPDIR`, which is always absolute.
   The one input shape the acceptance names is the one shape the suite cannot
   reach.

2. **Running it literally mutates the committed tree.** Ten stray files were
   measured written under `_eval/testdata/run_pass/` by one acceptance run:
   `results.json`, `json-cli/testdata/items.json`, `json-cli/bad.json`,
   `text-report/empty.log`, `sqlite-indexer/testdata/tree/**`. The tests are
   careful about exactly this (`score_test.tl:8-12`: "neither may ever touch the
   committed tree"); the CLI the acceptance invokes has no such guard. A
   reviewer who runs the acceptance and then runs `git status` cannot tell a
   dirty tree from a real change.

## Evidence this is a class, not one issue

- **#1179 / PR #1209** — both defects above, found only because the reviewer ran
  the command verbatim rather than through a temp copy.
- **#1192 / PR #1195** — the same shape from the other direction: the acceptance
  named `bin/cosmic --make run _perf/run.tl --out o/perf/current.json` as "the
  load-bearing check" precisely because `--make ci` never executes the bench
  `check` bodies. It was right to name it, and it worked — which is the positive
  control for this rule: an acceptance command that genuinely exercises the
  changed path catches what the gates cannot.

## Change

Two halves, core before docs.

1. **Core — the scoring CLI must not depend on, or damage, its caller's cwd.**
   `_eval/score.tl` resolves the run dir to an absolute path once before
   `score_row`, or `support.run` passes `bin_rel` as argv[0] since `cwd` is
   already the workspace (closer to the briefs, which invoke `./o/bin/`).
   Plus a regression test that scores a fixture through a **relative** path.
   *This half is already required by PR #1209's standing verdict (Gap 1) and
   should land there, not here — it is named so this issue's scope is the
   general rule, not the instance.*

2. **Core — a scoring run must not write into its input.** The run dir is an
   operator artifact and `results.json` is an output; a CLI that mutates a
   committed fixture in place makes the fixture unusable as a fixture. Either
   copy the run dir to a temp location before scoring and write `results.json`
   to a named `--out`, or refuse to score a directory under version control
   without an explicit opt-in. Pick one and state it in the module's doc
   comment.

3. **Docs — the ready bar gains one sentence.** `skills/work/decompose.md`:
   an `## Acceptance` command must be safe and meaningful to run literally from
   the repo root — it may not write into the committed tree, and its argument
   shapes must be shapes a test actually covers. This is the judgment half that
   core cannot encode: only a human or planner reading the command can tell
   whether the path it names is the untested one.

## Non-goals

No change to any other issue's acceptance prose in passing; no sweep of the
board for other offenders (if a second instance appears, it is evidence on this
issue, not a fix inside it). No general "commands must be idempotent" rule — the
scope is writes into the committed tree and untested argument shapes, both of
which were measured. Not a lint: whether a path is "the untested shape" is not
mechanically decidable, which is why half of this is a docs change.

## Acceptance

- Scoring a fixture through a relative path from the repo root produces the same
  verdict as through an absolute path, pinned by a test.
- `bin/cosmic --make run _eval/score.tl _eval/testdata/run_pass` followed by
  `git status --porcelain _eval/testdata/` reports no modification.
- `skills/work/decompose.md` states the rule in the ready-bar section.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Second instance: #1222 / PR #1242 (2026-08-17)

The Non-goals above said a second instance would be evidence on this issue
rather than a fix inside it. Here it is, and it is a THIRD failure mode of the
same rule — the command was safe to run and it did run, but it did not measure
what the issue claimed:

```
$ git ls-files '*.tl' | xargs grep -l 'require("cosmic.literal")' | wc -l
12      # on PR #1242 head 425ae05; the issue's Acceptance demands 11
```

The property the check exists to protect — that extracting the lexer adds no new
importer of the public module — genuinely HOLDS: `cosmic/_literal_lex.tl` has
zero `require` statements. The twelfth match is the module's own doc comment at
`cosmic/_literal_lex.tl:9`, which spells `require("cosmic.literal")` in prose.
A text grep was asked a structural question.

#1178 / PR #1241, reviewed the same day, is the same mechanism again: its
Acceptance demanded `grep -c 'deps__build/env_vars_test :=.*_cli' o/project.mk`
-> `1`, and the unanchored pattern also matches the `srcdeps__build/env_vars_test
:=` line that contains it as a substring, so the command returns `2` before the
fix and `2` after it — it could neither pass nor distinguish the change.

Both were accepted (the implementations were correct and both implementers
substituted stronger evidence), but in both cases the reviewer had to reconstruct
what the command should have asked. The rule this issue states therefore has a
third clause to carry: an acceptance command must measure the property it claims
— a text grep standing in for a structural fact (who imports X, what the import
closure contains) is not that command.

The countermeasure for this clause is core and cheap, because the structural
answer already exists: `_make/imports.tl` computes each source's import closure,
and `o/project.mk` holds it as `srcdeps_`. A "who imports X" query an
acceptance can name would let these checks ask the real question. Whether that
belongs here or as its own slice is a refinement decision; #1243 covers the
adjacent-but-different failure (a count asserted with no facts block behind it,
which neither of these two had a defence against — #1222 DID carry a correct
facts block measuring 11, and the change itself moved the count to 12).


---
_Generated by [Claude Code](https://claude.ai/code)_