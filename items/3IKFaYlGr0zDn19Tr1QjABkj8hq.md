Neither cosmic nor whilp/cosmopolitan has any text-templating capability
today — checked both repos directly. (`cosmic/format/` and
`cosmic/_literal_format.tl` are cosmic's own *code* formatter, unrelated.)

Unlike the markdown parser (3IKD33rv), this should NOT be a vendored C
library. CommonMark justified reusing tested C because the spec is large and
easy to get subtly wrong (600+ conformance cases). A Go-`text/template`-style
grammar is small — dot (current data value), field/method access, `if`,
`range`, `with`, named template calls, and pipelines over registered
functions — small enough to implement natively in Teal, comfortably under
the 500-line file cap, fully inside cosmic's own typed/gated code with no
third-party C trust surface to vendor and maintain.

Scope, sequenced deliberately in two phases:

**Phase 1 (this item): plain-substitution `cosmic.template`.** Go's action
vocabulary (`{{.Field}}`, `{{if pipeline}}...{{end}}`,
`{{range pipeline}}...{{end}}` rebinding dot, `{{with pipeline}}...{{end}}`
rescoping dot, `{{template "name" pipeline}}` for composition, pipelines
`{{.Name | fn}}` over a registered function table), naive substitution, no
auto-escaping.

**Phase 2 (explicit, deferred follow-on, not this item): HTML-context-aware
auto-escaping**, modeled on how Go's `html/template` actually works — it is
not a separate implementation, it WRAPS `text/template`: same lexer/parser
producing one AST, and a pass that runs between parse and execute, walking
the tree, tracking HTML/JS/CSS/URL context from the literal text between
actions (a small state machine: inside a tag? an attribute? a `<script>`
block? a URL attribute?), and at each action REWRITES the pipeline to append
the right escaper call. The same executor then runs the now-escaping-injected
tree — no second engine, no execution-time mode switching.

Because phase 2 is proven to bolt onto phase 1 rather than replace it (that
is literally what Go did, in production, for over a decade), phase 1's
design must make five specific commitments now so phase 2 needs no rewrite
later — these are the acceptance-relevant constraints for this item, not
speculative gold-plating:

1. Parse to a real AST first; execute as a separate pass over it. The
   shortcut of compiling straight to a rendering closure in one pass is the
   one choice that would force a rewrite later.
2. Custom functions are data: a `Funcs` table (name -> Teal function)
   passed to the engine, invoked via pipeline syntax. Escaper functions
   (`html_escape`, `url_escape`, `js_escape`, ...) can be written and
   registered in phase 1 itself, usable manually (`{{.Body | html_escape}}`)
   — real, testable value now, not a stub for later.
3. A pipe is a mutable list of commands, not a pre-flattened composition —
   auto-escaping later works by consing an escaper command onto a pipe.
4. Literal text nodes survive between actions, in document order — the
   future context-scanner reads them to infer HTML/JS/CSS/URL context.
5. Module boundary mirrors Go's actual package split: `cosmic.template` is
   the phase-1 engine (shared parser + naive executor); a later
   `cosmic.template.html` (or similar) is a thin wrapper adding the
   context-tracking rewrite pass over the same tree/executor — no inert
   "escaping mode" flag sitting unused in phase 1's public API.

Relationship to the other recent captures: this is the render-time
composition layer the Pollen-publishing thread deferred ("render resolved
cross-references into output", "templates decoupled from content") — 3IKD33rv
(markdown AST) and 3IKEcDqs (cross-ref lint) are natural future consumers,
but this item does not depend on either and stands on its own (config-file
generation, code generation, any text output from data are all uses with no
markdown involved).

Non-goal for this item: HTML-context-aware auto-escaping (phase 2) — named
above only to constrain phase 1's design, not to be built now.
