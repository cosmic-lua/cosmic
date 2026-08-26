## Goal

G8 — the flow system: the verdict verb's kinds stop being
guessable-wrong toward the harshest outcome. Incident 2026-08-26
(item 3IOCco6e): a reviewer intending the middle verdict tried
`request-changes` and `rework`, got "unknown verdict" with no kind
list both times, fell through to `reject` — which parses and
de-commits to backlog — and the board needed a hand repair.

## Evidence

`_work/gitverdict.tl` (board branch, 210 lines): `VERDICT_MOVES`
holds exactly `accept`/`request changes`/`reject` (line ~41), the
canonical middle spelling carrying a SPACE; the unknown-kind refusal
(line ~66) echoes the input and teaches nothing. The consequence
asymmetry: `request changes` moves to `do` keeping the builder's
claim; `reject` moves to `backlog`, spending the commitment
(`VERDICT_MOVES` doc comment). No alias table exists;
`_work/gitverdict_test.tl` (159 lines) pins neither spelling nor the
refusal text.

## Change

1. **`_work/gitverdict.tl`** — a `KIND_ALIASES` map
   (`request-changes` and `rework` → `request changes`), applied
   before the `VERDICT_MOVES` lookup; the unknown-kind refusal
   enumerates the vocabulary with each kind's consequence
   ("accept, 'request changes' (to do, claim kept; request-changes
   and rework are aliases) and reject (to backlog, commitment
   spent)"). The verdict is RECORDED under the canonical spelling,
   so `is_rework` and every reader of `item.verdict` see one value.
2. **`_work/gitverdict_test.tl`** — one test: an unknown kind is
   refused; the hyphenated spelling moves the item to `do` with the
   builder's claim kept and the verdict recorded as
   `request changes`.
3. **Rejected, recorded here**: a confirmation step on `reject`.
   Sessions are non-interactive, so a confirm degrades to a flag
   nobody reads; the real protection is that the fall-through path to
   reject no longer exists (the aliases catch the plausible
   spellings, and the refusal teaches the rest), while reject keeps
   its existing deliberateness cost (`--enable` is already
   mandatory).

## Non-goals

- No change to the moves themselves or to `--enable`'s contract.
- No new verdict kinds.
- The claim-liveness change is its sibling (3ISONrYo, PR #1410);
  file-disjoint from this one.

## Acceptance

Run from the board-branch worktree:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `grep -c "KIND_ALIASES" _work/gitverdict.tl` reports 2 or more
  (today 0).
- `grep -c "request-changes" _work/gitverdict.tl` reports 2 or more
  (today 0) — the alias and the teaching refusal.
- `bin/cosmic --make test _work/gitverdict_test.tl` ends
  `test: PASS (1 file)` including
  `test_kind_aliases_and_the_teaching_refusal`.
- `git diff --name-only board` lists exactly `_work/gitverdict.tl`
  and `_work/gitverdict_test.tl`.

## Enablement

none needed. The change was applied and gated during refinement
(`ci: PASS (4 stages)` on the board worktree).
