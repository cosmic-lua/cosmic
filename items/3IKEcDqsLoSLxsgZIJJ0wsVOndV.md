Depends on 3IKD33rv (markdown parser/renderer: bind lowdown into cosmo, wrap
as `cosmic.markdown`) — needs a real parsed AST with header attrs to walk,
so this cannot start until that item has landed.

Evidence: cosmic's own decision records already cross-link by hand — e.g.
"[D24](docs/decisions/d24-structured-failures.md)" in AGENTS.md and
elsewhere — and nothing catches it when a rename or renumber breaks one of
those links. That is a silent-failure gap against G1 ("no silent bugs"), the
project's anchor promise, in the project's own docs.

This grew out of a broader "Pollen-style publishing" discussion (chapters,
cross-refs, multi-target render) that narrowed on purpose: the chapter/book
manifest and multi-target render orchestration pieces were dropped as
premature — cosmic's docs (decision records, guides) are not a linear book,
they're an unordered set that already references itself by ID, so no
pagetree/ordering structure is assumed or needed.

Scope for this item:

- stable IDs: headings carry an anchor via explicit `{#id}` header-attribute
  syntax (lowdown's `rndr_header` already carries an `attrs` field), with
  auto-slugified heading text as a fallback for headings with no explicit id.
- a global ID index: parse every doc in a target set (e.g. `docs/decisions/**`,
  `docs/guides/**`) to its AST via `cosmic.markdown`, collecting
  `id -> (file, node)`.
- resolution/validation: walk each doc's references — a markdown link
  pointing at another doc's anchor, or an explicit cross-ref marker — against
  the index, and flag anything that does not resolve (renamed file, deleted
  heading, typo'd id).
- surfaced as a new `cosmic --check lint` check, alongside the existing
  checks (fallible-returns, find-needle, cast-justification, ...) — no new
  gate machinery, just a new check registered in the existing lint pass.

Non-goal for this item: rendering resolved cross-references into working
output links/labels (HTML anchors, "see D24" prose, etc.) — that is a
natural follow-on once the ID index exists, not part of this slice. This
slice is lint-only: catch broken references, do not yet fix how they render.
