## Change

Board renders lead with the alias; the raw id becomes the bracketed
cross-reference. The alias is now the name a reader and a typist use
consistently; the id stays visible because it is the filename, the
branch name, and what every log grammar carries.

Current render, measured 2026-08-29 on the live board (post #1513):

    3ILx-muNE fs.find pays a stat(2) per entry ... [6YPM-A915]

The change, in `_work/gitview.tl` and `_work/gitshow.tl` only
(measure first; both under 300 lines — `wc -l`):

1. Every line that renders `<chunked-id8> <title> ... [<alias>]`
   flips to `<alias> <title> ... [<chunked-id8>]`: the status
   doing/todo item lines, `next`'s target line and its `or:`
   alternate lines (gitview), and the `show ID` header line
   (gitshow). The alias is computed exactly as today
   (`_work.alias.of`); nothing new is derived or stored.
2. Everything else is UNCHANGED: mutation verdict lines
   (`gitboard-take: 3Ib4KH0q is yours ...`), refusal texts, commit
   subjects, `flow item=` key=value lines, item files, and the
   guidance strings — those are log/parsing contracts and machine
   data, not reading surfaces; the earlier walls (no alias in
   committed text) hold.
3. Update the render tests in `_work/gitview_test.tl` and
   `_work/gitshow_test.tl` in place to assert the new order, keeping
   every non-order assertion as is.

## Non-goals

No resolution changes (both forms already resolve). No new fields,
no alias anywhere in committed text or log grammars, no verdict-line
format changes. Color and petnames remain rejected.
