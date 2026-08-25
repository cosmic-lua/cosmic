# D28 — a validating decode is combinators the checker checks, not a table of type-name strings

- **date:** 2026-08
- **status:** active
- **context:** `from any` is the reason on 192 of the tree's 389 `as`
  casts, and the largest of its seven shapes — 61 sites, mapped in
  [docs/design/casts.md](../design/casts.md) — is decoded-data shaping: a
  value comes out of `json.decode`, `literal.parse`, a loaded chunk or
  `Response:json()` and is then read field by field into a shape the code
  already knows, each read costing a cast. `_eval/score.tl:194` is the
  pattern at its purest, ten consecutive fields lifted off one decoded
  table with ten casts, preceded by a hand-rolled presence loop over a
  `REQUIRED_META_FIELDS` list. `cosmic.json.decode_object` and
  `decode_array` type the outermost table and stop; nothing turns a
  decoded table into a declared record with the fields checked, so every
  one of those reads is an unchecked assertion about data that came from
  outside the program. Two facts constrained the answer. The value does
  not always come from JSON — 17 of the 61 sites decode with
  `literal.parse`, `loadfile` or `pcall(chunk)` — so the mechanism cannot
  be a decode function. And Teal has no runtime reflection over record
  fields, so the target shape has to be described by a value the caller
  passes; the type itself comes from the caller's own annotation, which
  `cosmic --check types` confirms is inferred through a generic return in
  three call shapes and not in a fourth.
- **decision:**
  1. **`cosmic.shape` validates an already-decoded value, and the
     decoders keep their signatures.** `shape.into(value, spec)` takes
     `any` and returns it typed; `json.decode`, `json.decode_object`,
     `json.decode_array`, `literal.parse` and `Response:json()` are
     unchanged. One mechanism therefore serves every decoder in the tree
     and any a project adds.
  2. **The shape description is combinators, not data.** A `Spec` is
     built from `shape.string`, `shape.number`, `shape.integer`,
     `shape.boolean`, `shape.any`, `shape.list`, `shape.map`,
     `shape.record` and `shape.optional` — each a typed value or a
     function returning one. A misspelled combinator and a field bound to
     something that is not a `Spec` are compile errors, checked by the
     same pass that checks the rest of the file.
  3. **Extra keys are ignored, nothing is coerced, and errors are
     strings.** A payload that grows a field must not start failing, so
     `into` checks what the `Spec` names and no more. `shape.number`
     refuses `"1"`; the sole conversion is `shape.integer` normalizing a
     whole-valued float in place, because a Teal `integer` field holding a
     float is the type lie the module exists to prevent. A mismatch
     returns the first offender as `"<path>: <problem>"` —
     `"rows[2].id: expected string, got number"`.
- **rejected:**
  - **a table of type-name strings** (`{a = "string", b = "number?"}`) —
    terser at every call, and it round-trips through `cosmic.literal`,
    which combinators do not. It loses because the spec is then data the
    checker cannot check: `"strig"`, a `"number?"` where the module
    expects `"number ?"`, or a key holding a nested table where a string
    was meant are all runtime discoveries, and the failure mode of a
    validator that mis-parses its own spec is to skip a field silently —
    the exact class of silent bug [D3](d03-no-silent-bugs.md) ranks first.
    The accepted cost is verbosity: every spec is longer than its string
    form would be.
  - **generate the Spec from the Teal record declaration.**
    `cosmic/_teal_ast.tl` can read a record's fields, and a `*_gen.tl`
    could emit a validator per record with no spec written by hand at all
    — no duplication between the record and its shape, which is this
    decision's real cost. It loses on reach: a generated validator serves
    only records inside a project that runs the generator, so the public
    API a user calls on their own decoded data would still need this one,
    and cosmic would carry two. Revisit if the hand-written specs drift
    from their records often enough to be measured.
  - **a structured `Failure` record in slot 2** ([D24](d24-structured-failures.md))
    — D24 asks for one when failures carry real structure callers branch
    on. A validation failure carries a path and a reason, callers do not
    branch on which, and `check.must` already accepts a plain string, so a
    record would be ceremony. Revisit if a caller needs the path
    separately from the message.
  - **return a validated copy instead of the same table** — a copy would
    make `shape.integer`'s normalization invisible to the caller's
    original, which is tidier. It loses on cost and on surprise: every
    decoded payload would be walked twice and duplicated in memory, and a
    caller holding the decoded value would silently be holding a different
    table from the one it just validated.
  - **refuse extra keys** — a stricter contract that would catch a
    misspelled field in a config file. It loses because the same
    strictness turns every additive change in an upstream JSON payload
    into a hard failure, and the values being validated here are largely
    payloads cosmic does not own.
- **consequences:** the 61 decoded-data sites become ordinary typed reads
  through one API, and the hand-rolled presence checks above them
  (`REQUIRED_META_FIELDS` in `_eval/score.tl`, the `results.results == nil`
  guard in `_perf/compare.tl`) are subsumed rather than duplicated. What it
  costs: a `Spec` restates by hand what a record declaration already says,
  and nothing checks that the two agree — a field added to the record and
  not to the spec is simply unvalidated. The generic return type is
  inferred from the caller's annotation, which means
  `local m = check.must(shape.into(raw, SPEC))` fails to compile with
  "cannot infer declaration type" while `local m: Meta = check.must(...)`
  succeeds; the module doc comment carries all four shapes because that is
  the wrong turn every converting session will take. `shape.into` is not a
  parser and does not become one: it never sees the text a value was
  decoded from, so it cannot report a line or column. Revisit if a caller
  needs validation to describe where in the SOURCE a bad value came from
  — that is a decoder's job, and would belong to `cosmic.json` and
  `cosmic.literal` rather than here.
