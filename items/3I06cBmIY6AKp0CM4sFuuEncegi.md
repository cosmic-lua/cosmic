Imported from whilp/cosmic#1190. Refined 2026-08-17 against the current `_work/`
layout (the tool was renamed from `work` to `gitboard` and its verbs split into
per-file modules since this item's facts were first measured — see below).

## Goal

G8 — the flow system (its parent epic #1117 closed 2026-08-16, so this cites
the goal directly).

## Change

**Why this is a re-refine, not a fresh card.** The item's original facts named
`_work/github.tl` and `_work/implementer.tl`, which no longer exist — the tool
was refactored into per-verb modules (`_work/gh.tl` transport, `_work/gitland.tl`
the land verb, `_work/gitverbs.tl` the other verbs, `_work/gitboard.tl` dispatch,
`_work/gitgate.tl` shared gate/verdict machinery). That refactor also already
added a partial 403 short-circuit inside `gh.merge` (today's lines 130-135) —
but `merge` still returns a bare `boolean, string`, so `_work/gitland.tl`'s
`cmd_land` cannot classify a failure by the numeric HTTP status; it only prints
whatever string `merge` hands back, with no REFUSED/ERROR distinction and no
"ask a maintainer" text on the 403 path. This item still holds: make a refused
merge say which of two things happened, against the CURRENT tree.

The original design put the new code in a separate `_work/merge.tl` because
`_work/github.tl` had only 15 lines of headroom. That constraint is gone:
`_work/gh.tl` today has 344 lines of headroom (156/500), so the classifier
belongs directly in it — one module, no new file for ~25 lines of pure code.

1. **`_work/gh.tl`** — widen `merge`'s return from `boolean, string` to
   `Result | nil, string`:
   - Add `local record Result` with `status: integer` and `detail: string`
     (`""` on success).
   - Change `merge(s: store.Store, number: integer): Result | nil, string`:
     `nil, err` ONLY when `api.call` returns nil (no response arrived — the
     transport-failure branch, unchanged). Otherwise always return a `Result`:
     `detail = api.error_of("PUT", path, res)` when `not api.is_success(res.status)`,
     `detail = ""` on success. Delete the existing ad-hoc 403 short-circuit
     (current lines 130-135) — classification moves to the pure helper below,
     which branches on the field, not inline in `merge`.
   - Add `is_merged(res: Result): boolean` — pure; `api.is_success(res.status)`.
   - Add `refusal(pr: integer, res: Result): string` — pure; exactly two shapes,
     both interpolating `res.detail` verbatim as the final clause so GitHub's own
     message still reaches the operator:
     - `status == 403` →
       `REFUSED (403: this token may not merge PR #<pr> into the base branch —
       a permission refusal, not the diff. The accept stands and PR #<pr> stays
       in land — ask a maintainer to squash-merge PR #<pr>. <res.detail>)`
     - every other non-2xx →
       `ERROR (the merge of PR #<pr> failed and nothing was merged; PR #<pr>
       stays in land — re-run land once the cause clears. <res.detail>)`
   - Update the `gh` record's `merge` signature and the `M` table entries to
     match; add `Result`, `is_merged` and `refusal` to both.
2. **`_work/gitland.tl`** — replace the merge tail (today's lines 49-52) with:
   ```teal
   local res, merr = gh.merge(s, it.pr)
   if res == nil then
     return gate.verdict_line("land", false, merr)
   end
   if not gh.is_merged(res) then
     return gate.verdict_line("land", false, gh.refusal(it.pr, res))
   end
   ```
   The no-response branch keeps today's bare error string (no REFUSED/ERROR
   wrapper) — only a response-bearing failure gains the new classified text.
   `cmd_land` already does not call `verbs.cmd_done` on any merge failure (it
   returns before reaching that line), so "stays in land" is already true
   structurally; this item only fixes what gets printed.
3. **`_work/gh_test.tl`** (new — no test file for `_work/gh.tl` exists today):
   pure tests for `is_merged` and `refusal`, `Result` values written as
   literals, no network and no token:
   - `test_refusal_names_the_permission_wall` — `refusal(1196, {status = 403,
     detail = "d"})` starts with `REFUSED (`, contains
     `permission refusal, not the diff`, contains `ask a maintainer`, ends
     with `d)`.
   - `test_refusal_reports_other_failures_as_error` — `refusal(2, {status =
     500, detail = "d"})` starts with `ERROR (`, contains `re-run land`.
   - `test_is_merged_reads_the_status` — true for `{status = 200}`, false for
     `{status = 403}` and `{status = 500}`.

Moving the classifier into `gh.tl` in place (rather than a new file) means no
coverage-baseline path shuffle; if the coverage ratchet still complains, run
exactly the regen command its failure message prints
(`bin/cosmic --make coverage --baseline`) and commit the rewritten
`.cosmic-coverage`. That is in scope; weakening the gate any other way is not.

Every tree-fact above, measured on the `board` branch worktree at HEAD,
2026-08-17:

```facts
$ wc -l < _work/gh.tl
156
$ wc -l < _work/gitland.tl
66
$ grep -rn "gh\.merge\b" --include=*.tl . --exclude-dir=o
./_work/gitland.tl:49:  local merged, merr = gh.merge(s, it.pr)
$ sed -n '45,54p' _work/gitland.tl
  if (it.pr or 0) == 0 then
    return gate.verdict_line("land", false,
      ("REFUSED: %s names no PR to merge"):format(id:sub(1, 8)))
  end
  local merged, merr = gh.merge(s, it.pr)
  if not merged then
    return gate.verdict_line("land", false, merr)
  end
  print(("gitboard-land: merged PR #%d"):format(it.pr))
  return verbs.cmd_done(s, id, "completed", force, why)
end
$ grep -n "403" --include=*.tl -r _work --exclude-dir=o
_work/gh.tl:130:  -- 403 is its own answer: the request is fine and this token may not
_work/gh.tl:132:  if res.status == 403 then
_work/gh.tl:133:    return false, ("PR #%d: this token may not merge (403) — a human with "
_work/gh.tl:134:      .. "write access has to land it"):format(number)
$ ls _work/gh_test.tl 2>/dev/null | wc -l
0
```

## Non-goals

- **The other bare-`REFUSED:`/`ERROR` sites in `cmd_land` are untouched.**
  `_work/gitland.tl`'s no-PR, wrong-phase, no-accept and no-response branches
  keep their current strings and their current position in the gate sequence
  — only the response-bearing merge failure gains classified text.
- **No GraphQL.** `_work/api.tl` stays REST-only and is not edited at all: no
  new transport, no `node_id`, no mutation.
- **The verdict-line prefix is frozen at `gitboard-land:`.** Do not revert to
  the old `work-land:` prefix the original issue used — the tool has since
  been renamed and `gate.verdict_line` already supplies the current prefix
  from the verb name; nothing in this change touches `verdict_line` itself.
- **No new gate order and no new gates.** The phase / accept / no-PR / merge
  sequence in `cmd_land` keeps its current order and its current strings for
  every branch this item does not name above.
- **No retry, no auto-merge, no fallback merge path.** A 403 is reported,
  never worked around: nothing in this diff may attempt a second merge, a
  different merge method, or a push.
- **No status classification by string-matching.** `_work.api`'s
  `"%s %s: HTTP %d%s"` message is for humans; branch on `res.status`, the
  field.
- **`_work/gitverbs.tl` and `_work/gitboard.tl` are not touched.** The merge
  call and its classification are entirely inside `gitland.tl`/`gh.tl`.
- **Do not create a new `_work/merge.tl`.** The original design's reason for
  a separate module (15 lines of headroom on the old `github.tl`) no longer
  holds; `gh.tl` has 344 lines of headroom today, and splitting it now would
  be an unforced module for ~25 lines of pure code.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`, run from the `board` branch worktree
  (its own `README.md` has the bootstrap).
- `bin/cosmic --make test _work/gh_test.tl` ends `test: PASS (1 file)`.
- `grep -c "status == 403" _work/gh.tl` prints `1` — the classification
  branches on the FIELD. The pattern matches nowhere else in `_work/**` today
  outside `gh.tl` itself.
- `grep -c "permission refusal, not the diff" _work/gh.tl` prints `1`.
- `grep -c "REFUSED (403" _work/gh.tl` prints `1`.
- `grep -rn "gh\.merge\b" --include=*.tl . --exclude-dir=o | grep -v _test` prints
  exactly `./_work/gitland.tl:...` (still the one caller — unchanged count).
- `grep -c "gh\.is_merged\|gh\.refusal" _work/gitland.tl` prints `2`.

## Enablement

none needed. Every countermeasure this slice wants is already a gate:
`--check lint` enforces the 500-line cap that decided the placement above
(now trivially satisfied — `gh.tl` stays well under 500 even after growing by
~25 lines), the `fallible-returns` lint refuses a third return slot on the
widened `merge` signature, `--check types` fails on any unused import or a
`Result` field typo, and CI's loopback-only network namespace fails loudly if
the new test reaches for a token. The one wrong turn no gate catches — reviving
the old separate-module design after the headroom pressure that motivated it
is gone — is answered by the measured headroom fact above and the explicit
placement decision in `Change`.
