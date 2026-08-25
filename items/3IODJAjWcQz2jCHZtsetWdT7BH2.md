## Goal

G3 — an honest type layer, no escape hatches. The win condition is zero
`as` casts and the `-- cast:` scaffolding deleted. `from any` is the
single largest bucket standing between the tree and that condition, and
nothing today says what those sites actually ARE — so nobody can size
the work of closing them. This slice produces the classification: what
shapes the 192 sites take, which existing mechanism closes each shape,
and which shapes have no mechanism yet. Its deliverable is one committed
document plus the follow-up items it seeds; no cast is removed here.

## Evidence

Measured 2026-08-25 against `whilp/cosmic` `d3e59de7` (`main`).

**`from any` is 48% of every justified cast in the tree.**

```
$ git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l
402
$ git ls-files '*.tl' | xargs grep -h -- "-- cast: " | grep -c "from any"
192
```

**The reason text carries no classification signal.** 189 of the 192
sites say exactly `from any` and nothing more, so the class has to come
from reading the code at each site, not from grepping the comment:

```
$ git ls-files '*.tl' | xargs grep -h -- "-- cast: " | grep "from any" \
    | sed 's/.*-- cast: //' | sort | uniq -c | sort -rn
    189 from any
      1 from any",
      1 from any (pcall result)
      1 dynamic E* lookup, from any
```

**63 files hold them, and the heaviest are tests and eval tooling.**

```
$ git ls-files '*.tl' | xargs grep -l -- "-- cast: .*from any" | wc -l
63
$ git ls-files '*.tl' | xargs grep -c -- "-- cast: .*from any" \
    | awk -F: '$2>0' | sort -t: -k2 -rn | head -5
cosmic/quicksand/box/merge_test.tl:14
_eval/score_test.tl:12
cosmic/json_test.tl:10
_eval/score.tl:10
cosmic/quicksand/box/init_test.tl:9
```

**Roughly half the sites are in gated non-product files**, which matters
because a test's cast is closable by a test-only mechanism:

```
$ sites=$(git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any")
$ echo "$sites" | grep -c '_test\.tl:'      ->  97
$ echo "$sites" | grep -c '_example\.tl:'   ->   5
$ echo "$sites" | grep -vcE '_test\.tl:|_example\.tl:'  ->  90
```

**Two of the seed classes already have a closing tool in the tree.**
`cosmic/json.tl:135` declares `decode_object(str): {string: any} | nil,
string` and `cosmic/json.tl:155` declares `decode_array(str): {any} |
nil, string`, so a `json.decode(...) as {string: any}` site is a call
change, not a mechanism gap. `grep -c 'json\.decode' ` over the site
list is 12.

**The target file does not exist**, and `docs/design/` holds free-form
design prose with no index to update (`ls docs/design/` is `make`;
`ls docs/design/casts.md` reports No such file):

```
$ ls docs/design/casts.md
ls: cannot access 'docs/design/casts.md': No such file or directory
```

**Fenced code in `docs/**` is gated.** `_build/snippets_test.tl`
declares `--- reads: docs` and holds every ```` ```teal ```` fence under
it to the formatter AND the checker at full strictness. A census quotes
fragments that do not compile on their own, so its fences must be
```` ```text ````.

**No committed floor moves.** This diff adds one markdown file and
touches no `.tl`, so `_build/casts_baseline.tl` (126 lines, a per-file
cast total) and `.cosmic-coverage` are both unmoved by construction.

## Change

Add one new file, `docs/design/casts.md`, and mint the follow-up items
it seeds. No `.tl` file is edited and no cast is removed.

**The document.** Exactly these five headings, in this order:

1. `# from-any casts` then one paragraph saying what the document is:
   the current classification of every `from any` cast in the tree, and
   what closes each class. State the measurement date and the commit
   measured against.
2. `## Method` — the commands above that produce the site list and the
   per-file counts, verbatim, so a later reader re-derives the census
   instead of trusting it.
3. `## Classes` — one `###` subsection per class. Start from these five
   seed classes, each named here with the exemplar site that grounds it:

   - **decoded-json shaping** — a value out of `json.decode` (or a
     decoded config) reshaped field by field. `_eval/score.tl:194`,
     `cosmic/json_test.tl:6`, `_perf/compare.tl:41`.
   - **any-map field walk** — indexing an `any` known to be a table,
     one field at a time, usually `as {string: any}` repeated down a
     path. `cosmic/quicksand/box/merge_test.tl:22`,
     `_tool/coverage/lines.tl:44`, `cosmic/fs/types.tl:251`.
   - **dynamic-call return** — a value out of `pcall`, `load` or
     `require`, which the checker types `any` by construction.
     `_cli/main_handlers.tl:64`, `_perf/run.tl:167`.
   - **binding boundary** — a `cosmo.*` or Lua-stdlib return the
     generated declarations type `any`. `cosmic/url.tl:64`
     (`cosmo.ParseParams`), `cosmic/coverage/init.tl:124`
     (`os["exit"]`), `cosmic/teal.tl:166`.
   - **test probe** — a test reaching a value the type deliberately
     does not describe.

   A site that fits none of the five gets a NEW `###` subsection, and
   that subsection states the rule that admits a site to it in one
   sentence, the same way the five above are stated. Assign every site
   to exactly one class; when two classes fit, the more specific one
   wins and the subsection says so.

   Each `###` subsection carries, in this order: one paragraph on the
   shape; **what closes it** — name the concrete mechanism (an existing
   API such as `json.decode_object`, an `is` dispatch, a typed record, a
   carried-patch narrowing, an upstream tl fix) or state that no
   mechanism exists yet and what one would have to do; and then a
   markdown table of the files in that class, one row per file, in the
   exact shape `| <path> | <n> |` under a `| file | sites |` header,
   plus a final `| **total** | <n> |` row.

