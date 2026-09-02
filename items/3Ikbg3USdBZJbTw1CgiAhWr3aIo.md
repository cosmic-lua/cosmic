## Change

Bring the board branch's tests to the shape AGENTS.md requires for
new files ("write new files in runner mode, the legacy self-calling
shape is on its way out", D29): delete every self-call line.

Measured 2026-09-02 on origin/board 777abb92: 34 `_work/*_test.tl`,
all legacy — `for f in _work/*_test.tl; do grep -cE
'^test_[A-Za-z0-9_]+\(\)$' $f; done` is non-zero for every file; the
self-call lines total 335 (`cat _work/*_test.tl | grep -cE
'^test_[A-Za-z0-9_]+\(\)$'`), exactly one per `local function test_*`
definition (also 335), the largest files being `_work/gitverbs_test.tl`
(21), `_work/item_test.tl` (20), `_work/review_test.tl` (20). The
mechanical edit `sed -i -E '/^test_[A-Za-z0-9_]+\(\)$/d'` applied to
`_work/githold_test.tl` produced a runner-mode file that `--make test`
ran (`test: PASS (1 file)`) and `--make check` accepted (`check: PASS
(67 files)`) under main's pin 2026-08-31-a5b36f4; under the board's
current pin the same file fails cold `check` — hence the blocker.

1. Every `_work/*_test.tl`: delete each top-level line matching
   `^test_[A-Za-z0-9_]+\(\)$` (the immediate self-call after a case's
   `end`), nothing else. A file is all-or-nothing: the `mixed` lint
   (`_cli/lint.tl:162-169`) refuses a file with some cases called and
   some not, so a partial deletion fails the gate rather than double
   running.
2. Any case whose self-call was not of that exact shape (a call with
   arguments, a call inside a wrapper) is converted by hand to the
   defined-not-called form; name each such file in the PR body.
3. `bin/cosmic --make ci` on the board branch ends `ci: PASS`;
   `.cosmic-coverage` is regenerated with `--make coverage --baseline`
   only if the ratchet moves (per-test runs change no covered line,
   so it is not expected to).

Land as one PR (a pure deletion of 335 lines across 34 files; sized
under the ~400-line smell only because every hunk is identical and
mechanical) or split by file groups if a reviewer asks — never a
subset that leaves a file mixed.

## Non-goals

No change to the tests' bodies, order, or names; no new cases; no
change to `_work/fixture.tl` or any non-test module. No pin change
(that is the blocker item).

## Acceptance

- `cat _work/*_test.tl | grep -cE '^test_[A-Za-z0-9_]+\(\)$'` is 0.
- `bin/cosmic --make ci` ends `ci: PASS` with the same test count the
  gate reported before (`34 checks: 34 passed`) and per-case counts in
  the runner's output (`(N test functions)` per file, 335 total).
