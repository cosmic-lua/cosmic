Imported from whilp/cosmic#1190.

## Goal

G8 — the flow system (its parent epic #1117 closed 2026-08-16, so this cites
the goal directly).

## Change

Make a refused merge say which of two things happened — GitHub refused this
token permission, or the merge failed for any other reason — and what the
operator does next. Three files, one new module.

**1. New `_work/merge.tl`** — the merge half of a landing: the squash-merge
call plus the pure rendering of what GitHub answered. It exists as its own
module because `_work/github.tl` has 15 lines of headroom against the 500-line
cap (fact below) and this change needs ~20 there. Move `merge_pull` here,
renamed, and widen its return so the HTTP status survives:

- `local record Result` with two fields — `status: integer` (the status GitHub
  answered) and `detail: string` (`_work.api`&#39;s `error_of` rendering, `&#34;&#34;` on
  success).
- `squash(repo: string, pr: integer): Result | nil, string` — the same
  `PUT /repos/%s/pulls/%d/merge` with `{merge_method = &#34;squash&#34;}` that
  `merge_pull` sends today. `nil` plus a message ONLY when no response arrived
  (`api.call` returned nil); a non-2xx status is a `Result`, not an error,
  because the caller must classify it. Fill `detail` with
  `api_error(&#34;PUT&#34;, path, res)` only when `is_success(res.status)` is false.
- `is_merged(res: Result): boolean` — pure; `api.is_success(res.status)`. It
  exists so `_work/implementer.tl` never requires `_work.api` itself.
