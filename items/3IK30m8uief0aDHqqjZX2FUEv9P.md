## Goal
G6 — the defining paths, ratcheted (this item's parent is the G6
container). Reading the docs to find how the modules compose is a
defining path: it is the first thing every newcomer does, and the
2026-08-23 eval round measured two of four agents reinventing a
composition that `guide.recipes` already documents.

## Problem
`guide.recipes` exists and answers "how do these modules compose", but
nothing early routes anyone to it. Measured 2026-08-24 at 6e3af831:

    $ grep -c 'guide.recipes' sys/help.md                 # 0
    $ o/bin/cosmic --help | grep -c 'guide\.recipes'       # 0
    $ o/bin/cosmic --docs guide.quickstart | grep -n 'guide\.recipes'
    159:- `cosmic --docs guide.recipes` — worked end-to-end programs (a CLI

The quickstart renders 161 lines, so its only pointer at recipes is on
line 159 — the last screen, reached after a newcomer has already worked
through the whole page. `--help` never names the guide at all. The
`docs/guides/index.md` listing (line 57) names it, but only among ten
peers with no signal that this is the composition answer.

## Change
Two files. Insert the literal text below; change nothing else.

**1. `sys/help.md`** (75 lines, no cap concern). In the `Documentation:`
block, the line after `cosmic --docs guide.quickstart  your first
project, end to end`, insert:

      cosmic --docs guide.recipes  whole programs: which modules a CLI composes

Two spaces after `guide.recipes`, matching the `guide.testing` and
`guide.gotchas` lines directly below it, which already use two rather
than column alignment. The line is 74 columns.

**2. `docs/guides/quickstart.md`** (160 lines). Immediately after the
intro paragraph that ends `you do not have to.` (line 7) and before the
blank line preceding `## the layout` (line 9), insert a blank line and
this paragraph:

    this page is one project's skeleton. for whole programs — which
    `cosmic.*` modules a CLI, a file indexer or a TCP server composes,
    and in what order — read `cosmic --docs guide.recipes` alongside
    it.

That places the pointer on the first screen (rendered line ~9-12 of
161), which is what the eval evidence asks for.

**Leave the existing line 159 bullet in `where to go next` in place.**
It is correct there; the fix is an early pointer in addition to it, not
instead of it, and Acceptance 4 pins that both survive.

## Non-goals
- **Do not edit `docs/guides/recipes.md`.** The eval finding is that the
  guide is not FOUND, not that its content is wrong; both agents who
  named it described it as sounding like the right page. Content changes
  are a separate item with separate evidence.
- **Do not touch `generate_welcome()` in `_cli/main_handlers.tl`.** The
  first-run banner is four lines whose job is to route to `--docs` and
  `--help`, and both of those name recipes after this change. Adding a
  fifth line is a different judgment about the banner.
- Do not reorder, retitle, or re-describe the other guides, in
  `sys/help.md`, `docs/guides/index.md`, or the quickstart's
  `where to go next` list.
- Do not add a new guide, a new `--docs` query form, or a new CLI flag.
- Do not change the `Documentation:` block's shape in `sys/help.md`
  beyond the one added line — `_cli/help.tl` reads `/zip/sys/help.md`
  and substitutes `{{recipe_verbs}}`, `{{make_verbs}}` and
  `{{env_vars}}`; none of those placeholders is in this block and none
  moves.

## Acceptance
Run from the repo root; the build under test is what this change
produces (`bin/cosmic --make build`, then `o/bin/cosmic`). Every command
writes only under `o/`.

1. `bin/cosmic --make ci` ends with `ci: PASS`.
2. `--help` names the guide:

       o/bin/cosmic --help | grep -c 'guide\.recipes'    # 1   (0 today)

3. The quickstart names it on the first screen. The inserted paragraph
   lands at rendered lines 9-12 of 165, so `head -14` carries margin for
   a different wrap and still proves "first screen":

       o/bin/cosmic --docs guide.quickstart | head -14 | grep -c 'guide\.recipes'   # 1   (0 today)

4. …and still names it where it already did, so the count over the whole
   page rises by exactly one:

       o/bin/cosmic --docs guide.quickstart | grep -c 'guide\.recipes'   # 2   (1 today)

5. The recipes guide itself is untouched and still resolves:

       o/bin/cosmic --docs guide.recipes | head -1        # "# Recipes"

6. Only the two named files changed — run against the base so it reads
   the same whether or not the work is committed yet:

       git diff --name-only origin/main
       # docs/guides/quickstart.md
       # sys/help.md
       # …and nothing else, recipes.md included

## Enablement
none needed. Both files are prose read verbatim by surfaces that already
exist (`_cli/help.tl` reads `/zip/sys/help.md`; `--docs guide.<topic>`
renders `docs/guides/<topic>.md` line-for-line — the rendered line
numbers above are the source's), and `--make ci` already gates both.
Every predicted wrong turn has a command: a pointer added only at the
bottom fails Acceptance 3; one that replaces the existing bullet instead
of adding to it fails Acceptance 4; a helpful rewrite of the recipes
guide fails Acceptance 5; any other file touched fails Acceptance 6.

**This item's re-run proof is not an Acceptance command.** The finding
came from a clean-room eval round (`skills/agent-eval`), and the
evidence that it is fixed is a later round's journal citing
`guide.recipes` during initial exploration rather than listing
per-module doc lookups as friction. That round is its own work — do not
run one inside this slice, and do not weaken the acceptance above to
stand in for it.
