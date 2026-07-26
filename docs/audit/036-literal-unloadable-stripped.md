# 036 — `cosmic.literal` fails to load in every stripped artifact

severity: medium (public module unusable by its target audience)
type: bug (floor coherence)
area: `cosmic/literal.tl`, `cosmic/embed/floor.tl`

## issue

`cosmic/literal.tl:20` requires `tl` at module top level — its only use is
`tl.lex` (`literal.tl:110`). the strip floor keeps compiled `cosmic/**`
(so `cosmic/literal.lua` ships in every stripped artifact) but strips
`tl.lua`. the result: in a stripped artifact,
`require("cosmic.literal")` throws `module 'tl' not found` at load.

the module's own docstring pitches it at "any project that wants a config
file which *cannot do anything*" — and projects shipping stripped
artifacts are precisely that audience. the floor promises that what it
carries boots; here it carries a module that cannot.

## where

- `cosmic/literal.tl:20` — `local tl = require("tl")`, top level.
- `cosmic/literal.tl:110` — the single use, `tl.lex(source, where)`.
- `cosmic/embed/floor.tl` — keeps `cosmic/**`, strips `tl.lua`.

## the wider class, for the record

`cosmic/teal.tl:8`, `cosmic/format/init.tl:6`, and
`cosmic/coverage/lines.tl:8` also require `tl` at top level and also ship
in the floor unloadable. those three *are* compiler wrappers — needing tl
is their nature, and a stripped artifact reasonably lacks them. literal is
different: its purpose (safe config as data) does not inherently need the
compiler, only a lexer. fixing the class is not the ask; fixing literal
is.

## failure scenario

a user builds a stripped artifact whose code reads its own config with
`literal.of_file("config.tl")`. the artifact boots, and the first call
dies with `module 'tl' not found` — an error about the Teal compiler, in
an artifact that deliberately does not carry one, from a module whose
pitch is that it never runs anything.

## suggested fix

two levels, either acceptable:

1. **minimum (honest error):** move the require inside `of_source` behind
   `pcall(require, "tl")` and return
   `nil, "cosmic.literal needs the Teal lexer (tl), which this artifact does not carry"`
   — the module loads everywhere and fails per-call with the truth,
   matching the `value, string` contract.
2. **full (works when stripped):** replace `tl.lex` with a small
   self-contained lexer — the literal grammar needs only identifiers,
   strings, numbers, and punctuation, ~60-80 lines. this also removes the
   coupling that copied tl's naive `unquote` into the module (see 004:
   tl 0.24.8's own `unquote` at tl.lua:3104 is the same `sub(2, -2)` —
   escapes undecoded — so the shared lexer is not buying correct string
   handling today anyway). decide together with 004/005, whose fixes land
   in the same lines.

## test to add

the stripped-artifact lane the design calls for (make-plan.md gates)
should include `require("cosmic.literal")` plus one `of_source` call — it
would have caught this, and pins option 1 or 2 in place.