- `refusal(issue: integer, pr: integer, res: Result): string` — pure; the
  verdict line minus the `work-land: ` prefix, exactly two shapes:
  - `status == 403` →
    `REFUSED (403: this token may not merge PR # into the base branch — a
    permission refusal, not the diff. The accept stands and # stays in
    work:land: ask a maintainer to squash-merge PR #. )`
  - every other non-2xx →
    `ERROR (the merge of PR # failed and nothing was merged; #
    stays in work:land — re-run land once the cause clears. )`

  Both interpolate `res.detail` verbatim as the final clause, so GitHub&#39;s own
  message (&#34;Merging into a protected base branch is not permitted for this
  session type.&#34;) still reaches the operator.

**2. `_work/github.tl`** — delete `merge_pull` (its doc block, its function,
its `github` record signature line, its `M` entry). Nothing else in the file
moves. It has exactly one caller in the tree (fact below), which step 3
rewrites, so `merge_pull` disappears entirely — leave no alias behind.

**3. `_work/implementer.tl`** — add `local merge = require(&#34;_work.merge&#34;)`
beside the existing requires, and replace the six-line merge tail of `cmd_land`
(lines 185-190 today, pinned as a fact below) with:

```teal
  local res, merr = merge.squash(repo, pr)
  if res == nil then
    io.stderr:write(merr .. &#34;\n&#34;)
    print(&#34;work-land: ERROR&#34;)
    return 1
  end
  if not merge.is_merged(res) then
    print(&#34;work-land: &#34; .. merge.refusal(issue, pr, res))
    return 1
  end
```

The no-response branch keeps today&#39;s bare `work-land: ERROR` with the detail on
stderr; only a response-bearing failure gains the new text.

**4. New `_work/merge_test.tl`** — a `*_test.tl` in the house pattern (each
`test_*` called on the line after its `end`), covering the pure half only, with
`Result` values written as literals and no network and no token:

- `test_refusal_names_the_permission_wall` — `refusal(1137, 1196, {status =
  403, detail = &#34;d&#34;})` starts with `REFUSED (`, contains
  `permission refusal, not the diff`, contains `ask a maintainer`, and ends with
  `d)`.
- `test_refusal_reports_other_failures_as_error` — `refusal(1, 2, {status =
  500, detail = &#34;d&#34;})` starts with `ERROR (` and contains `re-run land`.
- `test_is_merged_reads_the_status` — true for `{status = 200}`, false for
  `{status = 403}` and `{status = 500}`.

Moving code between files moves per-file coverage, and `.cosmic-coverage` is
keyed by path with no entry for `_work/merge.tl`. If the coverage ratchet
complains, run exactly the regen command its failure message prints
(`bin/cosmic --make coverage --baseline`) and commit the rewritten
`.cosmic-coverage`. That is in scope; weakening the gate any other way is not.

Every tree-fact above, measured on `a3cd318`:

```facts
$ wc -l &lt; _work/github.tl
485
$ wc -l &lt; _work/implementer.tl
211
$ wc -l &lt; _work/implementer_test.tl
80
$ grep -rln &#34;merge_pull&#34; --include=*.tl --exclude-dir=o . | sort
./_work/github.tl
./_work/implementer.tl
$ sed -n &#39;185,190p&#39; _work/implementer.tl
  local ok, merr = gh.merge_pull(repo, pr)
  if not ok then
    io.stderr:write(merr .. &#34;\n&#34;)
    print(&#34;work-land: ERROR&#34;)
    return 1
  end
$ grep -rn &#34;403&#34; --include=*.tl _work | wc -l
0
$ ls _work/merge.tl _work/merge_test.tl 2&gt;/dev/null | wc -l
0
```

## Non-goals

- **The draft refusal is not this card.** `_work/implementer.tl`&#39;s
  `PR #%d is a draft; mark it ready for review — the REST API cannot` (one match
  today) stays byte-identical, and so does its position in the gate sequence.
  Un-drafting is a separate slice, and it must land after this one.
- **No GraphQL.** `_work/api.tl` stays REST-only and is not edited at all: no
  new transport, no `node_id` on `RawPull`, no mutation.
- **The verdict vocabulary is frozen.** `work-land:` lines begin with `REFUSED`,
  `ERROR`, or the success form `#%d via PR #%d`. Do not invent a third word
  (`BLOCKED`, `DENIED`) and do not change the three other bare
  `work-land: ERROR` sites in `cmd_land` (the get_pull, get_issue and
  list_issue_comments failures).
- **No new gate order and no new gates.** The closes / merged / open / draft /
  phase / accept / `mergeable_state` sequence keeps its current order and its
  current strings. `work-verdict: accept` remains the accept gate.
- **No retry, no auto-merge, no fallback merge path.** A 403 is reported, never
  worked around: nothing in this diff may attempt a second merge, a different
  merge method, or a push.
- **`_work/github.tl` gains no lines.** It has 15 of headroom; the only edit
  there is the deletion. Do not park the new record or the classifier in it, and
  do not split it further in this PR.
- **No status classification by string-matching.** `_work.api`&#39;s
  `&#34;%s %s: HTTP %d%s&#34;` message is for humans; branch on `res.status`, the field.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/merge_test.tl` ends `test: PASS (1 file)`.
- `bin/cosmic --make test _work/implementer_test.tl` ends `test: PASS (1 file)`
  — the existing pure tests are untouched.
- `grep -rln &#34;merge_pull&#34; --include=*.tl --exclude-dir=o . | sort` prints
  nothing (it prints `./_work/github.tl` and `./_work/implementer.tl` today).
- `grep -c &#34;status == 403&#34; _work/merge.tl` prints `1` — the classification
  branches on the FIELD, not on a substring of `api.error_of`&#39;s prose. The
  pattern matches nowhere in `_work/**` today (`grep -rn &#34;status == 403&#34;
  --include=*.tl _work | wc -l` prints `0`). Do not widen this to `grep -c
  &#34;403&#34;`: the message text also carries `403`, so that pattern counts two
  lines, not one.
- `grep -c &#34;permission refusal, not the diff&#34; _work/merge.tl` prints `1`.
- `grep -c &#34;REST API cannot&#34; _work/implementer.tl` prints `1` — the draft
  refusal is unchanged (it prints `1` today).
- `wc -l &lt; _work/github.tl` prints a number below `485`.

## Enablement

none needed. Every countermeasure this slice wants is already a gate:
`--check lint` enforces the 500-line cap that decides the placement above, the
`fallible-returns` lint refuses a third return slot on the widened signature,
`--check types` fails on the unused `gh` alias if the require is dropped, and
CI&#39;s loopback-only network namespace fails loudly if the new test reaches for a
token. The one wrong turn no gate catches — parking the new code in
`_work/github.tl` and hitting the cap — is answered by the measured headroom
fact and the explicit placement in `Change`.


---
_Generated by [Claude Code](https://claude.ai/code)_