## Goal

G3 — an honest type layer, no escape hatches (parent: the G3 root
`3HyRcW05`). G3's win condition is zero `as` casts.
`docs/design/casts.md` is the only map of what stands in the way, and
its first sentence scopes it to the `from any` reason — 7 of the
tree's 214 justified casts. The from-any container is two items from
closing, at which point the board would show G3's cast work as done
with 97% of its own measure never classified. This slice widens that
document to every cast in the tree, gives each class one of three
verdicts — closable here, closable upstream, or a floor — and
measures the floor, so the question the 2026-08-19 epic left open
(is G3's zero literal, or zero plus a named justified floor?) becomes
answerable from today's evidence instead of the 2026-08-15 census.
No cast is removed and `docs/goals.md` is not touched.

## Evidence

Measured 2026-08-28 against `whilp/cosmic` `40776231` (`origin/main`).

**The filed numbers were grep numbers; the tree has 214 casts, not
225.** The grep in this item's original spec counts `-- cast: `
comment lines, and 11 of them are not casts — they are the reason
text quoted inside the cast lint's own fixtures and doc comments.
The authoritative counter is `_build/casts.tl`, which walks `as`
tokens through `_cli.lint`'s lexer; its committed output is the
per-file floor:

```
$ git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l
225
$ awk -F'= ' '/\] = /{gsub(/,/,"",$2); s+=$2} END {print s}' \
    _build/casts_baseline.tl
214
```

The 11 false positives sit in exactly five files, and the per-file
grep-minus-baseline difference names them: `_build/casts.tl` (+1,
a doc comment), `_build/casts_test.tl` (+4), `_cli/assert_lint_test.tl`
(+1), `_cli/lint.tl` (+2, doc comments), `_tool/lint_test.tl` (+3).
Outside those five, grep and the lexer agree file for file.

**7 real from-any sites, 207 everything else.** Four of the 11
from-any grep hits are fixture text (`_build/casts_test.tl:68`, `:74`,
`_cli/assert_lint_test.tl:137`, `_tool/lint_test.tl:58`). The 7 real
ones are all in library code, none in a test:

```
$ git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"
cosmic/errno.tl:52  cosmic/fd.tl:187  cosmic/fetch/init.tl:238
cosmic/fetch/init.tl:366  cosmic/fetch/init.tl:384
cosmic/quicksand/proc.tl:262  cosmic/zip.tl:222
  (plus the 4 fixture lines above)
```

**Four of `casts.md`'s seven classes now describe zero sites.** With
all 7 survivors in `errno`, `fd`, `fetch`, `proc` and `zip`, the
Decoded-data shaping, Any-map field walk, sqlite row column read and
Untyped-probe fallout subsections have no live from-any member — while
the SHAPES they name still have live casts under other reason strings
(`a row column is \`any\``, `record inspected as map`, `deliberate
invalid input`). The document is not wrong; it is scoped to a reason
that has been drained out from under it.

**The reason text does carry classification signal here, unlike the
from-any census.** `3IODJAjW` faced 189 sites that all said exactly
`from any`; today's 207 carry 116 distinct reason strings, 78 of them
unique, clustering into legible families:

```
$ git ls-files '*.tl' | xargs grep -ho -- "-- cast: .*" \
    | sed 's/-- cast: //; s/ *(.*//' | sort | uniq -c | sort -rn | head
     21 userdata boundary        9 tuple element
      9 function shape           9 deliberate invalid input
      7 the registry defines it  6 from any
      4 tl declares number       4 record union after guard
      4 probe removed surface    4 probe past the declared surface
```

Keyword counts over the 207 reason strings, as a sizing signal only —
the classes come from reading the sites: `userdata` 21, `probe` and
its neighbours 32, `dynamic`/`registry`/`constant lookup` 19, `tl
AST`/`statement`/`thaw`/`patch` 30, `map` 20, `record union`/guard 17,
`tuple` 12, `function shape` 10, `enum` 9, `metatable` 7, `pcall` 5,
`generic T` 5.

**Distribution.** 88 files hold the 214. 158 sites are outside tests
and examples, 55 in `*_test.tl`, 1 in `*_example.tl`; 166 are under
`cosmic/**`. Heaviest files: `cosmic/fs/types.tl` 12,
`cosmic/time.tl` 7, `cosmic/fetch/init.tl` 7, `_make/init.tl` 7,
`_types/tlast.tl` 6.

**One open non-from-any item already exists, so the premise in this
item's own Problem section is wrong and this slice must not
re-mint it.** `3IQtewgN` ("cosmo contracts made exact") targets the
degenerate-input unions and tuple-shape deviations at the C boundary —
which is exactly the `tuple element` family (`cosmic/time.tl:132`,
`cosmic/re.tl:287`) and the `dual-shape binding return` pair. Its
census is decomposed into 12 per-namespace children, and `3ISJHfNY`
under it covers the `E*`/`SIG*` name lookups (`cosmic/errno.tl:52`,
`cosmic/quicksand/proc.tl:262`).

**The site list is extractable with an existing public API.**
`_cli.lint.cast_lines(content, file): {integer}` returns the line
numbers of the real casts in a file (`_cli/lint.tl:404` exports it;
`_build/casts.tl:67` is the one caller). A ~25-line throwaway over it
reproduces the 214 sites with line numbers; run during this
refinement, its per-file counts equal `_build/casts_baseline.tl` row
for row. The script is in `## Enablement`.

**The reason line is not always the cast line.** 69 of the 214 sites
carry a standalone `-- cast: <reason>` comment on the line ABOVE the
cast; the other 145 are trailing. A join between the grep's
`file:line` and the lexer's `file:line` therefore mismatches on 69
sites. Both spellings are legal (`_cli/lint.tl:62`).

**Prose citations into the tree are gated.** `_cli/citations.tl`, run
over every `.md` by `--check lint` (`_cli/lint.tl:376`), checks that a
fenced `-- <path>:<line>` block's quoted text still matches the source
line, and that an inline `` `path:line` `` resolves. Verified during
this pass: repointing `casts.md`'s `cosmic/errno.tl:52` quote to `:53`
makes `cosmic --check lint docs/design/casts.md` fail with
`doc-citation: ... the quoted line is not cosmic/errno.tl:53`. A
document that opens with a `` Measured against `<sha>` `` line is
treated as a snapshot and its LINE numbers stop being checked — so
`casts.md` must NOT gain that line.

**Room for the document.** `wc -l docs/design/casts.md` is 215.
`--check lint` applies the 500-line file cap to markdown too
(`_cli/lint.tl:314`, `_tool/lint.tl:31`); the house precedent for a
census of this size is `docs/design/nil-flow.md` at 464 lines with its
site inventory committed beside it as `docs/design/nil-flow-sites.tsv`
(358 lines). `docs/design/` today holds `casts.md`, `nil-flow.md`,
`nil-flow-sites.tsv` and `make/`.

**Fences in `docs/**` are gated.** `_build/snippets_test.tl` declares
`--- reads: docs` and holds every ```` ```teal ```` fence to the
formatter AND the checker at full strictness. A census quotes
fragments that do not compile alone, so every fence in this document
is ```` ```text ````.

## Change

Two files change and no `.tl` is edited.

### 1. Rewrite `docs/design/casts.md` to cover every cast

Retitle from `# from-any casts` to `# casts` and rewrite the opening
paragraph: the document is the classification of every `as` cast the
committed tree carries, and what closes each class. Keep the existing
design property — the document holds no counts, because counts are
derived and the `## Method` command derives them. Do NOT add a
`` Measured against `<sha>` `` line; the live citation check is worth
more than the snapshot exemption.

**`## Method`** — replace the from-any grep with three commands:

1. the authoritative total, `awk` over `_build/casts_baseline.tl` (as
   in Evidence above), with one sentence saying why the grep over
   `-- cast: ` is 11 higher and naming the five files where it
   diverges;
2. the reason census (`grep -ho -- "-- cast: .*" | sed ... | uniq -c`);
3. the site inventory: point at `docs/design/cast-sites.tsv` beside
   it, and say that where the file and the prose disagree the file is
   right.

Fold the present `### Fixture text, not a cast` subsection into this
section as prose. It stops being a class, because a class is a set of
casts and those lines are not casts.

**`## Classes`** — one `###` subsection per class, disjoint, every one
of the 214 sites in exactly one. Keep the existing "more specific
description wins" tie-break sentence. Seed from these twelve, each
verified live during refinement; split, merge, rename or add as the
reading requires, and state each class's admission rule in one
sentence the way the current subsections do:

- **userdata boundary** — a raw userdata handle from a binding
  re-typed to the record that describes it, or a method table typed
  `{string: any}` whose `self: any` is re-typed on every method.
  `cosmic/fs/types.tl:214`, `cosmic/fs/find.tl:313`,
  `cosmic/embed/init.tl:103`.
- **binding tuple shape** — a `cosmo.*` tuple whose every slot is
  declared as the union of the success and failure shapes, re-typed
  after the caller's guard. `cosmic/time.tl:132`, `cosmic/re.tl:287`.
- **dynamic name lookup** — a table indexed by a name computed at
  runtime: an `E*` constant, a signal number, a registry entry, a
  `package.searchers` slot. `cosmic/errno.tl:52`,
  `cosmic/quicksand/proc.tl:262`.
- **type-defeating test probe** — a test that re-types an API to feed
  it input the signature forbids, or to reach a surface the type
  deliberately hides, so that the runtime guard can be exercised.
  `cosmic/hash_test.tl:169`, `cosmic/fs/traps_test.tl:11`,
  `cosmic/log_test.tl:111`.
- **record as map for a dynamic walk** — a declared record viewed as
  `{string: any}` by a formatter, a deep copy, a merge or a coverage
  walk. `cosmic/format/init.tl:118`, `cosmic/quicksand/proxy.tl:141`.
- **tl AST surface** — the narrowed tl API types a parsed node `any`,
  so every field read costs a cast. `_types/tlast.tl:105`,
  `_types/tlast.tl:249`.
- **function shape** — an overloaded binding declared as a union of
  signatures, one arm selected by cast.
- **enum relation** — an enum value used where a `string` is wanted,
  or one enum's word set used where a wider enum is declared.
  `cosmic/sys_test.tl:15`, `cosmic/hash.tl:104`,
  `cosmic/compress_test.tl:25`.
- **numeric narrowing** — an integer the code has proved (digits
  parsed, `math.type` checked, a bound applied) that tl types
  `number`.
- **generic T** — a fresh table or a map view re-typed as a generic
  parameter, because Teal cannot relate them.
- **metatable access** — `getmetatable`/`debug.getmetatable` returns,
  and identity compares over them.
- **sqlite row column read** — `Row` is `{string: any}`, so a column
  of known type costs a cast per read.

Each subsection carries, in this order: one paragraph on the shape;
one or two fenced `text` citations in the `-- <path>:<line>` + quoted
source form (so `--check lint` compares them against the tree on every
run); then EXACTLY ONE bolded verdict line opening with one of these
three literal strings, and its justification:

- `**What closes it here.**` — the mechanism exists or is ordinary
  work in this repository; name it concretely (a record to declare, an
  accessor to add, an `is` dispatch, a test helper).
- `**What closes it upstream.**` — the fix belongs in
  `whilp/cosmopolitan`'s `tool/net/definitions.lua` or in tl (carried
  patch `3p/tl/tl_patch/`, or upstream), and reaches this tree as a
  pin bump. Name the repository and the change.
