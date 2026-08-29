## Change

Two finishing touches on the tail-8 handle, one surface each way:
the last head-8 reading line flips to the tail, and every rendered
handle gains a wrapper that marks it as a handle at a glance.

1. Triage lines join the tail renders. Evidence (2026-08-29, live
   board): bare `show`'s triage section renders the unchunked HEAD
   prefix — `_work/gitview.tl:131` is
   `("  %s %s"):format(f.id:sub(1, 8), f.title)` — while every
   other reading surface (doing/todo lines, next target and `or:`
   alternates, show header) leads with the tail. Live output shows
   `3IbEvcS1 gitboard lacks a retitle verb` beside
   `PtPT-MEq6 ...` in the same report. Flip that line to the same
   handle render as `id_line`.
2. Wrap every rendered handle in guillemets: `«d0x1-37YJ»`.
   Measured: `«`/`»` appear NOWHERE in `_work/` or the README today
   (`grep -rn "«\|»" _work/ README.md | wc -l` → 0), so the pair
   is unambiguous — a reader can tell a handle from a word, a
   count, or the `[full id]` bracket instantly. Mechanically:
   - Rename `_work/tail.tl`'s `chunk` to `handle` and have it
     return `"«XXXX-XXXX»"` — every caller is a render site
     (`_work/gitview.tl:72` id_line, the `or:` alternate line,
     `_work/gitshow.tl:47` header, and the new triage line from
     (1)), so wrapping at the one source keeps every surface
     consistent by construction. Callers change only the function
     name. The show header keeps its `[full id]` bracket:
     `«OwD7-lq9d» title [3IbEvcS1...]`.
   - Input tolerance: a pasted handle resolves. In `resolve`,
     strip `«` and `»` alongside the existing hyphen strip (Lua
     patterns are byte-wise; `(input:gsub("[«»%-]", ""))` handles
     the multibyte pair as literal bytes). `is_tail_shape` accepts
     the wrapped form too, so gitboard.tl's dispatch (which gates
     the board-wide search on shape) needs no change beyond what
     the shape function returns — measure its call site before
     assuming (`grep -n is_tail_shape _work/gitboard.tl`).
3. Tests, in place: update the render assertions in
   `_work/gitview_test.tl` (including the assertion pinning the
   `or:` line's full format), `_work/gitshow_test.tl`, and
   `_work/tail_test.tl` (5 `chunk` references, `grep -c`); add one
   triage-line render assertion and one resolve-accepts-pasted-
   handle (`«d0x1-37YJ»`-form) assertion.

Current sizes (`wc -l`): tail.tl 87, tail_test.tl 106,
gitview.tl 282, gitshow.tl 192 — nothing near the 500 cap.

## Non-goals

Mutation verdict lines, refusal texts, commit subjects,
`flow item=` key=value lines, item files, and guidance strings are
untouched (run `_work/flowstats_test.tl` to prove the grammars) —
the guillemets exist ONLY where the tail handle renders, never
around head-8 prefixes or full ids. No color, no petnames. The
handle stays derived, never stored.
