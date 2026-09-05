# Teal-aware structural search & replace: exploration notes

Reference material from a spike exploring what an ast-grep-style
structural search & replace tool would look like for Teal, built on
`tl`'s own lexer/parser rather than regex. `tlgrep.tl` in this directory
is the spike script (`bin/cosmic docs/design/ast-rewrite/tlgrep.tl
'<pattern>' <file> ['<replacement>']`), kept as a working reference, not
shipped code: it isn't a `cosmic.*` module, isn't gated by `--make ci`,
and has no tests. This is not a decision record — no tradeoff here is
settled, and nothing here binds future work.

## What it demonstrates

- The pattern is parsed with the same parser as the target (`tl.lex` +
  `tl.parse_program`), so `os.execute($X)` is a real (partial) AST, not
  a regex. `$NAME` is a single-node capture; `$$$NAME` is a rest-capture
  matching zero or more trailing list elements (ast-grep's own
  spelling). Both desugar to valid Teal identifiers (`_NAME`/`___NAME`)
  before lexing, since `$` isn't a legal identifier character and the
  pattern must parse as real Teal to become a real AST.
- Matching is one fully generic recursive structural walk (`match_value`
  in `tlgrep.tl`): every named field the pattern specifies must match,
  with unspecified fields ignored (subset matching), so a statement or
  block pattern (`if $C then $$$BODY() end`) falls out of the same
  recursion that handles a call's arguments — no per-node-kind
  special-casing needed.
- A match's span is computed by recursing to the real leftmost/
  rightmost descendant token rather than trusting `tl`'s own
  `yend`/`xend` uncritically (see Findings below), precise enough to
  splice the ORIGINAL bytes outside the matched range.
- The spliced result is re-run through `cosmic.format` rather than
  hand-preserving inter-argument whitespace, and a match that would
  silently drop a comment (one sitting in the "connective tissue"
  between captures, not covered by any capture's span) is refused
  rather than applied.

Validated empirically against real files in this repository (search
only — no tracked file was modified by running it): 1103 matches with
zero crashes across 80 real `.tl` files for a block-level pattern.

## Findings worth carrying into any real design

**tl's own end-position bookkeeping is unreliable for arbitrary spans.**
`tl.lua`'s `parse_list` (`tl.lua:2776-2781`) stamps a list node's
`yend`/`xend` using the TERMINATOR token that stopped it — correct when
that terminator is a real delimiter belonging to the node itself (a
call's `)`, a table's `}`), but for a bare list with no delimiter of its
own (`return a + b`'s `expression_list`, stopped only by the enclosing
block's `end` three lines later) it points at someone else's token
entirely. The same node kind (`expression_list`) is both cases; there is
no kind-based rule that separates them. The spike resolves this by
checking the actual source character at the reported position (trust
only a real close-bracket) and, for a block (`kind == "statements"`),
trusting it unconditionally — a block's own `yend`/`xend` is the only
place its true close lives, since an empty or short block has no
descendant token that reaches it.

**tl's AST has real cycles, not just shared tables.** An `if_block`
carries an `if_parent` field pointing back at its own enclosing `if`
statement. A structural matcher (or any generic field-recursion) needs
an identity-keyed visited-set the same way `_tool/coverage/lines.tl`'s
walk already has one for shared nodes — confirmed by inspection, not
theoretical.

**A generic walk must handle bare-array fields explicitly.** A field
like `if_blocks` is a plain Lua array with no `kind`/`y` of its own;
Teal's `is` on a generic map type (`{any:any}`) matches any table at
runtime, so a naive `is {any}` fallback branch placed after an `is M`
check is unreachable dead code. The walk must check for a real position
field (`y`) to decide "is this a node" vs. "is this an array of nodes",
not lean on `is` to distinguish two structurally-overlapping type
aliases.

**`tk` is only sometimes semantic.** It's the real identity of a
`variable`/`identifier`/`string` leaf, but on a compound node
(`statements`, `if_block`) it's just whichever token happened to open
it — differs incidentally between pattern and target even on a genuine
structural match, and must be excluded from generic field comparison.

**Hit ordering must not depend on table traversal order.** The AST walk
falls back to `pairs()` over a node's non-array fields once its array
part is exhausted, and Lua's hash-part iteration order isn't guaranteed
stable across runs. Search output and rewrite application order are
sorted by source position explicitly rather than left to depend on it.

**Semantic rename needs different primitives than the ones `tl`
exposes.** `tl.symbols_in_scope(tr, y, x, filename)` and
`tl.get_token_at(tks, y, x)` are hover/autocomplete-shaped queries
("what's visible here, and what's the raw token text at this exact
position") built on a scope-stack trace (`TypeReporter`'s
`symbols_by_file`, with `@{`/`@}` bracket markers) — they don't provide
a stable per-declaration identity comparable across two different
positions the way a real find-references/rename needs. The checker's
actual variable resolution (`TypeChecker:find_var`, `tl.lua:7849`) does
resolve a name to a per-declaration `var` object while checking, but
that resolution isn't currently persisted anywhere queryable after the
fact. A real semantic rename would need either new, deeper (and
presently uncurated) plumbing into `TypeReporter`'s internals, or —
more robust against `tl` version drift — its own scope-aware walk built
directly over the AST: Teal's scoping is strict block-lexical scoping
that's already fully recoverable from the same node nesting the
structural matcher already walks (`local_declaration`/`local_function`/
a function's own parameter list introduce bindings; `statements`/block
nodes delimit their lifetime and shadowing follows nesting).

## If this became a real module

- `cosmic/ast/` (public, like `cosmic/fs/`), split under the 500-line
  cap: a real `Node` record (not `any` — `_types/gentl.tl` currently
  erases it, and every internal consumer re-derives its own narrow
  slice), a generic cycle-guarded walk, the matcher, and the
  span/splice logic, each its own file.
- A conformance test in the same spirit as `_types/gentl.tl`'s own
  ratchet against the pinned `tl` source, so a `tl` pin bump that
  reshapes a node fails loudly on this repo's own PR rather than
  silently mismatching downstream.
- Rewrite output piped through `cosmic.format` (as the spike already
  does) rather than hand-preserving whitespace — also doubles as a
  validity check, since the formatter reparses.
- Multi-pass rule application to a fixpoint, capped like
  `_make/converge.tl` already caps build convergence, with the same
  loud failure past the cap rather than an unbounded loop.
- Project-wide traversal via `_make`'s existing "which files belong to
  this project" logic rather than a second, separately-maintained one.
- A CLI verb (`_cli/rewrite.tl`) as a thin consumer of the library,
  mirroring `_cli`'s existing relationship to `cosmic.fs`.
