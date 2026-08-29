## Goal
G8 — the flow system. A rework that answers a bounce correctly must be
re-judgeable. Today `gitboard verdict` refuses one whenever the rework
moved the SPEC rather than the diff, so a finished, independently
re-reviewed accept cannot be recorded and the item is stuck in `check`
with nothing that can move it.

## Change
Widen what the verdict guard compares from the PR head ALONE to the pair
(PR head, spec revision), and record the second half on the item so the
next round has something to compare against. The guard keeps its
meaning — a judgment on evidence nothing has changed is still refused —
and gains no `--force`, no flag, and no per-verdict-kind exemption.

Why the pair rather than an exemption for `accept`: an accept that
follows a real rework passes because SOMETHING MOVED, not because it is
an accept. Exempting the kind would let an accept through on evidence
that is byte-identical to what was just bounced, which is the rubber
stamp the guard exists to refuse; and a second identical `request
changes` stays noise under the same rule, with no second predicate to
keep in step. One symmetric predicate, both properties.

Five files, all on the `board` branch:

- `_work/spec.tl` — measured `wc -l _work/spec.tl` → `129`, so 371 lines
  of headroom under the 500-line cap. Add one pure function beside
  `ready_gaps`/`section_of`:

  ```teal
  --- The revision of a spec sidecar: a content digest of its body, so
  --- two readings of the same text are the same revision and any edit
  --- is a different one.
  --- @param body string The spec sidecar's markdown, "" when it has none
  --- @return string 64 lowercase hex characters
  local function revision(body: string): string
    return hash.sha256_hex(body)
  end
  ```

  with `local hash = require("cosmic.hash")` at the top and `revision`
  added to the `spec` record and `M`. It lives here because this module
  already owns what a spec IS, and because both callers below hold the
  body rather than the store — `spec.revision` stays pure and neither
  caller grows a read. `hash.sha256_hex` is infallible and returns a
  bare string (`cosmic --docs cosmic.hash.sha256_hex` → "Returns a
  64-character lowercase hex string"), so this is not a fallible return
  and carries no error slot. An item with no sidecar hashes `""` to a
  stable constant, so "no spec" needs no special case anywhere.

- `_work/item.tl` — measured `wc -l _work/item.tl` → `336` (164 of
  headroom). Add one field to `Item`, directly under `verdict_head`:

  ```teal
  --- The spec revision the verdict judged (`_work.spec.revision` of
  --- the sidecar as it stood). "" on an item verdicted before the
  --- field existed, which is not the same as a spec that has not
  --- moved: unknown, so nothing may be concluded from it.
  verdict_spec: string
  ```

  Mirror it in `decode` beside `verdict_head` (line 238) as
  `verdict_spec = tostring(t.verdict_spec or "")`, and in `encode`
  beside `verdict_head` (line 289), written only when non-empty. Add
  NOTHING to `problems`: `verdict_head` has no rule there either, and
  this field is derived by the verb, never typed by a caller.

- `_work/gitverdict.tl` — measured `wc -l _work/gitverdict.tl` → `237`
  (263 of headroom); the guard is at line 133, measured
  `grep -n "head == (it.verdict_head" _work/gitverdict.tl` →
  `133:  if (head or "") ~= "" and head == (it.verdict_head or "") then`.
  Require `_work.spec`, read the sidecar once before the guard
  (`local now = spec.revision(store.read_spec(s, id))`), and replace the
  predicate with one that refuses only when BOTH facts are known and
  BOTH are unchanged:

  ```teal
  if (head or "") ~= "" and head == (it.verdict_head or "")
  and (it.verdict_spec or "") ~= "" and now == it.verdict_spec then
  ```

  An empty recorded revision does not refuse, for the same reason an
  empty `head` does not today: the board does not know what spec that
  verdict read, so it cannot assert nothing new happened. Every item
  verdicted from this change onward records one.

  Record it where the head is recorded (line 164):
  `it.verdict_spec = now`, on the line after `it.verdict_head = head or ""`.
  `--head` keeps every one of its jobs — the field it writes is
  untouched, and `land`'s dependence on it (`_work/gitland.tl:66,75,78`
  through `_work/review.tl`'s `head_moved`/`blocks_land`) is unchanged.

  The refusal keeps its diagnostic value by naming BOTH facts it
  compared and nothing else:

  ```
  REFUSED: %s already carries a %s verdict on head %s with spec %s —
  neither the diff nor the spec has moved since
  ```

  formatted with `id:sub(1, 8)`, `it.verdict`, `head:sub(1, 7)` and
  `now:sub(1, 7)`, on one logical line. It states what the board
  compared; it does not suggest editing the spec as a way past itself.

- `_work/gitverbs.tl` — measured `wc -l _work/gitverbs.tl` → `385` (115
  of headroom). `cmd_move`'s return branch already clears `verdict`,
  `verdict_head` and `enable` when an item moves leftward out of
  `check`/`land` (lines 279–282). Clear `verdict_spec` there too: half a
  cleared record would leave the guard comparing a revision against a
  head that is gone.

- `_work/gitshow.tl` — measured `wc -l _work/gitshow.tl` → `246` (254 of
  headroom). `show_report` already receives the sidecar `body` and is
  PURE over it, and already requires `_work.spec`. The verdict line
  (lines 99–102, today `verdict: %s (head %s)`) gains the derived fact a
  re-reviewer actually needs — whether the spec has moved since the
  judgment — rendered only when `it.verdict_spec ~= ""`:

  ```
  verdict: request changes (head 5364cc2, spec changed since)
  verdict: accept (head 5364cc2, spec unchanged since)
  verdict: request changes (head 5364cc2)      -- unrecorded revision
  ```

  This is the human half of the same defect: `gitboard show` is what a
  re-reviewer reads before deciding whether there is anything new, and
  today it can only show the head.

Tests, three files:

- `_work/item_test.tl` (`wc -l` → `229`): extend the encode/decode
  round-trip that already sets `verdict_head = "abc1234"` (line 45) to
  carry a `verdict_spec`, asserting it survives the round trip and that
  an empty one is omitted from the encoded table.
- `_work/gitverdict_test.tl` (`wc -l` → `235`; measured baseline
  `bin/cosmic --make test _work/gitverdict_test.tl` → `✓
  _work/gitverdict_test.tl (9 test functions)` and `test: PASS (1
  file)`): extend `test_a_verdict_refuses_a_head_it_already_judged` so
  it pins the UNCHANGED case explicitly — same head, spec untouched, a
  second verdict of either kind refused — and add
  `test_a_spec_only_rework_earns_a_fresh_verdict`: bounce on a head,
  rewrite the sidecar through `verbs.cmd_spec` with `--base`, move back
  to `check`, and assert the accept on that same head is ACCEPTED and
  the item reaches `land`.
- `_work/gitshow_test.tl` (`wc -l` → `193`): assert the rendered verdict
  line carries `spec changed since` after a spec-only rework and
  `spec unchanged since` when it has not moved.

## Non-goals
- No `--force` on `verdict`, no new flag, and no way for a caller to
  assert "the record changed" — the board holds the spec and does the
  comparing.
- `--head` is never dropped and `verdict_head` never stops being
  written: `land` depends on it (`_work/gitland.tl:66,75,78`,
  `_work/review.tl:121,143`). Neither `gitland.tl` nor `review.tl` is
  touched.
- No per-verdict-kind exemption. An accept on evidence that has not
  moved at all stays refused.
- No change to `gate.commit_and_publish`, `store.save`, `item.problems`
  or any other validation path — every mutation keeps going through the
  same compare-and-swap publish and the same per-item validation.
- Nothing under `items/**` is hand-edited, and no verdict is recorded on
  `3IZ0nP5R` by this slice — the tool is the work, not the item it
  unblocks.
- `skills/**` and the product tree on `main` are not touched. The
  matching sentence in `skills/work/review.md:128` ("treat an unmoved
  head as nothing to judge") is out of this branch's reach and is filed
  as `3IalNYkq`.
- No `docs/flow-review.md` change; no WIP limit moves.

## Acceptance
Run from the `board` worktree root.

1. `bin/cosmic --make ci` — ends `ci: PASS`. (An orphan-branch note,
   `HEAD is not a descendant of origin/main`, is expected and benign.)
2. `bin/cosmic --make test _work/gitverdict_test.tl` — ends
   `test: PASS (1 file)` and reports `11 test functions` (9 today,
   measured above; the two new ones are the identical-state pin and
   `test_a_spec_only_rework_earns_a_fresh_verdict`).
3. `bin/cosmic --make test _work/item_test.tl _work/gitshow_test.tl` —
   ends `test: PASS (2 files)`.
4. `grep -c "verdict_spec" _work/gitverdict.tl` — exactly `2`: the
   guard's read of the recorded revision and the write that records
   the new one. The refusal formats the freshly computed local, not
   the field, so it is not a third. Measured today across `_work/` and
   `cmd/`, `grep -rn "verdict_spec" _work/ cmd/ | wc -l` → `0`.
5. The mutation test, run by hand and quoted in the handover: delete the
   `and (it.verdict_spec or "") ~= "" and now == it.verdict_spec` half of
   the guard's predicate and re-run command 2 — it must FAIL on
   `test_a_spec_only_rework_earns_a_fresh_verdict`; restore it and re-run
   to green. A guard that cannot be shown to fail is decoration.
6. `o/bin/gitboard show 3IZtg3eG` — after `--make build`, prints a
   `verdict:` line for any item carrying one; on an item whose
   `verdict_spec` is unrecorded the line is byte-identical to today's
   `verdict: %s (head %s)` form.

## Enablement
None needed. Everything the change touches is on this branch;
`cosmic.hash.sha256_hex` already ships in the pinned cosmic
(`bin/cosmic --docs cosmic.hash.sha256_hex` prints its signature), and
`_work/fixture.tl` already builds the scratch boards the two new tests
need. The one adjacent gap — `skills/work/review.md:128` teaching
reviewers the same wrong assumption — lives on `main`, cannot be fixed
from this branch, and is filed as `3IalNYkq`; it blocks nothing here,
because the tool refusing correctly is what makes the doc's advice
merely incomplete rather than load-bearing.

---

## Measured

Measured 2026-08-29 against `board` at `09ec0eb`.

**The guard, run.** Written to `_work/scratch_measure.tl` and run with
`bin/cosmic --make run _work/scratch_measure.tl`, then removed — it is
not part of the diff:

```teal
local check = require("cosmic.check")
local fixture = require("_work.fixture")
local fs = require("cosmic.fs")
local store = require("_work.store")
local verbs = require("_work.gitverbs")
local vrd = require("_work.gitverdict")

local s = fixture.init_state_repo("scratch-measure")
local goal, leaf = fixture.root_with_leaf(s)
fixture.give_spec(s, leaf)
verbs.cmd_move(s, leaf, "ready", nil, 0, false, "")
verbs.cmd_move(s, leaf, "do", "builder", 0, false, "")
verbs.cmd_move(s, leaf, "check", nil, 42, false, "")
local counter = fixture.file_item(s, "the countermeasure", goal)
vrd.cmd_verdict(s, leaf, "request changes", 42, "5364cc21", counter,
  "reviewer-one")
local base = fs.join(fixture.tmpdir, "base-spec.md")
local path = fs.join(fixture.tmpdir, "reworked-spec.md")
assert(fs.write(base, store.read_spec(s, leaf)))
assert(fs.write(path, fixture.READY_SPEC .. "## Evidence\nRe-ran it.\n"))
verbs.cmd_spec(s, leaf, path, base)
verbs.cmd_move(s, leaf, "check", nil, 42, false, "")
print(vrd.cmd_verdict(s, leaf, "accept", 42, "5364cc21", "", "reviewer-two"))
print(vrd.cmd_verdict(s, leaf, "accept", 42, "deadbeef", "", "reviewer-two"))
```

Output, verbatim:

```
--- round 1: request changes on head 5364cc21
gitboard-verdict: request changes on 3IakwRYo: check -> do
rc: 0
  phase=do verdict=request changes verdict_head=5364cc21
--- rework: change ONLY the spec sidecar, head stays 5364cc21
gitboard-spec: 3IakwRYo's spec replaced
spec: 0
  spec now 184 bytes
gitboard-move: 3IakwRYo do -> check
move check: 0
  phase=check verdict=request changes verdict_head=5364cc21
--- round 2: accept on the SAME head after a spec-only rework
gitboard-verdict: REFUSED: 3IakwRYo already carries a request changes
verdict on head 5364cc2 — nothing new to judge
accept: 1
--- a moved head is still judged
gitboard-verdict: accept on 3IakwRYo: check -> land
accept: 0
```

So: the sidecar genuinely changed (110 bytes → 184), the head did not,
the `do -> check` move preserved `verdict_head` (it is a forward move,
and only `flow.is_return` clears the verdict fields —
`_work/gitverbs.tl:277-283`), and the accept was refused with exit 1. A
moved head is judged normally, exit 0. Neither fact was read off the
source; both were run.

**The real case.** On `3IZ0nP5R`, the rework between the bounce
(`3feba53`) and the return to `check` touched the sidecar and only the
sidecar:

```
$ git diff --stat 3feba53 e69b0dd -- items/3IZ0nP5RQEOKtnuYUdd9j6E4POu.md
 items/3IZ0nP5RQEOKtnuYUdd9j6E4POu.md | 75 +++++++++++++++-------------
 1 file changed, 44 insertions(+), 31 deletions(-)

$ git show 3feba53:items/3IZ0nP5RQEOKtnuYUdd9j6E4POu.md | sha256sum
ce43b80a5bf10aa95fb004f63918c6ac6d9b2355cd614375112d072bb09f76c5

$ git show e69b0dd:items/3IZ0nP5RQEOKtnuYUdd9j6E4POu.md | sha256sum
d244c2e538f53b0fd02fb895ec7f234e9d3fdad065360559e40d87b421344af7
```

`verdict_head` on that item is still `5364cc217cbc4377...`, unchanged
across the rework. The pair the widened guard compares therefore
differs, which is exactly the fact the head alone cannot carry.

**Sizes and sites.**

```
$ wc -l _work/spec.tl _work/item.tl _work/gitverdict.tl \
        _work/gitverbs.tl _work/gitshow.tl
  129 _work/spec.tl
  336 _work/item.tl
  237 _work/gitverdict.tl
  385 _work/gitverbs.tl
  246 _work/gitshow.tl

$ grep -rn "verdict_spec" _work/ cmd/ | wc -l
0

$ grep -n "verdict_head" _work/*.tl | grep -v _test.tl
_work/gitgraph.tl:44, _work/gitland.tl:66,75,78, _work/gitshow.tl:101,
_work/gitverbs.tl:281, _work/gitverdict.tl:133,164, _work/item.tl:80,238,289,
_work/review.tl:116,119,121,122,140,143,151,153,164,165
```

`gitgraph.tl:44` builds a fresh item with a record literal that already
omits several fields (`builders`, `reviewer`, `enable`), so a new field
needs no edit there — confirmed by that literal type-checking today
without them.

---

## Result

Landed on `board` as `46bfab8` ("verdict judges a pair: the head and the
spec revision it is measured against"). There is no PR: this is
board-branch machinery, which the branch's own README publishes by push
and gates with the `board` workflow.

**What shipped.** The evidence a verdict judges is now the pair (PR
head, spec revision). `_work.spec.revision(body)` digests the sidecar;
`gitverdict` computes it once per call, refuses only when the head is
known-and-unchanged AND the recorded revision is known-and-unchanged,
records it beside `verdict_head`, and names both halves in the refusal.
`gitverbs` clears both halves together on a leftward move out of
`check`/`land`. `gitshow` renders the derived fact — `spec changed
since` / `spec unchanged since` — and says nothing when the revision is
unrecorded.

**Diff stat**, `git show --stat 46bfab8`:

```
 _work/gitshow.tl         | 18 ++++++++++--
 _work/gitshow_test.tl    | 30 +++++++++++++++++++
 _work/gitverbs.tl        | 12 +++++---
 _work/gitverdict.tl      | 35 +++++++++++++++++-----
 _work/gitverdict_test.tl | 75 +++++++++++++++++++++++++++++++++++++----
 _work/item.tl            |  9 ++++++
 _work/item_test.tl       | 22 ++++++++++++++
 _work/spec.tl            | 19 ++++++++++++
 8 files changed, 200 insertions(+), 20 deletions(-)
```

**Acceptance, run.**

1. `bin/cosmic --make ci` → `ci: PASS (4 stages)`, with
   `coverage: PASS (29 files)` and `coverage ratchet ok`.
2. `bin/cosmic --make test _work/gitverdict_test.tl` →
   `✓ _work/gitverdict_test.tl (11 test functions)` and
   `test: PASS (1 file)`. 9 before, 11 after, as specified.
3. `bin/cosmic --make test _work/item_test.tl _work/gitshow_test.tl` →
   run together with (2) as `test: PASS (3 files)`:
   `✓ _work/gitshow_test.tl (8 test functions)`,
   `✓ _work/item_test.tl (12 test functions)`.
4. `grep -c "verdict_spec" _work/gitverdict.tl` → `2`, the corrected
   bound (see the note below).
5. Mutation test. Replacing the guard with its old predicate —
   `if (head or "") ~= "" and head == (it.verdict_head or "") then`,
   dropping the `and (it.verdict_spec or "") ~= "" and judged_spec ==
   it.verdict_spec` half — and re-running (2) gives
   `test: FAIL (1 of 1 file)` at
   `o/_work/gitverdict_test.lua:129: and the accept on that same head
   is a fresh round`, inside
   `test_a_spec_only_rework_earns_a_fresh_verdict`. Restoring the half
   returns `test: PASS (1 file)`. The guard has been shown to fail.
6. `o/bin/gitboard show 3IZ0nP5R` after `bin/cosmic --make build` →
   `verdict: request changes (head 5364cc217cbc4377966dd16dcbd981d91686b5ba)`,
   byte-identical to the pre-change form, because that item's revision
   is unrecorded. Same for `3IZaO4Vj`.

**Board CI.** Run 3361 on `board`,
<https://github.com/whilp/cosmic/actions/runs/33255642987>, head
`46bfab8`, job `ci`, conclusion **success** (the `gate` step is
`bin/cosmic --make ci`).

**Two deviations from the Change, both naming only.** The local holding
the freshly computed revision is `judged_spec`, not `now` — it sits one
line from `it.verdict_spec` and `now` read as a timestamp. And the
Acceptance count in (4) was written as "at least 3" on the assumption
that the refusal would format the FIELD; it formats the local, so the
true count is 2 and the bound was corrected in place rather than the
code contorted to meet it.

**What did not move.** `--head` is still required and `verdict_head` is
still written on every verdict; `_work/gitland.tl` and
`_work/review.tl` are untouched, so `land`'s head enforcement is
exactly what it was. No `--force` was added to `verdict`. No verdict
was recorded on `3IZ0nP5R` and its files were not touched. Nothing
under `items/**` was hand-edited. `skills/**` and the product tree on
`main` were not touched; the matching sentence at
`skills/work/review.md:128` is filed as `3IalNYkq`.

**What a reviewer should check hardest.** That an unrecorded revision
refusing nothing is the right migration rule. Every item verdicted
before `46bfab8` — `3IZ0nP5R` and `3IZaO4Vj` among them — gets exactly
one re-verdict on an unmoved head, because the board genuinely cannot
say what spec those verdicts read. The alternative, reconstructing the
sidecar at the verdict commit from the git log, would be precise but
would make the guard depend on archaeology rather than on a recorded
fact. That tradeoff is the one judgment call in this diff.