- `**Why it is a floor.**` — no mechanism can close it without
  deleting the thing the cast serves. State what that thing is, and
  the smallest count the class could be reduced to (a class that
  collapses from 30 sites to one shared helper is a floor of one, not
  of 30).

**`## The floor`** — replace `## What no mechanism closes` with this
section. Gather every class whose verdict was `**Why it is a floor.**`,
state the summed floor as a number derived from
`docs/design/cast-sites.tsv`, and state in plain words what a win
condition of "zero casts" would have to become for that floor to be
honest — as a QUESTION put to the goal owner, not as an answer.
`docs/goals.md` is not edited here.

**`## What this is not`** — keep, updated: the document is the map,
`_build/casts_baseline.tl` is the ratchet, `cosmic --check lint` is
what enforces the justification comment.

### 2. Add `docs/design/cast-sites.tsv`

The site inventory, in the shape `docs/design/nil-flow-sites.tsv`
established. One header line `path`, `line`, `class` (tab-separated),
then one row per cast: the root-relative path, the line the `as`
TOKEN is on (not the reason comment's line — they differ on 69 of the
214), and the class name spelled EXACTLY as it appears after `### ` in
`casts.md`. Sorted by path, then by line. 215 lines total.

Produce it with the throwaway extractor in `## Enablement` — write the
paths and lines from `_cli.lint.cast_lines`, then fill the class column
by reading each site. Do not commit the extractor.

