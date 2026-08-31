## Capture

HTML parsing for cosmic: research recorded, library decision deferred. Not
pullable as written — refinement must settle the library and then decompose into
the binding and the cosmic wrapper.

Scope wanted: parsing HTML cosmic produces (certain), and scraping fetched pages
(probable). **Those two pull toward different libraries**, and that is the whole of
the decision.

### Production is already covered; this item is parsing only

Generating HTML is the templating work, not this: `jABkj8hq` compiles templates to
Teal with a nominal `SafeHtml` that makes an unescaped interpolation a build-time
type error, and `w6WhvGLB` adds the URL/JavaScript/CSS contexts. `cosmic.html`
already wraps `cosmo.EscapeHtml`, and `cosmo.EscapeLiteral` (the JS string-literal
escaper, `escapejsstringliteral.c`) is bound in C but unwrapped in cosmic. No new C
is needed to *produce* HTML.

### What exists today

The only HTML binding in the fork is `EscapeHtml`:

```
$ grep -oE "^function cosmo\.[A-Za-z]*[Hh]tml[A-Za-z]*" tool/net/definitions.lua
function cosmo.EscapeHtml
```

`cosmic/html.tl` is 49 lines — `escape` and `unescape`. Nothing in the cosmic tree
emits HTML at all (`_docs/publish.tl` publishes markdown), so every use here is
prospective.

### The three candidates, measured

| | lines | status | parse algorithm | querying |
|---|---|---|---|---|
| **tidy** | 53,373 | **already vendored, unused** | Tidy's own | node-tree walk |
| **lexbor** html+dom+core+tag+ns | 65,298 | new vendor, Apache-2.0, active | full WHATWG tree construction | +selectors/css (36k) later |
| **gumbo** | small | upstream dead since 2016 | HTML5-conformant | parse tree only, no mutation |

**tidy is free.** `third_party/tidy` is htacg `tidy-html5`, not the HTML4 original —
its tag table carries `article`, `section`, `figcaption`, `template`, `main`,
`dialog`, `details`, `picture`, `slot`, and `README.cosmo` states HTML5 support.
`libtidy` exposes a DOM-like node tree plus diagnostics and pretty-printing. It sits
in the unreferenced set (no shipped target reaches it), so wiring it up **reverses a
deletion candidate** instead of growing the fork's diff. Upstream's last release is
5.8.0, July 2021.

**lexbor's HTML module is genuinely self-contained** — the reason its 22 MB
repository is not the vendoring cost:

```
$ grep -rhoE '#include "lexbor/(encoding|unicode|css|selectors)/' source/lexbor/html/
(no matches)
$ find source/lexbor/{html,dom,core,tag,ns} -name '*.c' -o -name '*.h' | xargs cat | wc -l
65298
```

So the parse subset stands alone and skips 529k lines of encoding and Unicode
tables. Pure C99, zero dependencies, no SIMD, amalgamation support, statically
linkable — all of which fit the fat binary. Used by PHP 8.4+ and selectolax.

### The decision, and what settles it

**Strict parsing is a coherent policy only for HTML you generate.** HTML fetched
from the web is never strict, and deterministic recovery from malformed markup *is*
the WHATWG algorithm. So:

- if scraping stays in scope, **lexbor** is the answer and tidy's freeness stops
  mattering;
- if scraping is dropped and only cosmic's own output is parsed, **tidy** covers it
  at zero vendoring cost — and it is worth asking whether a parser is needed at all,
  since output generated from a typed template is better tested at the template than
  re-parsed downstream.

Refinement should settle scraping first; the library follows from it.

### Decomposition once decided

- **cosmopolitan** — vendor (or wire up) the chosen parser, declare the binding in
  `tool/net/definitions.lua` in the same commit, and expose a node surface: parse a
  string to a tree, walk children, read tag names, attributes and text. If lexbor,
  decide separately whether `selectors` + `css` (+36k lines) come now or later; CSS
  selector querying is the ergonomic that makes scraping pleasant and is not needed
  for validation.
- **cosmic** — `cosmic.html` gains parse and query. It is 49 lines today with room
  under the cap, but templating is also adding `SafeHtml`/`safe`/`trusted` to it, so
  check whether it should become a directory module (`cosmic/html/`, the
  `cosmic/doc/` shape) before writing into `html.tl`.

### Open questions

- Is scraping actually in scope, or aspiration? It is the only thing that forces
  lexbor.
- Does a parser earn its place for own-output validation, given the templating
  item's type-level guarantees?
- If lexbor: selectors now or later.
- If tidy: is a 2021 upstream acceptable for a parser that will meet adversarial
  input?
