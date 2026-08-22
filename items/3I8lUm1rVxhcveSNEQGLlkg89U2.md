## Goal

G8 — the flow system. The 403 a protected base returns names the
recovery that works, so a session hitting it finishes the item in one
more command instead of stopping at advice it cannot act on.

## Evidence

Re-measured 2026-08-22 at board head `98b1c6bf`.

`gitboard land` calls `gh.merge` on both the plain and `--force`
paths, and in this environment that call is answered
`HTTP 403: Merging into a protected base branch is not permitted for
this session type` every time. Not the PR, not the branch protection,
not the account: the SAME squash-merge issued through the session's
GitHub tooling succeeds immediately on the same PR. It is which client
issues the call. Observed on `whilp/cosmic` base `main` (PRs #1285,
#1295, #1301, #1303) and on `whilp/cosmopolitan` base `master`
(PR #267) — protected bases generally, not one branch.

**The recovery exists and works, and the message does not name it.**
Merge out of band, then re-run `gitboard land ID`: it takes the
already-merged path added in #1284 and ends the item cleanly.

```
gitboard-land: PR #1301 was already merged
gitboard-done: 3I7LGcLa completed (land)
```

What `_work/gh.tl`'s `refusal` says instead, today:

```
REFUSED (403: this token may not merge PR #N into the base branch — a
permission refusal, not the diff. The accept stands and PR #N stays in
land — ask a maintainer to squash-merge PR #N. ...)
```

"Ask a maintainer" is undiscoverable guidance for a session that holds
a second, better-privileged credential and can merge the PR itself in
the next command. It also invites the `gitboard done ID` workaround,
which bypasses `land`'s merge step and leaves no statement that the PR
landed at all.

## Change

One file plus its test. `wc -l < _work/gh.tl` is 220;
`wc -l < _work/gh_test.tl` is 62.

1. **`refusal`'s 403 branch names the two-step recovery** instead of
   deferring to a maintainer. It must say, in this order: that the
   merge was refused for the CLIENT rather than for the diff; that the
   accept stands and the item stays in `land`; and that the recovery
   is to merge the request by another route and then re-run
   `gitboard land <id>`, which takes the already-merged path. Keep
   GitHub's own detail verbatim at the end, as it is today. Do not
   name a specific tool for the out-of-band merge — the credential
   that works is a property of the session, not of the board.

2. **Nothing else changes.** `is_merged`, the 409 branch, the generic
   branch and the merge call itself are untouched.

3. **Tests.** `_work/gh_test.tl`'s
   `test_refusal_names_the_permission_wall` currently asserts the
   message contains `ask a maintainer`. Update it to assert the new
   contract instead: that the 403 message names `land` as the
   recovery verb and still ends with GitHub's detail, and that it
   remains distinct from both the 409 and the generic branches.

## Non-goals

- **Do NOT make `land` merge by another route.** The board tool
  issuing its own HTTPS request is the design; routing it through a
  session's harness credential is a different item and a much larger
  question about what the board is allowed to do on a session's
  behalf. This slice changes a MESSAGE.
- Do not add a flag, a retry, or a fallback path to `cmd_land`.
- `_work/gitland.tl` is not touched.
- No change to the 409 branch (added by #1323), to the generic
  branch, or to `is_merged`.
- No change to the `REFUSED (`/`ERROR (` prefixes — they are the
  shape an operator greps for.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/gh_test.tl` ends `test: PASS`.
- `grep -c 'ask a maintainer' _work/gh.tl` is **0** (it is 1 today —
  verified with `git show origin/board:_work/gh.tl | grep -c 'ask a
  maintainer'`).
- `grep -c 'land' _work/gh.tl` is at least 1 (it is 0 today, verified
  the same way).
- `wc -l < _work/gh.tl` ≤ 260.

## Enablement

none needed — `refusal` already branches by status and its test
already asserts message content by substring, so both halves have
their shape established. The wrong turn to predict is fixing the
underlying permission problem instead of the message: the evidence
says the working credential belongs to the session rather than to the
board, and reaching for it would change what the board tool is allowed
to do. `Non-goals` states that, and the slice is one branch of one
function.
