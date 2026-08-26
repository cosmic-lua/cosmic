## Goal

G3 — an honest type layer, no escape hatches. `docs/design/casts.md` is
the document the from-any cast-closure items are cut from, and every
number in it is now roughly twenty times the truth. This slice makes
the document carry only facts a gate can check, so it cannot drift
again.

## Evidence

Measured 2026-08-26 at main `5ba85817`, from the repo root.

- **The from-any bucket is 9 live sites, not 192.** The doc's opening
  sentence says "192 of the 402". Today:

  ```text
  git ls-files '*.tl' | xargs grep -h -- "-- cast: " | wc -l          # 224
  git ls-files '*.tl' | xargs grep -h -- "-- cast: " | grep -c "from any"  # 13
  git ls-files '*.tl' | xargs grep -lc -- "-- cast: .*from any" | wc -l    # 10
  ```

  Four of those 13 are fixture TEXT inside test data, not casts —
  `_build/casts_test.tl:69` and `:75`, `_cli/assert_lint_test.tl:152`,
  `_tool/lint_test.tl:60`. The 9 live sites, in 8 files, are the whole
  remaining class:

  ```text
  cosmic/errno.tl:52
  cosmic/fd.tl:187
  cosmic/fetch/init.tl:238
  cosmic/fetch/init.tl:366
  cosmic/fetch/init.tl:384
  cosmic/quicksand/proc.tl:262
  cosmic/surface_test.tl:92
  cosmic/teal.tl:166
  cosmic/zip.tl:222
  ```

  (`cosmic/fetch/init.tl`'s three are board item `3IQCrJpB`.)

- **The per-class tables are dead weight, row by row.** The seven
  tables name 63 distinct files; **55 of them carry zero from-any
  sites today** and 8 still carry one. None is gone — the earlier
  filing's claim that five rows name deleted files is wrong: all five
  of `cosmic/deep_example.tl`, `cosmic/deep_test.tl`,
  `cosmic/quicksand/box/init_test.tl`, `cosmic/quicksand/box/merge.tl`
  and `cosmic/quicksand/box/merge_test.tl` exist and simply carry no
  from-any cast any more. Reproduce by extracting the table rows
  (`grep -oE '^\| [A-Za-z0-9_./-]+\.tl \|' docs/design/casts.md`) and
  counting `grep -c -- '-- cast: .*from any'` per file.

- **The tables are 102 of the document's 286 lines.**
  `grep -cE '^\|' docs/design/casts.md` is `88` rows, plus a
  two-line header per table; `wc -l < docs/design/casts.md` is `286`.
  The seven stated per-class totals
  (`grep -nE '^\| \*\*total\*\* \| [0-9]+ \|' docs/design/casts.md`,
  at `:78,111,132,177,205,235,254`) are `61, 55, 9, 38, 13, 15, 1` —
  192 against 9.

- **The `Measured against` line is what let it drift.**
  `grep -c 'Measured against' docs/design/casts.md` is `1` (line 12).
  `_cli/citations.tl:19-25` makes any document opening a line with
  ``Measured against `<hex>` `` a SNAPSHOT: its citations' PATHS are
  still checked, but their line POSITIONS are left unjudged. Remove
  that line and every citation in the file becomes position-checked on
  every CI run (`_cli/citations.tl:163-187`, reached from
  `_cli/lint.tl:425-428` for every `.md` the walk gates).

- **The document has 13 inline citations and 0 fenced ones.**
  `grep -oE '`[A-Za-z0-9_./-]+\.tl:[0-9]+(-[0-9]+)?`' docs/design/casts.md
  | wc -l` is `13`;
  `grep -cE '^-- [A-Za-z0-9_./-]+\.tl:[0-9]+$' docs/design/casts.md`
  is `0`. Every one of the 13 paths exists and every line number is in
  range today, so dropping the snapshot line is green on arrival. But
  only two of the 13 name a line that still carries a from-any cast
  (`cosmic/errno.tl:52`, `cosmic/surface_test.tl:92`); the rest
  illustrate the classes with sites that are closed, so the prose
  around them is now fiction the gate cannot see.

- **A fenced citation is checked for TEXT, not just position.**
  `_cli/citations.tl:110-117` reads a `-- <path>:<line>` comment as a
  code block's first line, and `:190-209` compares the next non-blank
  line against that source line, trimmed. So a site quoted in the
  fenced form fails CI the moment the quoted line changes — which is
  the mechanism that keeps this document current without anyone
  remembering to look.

- **The ratchet already gates the other direction.** `_build/casts.tl`
  counts `as` tokens per file through `_cli.lint`'s lexer against the
  floor in `_build/casts_baseline.tl` (90 lines), so a NEW cast cannot
  appear unnoticed. The document does not need to count anything.

## Change

Rewrite `docs/design/casts.md` so that it states only what is constant
and cites only what a gate verifies. One file; no `.tl` changes.

1. **Delete the snapshot line** (line 12,
   ``Measured against `d3e59de7` on 2026-08-25.``) and the sentence
   beside it about the counts being a snapshot. This is what turns the
   citation gate on for the file, so it must go first.
2. **Delete all seven per-class tables**, headers and `**total**` rows
   included, and every count in the prose — the opening
   "192 of the 402", the "189 of the 192", the "63 files", and each
   class's stated size. The document makes no numeric claim afterwards.
   **A COMPARATIVE claim is a count.** "the largest live class", "the
   largest single win available anywhere in this document", "worth
   roughly a third of this document" — each ranks classes by how many
   sites they hold today, so each drifts exactly the way a number does
   and no gate can see it. They go with the counts, wherever they
   appear, whether they were already in the document or would be new
   prose. `main` carries three — `:5` ("largest single bucket", inside
   the opening sentence this rule already deletes), `:60` (on
   **Decoded-data shaping**, a class with zero live sites, so that
   claim is not merely undurable but false) and `:264` ("worth roughly
   a third of this document", in `## What no mechanism closes`). PR
   #1402's head `8c0b67a6` cut `:5` and `:264` and kept `:60`, then
   added a new one ("This is the largest live class", on **Binding
   boundary**); both of those go. What survives is
   qualitative: what a class IS, and the mechanism that would retire
   it. Where ordering genuinely matters, say it as a property of the
   MECHANISM ("this class closes in the other repository, so it moves
   as a pin bump"), never as a size.
3. **Keep all seven `###` class headings and their "What closes it"
   prose**, and the `## What no mechanism closes` and
   `## What this is not` sections. That is the durable half: the shape
   of each site and the mechanism that would retire it.
   `docs/decisions/d28-shape-combinators.md:7` cites this document for
   the decoded-data-shaping class, so that heading and its closure
   prose stay even though the class has no live site left. "Keep the
   prose" is subject to rule 2: a kept paragraph still has its
   comparative claims cut, which is what `docs/design/casts.md:60`
   needs. Keeping a class whose live count is zero is right — the
   taxonomy is what a future site is read against — but the document
   must not then rank it above classes that do have sites.
4. **Rewrite `## Method`** to hold the census as the one thing a reader
   runs, and to say that the four fixture-text hits are text, not
   casts:

   ```text
   git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"
   ```

5. **Quote every live site in the fenced form**, under the class it
   belongs to, classified with the document's own definitions (the
   `## Classes` preamble's "more specific one takes it" rule decides a
   site two descriptions fit). Each is a `text` fence whose first line
   is the `-- <path>:<line>` comment and whose second is the source
   line verbatim:

   ````text
   ```text
   -- cosmic/errno.tl:52
     return (unix as {string: any})[name] as integer -- cast: dynamic E* lookup, from any
   ```
   ````

   All nine sites listed in Evidence get one. A class with no live site
   keeps its prose and cites nothing.
6. **Keep the two mechanism citations inline**: `cosmic/json.tl:135`
   and `cosmic/json.tl:155` name the `decode_object`/`decode_array`
   declarations rather than cast sites, so they stay backticked inline
   references. Drop the remaining inline citations that illustrate
   closed sites.

## Non-goals

- **No `.tl` file is touched.** This slice closes no cast and moves no
  count. `git diff --name-only` against `main` must name
  `docs/design/casts.md` and nothing else.
- **`docs/decisions/d28-shape-combinators.md` is not touched**, and
  neither is any other record under `docs/decisions/`. D28's context
  carries its own stale figures ("192 of the tree's 389 `as` casts",
  "61 sites"); a record states the decision as it was made, and
  amending one is the `decide` skill's business, never a side effect of
  a docs slice.
- **No generator.** The earlier filing offered deriving the tables from
  the tree the way `_build/casts_baseline.tl` is derived. Nine sites do
  not earn a generator, and this change removes the tables rather than
  producing them.
- **`_build/casts.tl`, `_build/casts_baseline.tl` and
  `_build/casts_test.tl` are untouched.** The cast ratchet is a
  separate mechanism and is working.
- **Never a ```teal fence.** `_build/snippets_test.tl` compiles and
  format-checks every `teal` fence at full strictness, and a quoted
  cast line is not a compilable module. Every fence this slice writes
  is ```text.
- **Do not delete the document** or fold it into another. D28 links to
  it, and the class taxonomy is what a future from-any site is read
  against.
- **Do not rename the file or its headings.** The `### Decoded-data
  shaping` heading in particular is what D28's sentence points a reader
  at.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS` — which is where the citation
  gate runs, so it is also the proof that all nine quoted lines match
  their sources.
- `grep -c 'Measured against' docs/design/casts.md` prints `0`
  (today `1`).
- `grep -cE '^\|' docs/design/casts.md` prints `0` (today `88`).
- `grep -cE '^-- [A-Za-z0-9_./-]+\.tl:[0-9]+$' docs/design/casts.md`
  prints `9` (today `0`) — one fenced citation per live site.
- `wc -l < docs/design/casts.md` prints a number ≤ `230` (today `286`:
  102 lines of table leave, roughly 36 lines of fenced citation
  arrive).
- `git diff --name-only origin/main` prints exactly
  `docs/design/casts.md`.
- `git ls-files '*.tl' | xargs grep -h -- "-- cast: " | grep -c "from any"`
  still prints `13` — unchanged, because this slice closes nothing.
- `grep -ciE 'largest|smallest|roughly a (third|half|quarter)|most of the|the bulk of' docs/design/casts.md`
  prints `0`. On `main` it is `3` (`:5` "largest single bucket", `:60`,
  `:264`); on PR #1402's head `8c0b67a6` it is `2` (`:61` and `:115`,
  the latter newly written) — no class is ranked by
  how many sites it holds. The pattern is a tripwire for the shape,
  not an exhaustive grammar: the reader still checks by eye that no
  kept or newly written sentence ranks the classes by size.

## Enablement

none needed. Every mechanism this relies on is in the tree and gated
today: `_cli/citations.tl` already checks fenced quotes and already
exempts snapshots, `_cli/lint.tl:425-428` already runs it over every
`.md`, and `_build/snippets_test.tl` already decides which fence
language is safe. The conventions that bind are AGENTS.md's and the
`docs-style` skill's, unchanged.
