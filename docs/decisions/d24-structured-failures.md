# D24 — slot 2 may carry a structured error: concrete per-module records, one `Failure` supertype

- **date:** 2026-08
- **status:** active
- **context:** the doctrine said "errors are strings": a fallible
  return is `T | nil, string`, full stop. That held until a domain had
  errors with real structure — `cosmic.fetch` classifies every failure
  with an `ErrorKind` enum that its retry policy branches on
  exhaustively (`RETRYABLE_KIND < total >`). #1063/#1066 enforced D20
  rule 11 (nothing past slot 2) and folded the classification into the
  message as a `"<kind>: "` prefix — good for logs, but text, so the
  only way a caller could branch on the classification was to parse a
  prefix out of a message, which no language surveyed makes callers do
  (#1067). The tension was never rule 11; it was the string doctrine
  meeting a structured domain.
- **decision:** slot 2 is `string` by default, and a module whose
  failures carry structure returns **its own concrete error record**
  there — still two slots, rule 11 untouched.
  - One interface, `cosmic.errors.Failure` (`message: string`,
    `metamethod __tostring`), declared low so `cosmic.check` can
    reference it. It is the **sink-side supertype only**: Teal admits
    at most one table type in a union, so there can be exactly one,
    and a sink that accepts any module's error names it —
    `check.must(value: T | nil, err?: string | Failure)`.
  - Producers return the concrete type: `fetch.fetch(url): Response |
    nil, fetch.Error`, with `record Error is Failure` carrying
    `kind: ErrorKind`. The enum stays module-local and exhaustive at
    the call site — a typo'd kind or an undecided retry position is a
    compile error. Returning the interface instead would flatten every
    caller to `message`-only (no field covariance: an interface `kind`
    field would force ONE library-wide enum) and defeat pass-through
    combinators, which preserve the concrete type via generics.
  - **Classification is by field value, never by `is`**: `is` compiles
    to `type(x) == "table"`, so narrowing `Failure` to a concrete
    record is unsound — measured, not assumed (#1067). There is no
    `errors.As` here and the design does not pretend otherwise.
  - **`__tostring` yes, `__concat` no.** `tostring(err)` renders the
    classified form (`"<kind>: <detail>"` — exactly the string slot 2
    used to carry); `message` stays clean of prefixes. `..` on an
    error record is a deliberate compile error, so rendering is always
    honest. The checker believes declared metamethods whether or not a
    value went through the constructor that attaches them, so each
    producing module funnels every error through one constructor and
    pins it with a metatable assertion in its tests.
  - **Translate at the boundary.** When a second module goes
    structured, one function cannot name two concrete records in a
    slot (the union rule). The sanctioned escape is Go-style
    translation into the enclosing module's own error type — each
    module's vocabulary stays closed and locally owned; the cause
    degrades to text at the hop. Widening to `Failure` (losing both
    classifications) is not.
  - Cause chaining is a non-goal: a `cause: Failure` field would be
    readable but never discriminable, documentation rather than
    dispatch.
- **rejected:** three positional slots (`value, message, code`) — rule
  11 outlaws it and no surveyed language does it; a uniform `Failure`
  in every structured slot 2 (no field covariance means one global
  enum, and combinators flatten the concrete type); a generic
  `Failure<T>` payload (`Failure<FetchData>` does not reach a
  `Failure<any>` parameter — measured dead); parsing the kind out of a
  message prefix (the #1066 status quo this record replaces); keeping
  errors strings and dropping `fetch.Error` from the public surface
  (there was no `.kind` consumer yet, but the retry policy already was
  one, and the prefix would have become a de-facto parsed contract).
- **consequences:** `check.must` keeps its teeth — a concrete record
  reaches `string | Failure` through multiple-return passthrough, a
  slot-2 boolean is still rejected by name, and `must` throws the
  rendered `tostring`. Callers that want text write `tostring(err)`
  or read `.message`; concatenation sites fail to compile until they
  do. The `fallible-returns` lint is arity-only and unaffected.
  `fetch` is the first structured module (its download local-IO
  failure is fetch's own `"io"` kind, not a prefix-less special
  case); sqlite/fs may follow this record, converting per module and
  translating at boundaries. The doctrine prose in AGENTS.md,
  `docs/stdlib.md`, and `docs/guides/modules.md` points here. A
  type-only public module (`cosmic/errors.tl`) is a new shape for
  the tree: position still declares it public, and its runtime value
  is an empty table carrying only the type.
