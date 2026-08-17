Imported from whilp/cosmic#1204.

## Goal
G8 — the flow system. The implementer loop mandates a comment at three
points (`SKILL.md` step 2&#39;s claim, step 4&#39;s PR link, the bounce) and
`review.md` mandates one per verdict; the board tool dispatches eleven
verbs and none of them writes a comment, so every one of those is a
hand-rolled GitHub API call today.

## Change
Add a `comment` verb to the board tool: `comment N --body-file F` posts
the file&#39;s contents verbatim as a comment on issue (or PR) N, prints the
created comment&#39;s URL, and ends with a `work-comment:` verdict line.
`--body-file` is MANDATORY — a multi-paragraph verdict must never have to
survive shell quoting — and there is no inline `--body`.

`_work/close.tl` (114 lines) and `_work/close_test.tl` (53 lines) are the
template for the whole shape; read both before writing anything, and
mirror them.

Four steps, in order. `_work/github.tl` has no room for the POST today (485 of
500 lines, and the POST costs 26) — #1252 makes that room by extracting the
`Raw*` records, and this card is blocked on it. Do not pay that cost here.

**1. The API half, in `_work/github.tl`.** Add `create_issue_comment(repo,
number, body): RawComment, string` directly beside the existing GET
`list_issue_comments`, exported through the same `github` record and the
same `M` table. It POSTs `{body = body}` to
`/repos/%s/issues/%d/comments` — the same path the GET reads — and follows
`close_issue`&#39;s body exactly: `api(&#34;POST&#34;, path, ...)`, `nil, err` on a
transport failure, `nil, api_error(&#34;POST&#34;, path, res)` when
`is_success(res.status)` is false, and
`return res.value as RawComment -- cast: from any`. Add `html_url: string`
to `RawComment` (the verb prints it) — after #1252 lands that record lives in
`_work/raw.tl`; leave its other fields alone.

**2. The verb, in a new `_work/comment.tl`.** Mirror `_work/close.tl`
exactly: a module doc-comment header saying what the verb is for, one
pure helper, one `cmd_comment(repo, number, body_file): integer` returning
the process exit code, then the `local record comment` / `local M: comment`
pair. The pure helper is
`is_postable(body: string): boolean` — false for an empty or
whitespace-only body, true otherwise — and `cmd_comment` calls it.
`cmd_comment` reads the file with `fs.read` and reports a read failure the
way `verbs.cmd_edit` does (`io.stderr:write(rerr .. &#34;\n&#34;)`, then the
verdict line). Exact output contract:

- read failure, or a POST failure: the error on stderr, then
  `work-comment: ERROR`, return 1.
- body not postable: `work-comment: REFUSED ( is empty; a comment
  needs a body)`, return 1. No network call is made.
- success: `print(&#34;  &#34; .. created.html_url)`, then
  `work-comment: # posted`, return 0.

There is no phase gate and no state gate. A comment is the trail, so it
is admissible from every phase and on a closed issue — unlike `close`,
which gates on phase because a close can lose a card mid-flow.

**3. Dispatch, in `_work/board.tl`** (231/500 lines — ample headroom).
Add `local commenting = require(&#34;_work.comment&#34;)`; add a `comment` entry
to `CSPEC.commands`, placed after `close`, with
`summary = &#34;post a comment on ISSUE from a file&#34;`,
`usage = &#34;ISSUE --body-file FILE&#34;`, and flags `repo_flag()` plus
`{long = &#34;body-file&#34;, arg = &#34;FILE&#34;, help = &#34;comment body markdown&#34;}`; add
the `d.command == &#34;comment&#34;` branch, which parses the issue number and
refuses BOTH missing arguments on stderr before any API call
(`&#34;comment needs an issue number\n&#34;`,
`&#34;comment needs --body-file\n&#34;`, return 1) and otherwise calls
`commenting.cmd_comment(repo, n, body_file)`. Update the file&#39;s header
doc-comment in all three places that enumerate the surface: the verb
sentence, the usage block (`cosmic --make run _work/board.tl comment 123
--body-file F`), and the closing sentence naming which module owns which
verbs.

**4. Tests, in a new `_work/comment_test.tl`**, mirroring
`_work/close_test.tl`: `require(&#34;_work.comment&#34;)`, one `test_*` function
per claim, each called on the line after its `end`, pure functions only
(no network). Cover `is_postable`: a one-line body is postable, a
multi-paragraph body is postable, `&#34;&#34;` is not, a whitespace-only body is
not, and a body that is only a newline is not.

Measured now, and what the steps above assert:

```facts
$ wc -l &lt; _work/github.tl
485
$ wc -l &lt; _work/board.tl
231
$ wc -l &lt; _work/close.tl
114
$ wc -l &lt; _work/close_test.tl
53
$ grep -c &#39;api(&#34;POST&#34;&#39; _work/github.tl
3
$ grep -c &#39;issues/%d/comments&#39; _work/github.tl
1
$ grep -c create_issue_comment _work/github.tl
0
$ ls _work | grep -c &#34;^comment&#34;
0
$ grep -o &#39;^    {name = &#34;[a-z]*&#34;&#39; _work/board.tl | cut -d&#39;&#34;&#39; -f2 | tr &#34;\n&#34; &#34; &#34;
status next check move new edit show land close stats init
```

Read those as: the write half has three POST precedents in the file
already; the comments endpoint appears exactly once today, as the GET;
`create_issue_comment` does not exist; `_work/comment.tl` and
`_work/comment_test.tl` do not exist; and the eleven names above are the
pre-change verb surface this change makes twelve.

## Non-goals
**The verdict grammar does not move.** `_work/implementer.tl:17-18`
machine-reads it before `land` will merge —
`is_accept(body) = verdict.parse(body) == &#34;accept&#34;` — and
`_work/verdict.tl:57-66` is the grammar: a verdict is a comment whose
FIRST line is exactly `work-verdict: `, with `plan-verdict: `
the older spelling open PRs still carry, `` one of `accept`,
`request changes`, `reject`, and a trailing `\r` tolerated. Therefore:

- `cmd_comment` posts the body file&#39;s bytes UNCHANGED. No header, no
  banner, no &#34;posted by the board tool&#34; footer, no signature, no
  indentation, no leading or trailing newline added or stripped. A
  prepended anything would push a verdict off line 1 and silently make
  every accept unlandable.
- Do not edit `_work/verdict.tl` or `_work/implementer.tl`. `parse`,
  `latest`, `standing`, `KINDS`, `is_accept` and `cmd_land`&#39;s accept
  requirement all stay exactly as they are.
- The verb does not inspect the body for verdict grammar and does not
  refuse, warn about, or route a body that happens to be a verdict.
  Whether verdicts belong on the PR is `review.md`&#39;s rule, not this
  verb&#39;s business.
- `work-comment:` is a stdout verdict line, not comment-body grammar. Do
  not add `comment` to `_work/verdict.tl`&#39;s `KINDS`.

Other walls:

- This issue does NOT absorb #1193. The `close` verb already landed as
  `_work/close.tl`; it is this change&#39;s read-only template, not its
  scope. Do not touch `_work/close.tl` or `_work/close_test.tl`.
- No inline `--body` flag, no stdin, no `$EDITOR`. `--body-file` is the
  only way in.
- Do NOT extract the `Raw*` records, split `_work/github.tl`, or otherwise
  make room here. That is #1252, this card&#39;s blocker, and it lands first
  precisely so this diff is the verb and nothing else. If you find
  `_work/github.tl` still at 485 lines, #1252 has not landed and this card
  is not pullable yet — say so and stop rather than doing its work.
  `only_issues`, `issue_of` and `issue_patch` stay where they are.
- Do not change `list_issue_comments`, `_work/api.tl`, `implementer
  .cmd_show`, the label vocabulary, `model.PHASES`, or the WIP-limit
  machinery.
- Do not reword any existing `work-:` verdict line — other
  sessions and skills read them.
- No edits under `.claude/skills/work/**`. Pointing the loop&#39;s three
  mandated comments at the new verb is a separate doc slice; this one
  ships the verb.
- No new dependency and no `gh` CLI. `_work/github.tl` remains the only
  module that requires `_work.api`.

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS`. The `lint` stage is the 500-line gate.
- `bin/cosmic --check lint _work/github.tl` prints nothing and exits 0,
  and `wc -l &lt; _work/github.tl` prints a number below 500.
- `bin/cosmic --make test _work/comment_test.tl` passes, including
  `test_is_postable_*`.
- `bin/cosmic --make test _work/github_test.tl _work/verdict_test.tl
  _work/implementer_test.tl _work/close_test.tl _work/stats_test.tl`
  passes unchanged — the verdict grammar did not shift.
- `bin/cosmic --make run _work/board.tl --help` lists `comment` with its
  summary, and
  `bin/cosmic --make run _work/board.tl comment --help` shows
  `ISSUE --body-file FILE`.
- The two argument refusals, which make no network call:
  `bin/cosmic --make run _work/board.tl comment` writes
  `comment needs an issue number` to stderr and exits 1;
  `bin/cosmic --make run _work/board.tl comment 1204` writes
  `comment needs --body-file` to stderr and exits 1.
- **One real post, by hand, and it is the loop&#39;s own step 4.** A real
  `comment` writes to GitHub, so no gate can run it: `--make ci` runs
  inside a loopback-only network namespace and a gate with a side effect
  on a live issue thread is not a gate. Instead, dogfood it — the
  implementer&#39;s step 4 already owes this issue a comment carrying the PR
  link, so post THAT comment with the new verb:
  `bin/cosmic --make run _work/board.tl comment 1204 --body-file
  /tmp/prlink.md`, and quote its `work-comment: #1204 posted` line and the
  printed comment URL in the PR description. If the verb cannot post it,
  the change is not done.

## Enablement
Blocked by: #1252

`_work/github.tl` is at 485/500 and the POST this card adds costs 26 lines, so
the file-length lint would fail; #1252 extracts the `Raw*` records to about 410
and must land first. Splitting it out rather than folding it in follows
`enable.md` — a countermeasure that lands inside the PR it enables proves
nothing — and `decompose.md`&#39;s rule that an &#34;and&#34; between two independent
changes is a cut, not a sentence.

Beyond that blocker, nothing. Every convention this change needs is already mechanized or
already written down: `_work/close.tl` + `_work/close_test.tl` are a
working template for the module shape, the verdict line and the test
form; `cosmic/stream.tl` is a working template for the types-only module
step 1 creates; `close_issue` is a working template for the POST; the
500-line lint, the `-- cast:` justification lint and the
call-after-define lint each catch their own wrong turn during `--make
ci`; and the one wrong turn a gate CANNOT catch — decorating the posted
body and thereby breaking `work-verdict:` parsing — is walled in
Non-goals and pinned by `_work/verdict_test.tl` staying green.


---
_Generated by [Claude Code](https://claude.ai/code)_