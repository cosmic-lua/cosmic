## Evidence

This `/work 9 --routine` pass (2026-09-04, orchestrator session
`3df204e9-...`) tried to fill spare wave width with builds and found the
entire top of the pullable queue — every band-1 `todo`/`building` item —
targets the same one or two files. `git grep -l '_work/brief\.tl\|_work/brieftext\.tl' items/*.md`
on the `board` worktree returns nine item specs, of which eight are
currently open (`todo` or `building`, checked via `gitboard show <id>`
one at a time — no bulk query exists):

- «RxN2_253n» (building) — `_work/brief.tl`, `_work/gitverbs.tl`
- «Elus_cLzz» (todo) — `_work/brief.tl`
- «FacE_b8sh» (todo) — `_work/gh.tl`, `_work/gitverbs.tl`, `_work/action.tl`, `_work/brief.tl`
- «rNh1_b1Se» (todo) — `_work/brieftext.tl` → `_work/brieftext_review.tl` split, `_work/brief.tl` (import site)
- «XsHJ_6fGm» (todo) — `_work/brief.tl`
- «4mpH_hi6v» (todo) — `_work/brief.tl`
- «qWfP_VKKJ» (todo) — `_work/brieftext.tl`
- «WyFa_GL3c» (todo) — `_work/brief.tl`

`gitboard help orchestrate`'s disjointness rule ("Disjoint or not at
all... judged on the MERGE") puts the burden on the orchestrator to
notice this before spawning a wave, but nothing surfaces it: `next`
shows one top action plus three alternates by priority alone, with no
signal that they collide on file scope, and `show <id>` prints one
item at a time with no cross-reference to what else names the same
path. Finding the eight-way collision above cost this pass 6 tool
calls (four full `show` reads to compare `## Change` sections by eye,
then a `grep -l` across `items/*.md` to confirm the pattern held
beyond the three `next` surfaced) — for a fact the board's own item
files already encode and could answer directly. `_work/brieftext.tl`
is separately noted (in «rNh1_b1Se»'s own spec) as 3 lines under its
500-line cap, so this is not a hypothetical: two sibling specs
touching it in the same wave would collide on the cap itself, the
exact "thin headroom" case `help orchestrate` names as still counting
as shared.

## Change

`_work/gitverbs.tl` (or a new `_work/overlap.tl` the `show`/`next`
paths both import): a function `paths_named(spec_text: string):
{string}` that extracts every backtick-quoted path-looking token
(matching an existing file under the repo root — reuse whatever path
extraction the coverage or lint tooling already does, if `_tool/`
carries one, rather than inventing a new heuristic) from an item's
`## Change` section. `gitboard show ID` gains one line, printed only
when another `todo`/`doing` item's extracted paths intersect this
item's: `overlaps: <handle> on <path>[, <path>...]` (one line per
colliding item, silent when none). `gitboard next`'s three `or: pull`
alternates gain the same annotation inline when applicable.

`_work/gitverbs_test.tl`: two fixture items whose `## Change` sections
both name `_work/brief.tl` — `show` on either prints the other's
handle under `overlaps:`; a third fixture item naming an unrelated
path prints nothing.

## Non-goals

Not a hard refusal — an orchestrator may still judge two specs
touching the same file are safe together (e.g. one only adds a test
fixture) and proceed; this only makes the fact visible instead of
requiring a manual `show`-by-show comparison across the whole
pullable set to discover it. Not a general dependency graph;
`blocked_by` edges remain the tool's only durable ordering.
