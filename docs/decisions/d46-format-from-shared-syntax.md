# D46 — formatting reads shared parsed syntax and returns its validated output snapshot

- **date:** 2026-09
- **status:** draft proposal — quiet-window old/new measurement pending
- **context:** `cosmic.format` validated its input with Teal's parser, then
  discarded the tree and reconstructed type position from nearby tokens in
  `cosmic/format/types.tl`. the approximation had accumulated separate rules
  for casts, parenthesized types, wrapped function signatures, comments
  between a colon and its type, and generic parameters. each missed case can
  misclassify a function type as a function body and bank indentation that no
  `end` closes; formatting the damaged result again is still a fixpoint. the
  formatter also had no entry point for a source another analysis tool had
  already parsed. after output validation became mandatory, one standalone
  format performed two lexes and two parses; parsing first in a caller and
  then calling the string API performed three of each. an instrumented test
  now fixes the shared caller plus formatter total at two lexes and two parses:
  one input pass and one mandatory output-validation pass. the pre-migration
  corpus baseline formatted all 718 tracked Teal sources successfully with
  runtime SHA-256
  `c37b286b10ef095a03b012896c83b7ed4678490b36ad0ca1bd5bc51d0b6f5ffb`.
  a quiet-window old/new timing and complete output-hash comparison are
  deliberately deferred; contended trial runs had 15–64% relative noise and
  support no speed claim. Teal v0.24.8's parsed type values originally carried
  only a start coordinate, so exact type ends could not be recovered from the
  AST without parsing type tokens again.
- **decision:** formatting consumes `cosmic.ast.source.Snapshot` syntax and
  retains the existing token emitter and house style.
  - `format_snapshot` uses the supplied tokens and parser-owned type, generic,
    attribute, child, and role indices without parsing its input again. its
    second return is the validated output snapshot, so a checking or editing
    pipeline can continue from the formatter's mandatory output parse.
  - type annotations are syntax. formatting never requires inferred types,
    resolved imports, or a type-correct program.
  - parser-owned byte ranges classify function types, generic parameter lists,
    and declaration attributes. a category moves off token heuristics only
    when the supported grammar has exact ranges and corpus comparison retains
    the current output. an unknown range remains explicit; it is not called
    structural because a token-window fallback produced an answer.
  - output must retain the ordered lexical stream, comment contents, and exact
    literal token spellings, then parse successfully. lexer boundaries override
    spacing preferences.
- **rejected:**
  - **keep extending token-window type heuristics.** this avoids parser adapter
    work, but every new type shape can silently become a phantom code block;
    input parsing and formatter idempotence do not detect that damage.
  - **use inferred Teal types as the formatter's structure.** inference is not
    source syntax, and it makes basic formatting depend on imports resolving
    and the program passing its type check.
  - **build a second concrete-syntax parser in the formatter.** it would
    duplicate Teal's changing grammar and make disagreement with the compiler
    a permanent formatter state.
  - **generate source from the AST.** Teal's generator does not own Cosmic's
    comment placement, literal spelling, shebang, and blank-line style; using
    it would replace a layout formatter with a source regenerator.
- **consequences:** a parsed snapshot can flow through formatting and into the
  next analysis step with one input parse and one validating output parse.
  standalone formatting still pays both passes because accepting valid input
  does not prove the emitter preserved it. `cosmic.ast.source` and the carried
  Teal range patch become formatter dependencies, including canaries for every
  supported type-range parse site. the first migration keeps
  `cosmic.format.types` as a compatibility and comparison surface, but
  formatter-owned items carry a structural-classification marker and do not
  fall back to it. structural coverage is limited to grammar-instrumented type
  syntax and the child kinds listed by `cosmic.ast.source`; missing or foreign
  ranges are refused by that API. declaration-wide record, interface, and enum
  type values are excluded from type-token marking because their parser ranges
  also contain the real block opener and closer; their nested field type ranges
  remain structural. the performance scenario records string and shared-
  snapshot entry points, but its comparison is pending a quiet measurement
  window.
