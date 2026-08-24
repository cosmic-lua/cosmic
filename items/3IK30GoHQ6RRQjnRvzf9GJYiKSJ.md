## Goal

G6 — the defining paths, ratcheted (this item's parent), on the
defining path G6 names last: agent cycles-per-task on the eval suite.

The 2026-08-23 clean-room round (`skills/agent-eval`; four isolated
Sonnet agents, leak probe NONE, one working-tree binary each at head
98dde1f, `ci: PASS` before the round; briefs bookmark/logstats/
inventory/sitegen) shipped 4/4 green — and 4/4 burned their FIRST `ci`
run on the fmt or lint stage that `--make build` and `--make test`
skip. That is one predictable wasted cycle per project, and every
agent recovered in exactly one more.

The knowledge was already published twice: `docs/guides/quickstart.md`
tells you to make `--make ci` the inner loop, and every successful
build or test already prints a trailer saying fmt and lint did not
run. Three of the four agents QUOTED that warning and tripped anyway
("It bit me exactly as predicted: build and test were green, then ci
failed on formatting I hadn't checked"; "a normal build-it, run-it,
test-it loop gives false confidence that the tree is ci-clean"), so
more prose is not the countermeasure. What this slice changes is the
one line the agent is actually reading at the moment it decides it is
done: a passive disclosure of what did not run becomes an imperative
next step, in the shape agent 3 asked for.

Re-run proof is the NEXT eval round's journals (first `ci` green, or
the trailer quoted before the first `ci` run). That is a later
measurement on a later round, deliberately not this slice's
acceptance.

## Change

Rework the build/test trailer in `_make/stage.tl` into an imperative
next-step line, and split its decision out as a pure function so a
test can pin it.

1. Add `gate_note_text(verb: string, code: integer): string | nil`
   beside `gate_note` in `_make/stage.tl`. It carries the WHOLE
   decision `gate_note` makes today — `code == 0`, `verb` is `"build"`
   or `"test"`, and both `converge.GEN_ENV` and `converge.STEP_ENV`
   read `"0"` through `cenv.get_or` — returning the note text when all
   hold and `nil` otherwise. Doc-comment it with `@param`/`@return`.
2. The text it returns is exactly this one line, with no trailing
   newline (`gate_note` adds it):

   ``next: run `cosmic --make ci` — it gates on fmt and lint, which did not run here``

3. `gate_note` becomes the printing half only: call `gate_note_text`,
   `io.write(text .. "\n")` when it is non-nil, return `code`
   unchanged. Its own signature does not move, and neither do its two
   call sites in `_make/init.tl` (lines 475 and 477, measured below).
4. Export `gate_note_text` on the `StageModule` record and in the `M`
   table, beside `gate_note`.
5. Rewrite `gate_note`'s doc comment, whose headline today is "Say
   what a verb did NOT check" — the new wording inverts that. Say
   instead that the note names the next command, and keep the two
   facts already recorded there: why it goes on the output rather than
   into a document, and why a converging build stays quiet.
6. Fix the stale quotation in `_make/converge.tl:212-214`, which
   spells the old text out ("it would otherwise say \"fmt and lint did
   not run\" in the middle of the very gate running them"). Same
   point, quoting the new line.
7. Add `test_the_gate_note_recommends_the_gate()` to
   `_make/stage_test.tl`, called on the line after its `end` per
   AGENTS.md. Through `stage.gate_note_text` it asserts: non-nil and
   containing both `next: run` and `--make ci` for `("build", 0)` and
   `("test", 0)`; nil for `("build", 1)`, `("fmt", 0)` and
   `("example", 0)`; and nil for `("build", 0)` while
   `converge.STEP_ENV` is set to `"1"`, and again while
   `converge.GEN_ENV` is set to `"1"` — each unset with
   `cosmic.env.unset` afterwards so the rest of the file runs in a
   clean environment.

Measured 2026-08-24 at main head `9bcb0f7d`:

- `wc -l < _make/stage.tl` → 279 (221 lines of headroom under the
  500-line cap)
- `wc -l < _make/stage_test.tl` → 197 (303 lines of headroom)
- `grep -c gate_note _make/stage_test.tl` → 0 — nothing covers it today
- `grep -rn "gate_note" --include=*.tl . | grep -v '^./o/'` → 6 hits:
  definition, record field and table entry in `_make/stage.tl` (100,
  249, 268); the two call sites in `_make/init.tl` (475, 477); one
  prose reference in `_make/converge.tl` (62)
- `grep -rn "did not run here" . | grep -v '^./o/'` → 1 hit,
  `_make/stage.tl:104`. No guide, doc, test or workflow quotes the
  trailer, so nothing outside `_make/` needs updating
- `grep -rn '"note:' --include=*.tl . | grep -v '^./o/'` → 1 hit, the
  same line: the `note:` prefix is ad hoc, not a grammar, and dropping
  it for `next:` breaks no parser
- `grep -rn "next: run" --include=*.tl . | grep -v '^./o/'` → 0

## Non-goals

- **Do not make `build` or `test` actually run fmt or lint.** Checking
  instead of recommending is a different, larger change with its own
  contract question (does `build` now FAIL on a fmt error?); it is not
  this slice, and this slice must not half-start it.
- **Do not widen which verbs print the note.** `example`, `benchmark`,
  `check`, `fmt` and `lint` also skip parts of the gate; the evidence
  is about `build` and `test`, and a note after every verb is noise.
  The predicate stays exactly the four conditions it has today.
- **Do not change any verdict line.** `_tool/records.tl`'s
  `format_verdict` grammar and `records.exit_code` are frozen —
  downstream scripts and CI parse `build: PASS` / `ci: FAIL (stages)`.
  `gate_note` returns its `code` argument unchanged; no exit code moves.
- **Do not change the converge suppression rule.** `COSMIC_MAKE_GEN`
  and `COSMIC_MAKE_STEP` keep their meanings and their readers; only
  the text they gate changes.
- **Do not edit `docs/guides/quickstart.md`, `docs/guides/make.md` or
  `docs/build.md`.** Their inner-loop advice is correct and this slice
  is the error-site countermeasure to it, not a rewrite of it.
- No new flag, and no environment variable to silence the note.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _make/stage_test.tl` ends `test: PASS (1
  file)`, and its output names `test_the_gate_note_recommends_the_gate`.
- `bin/cosmic --make build` ends `build: PASS` and prints a line
  matching `next: run` before it. (Run from the repo root; it writes
  only into `o/`, which is not committed.)
- `grep -c "next: run" _make/stage.tl` → `1` (today `0`).
- `grep -c "note: fmt and lint did not run here" _make/stage.tl` → `0`
  (today `1`).
- `grep -c "gate_note_text" _make/stage.tl` → `4` (definition, the call
  in `gate_note`, the `StageModule` field, the `M` entry; today `0`).
- `grep -rn "did not run here" . | grep -v '^./o/'` returns no hit in
  `_make/converge.tl` (today its comment quotes the old text).
- `wc -l < _make/stage.tl` ≤ `500` and `wc -l < _make/stage_test.tl` ≤
  `500`.

## Enablement

none needed — this item IS enablement work (a countermeasure filed
against observed eval friction), and it needs none of its own. The
enablement check on its own `Change`: a literal-minded builder's three
predicted wrong turns are (a) rewording the verdict line instead of
the note, (b) helpfully extending the note to the other graph verbs,
and (c) leaving the decision buried in an `io.write` that no test can
reach. Non-goals walls (a) and (b) explicitly; step 1's pure-function
split plus step 7's test is the countermeasure for (c), and it is
small enough to land inside this slice because it is scaffolding for
the change, not a gate policing it.