### 3. Mint the follow-up items

From the `o/board` worktree, as SIBLINGS of this item under the G3
root (`gitboard new "<title>" --parent 3HyRcW05wBip6Wqcz145bUQBTyj
--spec-file F`) — never as children, because a child de-phases this
item into a container and it could then never be ended.

- **Before minting anything, `gitboard find` the class's shape.** If
  an open item already covers it, cite that item in the PR description
  and mint nothing. `3IQtewgN` already covers the binding tuple shape
  and, through `3ISJHfNY`, the `E*`/`SIG*` half of dynamic name
  lookup; do not duplicate either.
- Mint one closure item per uncovered class holding **8 or more**
  sites, and exactly one tail item covering every uncovered class
  below 8 together. Each spec file is one paragraph: the class, its
  measured site count and file list, the verdict and its mechanism,
  and that the closure diff must lower the affected
  `_build/casts_baseline.tl` rows.
- Mint exactly one further item, whatever the classification finds:
  **the G3 wording decision** — a `docs/goals.md` amendment putting
  the measured floor against the literal "zero casts" win condition,
  owned by the goal owner. Its spec states the measured floor number,
  the classes that make it up, and both candidate wordings. This item
  does not decide it. `3HyArM3A`'s closing note named this successor
  on 2026-08-19 and nothing has been filed for it since; `gitboard
  find "zero casts"` and `find "goals.md"` return only done items.