4. `## What no mechanism closes` — the residue, gathered in one place:
   for each class whose "what closes it" was "nothing yet", one
   paragraph on what the missing mechanism is and where it would live
   (cosmic API, the carried tl patch in `3p/tl/tl_patch.tl`, or
   upstream tl).
5. `## What this is not` — one paragraph: the counts are a snapshot of
   the commit named at the top, re-derived by the `## Method` commands,
   never a floor and never a gate. `_build/casts_baseline.tl` is the
   ratchet; this is the map.

**The minted items.** After the document is written, mint one closure
item per class holding **8 or more sites**, and exactly one tail item
covering every class below 8 together. Mint them as SIBLINGS of this
item under the G3 root — `gitboard new "<title>" --parent
3HyRcW05wBip6Wqcz145bUQBTyj --spec-file F` from the `o/board` worktree —
not as children of this item, because a child would de-phase this item
into a container and it could then never be ended. Each minted item's
spec file is one paragraph: the class, its measured site count and file
list, the mechanism that closes it, and that the closure diff must lower
the affected `_build/casts_baseline.tl` rows.

List every minted id in the PR description, one per line, as
`<8-char id> — <title>`. The ids stay OUT of `docs/design/casts.md`: the
document describes the tree, and board ids are not tree facts.

## Non-goals

- **Remove no casts.** `git diff --name-only main` must name exactly
  `docs/design/casts.md`. No `.tl` file is edited, so
  `_build/casts_baseline.tl`, `.cosmic-coverage` and
  `_build/public_surface_baseline.tl` all stay as committed.
- **Do not touch `AGENTS.md` or `docs/goals.md`.** The narrowing
  doctrine and G3's prose are unmoved; this document neither restates
  nor amends them.
- **Do not write a decision record.** No file under `docs/decisions/`
  is added or edited — a census records what is, and settles no
  tradeoff.
- **No ```teal fences.** Every fence in the new document is ```text,
  because a census quotes fragments that do not compile alone and
  `_build/snippets_test.tl` holds `docs/**` teal fences to the formatter
  and the checker.
- **No line numbers in the file tables.** Rows are `<path>` and a count;
  line numbers go stale on the next edit and the `## Method` commands
  re-derive them.
- **Do not touch `3p/tl/`, `_types/`, or anything in
  `whilp/cosmopolitan`.** Naming a needed upstream fix in prose is the
  deliverable; making one is not.
- **Do not mint items for classes below the 8-site threshold
  individually** — they go in the single tail item.

## Acceptance

All commands run verbatim from the `whilp/cosmic` repo root; the
`gitboard` ones run from the `o/board` worktree. Nothing here writes
into the committed tree.

- `bin/cosmic --make ci` ends `ci: PASS`. This is the check that
  matters: `_build/snippets_test.tl` reads `docs`, so a bad fence in the
  new document fails here.
- `git diff --name-only main` prints exactly `docs/design/casts.md` and
  nothing else.
- **The census is complete.** The file tables sum to the tree's site
  count:

  ```
  awk -F'|' '/^\| [^ ]*\.tl \| [0-9]+ \|$/ {s+=$3} END {print s}' \
    docs/design/casts.md
  ```

  prints `192`.

- **The census names the right files.** The set of paths in the tables
  equals the set of files carrying a `from any` cast:

  ```
  diff <(awk -F'|' '/^\| [^ ]*\.tl \| [0-9]+ \|$/ {gsub(/ /,"",$2); print $2}' \
           docs/design/casts.md | sort -u) \
       <(git ls-files '*.tl' | xargs grep -l -- "-- cast: .*from any" | sort -u)
  ```

  prints nothing and exits 0.

- `grep -c '^### ' docs/design/casts.md` is at least 5 — the five seed
  classes, plus any the census added.
- `grep -c '| \*\*total\*\* |' docs/design/casts.md` equals
  `grep -c '^### ' docs/design/casts.md` — every class subsection ends
  with its total row.
- `grep -c '```teal' docs/design/casts.md` is 0.
- `grep -cE '\.tl:[0-9]+ \|' docs/design/casts.md` is 0 — no line
  numbers inside the file tables.
- `wc -l < docs/design/casts.md` is at most 350.
- `grep -c 'docs/decisions' docs/design/casts.md` is 0.
- **The minted items exist and are placed.** For every id the PR
  description lists, `o/bin/gitboard show <id>` from `o/board` reports
  `parent: 3HyRcW05wBip6Wqcz145bUQBTyj` and a `backlog` phase. The count
  of listed ids equals the number of `###` classes with a total of 8 or
  more, plus exactly 1 for the tail item.

If the coverage or casts ratchet complains, run exactly the regen
command its failure message prints and commit the result — it is in
scope. Neither is expected to: the diff adds one markdown file and edits
no `.tl`.

## Enablement

none needed. Every number above was measured in this tree during this
refinement pass, with the command that produced it beside it, and the
two mechanisms the seed classes lean on are already in the tree
(`cosmic/json.tl:135` and `:155`). Conventions are AGENTS.md; the
comment-and-prose standard is `skills/docs-style/SKILL.md`, and the one
thing it adds here is that the document states what the tree contains
today rather than narrating how it got that way. `docs/design/make/`
is the shape to copy for a design document under `docs/design/`.
