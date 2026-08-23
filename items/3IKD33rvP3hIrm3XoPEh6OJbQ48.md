cosmic has no way to parse or render Markdown from Teal/Lua, and the gap is
already felt internally: `_build/ratchet.tl` hand-rolls a minimal markdown
table reader for decision-record tables, with a comment noting "three copies
of a markdown parser is three [too many]" — i.e. even ad hoc internal needs
for structured markdown reading already exist and are being worked around.

Researched candidate C libraries against cosmic's actual constraints
(permissive license, GFM-compatible tables since decision records use
markdown tables, actively-maintained provenance, portable to every BSD cosmic
ships on, and — important for a later Pollen-style processing pipeline — a
real AST rather than a flat HTML string, so `cosmic.markdown` can expose a
document tree and not just `render_html`):

- **cmark-gfm** (GitHub's fork, adds tables/strikethrough/tasklists): ruled
  out — no longer appears actively maintained, a provenance risk for a
  vendored dependency.
- **cmark** (CommonMark reference impl): ruled out — no table support, and
  cosmic's own docs use markdown tables.
- **md4c**: fastest, single `.c`+`.h`, MIT, actively maintained, GFM tables
  via `MD_FLAG_TABLES`. But SAX/callback-only — no tree — so cosmic's binding
  would have to build its own AST from callbacks instead of getting one from
  the library. Good fallback if `_perf` later shows the AST-building parser
  too slow.
- **lowdown** (kristapsdz/lowdown, ISC license) — **recommended**. Actively
  maintained (commits through July 2026, including a May 2026 source-tree
  restructure). Ships a genuine AST: `struct lowdown_node` — 37 node types,
  parent pointer + `TAILQ`-linked children, tagged union of per-type structs
  (`rndr_header{level,attrs}`, `rndr_link{link,title,attrs}`,
  `rndr_list{flags,start,items}`, `rndr_table_cell{...}`, etc). Parse
  (`lowdown_doc_parse`) is separate from rendering, and multiple renderers
  already consume `const struct lowdown_node *`: html, latex, gemini, term,
  roff/man, odt, tree/debug. Built and tested specifically against
  OpenBSD/NetBSD/FreeBSD/Linux — the exact platform set cosmic ships. Gap:
  no source line/offset on nodes (fine for v1; would matter only if we later
  want markdown-source-accurate error locations). No walk/traverse helper is
  exposed — cosmic's binding writes the recursive descent itself (trivial
  `TAILQ_FOREACH`), which is also exactly the code that projects lowdown's C
  union into public Teal record types.

Binding shape, following the existing pattern in whilp/cosmopolitan
(`tool/net/l<lib>.c`, closest precedent `lre.c` — a small userdata-with-
metatable binding): vendor lowdown's `src/` tree into
`third_party/lowdown/` (argon2-style — original file layout + own `BUILD.mk`
+ `README.cosmo` with ORIGIN/LICENSE/VENDORING), write
`tool/net/lmarkdown.c` binding `lowdown_doc_parse` into a
`cosmo.markdown.Document` userdata (walking the `TAILQ` children into a Lua
table tree of `{type=, attrs=, children=}`) plus render functions, register
in `lcosmo.c`, annotate in `definitions.lua`, and add the new module to the
annotation-coverage ratchet (`tool/lua/test_definitions_coverage.lua`). On
the cosmic side, wrap as `cosmic/markdown.tl` following the
`cosmic/re.tl`/`cosmic/json.tl` D24 error-shape conventions, exposing the
parsed tree as typed records — not just HTML — so downstream code can
walk/transform it.

Non-goal for this capture: no commitment to a Pollen-style `◊`-command
preprocessor or multi-target publishing pipeline — that's a distinct, later
idea. This item is scoped to: cosmo binding + `cosmic.markdown` wrapping the
AST + at least HTML rendering.
