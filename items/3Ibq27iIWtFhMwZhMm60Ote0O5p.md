## Change

Reproduced 2026-08-30 in a scratch store copy: one item file whose
title carries a literal newline (a shape an older, pre-refusal writer
could have committed; crafted via a valid `\<newline>` escape) bricks
EVERY listing verb — `show`, `show <id>`, and `next` all exit 1
printing only "title must be one line: no newlines"; with the file
moved aside the same board renders ~172 items normally. Mechanism:
`item.problems()` holds the one multiline-title check
(`_work/item.tl:196-199`) and is wired into BOTH the write gate
(`_work/gitgraph.tl:49` cmd_new; `_work/store.tl:227` stage — correct,
keep) and the read path: `item.decode()` folds `problems(it)` into its
own failure (`_work/item.tl:323-326`), and `store.list()` aborts the
whole loop on the first bad item (`_work/store.tl:211-214`). Even
`cmd_new` lists first, so one bad old record blocks filing new ones.

The change, in `_work/item.tl` and `_work/store.tl` only:

1. `decode()` stops treating a content problem as a parse failure: it
   fails hard only on genuine corruption (unparseable literal, wrong
   field types) and otherwise returns the constructed Item even when
   `problems(it)` is non-empty (carry the problems in a second channel
   that does not break the fallible-return shape — e.g. a
   `decode_with_problems` sibling or a problems field the callers
   read; pick the least shape that types cleanly).
2. `store.list()` keeps going past a problem-carrying item and returns
   it flagged, so `show`/`next` render the rest and report
   "1 unreadable/flagged: <id8> — <reason>"-style, instead of dying.
3. Write-refusal stays exactly as is: `stage`/`cmd_new` still refuse
   via `problems()`.
4. Repairability falls out: `set --title` loads through the tolerant
   decode, so a stored bad title can be corrected in place — pin that
   with a test (craft the bad record in a test store, `set` a one-line
   title over it, listing recovers).

Tests in `_work/item_test.tl` / `_work/store_test.tl` (follow the
existing store fixture seam): a bad-title record decodes-with-problems
instead of nil; `list` over a store containing one bad record returns
the good ones; the write path still refuses; mutation-verify the
tolerance (restore the old fold-into-failure, watch the list test go
red). Watch the 500-line cap: store.tl history shows it has run at the
cap before — measure headroom first and extract minimally if needed.

## Non-goals

No gitgraph.tl edits (two sibling items own that file; `set`'s repair
works through decode, not through verb changes). No relaxation of the
write-time refusal. No schema migration of stored items.

## Rework note (2026-08-30, speccer)

The Change's item 2 promised a rendered "N flagged" report line while
naming only item.tl and store.tl — a contradiction the builder
correctly surfaced instead of guessing. Resolution: THIS item's scope
is the brick fix plus the pure formatter (`store.flagged_summary`);
the CLI wiring of that line into show/next output is a separate
follow-up item (filed), since it touches gitshow/gitview. Judge the
diff against that narrowed scope.
