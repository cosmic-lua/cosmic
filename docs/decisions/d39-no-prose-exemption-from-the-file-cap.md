# D39 — no prose exemption from the file cap; reclaim before you split

- **date:** 2026-08
- **status:** active
- **context:** `--check lint`'s file-length rule holds every file the
  project walk sees to ≤500 lines, `.md` included (`docs/reference/lint.md`),
  and AGENTS.md is itself one of the files it gates.
  Its `## Language and Conventions` section had grown to 175 lines — 82–256,
  36% of the file's own 491 — across four blocks, and most of that length
  was restatement, not rule: a 14-row `cosmo`→`cosmic` mapping table
  duplicating what `cosmic --docs <module>` already serves per module, a
  worked `is_main()` code block duplicating the one in `docs/howto/import-modules.md`,
  and narrowing/`check.must`/`is`/cast/`find-needle` walkthroughs duplicating
  `docs/howto/narrow-nil.md`, `type-errors.md`, and `lint.md`. G9
  (`docs/goals.md`) measures "AGENTS.md doctrine size" release over release
  and expects it to trend down; a doc that is exempt from the cap that
  measures it has no floor pushing back on that growth, and the owner's
  direction was explicit: no prose exemption from the 500-line cap,
  reclamation before any split, prefer gates over prose.
- **decision:**
  1. **no file is exempt from the 500-line cap for being prose.** AGENTS.md,
     `docs/**`, and every other `.md` file are held to the same
     `--check lint` file-length rule as source — the two carve-outs that
     exist (`.d.tl`, `testdata/`) are both about what a file's OWN grammar
     can express, never about whether it happens to be prose.
  2. **reclamation comes before any split.** when a doc nears the cap, the
     first move is cutting what the tree already enforces or already ships
     elsewhere — a lint's own rule text (`--docs guide.lint`), a module's own
     `--docs` page, a worked example under `docs/guides/**` — not dividing
     the file into two that each still carry the duplication. splitting is
     permitted once reclamation is exhausted and the doc still does not fit;
     it is never the first move.
  3. **prefer making the gate or the code explicit over describing its
     behavior in prose.** a table that restates what `--docs` serves, or a
     paragraph that walks through what a lint already enforces, is exactly
     the kind of text this cap exists to push back on — restated doctrine
     drifts from the mechanism it describes and doubles the places a change
     has to land.
- **rejected:**
  - **exempt AGENTS.md, or `docs/**` generally, from the file-length lint**
    — a doc that never faces the cap grows without the pressure every
    source file already carries, which is the opposite of what G9 measures
    (doctrine size trending down release over release); the cap already
    carves out `.d.tl` and `testdata/` for real grammar reasons, and "it's
    prose" is not one.
  - **split `## Language and Conventions` into multiple files first** — most
    of its length was duplication (the mapping table, the code block, the
    narrowing walkthroughs) already served, more exactly, by `--docs` and
    `docs/guides/**`; splitting before cutting that would have shipped the
    same duplication across more files instead of removing it.
  - **leave the section as it read** — it was well-written prose, but at
    175 of AGENTS.md's 491 lines it was 36% of the file's own budget under
    the cap this repo enforces on everything else, restating text a reader
    with only the binary can already reach through `--docs`.
- **consequences:** `## Language and Conventions` is 70 lines (82–151, four
  blocks: the bullets, `cosmo` vs `cosmic`, common patterns, error handling)
  and AGENTS.md is 386 lines, both comfortably under the 500-line floor
  `--check lint` already enforced on this file. every fact the section used
  to spell out — the `cosmo`→`cosmic` mapping, the `is_main()` pattern, the
  narrowing/cast/find-needle rules — still exists, but reached through
  `cosmic --docs` or `docs/guides/**` rather than duplicated here; a reader
  with only AGENTS.md now has to follow a pointer for detail the old prose
  gave inline, which is the cost, and is asked of them anyway once the
  binary is the only doc they have. this leans on `docs/guides/**` and
  `--docs` staying the reader's actual destination — if a guide this
  pointer names stopped shipping in the binary, that pointer would be
  lying and is what would force a revisit. changing what earns a prose
  exemption from the cap, or what "reclaim before split" requires, means
  amending this record.