List every minted id in the PR description, one per line, as
`<8-char id> — <title>`. Board ids stay OUT of both new files: the
documents describe the tree, and board ids are not tree facts.

## Non-goals

- **Close no cast.** `git diff --name-only origin/main` names exactly
  `docs/design/casts.md` and `docs/design/cast-sites.tsv`. No `.tl` is
  edited, so `_build/casts_baseline.tl`, `.cosmic-coverage` and
  `_build/public_surface_baseline.tl` are unmoved by construction. A
  cast that is obviously removable is recorded as such in its class's
  verdict and left in place.
- **Do not touch `docs/goals.md`.** G3's prose, its measurement and
  its win condition are unmoved. An outcome changes by PR to
  goals.md, owned by the goal owner; this slice supplies the evidence
  and mints the item, and states the question in `## The floor`
  without answering it.
- **Do not touch `AGENTS.md`.** The narrowing doctrine is unmoved.
- **Do not write a decision record.** No file under `docs/decisions/`
  is added or edited — a census settles no tradeoff.
- **Do not add a `` Measured against `<sha>` `` line to `casts.md`.**
  It would switch the citation check to snapshot mode and stop the
  line numbers being verified. The TSV is the snapshot; the document
  is live.
- **No ```` ```teal ```` fences** in either new or edited prose —
  `_build/snippets_test.tl` holds them to the formatter and the
  checker, and a census quotes fragments that do not compile alone.
- **Do not commit the extractor script**, and do not add a new gate,
  lint, or committed tool. If the classification wants one, it is a
  minted item, not this diff.
- **Do not touch `3p/tl/`, `_types/`, or anything in
  `whilp/cosmopolitan`.** Naming a needed upstream fix in a verdict is
  the deliverable; making one is not.
- **Do not re-mint work an open item already covers** — `3IQtewgN`,
  `3ISJHfNY`, `3IOK2cxG`, `3IOmhR2S`, `3IQCrJpB`.

## Acceptance

All commands run verbatim from the `whilp/cosmic` repo root; the
`gitboard` ones from the `o/board` worktree. Nothing here writes into
the committed tree.

- `bin/cosmic --make ci` ends `ci: PASS`. This is the check that
  matters: `_build/snippets_test.tl` reads `docs`, and `--check lint`
  runs `_cli/citations.tl` over every `.md`, so a bad fence or a
  drifted quote fails here.
- `bin/cosmic --check lint docs/design/casts.md` ends
  `Style check passed: docs/design/casts.md`.
- `git diff --name-only origin/main` prints exactly these two lines
  and nothing else:

  ```
  docs/design/cast-sites.tsv
  docs/design/casts.md
  ```

- **The inventory is complete.** Its row count equals the
  authoritative cast total:

  ```
  tail -n +2 docs/design/cast-sites.tsv | wc -l
  awk -F'= ' '/\] = /{gsub(/,/,"",$2); s+=$2} END {print s}' \
    _build/casts_baseline.tl
  ```

  Both print `214` (the second is unmoved by this diff; it prints
  `214` today).

- **Every inventory row names a real cast line.** This prints nothing
  and exits 0:

  ```
  tail -n +2 docs/design/cast-sites.tsv \
    | while IFS=$'\t' read -r p l c; do \
        sed -n "${l}p" "$p" \
          | grep -qE '(^|[^_[:alnum:]])as([^_[:alnum:]]|$)' \
          || echo "MISS $p:$l"; \
      done
  ```

- **Every row's file is a file the baseline knows.** This prints
  nothing and exits 0:

  ```
  diff <(tail -n +2 docs/design/cast-sites.tsv | cut -f1 | sort -u) \
       <(sed -n 's/^  \["\(.*\)"\] = .*/\1/p' _build/casts_baseline.tl \
         | sort -u)
  ```

  (88 paths on each side today.)

- **Classes and inventory agree exactly** — every `###` heading has
  sites and every site has a heading. This prints nothing and exits 0:

  ```
  diff <(tail -n +2 docs/design/cast-sites.tsv | cut -f3 | sort -u) \
       <(sed -n 's/^### //p' docs/design/casts.md | sort -u)
  ```

