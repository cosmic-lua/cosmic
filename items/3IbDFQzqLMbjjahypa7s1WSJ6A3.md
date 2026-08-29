## Change

Board renders lead with the KSUID's tail — the last 8 characters,
which are pure entropy and a literal substring of the id, so the
rendered handle greps item files, branch logs, and PR bodies
directly. The derived base32 hash alias is removed entirely.

Measured 2026-08-29 on the live board (559 items,
`ls items/*.tl | wc -l`): tail-8 is collision-free, exact AND
case-folded — both
`ls items/*.tl | sed 's|items/||;s|\.tl||' | awk '{print substr($0,20)}' | sort | uniq -d`
and the `tolower(...)` variant print nothing. KSUIDs are 27 chars,
so the tail is `id:sub(20)`. Sample renders: `3IbDFQzq...` →
`s1WS-J6A3`, `3HyArM3A...` → `vKmU-Z7KW`.

The pieces, in order:

1. New `_work/tail.tl` (small — alias.tl it replaces is 119 lines,
   `wc -l`) with three functions:
   - `chunk(id: string): string` — the last 8 chars hyphenated
     `XXXX-XXXX` (e.g. `s1WS-J6A3`).
   - `is_tail_shape(input: string): boolean` — exactly 8 base62
     chars `[0-9A-Za-z]`, with at most one hyphen after the 4th
     (accepts `s1WSJ6A3` and `s1WS-J6A3`).
   - `resolve(items: {Item}, input: string): string | nil, string` —
     strip the hyphen, then: unique exact match on `id:sub(20)`
     wins; if no exact match, unique case-insensitive match wins
     (tolerance for retyping — base62 is case-sensitive but the
     folded space is measured collision-free above); zero matches
     or >1 at either stage refuses with the candidates' tails
     named. Signature mirrors today's `alias.resolve` so the
     dispatch swap in (4) is one name change.
   New `_work/tail_test.tl` covering: chunking, both shape forms,
   exact resolution, case-folded resolution, the ambiguity refusal,
   and the no-match refusal.
2. Delete `_work/alias.tl` and `_work/alias_test.tl`. The only
   importers are `_work/gitboard.tl`, `_work/gitview.tl`,
   `_work/gitshow.tl` (`grep -rn "_work.alias" _work/*.tl`) — all
   three are touched below, so nothing else moves.
3. Renders flip to the tail as the one handle, no bracketed
   second name:
   - `_work/gitview.tl:72` `id_line` becomes
     `("%s %s"):format(tail.chunk(it.id), it.title)` — this feeds
     the status doing/todo lines, `next`'s target line, and the
     `or:` alternate lines at `gitview.tl:191`.
   - `_work/gitshow.tl:47` header becomes
     `("%s %s [%s]"):format(tail.chunk(it.id), it.title, it.id)` —
     show is the detail view, so the FULL id stays bracketed there
     (it is the branch name and the `Board:` line a builder needs).
4. `_work/gitboard.tl:218-229` dispatch: prefix resolution via
   `store.resolve` stays first and unchanged; the fallback swaps
   `alias.is_alias_shape`/`alias.resolve` for
   `tail.is_tail_shape`/`tail.resolve`. Suffix resolution does NOT
   go into `_work/store.tl` — it sits at exactly 500 lines
   (`wc -l`), the cap.
5. Tests: update `_work/gitview_test.tl` (200 lines) and
   `_work/gitshow_test.tl` (182 lines) in place to assert the new
   renders, keeping every non-order assertion. Add an assertion
   pinning the `or:` alternate line's FULL rendered format (a prior
   review found no test covers it — reverting that line's format
   left every render test green; close that gap here).

## Non-goals

Mutation verdict lines (`gitboard-take: 3IbDFQzq is yours ...`),
refusal texts, commit subjects, `flow item=` key=value lines, item
files, and guidance strings are log/parsing contracts and machine
data — untouched (run `_work/flowstats_test.tl` to prove the
grammars). Ids in those surfaces stay the full id or the head
prefix as today. No new stored fields — the tail is derived, always.
No color, no petnames (both recorded as rejected).
