## Goal

G9 — the least tree that keeps its promises. AGENTS.md sits at exactly
the 500-line cap; the owner's direction (recorded in this item's
history): no carve-out, per-file cap, and reclamation before any split —
"the win is fewer words, not more places to put them." This slice is the
first reclamation: the module table, which is derived, not authored.

## Change

Delete AGENTS.md's `## Standard Library Modules` table and the machinery
that re-derives it, replacing the section with a pointer. Measured
2026-08-19 at `f420391` (AGENTS.md is 500 lines; `CLAUDE.md` is a
symlink to it, so one file changes):

1. **`AGENTS.md`** (lines 346–401: the section heading, intro line, and
   45-row table, ending before `## \`--make\` fixtures` at 402): replace
   the whole section body with a short paragraph (keep the heading):
   modules live under `cosmic/` and import as `cosmic.*`; the
   authoritative list with one-line descriptions is served by the binary
   (`cosmic --docs` for the list, `cosmic --docs <module>` for one), and
   a module's description is its H1 first line. Expected size after:
   ≤ 455 lines (~50 reclaimed); state the exact `wc -l` in the PR.
2. **`_docs/derive.tl`** (260 lines): remove `modules_table` (lines
   143–…), the `MODULES_HEAD` and `AGENTS` constants, their record
   fields and exports (lines 34–35, 214–215, 217, 224–225, 227), and the
   `{AGENTS, MODULES_HEAD, modules_table()}` job from the `is_main`
   rewrite list (line 244). The decisions-index half (`decisions_table`,
   `INDEX`, `DECISIONS_HEAD`, `committed_table`) stays — `committed_table`
   is still consumed by the decisions drift test.
3. **`_build/docs_test.tl`** (57 lines): delete
   `test_the_module_table_matches_the_doc_index` (lines 39–55) and its
   call. The decisions test stays.

Measured consumer check: `git grep -n "modules_table\|MODULES_HEAD"`
returns only the lines named above — nothing else reads them.

## Non-goals

- no other AGENTS.md section changes: the Language-and-Conventions
  shrink (149 lines) is its own follow-up item, filed separately with
  the owner's direction, and the decision record rides with THAT slice —
  not this mechanical one.
- no structural split of AGENTS.md — reclamation lands first, per the
  direction.
- no change to the decisions-index derivation or its test.
- no change to what `cosmic --docs` serves — the doc index is untouched.

## Acceptance

- `wc -l AGENTS.md` prints ≤ 455.
- `git grep -c "modules_table" -- "*.tl"` prints nothing (no matches).
- `bin/cosmic --make test _build/docs_test.tl` ends `test: PASS (1
  files)`.
- `bin/cosmic --make ci` ends `ci: PASS`.

## Enablement

none needed — pure deletion plus a pointer; the consumers of the deleted
surface are enumerated above from a measured grep, and the drift test
that would have contradicted the deletion is removed in the same diff.
