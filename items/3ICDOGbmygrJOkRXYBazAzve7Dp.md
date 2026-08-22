## Goal

G8 — the flow system. Builder distance is enforced at both ends and
auditable afterwards: `verdict` refuses the builder, and the commit
says who judged.

## Evidence

2026-08-20 machinery audit of the board branch (at 5577fd73; still
true at board head `46f3f43b`). `_work/action.tl`'s `reviewable`
skips only `claim == session`; the rework path merely PRINTS "hand it
back with --claim <session>"; `cmd_move` neither requires nor
verifies a claim on the `do -> check` handover; and `cmd_verdict`
takes no `--session` at all (`grep -c session _work/gitverdict.tl` is
0). Every board commit is authored as the fixed identity
`cosmic-board <board@cosmic>` (`_work/store.tl` GIT_DEFAULTS), and a
verdict commit's subject is `verdict <id8> <kind> (check -> do)` —
so the log cannot show whether an accept was written by the builder.

**The predicted scenario ran, the same day.** 3I1J9Xhg (coverage floor
becomes a literal, PR #1295) was built by `claude-cloud-yv5jl8` and
bounced `request changes`. Session `dji1my` took the rework, pushed
`07ac88c4`, and moved it back with `move 3I1J9Xhg check --pr 1295` —
without `--claim dji1my`. `next --session dji1my` then offered
`dji1my` the verdict on the head `dji1my` had just pushed. Only an
operator instruction stopped it.

The repair sharpened the fix twice:

1. **No verb corrects a claim.** `move ID <its current phase> --claim
   X` answers `<id8> is already in <phase>` and drops the flag
   silently. The repair was `move … do --claim dji1my` then `move …
   check --pr 1295 --claim dji1my`, which writes two spurious
   transitions a flow instrument (3I4BaVrL) will read as real dwell.
2. **A no-op move silently discarding `--claim`/`--pr` is the wider
   bug.** The flags are accepted, the command exits 0, and nothing
   says the write did not happen.

## Change

Four changes, one guarantee: the session that built cannot be the
session that judges, and the log proves it.

1. **`verdict` takes `--session SESSION`.** `_work/gitboard.tl` adds
   `{long = "session", arg = "SESSION", help = "the reviewing session"}`
   to `verdict`'s flag list (the same flag `next` already declares at
   line 101) and passes `d.parsed.values["session"] or ""` through.
   `cmd_verdict`'s signature gains a trailing `session: string`.

2. **`cmd_verdict` refuses the builder.** After the phase guard and
   before the already-judged-head guard: when `session ~= ""` and
   `session == (it.claim or "")`, return
   `REFUSED: <id8> is <session>'s own build — no session accepts its own work`.
   An empty `--session` is not refused; naming yourself is what is
   checked, and the flag stays optional so an unattended repair is
   still possible.

3. **The verdict commit records the reviewer.** The subject becomes
   `verdict <id8> <kind> (<from> -> <to>) by <session>` when a session
   is named, and is unchanged when it is not. This is what makes the
   distance a property the flow review can measure from the log it
   already reads (item 3ICDP7Vn's whole ask).

4. **`move … check` names its builder, and a same-phase move applies
   its field flags.** In `_work/gitverbs.tl` `cmd_move`:
   - beside the existing `target == "check"` gates: refuse when the
     item would arrive unclaimed —
     `(claim or "") == "" and (it.claim or "") == ""` —
     with `REFUSED: a handover to check names its builder — pass --claim <session>`.
     `--force` passes, as with every other gate.
   - the `from == target` branch stops refusing outright: when
     `--claim` or `--pr` is passed it applies them, validates, and
     commits with the subject `set <id8> in <phase>`; with neither
     flag it refuses exactly as today (`<id8> is already in <phase>`).
     This is the repair path the evidence asked for — a claim settable
     without a phase change, so correcting one stops writing spurious
     transitions.

5. **Tests.** `_work/gitverdict_test.tl` (88 lines) gains
   `test_verdict_refuses_the_builder` and
   `test_verdict_subject_names_the_reviewer`.
   `_work/gitverbs_test.tl` (408 lines) gains
   `test_check_handover_needs_a_claim` and
   `test_same_phase_move_applies_its_flags`, the second asserting both
   that the field lands and that the phase did not change.

Measured at board head `46f3f43b`: `wc -l < _work/gitverdict.tl` is
127, `wc -l < _work/gitboard.tl` is 296, `wc -l < _work/gitverbs.tl`
is 464 — 36 under the 500-line cap, which the roughly 20 lines item 4
adds fit inside.

## Non-goals

- `_work/action.tl` is not touched. Widening `reviewable` past the
  single `claim` field is item 3IE6ttNh's slice; this one makes the
  claim honest at the two points that write it, and the two slices
  compose without either depending on the other.
- `--session` stays OPTIONAL on `verdict`. Making it mandatory would
  refuse every existing repair path and is a separate decision.
- No change to the board's commit identity (`_work/store.tl`
  GIT_DEFAULTS) — the reviewer rides in the subject, not the author.
- No change to the `gitboard-verdict:` or `gitboard-move:` verdict
  line formats.
- The three verdict kinds, their target phases, and the `--enable`
  requirement on a non-accept do not change.
- `land` is not touched; gating the move into it is item 3ICDNqdv's.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/gitverdict_test.tl
  _work/gitverbs_test.tl` ends `test: PASS`, including
  `test_verdict_refuses_the_builder`,
  `test_verdict_subject_names_the_reviewer`,
  `test_check_handover_needs_a_claim` and
  `test_same_phase_move_applies_its_flags`.
- `o/bin/gitboard help verdict` lists `--session`.
- `wc -l < _work/gitverdict.tl` ≤ 200, `wc -l < _work/gitboard.tl` ≤
  320, `wc -l < _work/gitverbs.tl` ≤ 500.
- `grep -c 'session' _work/gitverdict.tl` is at least 3 (it is 0
  today).

## Enablement

none needed — `next` already declares the identical `--session` flag
in `_work/gitboard.tl`, `cmd_verdict` already owns a stack of
refusals in exactly this shape, and `gate.commit_and_publish` already
takes the subject as a string. The wrong turn to predict is making
`--session` mandatory on `verdict`, which would strand every item
whose repair needs a verdict written without one; Non-goals states it
and `_work/gitverdict_test.tl`'s existing cases, which pass no
session, fail if it happens.
