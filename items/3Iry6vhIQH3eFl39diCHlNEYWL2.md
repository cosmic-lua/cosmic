## Goal

`repo` and `base` are inferred or left empty at every point an item
gains a parent (`new --parent`, `attach`) and only checked for SHAPE
when non-empty (`item.problems`) — never required. The one place that
notices a gap is `gitboard brief builder`, which guesses a default
(`master` for a cosmopolitan-repo item, `main` otherwise) rather than
refusing, and the guess can be wrong for a board-branch-only item
without ever surfacing as an error until a builder's worktree turns
out to have the wrong tree in it. Make `repo`/`base` explicit,
required parameters wherever an item becomes workable, and remove the
silent-guess fallback at brief time — the design principle the goal
owner asked for generally, not just a fix for the one incident below.

## Evidence

`14A3_CTsE`'s friction log (an earlier `/work` pass): `attach`ing an
unplaced root (`sWmK_pFNW`) into the priority order left `base` unset
— the item's own `## Change` named `_work/gitview.tl`, a path that
exists only on `board`, never on `main`. `gitboard brief builder`
defaulted the unset base to `origin/main` (the non-cosmopolitan
fallback), which would have hand a builder a worktree missing `_work/`
entirely. Caught only by the orchestrator reading the emitted brief's
"branched off the latest `origin/<X>`" line before spawning anyone,
then fixed by hand with `gitboard set sWmK_pFNW --base board`. The
log's own candidates section weighed two reactive fixes (`attach`
inferring from the parent, or `brief` refusing when the Change
section's paths don't resolve on the guessed base) and deferred both,
twice across two passes, for lacking a design decision.

`_work/item.tl`'s `problems(it)` (`cosmic/o/board/_work/item.tl:214`)
already enforces the SHAPE of a non-empty `repo`/`base`
(`owner/name`, a branch-name pattern) and already enforces the
opposite constraint for a root (`repo`/`base`/`claim`/`pr`/`verdict`
all must be EMPTY on a root — same function, lines ~236-240). It
never requires a non-root (`it.parent ~= ""`) item to carry them at
all — an item can sit parented, todo, and pullable with `repo = ""`
and `base = ""` indefinitely, and nothing until `brief` even looks.

## Change

1. `_work/item.tl`'s `problems(it)`: extend the existing root/non-root
   branch so a NON-root item (`it.parent ~= ""`) requires non-empty
   `repo` AND non-empty `base`, symmetric with the existing rule that
   a root requires them empty. This is the one shared gate `cmd_new`
   (`_work/gitgraph.tl:83`) and `cmd_attach` (`_work/gitgraph.tl:158`)
   already both call before committing, so the requirement lands at
   every place an item becomes parented with no new call site to
   thread it through.
2. `_work/gitgraph.tl`'s `cmd_attach`: gains `repo`/`base` string
   parameters (both optional — "" means "use what the item already
   carries"), setting `it.repo`/`it.base` from them when non-empty
   BEFORE `problems(it)` runs, mirroring `cmd_new`'s existing `repo`
   parameter. An item already carrying `repo`/`base` (set at `new`
   time, or by a prior `gitboard set`) attaches with no flags needed;
   one with neither the flags nor existing values is refused by step
   1's gate, naming which field(s) are missing.
3. `_work/gitboard.tl`'s CLI dispatcher: wire `--repo OWNER/NAME` and
   `--base BRANCH` flags onto the `attach` verb, parsed and passed
   through exactly like `new`'s existing `--repo` (`_work/gitboard.tl:363`).
4. `cmd_new`'s existing behavior when called WITHOUT `--parent` (an
   unparented capture, filed into triage) is unchanged — a root
   legitimately carries no repo/base until it gains one via `attach`.
   `new --parent X` with no `--repo` now REFUSES via step 1's gate
   (today it silently succeeds with `repo = ""`); `--base` gains the
   same requirement, so `new --parent X --repo Y` alone (no `--base`)
   also refuses now — a caller of the parented form must state both.
5. `_work/brief.tl`'s `cmd_brief` (`_work/brief.tl:217-232`): remove
   the `master`/`main` guess-when-unset fallback for `BASE_BRANCH`.
   Once step 1 ships, no NEWLY parented item can reach `brief` with an
   empty `base` — but an item parented before this change may still
   carry one. For that item, `brief` should refuse outright (naming
   the missing field, same as `problems`'s own message) rather than
   guess, closing the exact incident above at its last remaining
   silent-default site rather than leaving it as a narrower window.
6. Tests (`_work/item_test.tl`, `_work/gitgraph_test.tl`,
   `_work/brief_test.tl`): a root with empty repo/base still passes
   (unchanged); a root with either set still fails (unchanged); a
   non-root with either empty now fails, naming the missing field; `new
   --parent` with no `--repo`/`--base` refuses; `attach` with no
   flags and no pre-existing item repo/base refuses; `attach --repo
   --base` on a bare item succeeds and persists both; `attach` with no
   flags on an item that already carries repo/base (from `new --repo`
   or a prior `set`) succeeds unchanged; `brief builder` on a
   (synthetically constructed, pre-change-shaped) item with empty
   `base` refuses rather than guessing `main`/`master`.

## Non-goals

Not retroactively touching any already-attached item's stored
`repo`/`base` — existing items keep whatever they carry; this only
gates NEW `new --parent`/`attach` calls and closes `brief`'s guess for
whichever old items happen to still be missing one. Not `review`-kind
or `research`-kind briefs, or `RESEARCH_REVIEW`'s own base handling —
scope is `cmd_brief`'s `builder`-path `BASE_BRANCH` fill only, the one
site that guesses today. Not changing `gh.tl`'s `slug` fallback (origin
remote when `it.repo` is unset) — that path already only reads, never
guesses a BRANCH, and is unaffected by this item. Not a UI/help-text
change beyond the two new `attach` flags and updated refusal messages.
