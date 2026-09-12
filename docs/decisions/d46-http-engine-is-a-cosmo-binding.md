# D46 — the HTTP server engine is a cosmo.http binding over net/http; the surface is cosmic.http; htmx is a guide, not a coupling

- **date:** 2026-09
- **status:** active
- **context:** D9 named the gap — an HTTP client, sockets, poll, and
  SSE parsing, but no server or concurrency model — as direction, not
  deadline. The goal owner called the direction (2026-09-12): the core
  httpd lives in cosmopolitan, leveraging its `net/http/` code —
  redbean inverted — ergonomic under htmx without being coupled to it.
  Three shapes compete for the same gap. `docs/guides/recipes.md`'s
  "HTTP without a framework" section already teaches hand-rolled
  request-line and header-drain code over `cosmic.net` as the
  sanctioned answer until a real server exists; `net/http/` in
  cosmopolitan holds 86 files of parser, framing, and header code
  exercised by its own test suite (`test/net/http/parsehttpmessage_test.c`,
  `test/net/http/unchunk_test.c`, among others); and `tool/net/redbean.c`
  is a 7314-line fork-per-connection server with its own Lua API —
  `LuaGetHeader`/`LuaSetHeader`, gated by `OnlyCallDuringRequest` —
  built on the retiring Mbed TLS 2.26, kept alive only because "the
  fork was slimmed to the C core" (D9's own context line).
- **decision:** `cosmic.http` is the one HTTP server surface, built as
  a `cosmo.http` binding over cosmopolitan's `net/http/` parser and
  framing code, never a second implementation of either.
  - the binding lives at the C boundary like every other `cosmo.*`
    wrapper: cosmopolitan owns RFC 7230 framing, the repeatable-header
    table, and chunked decoding; `cosmic.http` wraps that binding with
    typed records and the error-handling doctrine every other module
    follows, never re-deriving a parser in Teal.
  - `cosmic.http` is ergonomic under htmx without being coupled to it:
    the request and response records expose headers, method, path, and
    body as plain data, so reading `HX-Request` or setting `HX-Trigger`
    is an ordinary header read or write — no htmx-specific type, field,
    or branch anywhere in `cosmic.http` itself.
  - htmx support, when it exists, is `cosmic.htmx` — pure functions
    over `cosmic.http`'s own request/response records — never a
    dependency `cosmic.http` carries or a behavior it special-cases.
- **rejected:**
  - **a pure-Teal server over `cosmic.net`** — the shape
    `docs/guides/recipes.md`'s "HTTP without a framework" section
    already teaches. Loses on correctness surface: re-deriving RFC 7230
    header framing, the repeatable-header table, chunked decoding, and
    a fuzzed parser in Teal duplicates 86 files of tested C
    (`net/http/`) with an unfuzzed rewrite, buying a second parser for
    no capability the first one lacks.
  - **vendoring redbean as-is.** `tool/net/redbean.c` is a 7314-line
    fork-per-connection server with its own Lua API
    (`LuaGetHeader`/`LuaSetHeader`, gated by `OnlyCallDuringRequest`),
    global request state (`cpm`, `inbuf`), and a TLS stack on the
    retiring Mbed TLS 2.26. Loses on ownership:
    the fork was deliberately slimmed to the C core, and vendoring
    redbean whole would ship a second Lua API and a second concurrency
    model alongside `cosmic.*`'s own.
  - **a `cosmic.htmx` server** — the Go-framework shape, a server whose
    handler type itself knows `HX-Request`. Loses on the least-thing
    rule (`docs/goals.md`): every non-htmx user of `cosmic.http` would
    pay for htmx-awareness they never asked for, when htmx's entire
    contract is a dozen request/response headers a pure function over
    plain records can already read and set.
- **consequences:**
  - a `cosmo.http` contract is frozen at the C boundary the same way
    every other `cosmo.*` binding is (cosmopolitan's AGENTS.md): a
    contract change lands there with a `definitions.lua` update in the
    same commit, and the cosmic-side type regen and wrapper fix follow
    as their own PR, never folded into an unrelated change.
  - `cosmic.http` v1 is single-connection-at-a-time, keep-alive within
    a connection — the concurrency model is a separate, later decision,
    and `serve`'s signature must be shaped so that decision does not
    force a handler-signature break when it lands.
  - `cosmic.http` never reads or writes an `HX-*` header itself;
    `cosmic.htmx`, if and when it exists, stays pure functions over
    `cosmic.http`'s `Request`/`Response` records, never a dependency
    `cosmic.http` carries.
  - D9 stands as direction, not deadline, and gets an amendment: the
    server story has started, the concurrency half remains open.
  - what would make us revisit: an engine need `net/http/` cannot
    serve (HTTP/2 is the concrete case on the horizon), or a second
    consumer of the `cosmo.http` binding whose message shape the
    binding cannot represent without breaking the first.