- **Every class carries exactly one verdict.** These three counts sum
  to the number of `###` headings, and the heading count is at least
  10:

  ```
  grep -c '^### ' docs/design/casts.md
  grep -c '^\*\*What closes it here\.\*\*' docs/design/casts.md
  grep -c '^\*\*What closes it upstream\.\*\*' docs/design/casts.md
  grep -c '^\*\*Why it is a floor\.\*\*' docs/design/casts.md
  ```

- **The floor is stated as a number and the question is left open.**
  `grep -c '^## The floor$' docs/design/casts.md` is 1, and
  `grep -c 'docs/goals.md' docs/design/casts.md` is at least 1 (the
  section names the goal whose wording the floor bears on).
- `grep -c '```teal' docs/design/casts.md` is 0.
- `grep -c 'Measured against' docs/design/casts.md` is 0.
- `grep -c 'docs/decisions' docs/design/casts.md` is 0.
- `wc -l < docs/design/casts.md` is at most **480** (the lint cap is
  500; `nil-flow.md` is 464, `casts.md` is 215 today).
- `wc -l < docs/design/cast-sites.tsv` is **215**.
- **The minted items exist and are placed.** For every id the PR
  description lists, `o/bin/gitboard show <id>` from `o/board` reports
  `parent: 3HyRcW05wBip6Wqcz145bUQBTyj` and a `backlog` phase. One of
  them is the G3 wording-decision item, and
  `o/bin/gitboard find "wording"` finds it.

If the coverage or casts ratchet complains, run exactly the regen
command its failure message prints and commit the result — it is in
scope. Neither is expected to: the diff touches no `.tl`.

## Enablement

Two countermeasures, both already in the tree; no blocker item.

**The gate that keeps the map honest exists.** `_cli/citations.tl`
(run over every `.md` by `--check lint`, `_cli/lint.tl:376`) compares
a fenced `-- <path>:<line>` block's quoted text against the source on
every `--make ci`. Verified during this refinement: repointing
`casts.md`'s `cosmic/errno.tl:52` quote to `:53` fails lint with
`doc-citation: ... the quoted line is not cosmic/errno.tl:53`. That is
why every class's exemplars go in as fenced citations, and why the
snapshot line is a Non-goal.

**The extraction is a solved problem** — the wrong turn to avoid is
classifying from the grep, whose 225 hits include 11 non-casts and
whose line numbers are the reason comment's, not the cast's, on 69 of
214 sites. Use `_cli.lint.cast_lines` instead. This script, run during
this refinement against `40776231`, printed exactly 214 rows whose
per-file counts equal `_build/casts_baseline.tl` row for row. Write it
to a scratch path OUTSIDE the tree and run it with the built binary
(`o/bin/cosmic /tmp/sites.tl > /tmp/sites.tsv`) from the repo root:

```text
local fs = require("cosmic.fs")
local lint = require("_cli.lint")
local TREES <const>: {string} = {
  "_build", "_cli", "_docs", "_eval",
  "_fuzz", "_make", "_perf", "_tool",
  "_types", "cmd", "cosmic",
}
for _, tree in ipairs(TREES) do
  if fs.is_dir(tree) then
    local found = fs.find(tree, {glob = "*.tl"})
    if found then
      for _, path in ipairs(found) do
        if not ("/" .. path):find("/testdata/", 1, true) then
          local text = fs.read(path)
          if text then
            for _, n in ipairs(lint.cast_lines(text, path)) do
              print(path .. "\t" .. tostring(n))
            end
          end
        end
      end
    end
  end
end
```

Conventions are AGENTS.md; the prose standard is
`skills/docs-style/SKILL.md`, whose one addition here is that the
document says what the tree contains today rather than narrating how
it got there. `docs/design/nil-flow.md` plus
`docs/design/nil-flow-sites.tsv` is the doc-plus-inventory shape to
copy, and the current `docs/design/casts.md` is the subsection shape.
