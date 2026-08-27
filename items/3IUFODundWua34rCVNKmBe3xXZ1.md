## Goal

G8 — the flow system (this item's parent is the G8 container). A refinement a
session commits is not silently replaced by a concurrent one, and every spec
change is visible in the item's own trail.

## Change

Two behaviours, three source files and two test files, all on the `board`
branch.

**1. `_work/store.tl` — the trail covers the sidecar.** `history` (line 412)
narrows an item's log to `items/<id>.tl` alone (line 416), so a `spec` commit —
which touches only `items/<id>.md` — never reaches `show`'s trail. Add the
sidecar to the same pathspec, one line below it, and say so in the function's
doc comment. Measured now: `wc -l < _work/store.tl` is 490, 10 lines of
headroom under the 500-line cap, and this adds at most 3.

**2. `_work/gitverbs.tl` — `spec` is a compare-and-swap.** `cmd_spec` (line 40)
writes the sidecar unconditionally, so a session that reads a sidecar, refines
it for minutes, and writes it back replaces whatever landed in between. Give it
a fourth parameter `base: string` — a path, or nil — and one rule before it
commits:

- the base text is `""` when `base` is nil or `""`, else the contents of that
  file (an unreadable base is a refusal, exactly as an unreadable FILE already
  is);
- when the base text differs from `store.read_spec(s, id)`, refuse: exit 1, no
  commit, no write.

One rule, no special case: an item with no sidecar reads back `""`, which is
what a call with no `--base` compares against, so the FIRST write of a spec
still needs no flag — which is why `give_spec` and `new --spec-file` keep
working untouched.

Two refusals, both `REFUSED:`-prefixed like the ones already in this module,
each naming the recovery:

- no `--base` and the item already has a sidecar — `REFUSED: <id8> already has
  a spec — pass --base FILE holding the text you read; a write with no base is
  last-write-wins`
- `--base` given and stale — `REFUSED: <id8>'s spec changed since you read it —
  re-read items/<id>.md, re-apply your edit, and pass the re-read text as
  --base (the trail is `gitboard show <id8>`)`

This deliberately breaks the bare `gitboard spec ID FILE` that open items'
prose names — 31 sidecars mention it and 16 of those belong to items with no
`resolution` field (`grep -rln "gitboard spec" items/*.md`, cross-checked
against each `items/<id>.tl`), measured 2026-08-27. Those calls now fail
loudly with a refusal that says what to add, which is the trade this item
exists to make. Measured now: `wc -l < _work/gitverbs.tl` is 329.

**3. `_work/gitboard.tl` — the flag.** Add
`{long = "base", arg = "FILE", help = "the spec text you read, as the
compare-and-swap base"}` to the `spec` command's flag list (line 96), and pass
`d.parsed.values["base"]` as `cmd_spec`'s fourth argument in the dispatch (line
292). Measured now: `wc -l < _work/gitboard.tl` is 372.

**4. Tests.** `grep -rn "cmd_spec(" _work/*_test.tl _work/fixture.tl` returns 8
call sites today; the two whose item already carries a sidecar —
`_work/gitverbs_test.tl:137` and `_work/gitverbs_test.tl:377` — pass the text
they are replacing as the new base argument, so each keeps testing what it
tested. Then add:

- `_work/gitverbs_test.tl` (441 lines, 59 of headroom):
  `test_spec_refuses_a_write_with_no_base` — a second `cmd_spec` with no base
  is refused, `store.read_spec` still returns the first text, and the commit
  count is unchanged; and `test_spec_refuses_a_stale_base` — with a first
  writer's text as base after a second writer replaced it, the write is refused,
  and re-reading the current text as base makes the same write succeed.
- `_work/store_test.tl` (283 lines):
  `test_history_covers_the_spec_sidecar` — `store.save` an item, then `save` it
  again changing only the spec argument, and assert `store.history(s, id)`
  carries that sidecar-only commit.

## Non-goals

- No change to `store.touched_at`: claim staleness stays keyed on the item
  file, and widening it is a separate question about what counts as working an
  item.
- No change to `_work/gitgraph.tl`'s `cmd_new`: a sidecar written at birth has
  no base to compare against.
- No `--force`/`--why` bypass on `spec`. The escape hatch is re-reading the
  sidecar and passing it as the base, which is one command and leaves a
  truthful base.
- No new field on the item record and no edit to `_work/item.tl`: the trail is
  git's, and the sidecar's own commits are what `show` was missing.
- No change to the `gitboard-<verb>:` verdict-line format, to any other verb's
  flags, or to `_work/flowstat.tl`'s whole-branch `store.history(s)` call.
- No edit to `skills/work/SKILL.md`, `docs/goals.md` or anything else on
  `main` — that is a different branch and a different pull request. This diff
  is the `board` branch only.
- No rewrite of the item sidecars whose prose names the bare `spec` command.

## Acceptance

- `bin/cosmic --make ci` from the `board` worktree ends `ci: PASS`.
- `bin/cosmic --make test _work/gitverbs_test.tl _work/store_test.tl` passes,
  including `test_spec_refuses_a_write_with_no_base`,
  `test_spec_refuses_a_stale_base` and `test_history_covers_the_spec_sidecar`.
- `wc -l _work/store.tl` is at most 500 (490 today); `wc -l _work/gitverbs.tl`
  at most 500 (329 today); `wc -l _work/gitboard.tl` at most 500 (372 today);
  `wc -l _work/gitverbs_test.tl` at most 500 (441 today).
- `o/bin/gitboard help spec` lists `--base FILE`.
- `o/bin/gitboard show 3IOCdZCA` prints the two `spec 3IOCdZCA` commits
  `848b1a68` and `5cef0e2e` in its trail; today it prints neither, which is how
  the incident this item records went unseen.

## Enablement

none needed — three source files and two test files on this branch, gated by
`bin/cosmic --make ci` from the worktree exactly as CI gates it, with no
blocker items and no dependency on anything landing first.
