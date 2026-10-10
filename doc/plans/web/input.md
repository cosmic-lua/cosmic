# cosmic.web: request input, state and security

Part of the cosmic.web design: see ../web.md for the overview, decisions and phasing.

This file covers how a request's data gets in (query, urlencoded forms,
multipart, JSON) and is bound to [`cosmic.shape`] specs, and the state and
protections layered on it: cookies, sessions, CSRF, CORS, security headers
and secrets. It builds on core.md: `Handler = function(Web.Request):
Web.Response`, `Middleware = function(Handler): Handler`, and the typed
per-request keys of core.md section 2.3. Routing, typed routes and error
pages are core.md; templates and the htmx integration are templates.md;
assets, SSE and the dev loop are assets.md.

What this file uses of core.md, stated once:

- `Web.Request` exposes `method`, `path`, `segments`, `query_string` (the
  raw escaped text), `headers` (lowercased names), `params`, `scheme`, the
  server's request as `raw` (so the body is `req.raw.body`, a
  [`Stream.Reader`], and its length `req.raw.length`; today's fields are at
  cosmic/http/server.tl:30-66), and `req:get(KEY)` / `req:set(KEY, v)` for
  per-request state. Every piece of state in this file is an exported
  `Web.Key<T>`, never a `req.state.x` field: `Input.QUERY`, `Input.FORM`,
  `Input.JSON` and `Input.CLEANUP` (section 2), `Session.KEY` (section 7),
  `Headers.NONCE` (section 10). `req.state` is core's untyped escape
  hatch and nothing here uses it.
- `Web.Response` is [`Server.Reply`] with `headers: {string: string |
  {string}}` (core.md 13.1; server.tl:91 is `{string:string}` today and is
  checked at server.tl:343, so the multi-valued change must reach
  [`wire.check`]/[`wire.send`]). Headers are read, set and appended with core's
  `Web.header(res, name)`, `Web.set_header` and `Web.add_header` (core.md
  section 3); `add_header` is how a `Set-Cookie` line or a `Vary` token is
  appended, and it merges `Vary` tokens. A header "set if absent" is
  `Web.header(res, name) == nil` then `Web.set_header`.
- `Request.scheme: "http"|"https"`, derived by the core from
  `X-Forwarded-Proto` only when the app declares a trusted proxy (open
  question 1). The server itself is plain HTTP; TLS is always a proxy's.
- `Web.problem` and a route's `on_invalid` (core.md section 6.4). This file
  produces `Input.Invalid` and core turns it into the response; nothing here
  renders error pages itself.

Layout of what this file adds (new files next to `cosmic/web/init.tl`):

- `cosmic.web.input` (`cosmic/web/input.tl`): query / form / JSON reading
  and shape binding.
- `cosmic.web.cookies` (`cosmic/web/cookies.tl`): Cookie parsing and
  Set-Cookie building.
- `cosmic.web.session` (`cosmic/web/session/init.tl`): the interface and
  the middleware, with the two stores beside it as
  `cosmic.web.session.cookie` and `cosmic.web.session.sqlite`
  (`cosmic/web/session/cookie.tl`, `sqlite.tl`); the sections below write
  `SessionCookie` and `SessionSqlite` for those two modules.
- `cosmic.web.csrf`, `cosmic.web.cors`, `cosmic.web.headers`
  (`cosmic/web/headers.tl`: security headers and CSP), and
  `cosmic/web/secret.tl` (key loading, used by the session stores).
- `cosmic/http/multipart.tl` (`cosmic.http.multipart`): a standalone
  RFC 7578 parser, usable without cosmic.web (it sits beside
  [`cosmic.http.server`]).

Changes to existing modules are listed in one place at the end ("Changes to
existing files").

## 1. Query and urlencoded decoding

### What exists, what is missing

`Request.query` is the raw text after the first `?`, still escaped
(server.tl:44-45, wire.tl:363-364). [`Url.unescape`] deliberately leaves `+`
alone (url.tl:104-114: "a form's rule, not a URL's"), and doc/roadmap.md:243-249
already lists "a query string decoded into names and values (`+` as a space, a
name given more than once kept as a list)" as wanted once a caller needs it.
cosmic.web is that caller, so it lands in [`cosmic.url`], not in cosmic.web:
`application/x-www-form-urlencoded` is the same grammar as a query string
(WHATWG URL "urlencoded parsing"), and a client-side `Http` caller sending a
form wants the encoder too.

### Proposed additions to cosmic/url.tl

```teal
local record Url
  --- One name and value of a query or form, unescaped.
  record Pair
    name: string
    value: string
  end

  --- A decoded query or urlencoded form: the pairs in the order sent, and
  --- each name's values in that order.
  record Query
    pairs: {Pair}
    --- name -> values in order sent; every name in `pairs` is a key.
    by_name: {string:{string}}
  end

  record QueryOptions
    --- The most pairs read; more is a refusal (1000).
    max_pairs: integer
    --- The most bytes of text read; more is a refusal (nil: no bound, the
    --- caller bounds the text, as a server bounds head and body).
    max_bytes: integer
    --- Read a "%" not followed by two hex digits as itself rather than
    --- refusing (false).
    lenient: boolean
    --- Refuse a name or value that is not valid UTF-8 (true).
    utf8: boolean
  end
end

--- `text` as a query string or urlencoded form body: split on "&", each
--- piece on its first "=", "+" read as a space and then "%XX" unescaped.
function Url.decode_query(text: string, opts?: Url.QueryOptions): Url.Query | nil, string

--- The first value of `name`, or nil. (Last-wins is the binder's rule for a
--- scalar field; see section 3. The raw accessors name which they mean.)
function Url.query_first(q: Url.Query, name: string): string | nil
function Url.query_last(q: Url.Query, name: string): string | nil
--- Every value of `name` in order; {} when none.
function Url.query_all(q: Url.Query, name: string): {string}

--- The inverse: pairs written as a query / form body, a space as "+",
--- everything but the unreserved bytes percent-escaped, so the result
--- decodes back to the same pairs. Raises on a pair whose name or value is
--- not a string.
function Url.encode_query(pairs: {Url.Pair}): string

--- `Url.unescape` with "+" read as a space first: the form rule for one
--- piece. (Order matters: "%2B" must stay "+".)
function Url.form_unescape(text: string): string | nil, string
```

Why a `Query` with both `pairs` and `by_name`: `pairs` keeps the order a
form was sent in (needed for multipart-like ordering questions, for
re-rendering, and for the `list(...)` binder, whose element order is the
form's); `by_name` makes `get` O(1) and keeps a repeated name as a list
without a second walk. Both are built in one pass.

### Rules, fixed

- Splitting: on `&` only. `;` is not a separator (HTML 4.01 suggested it;
  WHATWG, Go and Starlette do not accept it, and accepting it is a
  cache-poisoning vector: proxies that split on `&` and servers that split on
  `;` see different parameters).
- An empty piece (`a=1&&b=2`, a leading or trailing `&`) is skipped, and
  does not count toward `max_pairs`.
- A piece with no `=` is a name with value `""` (`?flag` is `flag=`). A piece
  starting with `=` has name `""`; it is kept (WHATWG keeps it) and a binder
  simply never asks for the name `""`.
- `+` is a space, `%2B` is `+`. The `+`-to-space step runs on the raw piece
  before percent decoding.
- Order: `pairs` is the order sent; `by_name[n]` is the order sent for `n`.
  Nothing is sorted. Which value a scalar binding takes from a repeated name
  is the binder's rule, not the decoder's: both accessors exist.
- Invalid percent escape (`%`, `%4`, `%zz`): by default the whole decode is
  refused with `nil, "url: '%' at byte N is not followed by two hex digits"`,
  the same wording and byte position [`Url.segments`] gives (url.tl:97), N
  counted in the whole text (the existing `unescape(text, offset)` helper at
  url.tl:93 already takes the offset, so the new function reuses it per
  piece). The caller answers 400. With `lenient = true` the `%` is kept as a
  literal `%` and decoding goes on (browser behavior for `?q=100%`); web code
  never sets it, but a scraper or proxy might.
  Rationale for strict by default: values flow into SQL parameters,
  templates and JSON; a request that silently decodes two ways in two parsers
  is the classic smuggling input, and a 400 is cheap.
- Invalid UTF-8 after decoding (`%FF`): refused unless `utf8 = false`.
  Reason: [`Json.encode`] and the template escapers expect text, and a lone
  `0xFF` in a name is never a legitimate browser submission. Checked with
  `utf8.len(s)` (strict: rejects surrogates and > U+10FFFF). The error names
  the pair index, not the bytes.
- NUL: a decoded `%00` in a name or value is allowed through the decoder
  (it is a byte, as [`Url.unescape`] allows it, url.tl:106-107) but the form
  binder refuses it in a scalar string (SQLite text, C strings and log lines
  mishandle it), unless the spec asks for `any`. Open question 5.
- Limits: `max_pairs` default 1000 (a legitimate form with a few hundred
  checkboxes fits; a hash-flood or memory attempt does not). `max_bytes` is
  deliberately nil by default: the caller already bounded the text (the
  request line by `limits.head_bytes` 64 KiB, server.tl:114-118; the body by
  `limits.body_bytes` 1 MiB, server.tl:119-120). The decoder is O(n); it
  never builds a table keyed by more than `max_pairs` names. Lua 5.4's string
  hashing is seeded per state, so collision flooding of `by_name` is not a
  concern beyond the pair bound.
- No bracket syntax: `a[]=1&a[b]=2` is just names `a[]` and `a[b]`. Lists are
  repeated names; nesting is dotted (section 3).
- Nothing raises on text; a non-string `text` raises (degenerate argument,
  cosmic idiom).

### Usage in cosmic.web

```teal
local q, why = Input.query(req)            -- Url.Query | nil, Input.Invalid
local page = Url.query_last(q, "page")
```

`Input.query(req)` decodes `req.query_string` once and caches it under the
exported key `Input.QUERY` (`Web.Key<Url.Query>`), so a middleware (CSRF
origin logging, a router with a query spec) and the handler share one
decode. An undecodable query (an invalid escape) is the 400 of section 2.

## 2. Request bodies: urlencoded, JSON, multipart

All three read through one function that enforces a per-route cap and a
Content-Type, because the server's limit (`limits.body_bytes`, 1 MiB,
server.tl:119-120) is one number for the whole server and uploads need more
than a login form does.

```teal
local record Input
  --- One refused field. These field names are the ones core.md section
  --- 6.4 puts in the problem+json `errors` list, so the two files use
  --- the same record.
  record FieldError
    --- Where the value came from: "path", "query", "form" or "body".
    --- (Not `in`, OpenAPI's word: it is a Lua keyword.)
    source: string
    --- The field: "email", "address.city", "tags", or "" for the whole body.
    field: string
    --- For a JSON body only: the JSON Pointer of the failing value
    --- ("/address/city"); nil for the other sources.
    pointer: string
    --- Plain text for a person ("must be a whole number").
    message: string
    --- A stable machine code: "required", "integer", "number", "boolean",
    --- "one_of", "type", "json", "too_many", "too_large", "utf8".
    code: string
  end

  record Invalid
    --- 400 for undecodable input, 422 for a value that fails its spec,
    --- 413 over the cap, 415 for a wrong Content-Type (see "Status"
    --- below).
    status: integer
    --- What went wrong overall; one line, no user data echoed unescaped.
    message: string
    errors: {FieldError}
    --- The submitted values, for re-rendering a form; names listed in
    --- `Options.secret` are left out. Nil for JSON.
    submitted: Url.Query
  end

  record Options
    --- Largest body read, in bytes. Default 64 KiB for urlencoded and JSON,
    --- 8 MiB of text parts and 64 MiB per file for multipart (the latter two
    --- in MultipartOptions). Above the server's limit it has no effect: the
    --- server's 413 comes first.
    max_bytes: integer
    --- Field names left out of `Invalid.submitted` (passwords, tokens).
    secret: {string}
  end
end
```

`Input.Invalid` is data, not a response: core turns it into a problem
response (HTML or JSON by Accept, core.md section 6.4) unless the route has
an `on_invalid`, and a handler that wants to re-render takes it instead
(section 3).

### The server's limit versus a route's

`wire.body(input, head, s.limits, go_on)` (server.tl:389) takes one
`body_bytes` for all requests. cosmic.web needs two things:

1. `Web.serve` sets `limits.body_bytes` to the largest `max_bytes` of any
   route in the table (computed when the table is built, so the config is in
   one place), default 1 MiB. This is the fallback when the server has no
   per-route body limit; with `ServeSpec.body_limit` (core.md 13.4) the
   server applies each route's number itself and nothing is raised
   server-wide. A server can therefore accept a 64 MiB upload on
   `/upload` but a route that reads a form is still capped at its own 64 KiB.
2. `Input` enforces the route's number itself: it checks `req.raw.length`
   against `max_bytes` first (a Content-Length over it answers 413 without
   reading a byte; `Expect: 100-continue` clients are then told 417/413 by
   the server's existing close-after-error path, server.tl:429) and wraps the
   body in `Stream.limit(req.raw.body, max_bytes + 1)` (stream.tl:690) for the
   chunked case with no length; reading the extra byte is the "over" signal.

No change to server.tl is needed for this; the TODO already in server.tl
(485-489) about a body deadline matters more here: a client sending a
50 MiB upload one byte per `timeout_ns` holds a connection. Uploads should wait
for that TODO or document the exposure (open question 7).

### Content-Type

`Input.media_type(req): string, {string:string}` parses the header into a
lowercased `type/subtype` and a parameter map (quoted-string handling for
`boundary="..."`). Rules:

- Urlencoded: `application/x-www-form-urlencoded`, parameter `charset` absent
  or `utf-8` (any case). Anything else: 415. A missing Content-Type on a
  request with a body: 415 (browsers always send one; a lenient default would
  let `text/plain` cross-site form posts through; see the CSRF section).
- JSON: `application/json` or any `application/*+json`; `charset` absent or
  `utf-8`. Otherwise 415. Requiring the JSON content type matters for
  security: a cross-site HTML form cannot send `application/json`, and
  `fetch` with that type triggers a CORS preflight, so JSON endpoints that
  insist on it are not CSRF-able by form posts even with a cookie session.
  `text/plain` bodies containing JSON, a known CSRF trick, are refused.
- Multipart (section 4; step 7 of ../web.md's order): `multipart/form-data` with a `boundary`.

### Functions

```teal
--- The query string, decoded (cached).
function Input.query(req: Web.Request, opts?: Url.QueryOptions): Url.Query | nil, Input.Invalid

--- The urlencoded body, decoded (cached; re-readable, see below).
function Input.form(req: Web.Request, opts?: Input.Options): Url.Query | nil, Input.Invalid

--- The JSON body, decoded with Json.decode (null_value = Json.null, so
--- Shape treats null as missing; max_depth 32).
function Input.json(req: Web.Request, opts?: Input.Options): any | nil, Input.Invalid

--- Query / form / JSON bound to a spec (section 3).
function Input.query_into<T>(req, spec: Shape.Spec, opts?): T | nil, Input.Invalid
function Input.form_into<T>(req, spec: Shape.Spec, opts?): T | nil, Input.Invalid
function Input.json_into<T>(req, spec: Shape.Spec, opts?): T | nil, Input.Invalid

--- The multipart body (section 4; step 7 of ../web.md's order).
function Input.multipart(req, opts?: Input.MultipartOptions): Input.Multipart | nil, Input.Invalid
```

`T` is inferred from the caller's annotation, exactly as [`Shape.into`]
(shape.tl:496) requires; the same [`Shape.record_of`] pattern gives the type
for free. `Typed<T>` gets matching sugar so a route can write
`SIGNUP:form(req)`: `Typed` stays in shape.tl, and web wraps it
(`Input.typed_form(typed, req)`), so shape.tl does not learn about requests.
Routes with specs (core.md section 6) call the same functions; a handler
calls them directly only on a route without specs.

### Reading and caching the body

`Input.form` and `Input.json` read the body once, store the parsed value
under the exported keys `Input.FORM` (`Web.Key<Url.Query>`) and `Input.JSON`
(`Web.Key<any>`), and replace `req.raw.body` with
`Stream.from_string(bytes)` (stream.tl:404; core's `req:bytes()` does the
same, core.md section 2.1), so a middleware that peeks at the form (CSRF) and
a handler that reads it again both work, and a handler that calls
`Stream.read_all(req.raw.body)` after `Input.json` still sees the bytes. A
body is never parsed twice: the second call returns the cache or, for a
different kind (`form` after `json`), a 415.

Failure mapping (all `Input.Invalid`):

- Read failure past the server's limit: the server already marked the body
  `over` and answers 413 in place of the handler's reply (server.tl:398-403);
  `Input` also returns `status = 413` so a middleware sees the same.
- Truncated or malformed chunked body: 400 (server.tl:402).
- Body read timing out: pass the failure through; the server answers 408
  (server.tl:404).
- JSON syntax error: 400, message from [`Json.decode`] (it names line and
  column), `code = "json"`.
- Body empty where a form or JSON is required: `required` on `""`.

### Status: 400, 413, 415 and 422

The statuses are the same in every part of cosmic.web (core.md section 6.4):

- Undecodable input (a bad percent-escape, malformed JSON, bad multipart
  framing): 400.
- A wrong Content-Type: 415. An oversized body: 413.
- A value that decodes but fails its shape spec: 422 (../web.md, decision
  7). htmx 2's default `responseHandling` swaps only 2xx, so a 422
  re-render would be discarded; the config that `Htmx.head` writes
  (templates.md section 6.6) swaps 422, so a form's re-render with its
  errors reaches the page.

`Input.Invalid.status` is one of these. A route's `on_invalid` (section 3,
"Route-level wiring") re-renders with it; without one, the router answers
the problem response with it.

JSON APIs get `application/problem+json` with
`{type:"about:blank", title:"Unprocessable Content", status:422, detail, errors:[...]}`,
each entry a `FieldError` (`source`, `field`, `pointer`, `message`, `code`), so
API clients can render per-field messages (core.md section 6.4 builds it).

## 3. Binding to a Shape spec

### What Shape does and does not do today

[`Shape.into`] (shape.tl:496) checks one decoded value against a spec and
reports only the *first* failure, as a JSON Pointer string (shape.tl:62-69,
446-485). It converts nothing except float-to-integer (shape.tl:59-61,
458-462); [`Shape.number`] refuses `"1"`; a missing boolean is an error. Both
are right for JSON and wrong for forms and query strings, where every value
is text, a checkbox is *absent* when unchecked, an empty text input is
submitted as `""`, and a page wants all the field errors at once.

JSON binding therefore goes straight through [`Shape.into`] unchanged, with the
pointer converted into a `FieldError.field` (`/address/city` -> `address.city`,
numeric steps kept: `items.0.name`) by parsing the failure message the same
way [`Json.from_pointer`] (json.tl:778) reads a pointer. Only the first error
is available there; for JSON APIs that is acceptable (the client is a
program), and it is Shape's documented rule. If a collect-all mode is wanted
for JSON too, the better change is in shape.tl (open question 2), not in web.

For path, query and form input the decoding differs enough that web owns a
*spec-directed binder*, `cosmic.web.input`'s `bind_strings` (core.md section
6.3 calls it for typed routes). It walks the
spec (it reads [`Spec.kind`], `fields`, `names`, `of`, `values`, `optional`,
the documented-as-"how `into` reads it" fields, shape.tl:89-106), pulls
strings from the `Url.Query`, coerces each, collects every error, and builds
a plain Lua tree. Then, if no error was found, it hands that tree to
`Shape.into(tree, spec)` as a final authority: the typed record the handler
gets is exactly what Shape produces, and any coercion bug surfaces as a
Shape failure rather than a wrong type.

This does not need cosmic.shape to change in v1. It does lean on
`Spec`'s fields being readable; they are documented fields of a public
record, and the tests pin the dependency (a test builds a spec of every Kind
and binds it, mirroring what shape.tl:140's comment says about its own
KINDS table).

### Coercion rules, fixed

Let `strings` be the values for a field's name.

- `Shape.string`: the last value (see "Repeated names" below). `""` is a
  valid string; a field that must be non-empty is validated by the handler
  (`Input.require_nonempty`, below) because Shape has no length facet.
  A string containing NUL is refused (`code = "type"`).
- `Shape.integer`: the last value, trimmed of ASCII space and tab at both
  ends, must match `^[+-]?[0-9]+$` and fit `math.tointeger`. No hex, no `1e3`,
  no `1.0`, no thousands separators, no leading `+` ambiguity beyond the
  pattern. Overflow (`99999999999999999999`) is refused by comparing the
  digit string, not by `tonumber` (which would round to a float). Error
  `code = "integer"`, message "must be a whole number".
- `Shape.number`: trimmed, pattern `^[+-]?[0-9]*%.?[0-9]+([eE][+-]?[0-9]+)?$`
  or digits with a trailing dot (`"1."` refused), via `tonumber` after the
  pattern check (Lua's `tonumber` accepts `0x10`, `inf`-like text on some
  inputs, and leading/trailing whitespace; the pattern is the gate). A result
  that is not finite is refused. Integers decode as integers.
- `Shape.boolean`: the HTML rule. Truthy: `true on 1 yes` (case-insensitive,
  exact). Falsy: `false off 0 no` and `""`. Anything else: `code = "boolean"`.
  The last value wins, which makes the standard `<input type=hidden value=0>`
  followed by `<input type=checkbox value=1>` pattern work. **A boolean
  field that is absent altogether is `false`** (an unchecked checkbox sends
  nothing), unless the spec is `Shape.optional(Shape.boolean)`, in which
  case absent is nil, so a tri-state is expressible. This is the one place
  a required Shape field is not "required"; documented on the function.
  (Query strings follow the same rule for uniformity.)
- `Shape.one_of(...)`: the last value is compared as text against the
  listed strings; for listed numbers/booleans, the value is parsed as the
  listed value's kind (integer then number then boolean rules) and then
  compared with `==`. Failure message lists the allowed values
  (`shape.tl:wanted` wording), `code = "one_of"`.
- `Shape.optional(x)`: absent, or present with value `""` for any kind
  except `string`, is nil. (Empty text input `<input type=number>` submits
  `""`; for an optional number that means "not given".) For
  `optional(Shape.string)`, `""` stays `""`; if "empty means nil" is wanted,
  `Input.empty_as_nil(spec)` wraps it (a binder-level marker, not a Shape
  change; a plain `Shape.optional` copy with a private flag the binder reads).
- Required and absent (or `""` for non-string kinds): `code = "required"`,
  message "is required".
- `Shape.list(of)`: all values of the name, in sent order, each coerced as
  `of`. A list of strings is `?tag=a&tag=b`. A single value gives a list of
  one; no value gives `{}` (`Json.array({})`, so it round-trips), never nil
  and never "required" (a list's emptiness is the handler's check), unless the
  list is a non-optional field of a *JSON* body, which is Shape's rule.
  Per-element errors name `tags.1`.
- `Shape.record(fields)` as the top-level spec: each field is read from the
  name `field`. A nested record reads its fields from `parent.child`
  (dotted names, which are what `name="address.city"` inputs send). Nesting
  depth is limited to 3.
- [`Shape.map`] and a `list` of records are refused when the route is
  registered, not at request time: `Input.check_spec(spec, "form")` walks the
  spec once and raises (naming the field path) for a kind a form cannot
  carry. A list of records is the common wish (`items.0.name`,
  `items.1.name`); it is left to v2 (roadmap), and in the meantime a handler
  that needs it reads `Input.form` and iterates itself. `any` is accepted
  and binds the last string.
- Unknown names are ignored, never bound: the spec is the allow-list, so
  there is no mass-assignment (`is_admin=1` is dropped). `strict_record`
  *does* refuse unknown names for query binding (shape.tl:222: a misspelled
  key is an error) *except* the reserved names the web layer itself consumes:
  `csrf_token`, and `_method` if ever added.

Repeated names: the last value wins for a scalar. This departs from Go
(first wins) and agrees with Django's `QueryDict.get`, Rails, and Starlette's
multi-dict `__getitem__`; it makes the hidden+checkbox idiom and htmx's
`hx-include` plus a form field both work. A route that cares can declare
`list` and check for length; the binder offers `Input.Options.repeated =
"error"` to refuse repeats of a scalar (`code = "repeated"`), recommended for
API-style query specs.

### Error collection and re-rendering

```teal
function Input.bind_strings<T>(q: Url.Query, spec: Shape.Spec, opts?: Input.Options): T | nil, Input.Invalid
```

`opts.source` (`"path"|"query"|"form"`, default `"form"`) is what the binder
writes into each `FieldError.source`.

On any failure the result is `nil, Invalid` with every field's error in
`errors`, ordered by the spec's field order (byte order, as Shape already
checks fields, shape.tl:388), and `submitted` holding the raw pairs minus
`secret` names. Template side: a form partial takes
`{values: {string:string}, errors: {string:string}}`; `Input.errors_by_field(inv): {string:string}`
joins several messages for one field with `"; "` (first one alone is the common
display) and `Input.value(inv, name): string` is the last submitted value.
Both are plain data a template can range over, so no new template feature is
needed.

Handlers can add their own errors (the email is already taken) to the same
structure so the re-render path is one path:

```teal
local function signup(req: Web.Request): Web.Response
  local form, invalid = SIGNUP:form(req, { secret = { "password" } })
  if form == nil then
    return render_signup(req, nil, invalid)          -- status 422, htmx swaps it
  end
  local taken = users.by_email(form.email)
  if taken then
    invalid = Input.fail(req, "email", "is already registered")
    return render_signup(req, nil, invalid)
  end
  ...
  return Web.redirect("/welcome")                    -- 303
end
```

`Input.fail(req, field, message): Input.Invalid` builds an `Invalid` over the
submitted form already cached under `Input.FORM`, so a handler can re-render
without re-binding.

For required but empty strings: `Input.require_nonempty(inv_or_nil, field,
value): Input.Invalid | nil` and a small set of one-liners (`min_length`,
`matches`) are helpers in the same module; they are deliberately outside
Shape (no facets in v1, matching shape.tl's "nothing is converted").
Whether to grow facets in Shape instead is open question 2.

### Route-level wiring

Core calls these when a route names a spec (core.md section 6). For a route
with `Web.input(path, query, body)` it binds the path parameters with
`bind_strings` (a `Url.Query` built from the params, so the coercions agree
across sources), then `Input.query_into`, then `Input.form_into` or
`Input.json_into`, *before* the handler, and passes the typed records to the
handler as arguments. The decoded views are in the exported keys
`Input.QUERY`, `Input.FORM` and `Input.JSON`, so a middleware and the
handler read the same decode; the typed records are not stored on the
request. On failure core answers from the `Input.Invalid`, unless the route
has `on_invalid: function(Web.Request, Input.Invalid): Web.Response` (core
owns the hook, core.md section 6.4). That hook is what makes the htmx
re-render case one line: it renders the form with `Invalid` and answers 422.

## 4. Multipart/form-data

**In v1, last (../web.md, decision 8).** The design below is
complete so that the call can be made; nothing else in this file depends on
it. The case for including it: file upload is the most common thing a plain
HTML form (`<form enctype="multipart/form-data">`) and
`hx-encoding="multipart/form-data"` do that urlencoded cannot; omitting it
makes the first "upload a profile picture" example impossible, and the body
is already a streaming [`Stream.Reader`], which is exactly the input a
streaming parser wants. The cost is real but bounded: ~400 lines of pure Teal
plus a fuzz test, and temp-file handling. Recommendation: include it, last,
after the body-deadline change (open question 7) has landed.

### The seam: `cosmic.http.multipart`

It knows nothing of cosmic.web, in the same relationship as
[`Server.range`] to the handler.

```teal
local record Multipart
  record Part
    --- Lowercased header names of this part (content-disposition,
    --- content-type, content-transfer-encoding is refused).
    headers: {string:string}
    --- Content-Disposition name, unescaped.
    name: string
    --- Content-Disposition filename (basename only, see below); nil for a
    --- text field.
    filename: string
    --- Content-Type of the part ("text/plain; charset=utf-8" default).
    content_type: string
    --- The part's bytes, read as they arrive; invalid after next_part().
    body: Stream.Reader
  end

  record Options
    --- The boundary from the request's Content-Type.
    boundary: string
    --- Most parts (100), longest header block (8 KiB), most header lines
    --- per part (16).
    max_parts: integer
    max_header_bytes: integer
  end

  --- A parser over `source`; `next_part` yields parts one at a time and
  --- skips the unread rest of the previous one.
  record Reader
    next_part: function(Reader): Part | nil, string
    close: function(Reader): boolean, string
  end
end

function Multipart.reader(source: Stream.Reader, opts: Multipart.Options): Multipart.Reader | nil, string
```

Parsing rules (RFC 7578 and 2046 section 5.1.1, hardened):

- Boundary: 1-70 chars of the RFC set; refused otherwise (a hostile 10 MB
  boundary would make the delimiter scan quadratic). Delimiter is
  `\r\n--boundary`. The preamble before the first delimiter is discarded
  (bounded to the header cap); text after the closing `--boundary--` is
  ignored.
- Part headers: `Content-Disposition: form-data; name="..."; filename="..."`
  required, `name` required. Quoted-string with the WHATWG escapes browsers
  use (`%22` for `"`, `%0D%0A` for newlines; backslash is *not* an escape
  there). `filename*=` (RFC 5987) is read as a fallback. Duplicate
  Content-Disposition: refused. A part header over `max_header_bytes`, a
  folded header, or a bare LF: refused (400).
- `Content-Transfer-Encoding` other than absent/`binary`/`7bit`/`8bit`: refused
  (RFC 7578 4.7 deprecated base64/quoted-printable).
- Streaming with bounded memory: the body Reader of a part is [`Stream.limit`]
  style over the source with a rolling window of `#delimiter - 1` bytes, so a
  delimiter split across reads is found; memory is O(window), not O(part).
- A part that is not read before `next_part` is skipped (dropped), so a
  handler ignoring a file does not buffer it.
- Truncated body (no closing delimiter): `nil, "multipart: the body ended
  before the closing boundary"`, mapped to 400.
- Fuzz test (`multipart_fuzz_test.tl`, [`Fuzz.label`]s `header_parsed`,
  `part_read`, `file_part`): a property that any generated well-formed
  multipart round-trips; another that arbitrary bytes never raise and never
  yield a part whose body exceeds the input.

### Filenames are hostile

`Part.filename` is the client's string: path separators (`../../etc/passwd`,
`C:\x`), NUL, control bytes, leading dots, absurd length. The parser returns it
reduced to the part after the last `/` or `\`, NUL and control bytes refused
(not stripped: silently altering is how `a.php\0.jpg` bugs start), at most
255 bytes. **Cosmic.web never uses it as a path.** Uploaded files are stored
under a random name (`Rand.entropy(16)` hex) in a directory the app names,
and the client's filename is metadata only. The same rule for
`content_type`: it is what the client claimed; the app must not serve it back
as the stored file's type without validation.

### cosmic.web's layer

```teal
local record Input
  record Upload
    --- Client's basename, display only. Never a path.
    filename: string
    --- Client's claimed Content-Type.
    content_type: string
    size: integer
    --- Where the bytes are: a file the app owns, in `MultipartOptions.dir`
    --- under a random name; removed when the request ends unless moved.
    path: string
  end

  record MultipartOptions is Input.Options
    --- Where file parts are spooled; mkdtemp'd under the system temp
    --- dir if nil. Files are removed after the response is written.
    dir: string
    --- Per-file and per-text-field caps, and total, in bytes.
    max_file_bytes: integer      -- 8 MiB
    max_field_bytes: integer     -- 1 MiB for a text field
    max_total_bytes: integer     -- = Options.max_bytes
    max_files: integer           -- 10
  end

  record Multipart
    fields: Url.Query            -- text fields, as a form's
    files: {string:{Upload}}     -- by field name, in sent order
  end
end
```

`Input.multipart(req, opts)` streams, writes file parts to disk through
[`Stream.create`] (stream.tl:1212) with mode 0600, counts bytes against the
caps as it goes (an over-cap file part aborts and removes the file), and keeps
text parts in memory as a `Url.Query` so the *same* binder from section 3
works: `Input.multipart_into<T>(req, spec)` binds `fields`; a [`Shape.record`]
field that is meant to be an upload is declared in the spec as
`Input.upload` (a [`Shape.any`]-kind marker) and bound from `files`. Upload
specs are refused when the route's spec is registered if the route is not
declared `multipart`.

Cleanup: files are removed by the router in a `finally`-style step after the
response is written (or the Reader body closes), via a list under the
exported key `Input.CLEANUP` (`Web.Key<{string}>`); the handler moves a file it keeps
([`Fs.rename`]) and the cleanup tolerates its absence. A crash leaves
orphans in `dir`; `Input.sweep_uploads(dir, older_than_ns)` is a sweeper for
a lifespan hook.

Content sniffing, virus scanning, image decoding: out of scope.

### CSRF interaction

The CSRF middleware needs the token before the handler reads a multipart
body. Rule: for multipart the token must be in the `X-CSRF-Token` header (what
htmx and `fetch` send) or be the **first part** of the form
(`<input type=hidden name=csrf_token>` first in DOM order; browsers send in
document order). The middleware peeks at most 16 KiB with
[`Stream.read_up_to`] (stream.tl:744), parses the first part header and, if it
is `csrf_token`, reads its small value; it then restores the consumed bytes
with `Stream.prepend(prefix, req.raw.body)` (stream.tl:730). If the first part is
not the token and the header is absent, 403. This keeps uploads from being
buffered whole to find a token.

## 5. JSON bodies

`Input.json(req)` is `Json.decode(text, { null_value = Json.null,
max_depth = 32 })` (json.tl:405, 165-172, 365-370) over the body, after the
Content-Type and size checks. [`Json.null`] is used so Shape's rule "missing and
null are the same thing" holds (shape.tl:54-58).

`Input.json_into<T>(req, spec)` = `Input.json` then [`Shape.into`]. The
failure, `pointer "/address/city": expected string, got integer`, is
parsed into a `FieldError` (`field = "address.city"`, `message = "expected
string, got integer"`, `code = "type"`); a non-parseable message goes in
`field = ""`. Parsing a message we produce ourselves is fragile, so shape.tl
should expose the pieces: a tiny change, [`Shape.into`] unchanged but a new
`Shape.into_at(value, spec): T | nil, string, Json.Steps` (or a record with
`path` and `reason`) returning the failing path as steps beside the text.
Recommended (open question 2). Until it lands, a single regexp on `^pointer
"(.-)": (.*)$` and [`Json.from_pointer`] is the fallback, with a `TODO: once
cosmic.shape reports a failing path as steps`.

Other JSON rules:

- Duplicate keys in an object: whatever [`Json.decode`] does (documented
  there); not re-decided here.
- A top-level non-object when the spec is a record: Shape's error at pointer
  `""`.
- Responses: `Web.json(value, opts)` is the core's (it calls [`Json.encode`]
  and sets `Content-Type: application/json`); no change here.
- An API that accepts either JSON or a form on the same route: not supported
  by one spec. The router can register the route twice (same path, two
  `content_type` guards), or the handler calls `Input.form_or_json`, which
  dispatches on the media type to the matching `*_into` with the same spec.
  Only `json` and `form` kinds compose (the spec must be representable in
  both; `check_spec` verifies).

## 6. Cookies

### Reading: how the server joins headers

`Request.headers` joins a repeated name with `", "` (server.tl:48-50,
wire.tl:415-434). For `Cookie` that is wrong in a precise way: RFC 6265 5.4
cookie pairs are separated by `"; "`; browsers send a single `Cookie` header on
HTTP/1.1, but HTTP/2 splits it into crumbs that an HTTP/1.1 translating proxy
(and some HTTP clients on 1.1) may send as *several* `Cookie` lines (RFC 9113
8.2.3 says to rejoin crumbs with `"; "`). Joined with `", "`, `a=1` and `b=2`
become `a=1, b=2`: a naive `;` split reads `a`'s value as `1, b=2` and loses
`b`.

Two layers, both cheap:

1. A one-line fix in wire.tl:434: join the values of `cookie` with `"; "`,
   all other names with `", "`. This is the right place (RFC 9110 5.3 allows
   combining by comma "except Set-Cookie"; RFC 9113 says cookie by `"; "`).
2. The parser also tolerates `", "` as a separator: cookie-octet (RFC 6265
   4.1.1) excludes `,`, space and `;`, so a `,` can never appear inside a valid
   cookie value we or any conforming client sent. A value with a comma is a
   sloppy sender; the parser splits there (before the rest of the pair) and the
   result is the same as if layer 1 had been in place. This keeps
   cosmic.web correct on a stale server and on a handler tested with a
   hand-built `headers` table.

### `cosmic.web.cookies`

```teal
local record Cookies
  enum SameSite "Lax" "Strict" "None" end

  record Attributes
    --- Default "/".
    path: string
    domain: string
    --- Seconds. nil: a session cookie (ends with the browser session, which
    --- modern browsers restore, so not a reliable expiry).
    max_age: integer
    --- Absolute expiry in ns since the epoch (Clock.now_ns scale); written
    --- as Expires only when `max_age` is nil and for compatibility with
    --- very old clients (default: never).
    expires_ns: integer
    --- Default true: not readable from script.
    http_only: boolean
    --- true/false; nil: take the middleware's default (section 7).
    secure: boolean
    --- Default "Lax".
    same_site: SameSite
    partitioned: boolean
  end
end

--- Cookie header -> name/value; first occurrence of a name wins.
function Cookies.parse(header: string | nil): {string:string}

--- A Set-Cookie line, or nil and why.
function Cookies.format(name: string, value: string, attrs?: Cookies.Attributes): string | nil, string

--- A Set-Cookie line that deletes `name` (Max-Age=0 plus Expires in the past
--- so clients that ignore Max-Age agree); attrs must match the original's
--- Path and Domain or the browser keeps the cookie.
function Cookies.expire(name: string, attrs?: Cookies.Attributes): string | nil, string

--- Adds `format`'s line to `res` (append, never replace).
function Cookies.set(res: Web.Response, name: string, value: string, attrs?: Cookies.Attributes): boolean, string

--- A Set-Cookie line read back as its parts, for `cosmic.web.testing`'s
--- cookie jar (core.md section 10.1) and nothing else; lenient about
--- attributes it does not know. nil and why for a line with no `name=value`.
function Cookies.parse_set_cookie(line: string): Cookies.Parsed | nil, string
```

`parse` rules:

- Pairs split on `;` (and, per above, `,`); optional spaces/tabs trimmed;
  a piece without `=` is ignored (name-only cookies are not a thing in
  RFC 6265 and are used to confuse parsers); empty names ignored.
- Names are matched case-sensitively as sent.
- **First occurrence wins** (browsers send the most specific path first). A
  cookie-tossing sibling-subdomain attack can still plant a same-named cookie
  with a broader or the same path; the defense is cookie prefixes, below, not
  a smarter parse.
- A value may be wrapped in double quotes (RFC 6265 allows it); the quotes are
  stripped. Values are not percent-decoded (cookies have no such rule), so
  apps that store arbitrary text escape it with [`Url.escape`] first
  (the sessions use base64url, so need nothing).
- Limits: at most 100 cookies and 8 KiB of header read (the server's
  `head_bytes` is 64 KiB for everything); the rest are ignored.
- Never raises; malformed pieces are skipped.

`format` rules (it returns `nil, why` for data-driven input, per the cosmic
idiom, and raises only for a degenerate call):

- `name` must be an RFC 7230 token (letters, digits, `!#$%&'*+-.^_`|~`);
  value must be cookie-octets (no CTL, space, `"`, `,`, `;`, `\`). A value
  with others: `nil, "cookies: value holds ';'"`. The apps's escape hatch is
  `Cookies.escape_value` = [`Url.escape`] (the reverse is the app's).
- Attributes are written in a fixed order:
  `name=value; Path=/; Max-Age=N; Domain=d; Secure; HttpOnly; SameSite=Lax`.
  `Path`/`Domain` must contain no `;`, CTL or space. A domain with a
  leading dot is normalized by dropping the dot. `Domain` is omitted by
  default (host-only cookie, the safe default).
- `SameSite=None` without `Secure` is refused (browsers drop it anyway).
  `Partitioned` requires `Secure`.
- Prefixes: a name starting `__Host-` requires `Secure`, `Path=/`, no
  `Domain`; `__Secure-` requires `Secure`. Violations are refused here so a
  misconfiguration fails in tests, not silently in the browser (a browser
  drops a bad `__Host-` cookie without any message).
- Total length of the line over 4096 bytes: refused with the count
  (`"cookies: 4137 bytes; browsers keep at most 4096"`). Silent truncation by
  browsers is the failure this prevents.
- Defaults: `path="/"`, `http_only=true`, `same_site="Lax"`. `secure`
  defaults from the middleware that sets it (section 7), not here: in
  `Cookies.format` called directly `secure` is false unless given, because the
  function cannot know the scheme.
- Max-Age is written, Expires only on request: Max-Age is supported
  everywhere that matters (IE is gone), avoids clock skew, and RFC 6265bis
  makes Expires the fallback.
- Values containing the secure default of `Secure` over http (localhost
  dev): Chrome and Firefox accept `Secure` on `http://localhost`, Safari does
  not; the dev-mode default is `secure=false` (section 7).

`Cookies.set` appends with core's `Web.add_header`, never replaces
(`Cookies.set` twice yields two `Set-Cookie` lines; deleting a cookie and setting
another is one response).

## 7. Sessions

### The interface

One user-facing type, two stores behind it. The unit stored is a JSON object;
values must be what [`Json.encode`] accepts (strings, numbers, booleans,
lists, string-keyed maps); a `set` of anything else raises at the `set`
(`json.tl` rejects functions/userdata), not at save time, so the stack trace is
the handler's.

```teal
local record Session
  record Flash
    kind: string      -- "info" "success" "warning" "error" or the app's own
    text: string
  end

  --- What a session holds, for a store to keep.
  record Data
    values: {string:any}
    --- Seconds since the epoch (not ns: JSON-safe in a double).
    created: integer
    expires: integer
  end

  --- The reading and writing a session needs from a backend.
  record Store
    --- The data `token` (the cookie's value) names. nil, "" when it names
    --- none (absent, tampered, unknown, expired): the request is anonymous.
    --- nil, why when the store itself failed (database error): a 500/503.
    load: function(Store, token: string, now: integer): Data | nil, string
    --- Persists; returns the cookie value to send. `changes` is the set of
    --- keys the request wrote, for a store that merges (SQLite).
    save: function(Store, previous_token: string, data: Data, changes: Changes, now: integer): string | nil, string
    --- Revokes `token` where the store can (SQLite deletes the row; the
    --- cookie store cannot).
    destroy: function(Store, token: string): boolean, string
    --- Whether destroy really revokes (for documentation / audits).
    revocable: boolean
  end

  record Changes
    set: {string:any}
    removed: {string}
    cleared: boolean
  end

  record Options
    store: Store                       -- required
    --- "session" ("__Host-session" if secure).
    cookie_name: string
    --- Lifetime in seconds: 14 days.
    max_age: integer
    --- Extend the expiry on use (false). See "Rolling".
    rolling: boolean
    --- Cookie attributes; defaults "/", HttpOnly, "Lax"; secure: nil = auto.
    path: string
    domain: string
    same_site: Cookies.SameSite
    secure: boolean
    --- For tests.
    now: function(): integer
  end
end
```

The per-request handle:

```teal
--- The request's session, `req:get(Session.KEY)`; raises if
--- Session.middleware is not installed.
function Session.of(req: Web.Request): Session.Handle

record Handle
  get: function(Handle, key: string): any
  get_string: function(Handle, key: string): string | nil
  get_integer: function(Handle, key: string): integer | nil
  get_boolean: function(Handle, key: string): boolean | nil
  set: function(Handle, key: string, value: any)
  delete: function(Handle, key: string)
  --- get then delete.
  pop: function(Handle, key: string): any
  --- Removes every key but the id/created/expires.
  clear: function(Handle)
  --- A new id and a fresh cookie, keeping the data (call at login).
  regenerate: function(Handle)
  --- Revokes this session and clears the cookie (logout). After it the
  --- handle is an empty anonymous session that may be written again.
  invalidate: function(Handle)
  flash: function(Handle, kind: string, text: string)
  --- Returns and clears the pending flashes.
  take_flashes: function(Handle): {Flash}
  --- Whether the request carried a valid session, without creating one.
  is_new: function(Handle): boolean
  --- The opaque id (SQLite) or nil (cookie): for logs only, never a
  --- credential once logged: it is. See "Logging".
  id: function(Handle): string
end
```

`Handle` is a plain record of functions (cosmic style: `record` with function
fields, no metatables in the public type; methods are called with `:`).

### The middleware: lazy, write only when changed

```teal
function Session.middleware(opts: Session.Options): Web.Middleware
```

For each request:

1. Put a *lazy* handle under the exported key `Session.KEY`
   (`Web.Key<Session.Handle>`, `req:set(Session.KEY, handle)`). Nothing is read and the
   cookie is not even parsed until the first `Session.of(req):get(...)` (or
   other access). A handler that never touches the session costs nothing
   and sends no `Set-Cookie` and no `Vary`. For the cookie store the
   "read" is just an HMAC; for SQLite it is a query, and laziness is what
   keeps assets, health checks and API calls off the database.
2. First access: parse the `Cookie` header (`Cookies.parse`), find
   `cookie_name`, call `store:load(token, now)`. A `nil, ""` is an anonymous
   session; `nil, why` raises `error("session: " .. why)`, a 500 (core's
   exception layer logs it, core.md section 8.2). A tampered or expired cookie is not an
   error: it is anonymous, and the response expires the bad cookie *only if*
   the session is then written or the cookie was present and invalid (to stop
   resending it).
3. Call the next handler.
4. After the handler returns (the response head is what is sent; see the
   streaming note), if the handle was *modified* (any `set`, `delete`,
   `clear`, `flash`, `take_flashes` that took something, `regenerate`,
   `invalidate`), call `store:save(...)` and add `Set-Cookie`. If it was only
   read, send nothing (unless `rolling` and the touch threshold passed).
   If the handle was *accessed* at all, add `Vary: Cookie` to the response
   (`Web.add_header(res, "Vary", "Cookie")`, which merges with any other
   `Vary` tokens) so a
   shared cache never serves one user's page to another; and for a
   non-cacheable default, add `Cache-Control: private` *only if the response
   has no Cache-Control* (never override the app's).
5. If the handler raised, nothing is saved (changes are lost), the error
   passes through to core's exception layer.

Streaming and late writes: a `Reply` whose body is a Reader (SSE, a
chunked download) has its head written before the producer runs, so the
`Set-Cookie` decision in step 4 has already been made. A session write
after the middleware finalized is a bug the user must hear about:
`Handle` is `frozen` after step 4 and `set` raises
`session: written after the response head was built; set it before returning
the response`. A background task that must change the session does so in the
request handler before returning.

Lost updates: two concurrent requests (htmx loading three fragments in
parallel) each read and each may write; with the cookie store the last
`Set-Cookie` the *browser* applies wins, silently dropping the other's change.
Mitigations that exist in the design: write-only-when-changed (read-only
fragments, the common case, never write); and SQLite's merge-on-save
(below). The cookie store cannot merge; documented.

### Rolling expiry

`max_age` is the absolute lifetime from creation by default
(`rolling=false`): a login lasts 14 days from sign-in, no matter how often
it is used, which is the safer default (a stolen cookie has a bound) and
avoids writing on every request. `rolling=true` extends `expires` whenever
the remaining life falls below half of `max_age` (so at most about twice per
period, not per request), which re-sends the cookie / updates the row.

### Regeneration, fixation, logout

- `regenerate()` at login (and any privilege change): SQLite mints a new id,
  copies the data, deletes the old row in the same transaction; the cookie
  store re-signs under a fresh `created` and the old cookie remains valid
  until its own expiry (the limitation of any signed-cookie session: it
  cannot be revoked). For sessions that gate authority (admin, payment)
  the recommendation is the SQLite store, or a cookie session whose payload
  carries a per-user `session_version` compared against the database.
- A session id is never accepted from the client as a *new* id: an
  unknown id in the cookie is anonymous, and the next write mints a fresh id.
  That is what stops fixation (an attacker planting an id, then waiting for
  the victim to log in under it); `regenerate` at login closes the
  remaining case where the planted id is a real anonymous one.
- `invalidate()`: delete the row (SQLite), send an expiring `Set-Cookie`
  with the same Path/Domain, empty the handle.
- CSRF (section 8) keeps its secret in the session and is regenerated
  with it.

### Flash messages

`flash(kind, text)` appends to the reserved key `_flash` (a list of
`{kind, text}`, at most 10, text at most 500 bytes, extra dropped oldest first).
`take_flashes()` returns them and deletes the key, and counts as a modification
only if any existed. Typical pattern: POST handler flashes then
`Web.redirect("/")` (post/redirect/get, 303); the layout renders
`take_flashes()` once. For htmx fragments, which do not render the layout,
prefer `HX-Trigger` (templates.md section 6.2) or an out-of-band swap
(templates.md section 6.5); if a
fragment response never calls `take_flashes()`, the messages simply wait for
the next full page, which is the safe failure.

### The signed-cookie store

```teal
function SessionCookie.store(opts: SessionCookie.Options): Session.Store

record SessionCookie.Options
  --- Newest first: signs with keys[1], verifies with all. At least one,
  --- each Secret.check'ed (section 11).
  keys: {string}
  --- Largest token (cookie value) in bytes: 3800. A cookie line is
  --- name + value + attributes under 4096.
  max_bytes: integer
  --- Mixed into the MAC with the cookie's name: "cosmic.web.session".
  context: string
end
```

Token format, fixed:

    token = b64url(payload) .. "." .. b64url(mac)
    payload = Json.encode({ v = 1, c = created, e = expires, d = values })
    mac = Hash.hmac("sha256", key, context .. "\0" .. cookie_name .. "\0" .. b64url(payload))

- [`Codec.base64url`] (codec.tl:230) is unpadded and URL- and cookie-safe, so
  no escaping is needed; [`Codec.unbase64url`] (codec.tl:241) is strict (rejects
  padding and nonzero trailing bits), so the token has exactly one spelling.
- `Hash.hmac("sha256", ...)` (hash.tl:83). Comparison: **constant time**.
  cosmic has none today (`grep` finds none; [`Hash.digest`] results compare with
  `==`). Add `Hash.equal(a: string, b: string): boolean` to cosmic/hash.tl:
  `false` at once when lengths differ (lengths of MACs are public), otherwise
  OR-accumulate `a:byte(i) ~ b:byte(i)` over all bytes with no early exit.
  A C binding (core/hash.c, a volatile accumulator over every byte), the only
  form that cannot be optimized into an early exit. It also serves the CSRF
  compare.
- Verify order: split on the last `.`; refuse a token over `max_bytes` *before*
  decoding (no big allocations from a hostile cookie); MAC first, against
  every key in `keys` (so rotation window = number of keys; at most 5
  accepted); only after the MAC verifies is the payload JSON decoded
  (`max_depth = 8`), `v == 1` checked, `e > now` checked. Nothing in the
  payload is trusted before the MAC.
- Binding the cookie name into the MAC stops a value minted for one cookie
  (a future "remember-me" cookie signed by the same key) being replayed as
  another.
- Expiry is *in the payload*, checked server-side; the cookie's `Max-Age` is
  advisory only.
- Key rotation: `keys = { new, old }`. Tokens verify under either; any
  token that verified under a non-first key is re-issued under keys[1] on the
  request's next write (the store reports `rekey = true` to the middleware,
  which treats it as modified). Retire `old` after `max_age`. `Secret.keys_from_env`
  (section 11) reads a list so rotation needs no code change.
- Size: `save` encodes, and if the token exceeds `max_bytes` returns
  `nil, "session: cookie would be 4132 bytes (limit 3800); keep ids, not
  objects, in the session or use the SQLite store"`. The middleware raises
  this: a request that loses its session silently is worse than a 500 the
  developer sees in the first test. Flash caps keep it from being a surprise.
- **Signed, not encrypted.** Anyone holding the cookie can read it
  (base64-decode the payload). Say so loudly in the docs: never store
  secrets, other users' data or anything the user must not see. cosmic ships
  no authenticated cipher today ([`cosmic.hash`] and [`cosmic.codec`] only), so
  encryption is not offered; if one lands, an `encrypt = true` option
  (AEAD, nonce in token) is the extension and the token's `v` field is the
  version hook. This is the same position as Starlette's `SessionMiddleware`
  (itsdangerous, signed, readable) and Flask; unlike Rails, which
  encrypts.
- Replay: a signed cookie cannot be revoked server-side; logout only
  clears it. Documented under `revocable = false`.

### The SQLite store

```teal
function SessionSqlite.store(db: Sqlite.Handle, opts?: SessionSqlite.Options): Session.Store | nil, string

record SessionSqlite.Options
  table: string            -- "web_sessions"; a plain identifier, checked
  --- How often an opportunistic sweep may run (10 minutes), and rows per
  --- sweep (500).
  sweep_interval: integer
  sweep_limit: integer
  --- Only touch `expires` when more than this many seconds have passed
  --- since the last (300).
  touch_interval: integer
end

--- Delete up to `limit` expired rows; for a lifespan task.
function SessionSqlite.sweep(store: Session.Store, now: integer, limit?: integer): integer | nil, string
--- Revoke every session of a subject (log out everywhere).
function SessionSqlite.destroy_subject(store: Session.Store, subject: string): integer | nil, string
```

Schema (created idempotently by `store(db)`):

```sql
CREATE TABLE IF NOT EXISTS web_sessions (
  id_hash  BLOB    PRIMARY KEY,   -- SHA-256 of the id
  data     TEXT    NOT NULL,      -- JSON object
  subject  TEXT,                  -- the app's user key, nullable
  created  INTEGER NOT NULL,      -- unix seconds
  touched  INTEGER NOT NULL,
  expires  INTEGER NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS web_sessions_expires ON web_sessions (expires);
CREATE INDEX IF NOT EXISTS web_sessions_subject ON web_sessions (subject)
  WHERE subject IS NOT NULL;
```

- Id: `Codec.base64url(Rand.entropy(32))` (rand.tl:155): 256 random bits, 43
  characters, the cookie value. No MAC needed: an unguessable id is the
  credential. The table stores `Hash.sha256(id)`, so a read of the database
  (a backup, an injection) does not yield live cookies. [`Rand.entropy`]
  failing is `nil, why`: the request is a 500, never a weak id from
  [`Rand.new`] (rand.tl:114, the seeded generator, which is not for secrets).
- `subject`: set by `session:set("user_id", ...)` is not enough for the store
  to find sessions by user; so `Handle:bind_subject(s)` (SQLite only, a no-op
  on the cookie store with `revocable = false`) writes the column. It is what
  makes "sign out everywhere" and "password changed" work. Optional.
- `load`: `SELECT data, created, expires FROM web_sessions WHERE id_hash = ?1
  AND expires > ?2`; absent row is anonymous. Parameters bound with
  [`Sqlite.Value`] (`{ blob = ... }`, `{ integer = ... }`), never
  concatenated; the table name, the only concatenated part, is validated as
  `^[A-Za-z_][A-Za-z0-9_]*$` at `store()`.
- `save` (merging): one transaction around: re-read the row's `data`, apply
  `changes` (set keys, remove keys, or replace on `cleared`), write back
  with new `touched`/`expires`; new session: `INSERT`. Because tasks are
  cooperative and the transaction contains no yield (no I/O wait, only
  synchronous SQLite calls), it is atomic with respect to other requests in
  this process; two requests writing disjoint keys both land. A single
  [`Sqlite.transact`] (sqlite.tl:639) cannot nest, so the store never opens
  one in the request path outside `save`/`destroy`, and the middleware does
  *not* hold a transaction open across the handler.
- Cross-process writers (another process sharing the file): SQLite's own
  locking applies; set `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=250;
  PRAGMA synchronous=NORMAL;` at `store()` unless the db is already
  configured. A `SQLITE_BUSY` after the timeout is `nil, why` and a 503 from
  core's exception layer, with `Retry-After: 1`.
- `regenerate`: in one transaction, insert under the new id (data copied),
  delete the old id's row.
- Expiry and sweep: `expires` is checked on every `load` (a row past its
  expiry is as good as absent); expired rows are deleted by an
  opportunistic sweep inside `save`/`load` at most every `sweep_interval`
  (one `DELETE ... WHERE id_hash IN (SELECT id_hash ... WHERE expires <= ?1
  LIMIT 500)`, so a big backlog never stalls the loop), and by
  `SessionSqlite.sweep` for apps that run it from a lifespan timer
  ([`Poll.delay`] loop).

The blocking-SQLite caveat, concretely:

- `Sqlite.*` calls block the thread (server.tl:563-566, TODO at 567-570
  regarding curl; the same holds for sqlite). While a session query runs, no
  other connection is served. In WAL mode a primary-key lookup or insert is in
  the tens of microseconds on SSD, which a handler can afford; a `DELETE`
  of a large backlog or an fsync on a slow disk is where it hurts. Hence:
  point lookups only; write only when changed; `synchronous=NORMAL`; the
  sweep is bounded in rows; the app uses one handle; WAL.
- A busy timeout is a *blocking sleep* of the whole server. Default
  `busy_timeout` is therefore small (250 ms), and a database shared with a
  heavy writer in another process should have the session table in its own file.
- The write at the end of a request does not delay that response's other
  tasks beyond the above; but the `fsync` on commit is the cost to
  measure. If it matters, move the sessions to a `:memory:`-like WAL with
  `synchronous=OFF` and accept loss on power failure, or use the cookie
  store.
- No SQLite call may be made from a Reader body producer that yields while
  holding a statement open; stores only run complete statements.
- Moving sessions off the thread is a later change (a worker process, once
  cosmic has a blocking-call offload); noted in doc/roadmap.md rather than a
  TODO because no API waits on it.

### Which store, when

- Signed cookie (default): zero infrastructure, no database read per
  request, fine for a small amount of non-secret state (a user id, flash,
  a CSRF secret, a theme). Cannot be revoked; user can read it; 4 KB.
- SQLite: revocable, server-side size, no readable state, "log out
  everywhere", bookkeeping per session. Costs one blocking query on first
  touch per request.

Both are `Session.Store`; swapping is one argument. The default
`Session.middleware` has no default store: it requires `store` so the
choice (and the key) is visible at the app's top.

### Cookie attributes in the middleware (the Secure question)

`secure = nil` (auto) means: `true` when `req.scheme == "https"`, else `false`.
`req.scheme` comes from the core: only `X-Forwarded-Proto` from a declared
trusted proxy changes it (open question 1), otherwise a request is http as
the server speaks http. The consequence to document: behind a TLS proxy
without `trusted_proxy` the session cookie is sent without `Secure`; the
app is warned once at startup by [`cosmic.log`] when `secure` is auto and the
server listens on a non-loopback address. A production app sets
`secure = true` explicitly; then the default cookie name is `__Host-session`
(requires Secure, Path=/, no Domain), which is also the defense against
sibling-subdomain cookie tossing. In dev (loopback, http) the name is
`session`.

### Logging

The session id (SQLite) is a bearer credential. `Handle:id()` is documented
as "for correlation after hashing"; logs get `Hash.hex_sha256(id):sub(1, 12)`
(`Session.log_id(req)`). Cookies, `Authorization` and `X-CSRF-Token` are
never written by the logging middleware (a fixed
redaction list `cookie`, `set-cookie`, `authorization`, `x-csrf-token`).

## 8. CSRF

### Threat model and approach

Browsers attach cookies to cross-site requests; SameSite=Lax on the session
cookie (our default) already blocks cross-site `POST`, `PUT`, `DELETE`
from other sites (Lax sends cookies only on top-level GET navigations), but
it is not enough alone: it does not cover same-site-but-cross-origin
attackers (a vulnerable sibling subdomain), older browsers, `SameSite=None`
embeds, a GET that mutates, or the first two minutes of a Chrome Lax+POST
grace period for cookies without an explicit attribute. So the middleware
layers two checks, and exposes the token for forms and htmx.

1. **Origin check** (stateless, no token, no session): for an unsafe method
   (anything but GET, HEAD, OPTIONS, TRACE):
   - if `Sec-Fetch-Site` is present and is `cross-site` (or `same-site` when
     `strict_same_site=true`): reject;
   - else if `Origin` is present: it must equal the request's origin
     (scheme from `req.scheme`, `Host` header) or be in `trusted_origins`;
     `Origin: null` rejected unless listed;
   - else (neither header: a non-browser client, or a browser too old):
     passes this layer.
   This is the check Go 1.25's `CrossOriginProtection` ships, and it makes
   htmx apps CSRF-safe in current browsers with no token plumbing at all.
2. **Synchronizer token** (session-bound): the secret is 32 random bytes in the
   session under `_csrf`, created lazily on first `Csrf.token(req)`. A
   request's token is checked on the same unsafe methods. Required whenever
   the request carries an identifying cookie (the session cookie): a request
   with a valid token but anonymous (login form) is fine, since the secret
   exists once the form was rendered.

Why session-bound rather than double-submit-cookie as the default: a
double-submit cookie (a random value in a cookie and in the form) is
defeated by any attacker able to plant cookies (sibling subdomain, or an
active network attacker on http); a token bound to the session secret is not,
and cosmic.web already requires the session for the apps that use auth. A
*signed* double-submit (HMAC of the session id) fixes the plant problem but
needs a session id; the cookie store has none. So: session secret. The
no-session case (a static-ish site with one form) gets layer 1 only plus an
optional `Csrf.middleware{ token = false }` — the explicit statement that origin
checking is the whole defense. A cookie-based double-submit mode is left for
the roadmap (nobody needs it with sessions present).

### Token format and masking

    token = b64url(mask .. xor(secret, mask))    -- 32 + 32 bytes, 86 chars

`mask = Rand.entropy(32)` is fresh per call, so each rendered page carries a
different-looking token and a compressed response that reflects it
(gzip middleware, v1) does not leak the secret through BREACH-style length
oracles. `check(token)` unmasks (xor of the halves) and compares with
[`Hash.equal`] against the session secret. XOR over 32 bytes is a small pure
Teal loop (`string.byte`/`char` over the pair); the secret itself never
leaves the session.

### API and middleware

```teal
local record Csrf
  FIELD: string      -- "csrf_token"
  HEADER: string     -- "X-CSRF-Token"

  record Options
    --- Extra origins allowed to send unsafe requests (CORS partners):
    --- "https://app.example.com".
    trusted_origins: {string}
    --- Run the Origin / Sec-Fetch-Site layer (true).
    origin_check: boolean
    --- Run the token layer (true).
    token: boolean
    --- Treat same-site cross-origin as cross-site (false).
    strict_same_site: boolean
    --- Skip requests this returns true for (nil).
    exempt: function(Web.Request): boolean
    --- Do not require a token for a request with `Authorization: Bearer`
    --- (true). Basic auth is ambient in browsers and is never exempt.
    bearer_exempt: boolean
    --- Replies to a rejected request; default a 403 problem.
    on_failure: function(Web.Request, reason: string): Web.Response
  end
end

function Csrf.middleware(opts?: Csrf.Options): Web.Middleware
--- A masked token for this request/session, creating the secret.
function Csrf.token(req: Web.Request): string
```

Order of checks and token lookup, for an unsafe-method request:

1. `exempt(req)` true, or a bearer-token request with `bearer_exempt`: pass.
   Why bearer is safe to exempt: a cross-site form or an `<img>` cannot set
   `Authorization`; a `fetch` that does needs a CORS preflight, which CORS
   governs. And the exemption keys on the header's presence, so an attacker
   cannot use it to *skip* the check on a cookie-authenticated request: that
   request has no Authorization header, so it is checked. A route that accepts
   cookie *or* bearer must treat an invalid Authorization as a 401, never fall
   back to the cookie; documented where `bearer_exempt` is.
   The primary recommendation for APIs is still structural: mount the API
   under its own `Mount` with a stack that has CORS and bearer auth and no
   CSRF middleware and no session middleware at all (core.md section 5.6:
   a Mount has its own middleware). Then there is no ambient credential to forge.
2. Origin layer as above; 403 on failure.
3. Token layer: token from `X-CSRF-Token` header; else for
   `application/x-www-form-urlencoded`, field `csrf_token` of the form (read
   via `Input.form`, cached and body restored, section 2); else for
   multipart per section 4 (header, or the first part); JSON bodies take the
   header only. Missing or wrong: 403. A request with no session cookie at all
   and `token = true`: 403 (nothing to check against) unless it is the login
   case: any form page was rendered with `Csrf.token`, which created the
   session; so a cookieless POST is a forgery or a cookie-blocking browser.

Safe methods: never checked and never rejected. The corollary stated in the
docs: GET handlers must not mutate; `hx-get` for anything that changes state is
a bug the middleware cannot catch.

Failures log the reason at `warn` with the path, method and `Origin`, never
the token.

### Forms and htmx

Plain form: `<input type="hidden" name="csrf_token" value="{{.csrf}}">`;
`Csrf.token(req)` in the page handler goes into the template data.

htmx: put the token once, on `<body>`, in `hx-headers`:

```html
<body hx-headers='{"X-CSRF-Token": "{{.csrf}}"}'>
```

The htmx dialect's typed `SafeJson` (templates.md section 5) is what makes
`{{.csrf}}` safe inside a JSON attribute; this file only needs the
header name. Every `hx-post`/`hx-put`/`hx-delete`/`hx-patch` descendant
inherits it. Things to know:

- htmx 2 sends `hx-headers` only to same-origin URLs by default
  (`selfRequestsOnly` true), so the token does not leak with a cross-origin
  `hx-get`; the htmx config `Htmx.head` writes (templates.md section 6.6)
  sets it explicitly and nothing should loosen it.
- With `hx-boost`, navigating swaps the body's *content* not its attributes;
  the token on `<body>` stays valid because every masked token unmasks to the
  same secret. After login the secret rotates (`regenerate`), so a boosted
  login must end with a full navigation (`HX-Redirect`, or `hx-boost="false"`
  on the login form). Documented in the htmx guide; the CSRF failure message
  for an htmx request (`HX-Request: true`) says "reload the page".
- A 403 from CSRF to an htmx request: `HX-Trigger: {"csrf-failed": ...}` is
  optional; the default is a plain 403 body that htmx shows as an error.
- The fallback that avoids inline attributes (a `<meta name=csrf-token>` read
  by script on `htmx:configRequest`) needs a script; avoided because the CSP
  in section 10 forbids inline script.

## 9. CORS

```teal
local record Cors
  record Options
    --- Exact origins "https://app.example.com" (scheme://host[:port], no
    --- path, lowercase host), or {"*"} for any. Validated with Url.parse at
    --- construction; a malformed or path-bearing origin raises.
    allow_origins: {string}
    --- A predicate in place of a list, e.g. any subdomain; checked after
    --- the list.
    allow_origin: function(origin: string): boolean
    --- Methods a cross-origin preflight may ask for. Default
    --- {"GET", "HEAD", "POST"} (Starlette defaults to GET only).
    allow_methods: {string}
    --- Request headers a preflight may ask for; {"*"} reflects the
    --- requested ones. CORS-safelisted headers are always allowed.
    allow_headers: {string}
    --- Response headers JS may read (Access-Control-Expose-Headers).
    expose_headers: {string}
    --- Allow credentials (cookies, Authorization). Default false.
    allow_credentials: boolean
    --- Seconds a preflight is cached; default 600 (browsers cap it:
    --- Chrome 7200, Firefox 86400).
    max_age: integer
  end
end

function Cors.middleware(opts: Cors.Options): Web.Middleware
```

Behavior:

- A request without an `Origin` header is not CORS: untouched (but gets
  `Vary: Origin` if the config is origin-dependent, so a cache does not serve
  a CORS reply to a non-CORS request or the reverse).
- **Preflight** is `OPTIONS` + `Origin` + `Access-Control-Request-Method`. The
  middleware answers it itself and does not call the router (an `OPTIONS` that
  is not a preflight goes through normally). Allowed: `204` with
  `Access-Control-Allow-Origin`, `-Allow-Methods` (the configured list),
  `-Allow-Headers` (the requested headers if allowed, else configured),
  `-Max-Age`, `-Allow-Credentials: true` when set, and `Vary: Origin,
  Access-Control-Request-Method, Access-Control-Request-Headers`.
  Refused (disallowed origin, method, or header): `403` with no CORS headers
  (Starlette answers 400; 403 is what the cause is; the browser blocks it
  either way because the headers are missing).
- **Actual request**: forwarded to the handler; on a response to an allowed
  origin, `Access-Control-Allow-Origin` (the origin, or `*` only when
  `allow_origins = {"*"}` and no credentials), `Access-Control-Allow-Credentials`
  when set, `Access-Control-Expose-Headers` when set, `Vary: Origin` added with
  `Web.add_header(res, "Vary", "Origin")`, which merges it into any existing
  `Vary`.
- `allow_credentials = true` with `allow_origins = {"*"}` raises at
  construction: the browser refuses `*` with credentials, and the common
  "fix" (reflecting any origin) hands every site the user's cookies; a
  credentialed config must list its origins (or use the predicate, and the
  predicate is the app's responsibility).
- The origin `null` (sandboxed iframes, `file:`, redirects) is never allowed
  by `*` or a predicate default; only if the string `"null"` is listed
  explicitly.
- Matching is exact on scheme, lowercased host, and port (default ports
  normalized: `https://a.com:443` equals `https://a.com`).
- Order in the stack: outermost, so a 401/403/404/413 produced inside
  carries CORS headers (a missing
  header turns "403 Forbidden" into an opaque "CORS error" in the browser
  console, the most common CORS debugging trap). Core's exception layer sits
  inside the user stack (core.md section 8.1), so the 500 it makes for a
  handler's raise also passes back out through CORS and carries the headers:
  the browser shows the JSON problem, not "CORS error". In Starlette,
  ServerErrorMiddleware is outermost, so its 500 lacks them; this is a
  departure.
- Interaction with CSRF: a credentialed CORS partner sends
  `Sec-Fetch-Site: cross-site`; its origin must also be in
  `Csrf.Options.trusted_origins`. A tiny helper
  `Cors.trusted(opts): {string}` returns the list so the two stay in one place.
- CORS is not authorization. Docs say it three times.

## 10. Security headers and CSP

```teal
local record Headers
  record Options
    --- X-Content-Type-Options: nosniff (true).
    nosniff: boolean
    --- Referrer-Policy ("strict-origin-when-cross-origin"; false: omit).
    referrer_policy: string
    --- "DENY" | "SAMEORIGIN" | false. Default "DENY" (and CSP frame-ancestors).
    frame_options: string
    --- Cross-Origin-Opener-Policy ("same-origin"; false: omit).
    coop: string
    --- Cross-Origin-Resource-Policy: nil (omitted) unless set; "same-origin"
    --- for an HTML app that serves nothing cross-origin.
    corp: string
    --- Permissions-Policy ("camera=(), microphone=(), geolocation=()").
    permissions_policy: string
    --- Strict-Transport-Security; nil (omitted) unless set. Applied only to
    --- https requests (req.scheme).
    hsts: { max_age: integer, include_subdomains: boolean, preload: boolean }
    --- nil: no CSP. See Csp.
    csp: Csp.Policy
    --- Send as Content-Security-Policy-Report-Only instead (false).
    csp_report_only: boolean
    --- Draw a per-request nonce (false); see below.
    nonce: boolean
  end
end

function Headers.middleware(opts?: Headers.Options): Web.Middleware
--- The request's CSP nonce, `req:get(Headers.NONCE)`: "" when nonce = false.
Headers.NONCE: Web.Key<string>
```

Rules:

- Each header is set *if absent*: a handler or an upstream middleware that
  set its own (a CSP for an embeddable widget route) wins. Names compared
  case-insensitively (core's `Web.header(res, name)`).
- Applied to every response, including errors and 304s; not to a `Reply` the
  server creates itself (400 for a malformed request, before any handler).
- Defaults chosen to break nothing in an htmx app: `nosniff`, a referrer
  policy, `frame_options`, `coop`. `corp`, `hsts` and `csp` are opt-in
  (CORP breaks cross-origin API consumers and CDN images; HSTS is sticky for
  a long time and must be a decision; a CSP wants testing). The recommended
  starting point is `Headers.middleware{ csp = Csp.htmx_default(), hsts = {
  max_age = 31536000 } }` for an https app. `X-XSS-Protection` is omitted
  (obsolete, introduces issues in old browsers).
- `X-Frame-Options` and `frame-ancestors` are both set; the CSP directive
  is the standard, the header the fallback.

### Csp

`Csp` is a record exported by `cosmic.web.headers` (`Headers.Csp`, written
`Csp` below).

```teal
local record Csp
  record Policy
    --- Directive name -> sources. A directive with {} is written bare
    --- ("upgrade-insecure-requests"). The source "{nonce}" is replaced by
    --- "'nonce-<value>'" per request.
    directives: {string:{string}}
  end
end

function Csp.format(p: Csp.Policy, nonce?: string): string
function Csp.htmx_default(): Csp.Policy
```

`Csp.htmx_default()`:

    default-src 'self'; script-src 'self'; style-src 'self';
    img-src 'self' data:; font-src 'self'; connect-src 'self';
    object-src 'none'; base-uri 'none'; form-action 'self';
    frame-ancestors 'none'

What this requires of the htmx integration (the contract with
templates.md and assets.md; the htmx config itself is defined once, in
templates.md section 6.6, and written by `Htmx.head`):

- htmx itself is a same-origin script (`/_web/htmx-2.0.11.min.js`, assets.md
  section 4.4, SRI-hashed by `Htmx.head`), so `script-src 'self'` allows it.
  An SRI hash is not a CSP source; it is checked in addition.
- htmx uses `eval` (via `new Function`) for `hx-on:*`, `hx-trigger` filter
  expressions, `hx-vals='js:...'` and inline `<script>` in responses. Under a
  CSP with no `'unsafe-eval'` these fail, so the config `Htmx.head` writes
  has `allowEval` and `allowScriptTags` off (and `selfRequestsOnly` on). The
  template compiler refusing slots in `hx-on:*` and `hx-vars` is the other
  half (templates.md section 2).
- `includeIndicatorStyles` is off in that config: htmx otherwise injects a
  `<style>` for `.htmx-indicator` and `style-src 'self'` blocks it; the
  rules ship as `Htmx.indicator_css()` (templates.md section 6.6) for the
  app's stylesheet instead.
- `style-src 'self'` also blocks `style="..."` attributes: templates use
  classes. If a project needs inline style, `'unsafe-inline'` for styles
  only is an acceptable loosening (script-src is what matters), set by the
  app, not the default.
- Inline `<script>` from the app: use the nonce. `Headers.middleware{ nonce =
  true, csp = ... }` with `script-src 'self' {nonce}`; the layout reads
  `req:get(Headers.NONCE)` and renders `nonce="..."` through the template
  attribute escaper, and passes the same value to `Htmx.head{ nonce = ... }`
  for its tags. htmx's own `inlineScriptNonce` is set from that value in
  the config if inline script tags in responses are ever allowed (not by
  default).
- SSE/`EventSource`: `connect-src 'self'` covers it.
- The nonce is 16 random bytes from [`Rand.entropy`], base64url, per request,
  kept under the exported key `Headers.NONCE` (`Web.Key<string>`, "" when
  `nonce = false`); it is a one-time value, so the response must not be
  cached shared (`Cache-Control: private` or `no-store` is added to
  responses that carry a nonce and have no Cache-Control).

`csp_report_only = true` ships a policy as `Content-Security-Policy-Report-Only`
to try it; reporting endpoints are not designed in v1 (open question 9).

## 11. Secrets

Keys come from the environment, never from source, and weak or default keys
are refused.

```teal
local record Secret
  --- The keys in environment variable `name`: a comma-separated list,
  --- newest first, each used as the raw bytes of the text (no decoding).
  function keys_from_env(name: string): {string} | nil, string
  --- Refuses a key unless it is at least 32 bytes with at least 10
  --- distinct byte values.
  function check(key: string): boolean, string
  --- A fresh random key as text (64 hex characters from 32 entropy bytes)
  --- for a person to put in an env var; `cosmic.web` prints it from
  --- `bin/cosmic web secret`.
  function generate(): string
  --- Dev only: an ephemeral per-process random key, warning once on stderr
  --- that sessions will not survive a restart.
  function ephemeral(): string
end
```

- Source: `Env.get(name)` (env.tl:10). The conventional name is
  `COSMIC_SESSION_KEYS`; the app chooses. A missing variable is
  `nil, "secret: COSMIC_SESSION_KEYS is not set; generate one with \
  bin/cosmic web secret"` and `Session.middleware` refuses to start (a raise
  at construction, before the server listens). No fixed default key in code,
  ever: a published default is how every Flask/Rails app with
  `SECRET_KEY = "dev"` gets its sessions forged.
- Weak keys: length at least 32 bytes, at least 10 distinct byte values
  (rejects `"aaaaaaaa..."`, `"changeme" x 8`, `"0123456789" x 4`'s mild cases;
  it is a floor, not an entropy proof). No deny-list of famous strings (it
  gives false confidence). A key from `Secret.generate()` (hex of 32 random
  bytes: 64 characters, 256 bits of entropy) passes. The message states the length found and how to make one.
- Keys are bytes of the text, not decoded: nothing to get wrong in encoding,
  no hex-vs-base64 ambiguity; the cost is that a hex key of 64 characters
  has 256 bits of entropy over a 64-byte HMAC key, which is fine (HMAC hashes
  keys longer than the block size, and 64 bytes is the SHA-256 block).
- Rotation: `COSMIC_SESSION_KEYS="new,old"`; first signs, all verify.
  At most 5 keys.
- The key never appears in logs, error messages (a `check` failure names the
  length, not the text) or the `Debug` output of the options record. The
  options are not `__tostring`-able for that reason.
- A key shared between purposes: the MAC input is domain-separated (context
  string + cookie name + `\0`), so one key can sign sessions and a future
  remember-me cookie without cross-use. Separate keys per purpose are still
  better; the middleware takes its own.

## 12. How it is tested

All pure Teal, no network, except the end-to-end cases (a few) which use
core's in-process client (`cosmic.web.testing`, core.md section 10) or a loopback server with
`Test.policy { loopback = { "127.0.0.1" } }`; those need the `Net` loopback
declaration, everything else declares nothing.

- `url_test.tl` (existing file, extended): `decode_query` — plus, spaces,
  `%2B`, repeated names (`by_name` order), empty pieces, `a` with no `=`,
  `=v`, `;` not a separator, strict invalid escape with byte position,
  lenient literal `%`, UTF-8 refusal, `max_pairs` (1000 ok, 1001 refused),
  encode/decode round trip. `url_fuzz_test.tl` (existing) gets a property:
  `decode_query(encode_query(pairs)) == pairs` and never raises on bytes;
  label `lenient_path`, `strict_refusal`.
- `input_test.tl`: bind each Shape kind from strings; integer overflow;
  `1e3`, `0x10`, ` 7 ` (trim); boolean absent -> false, `optional(boolean)`
  absent -> nil, hidden+checkbox last wins; `""` for optional number -> nil;
  list from repeated names; dotted nested record; all errors collected, in
  field order; `submitted` without `secret`; unknown names dropped; JSON
  pointer to field conversion; content-type 415 cases (`text/plain` JSON);
  413 from Content-Length without reading; 400 on invalid escape; body cached
  and re-readable.
- `cookies_test.tl` / `cookies_fuzz_test.tl`: parse (first wins, quotes,
  `, ` separator, name-only ignored, 100 cookies cap); format order, token
  and cookie-octet refusal, `__Host-` rules, `SameSite=None` without Secure,
  4096 cap; parse(format(x)) round trip; the wire.tl join test (two `Cookie`
  lines arrive `a=1; b=2`).
- `session/cookie_test.tl`: round trip; tamper any byte -> anonymous; token
  signed under old key verifies and is re-issued; expired; over-size error
  text; wrong cookie name's token rejected; fuzz of arbitrary tokens never
  loads data and never raises ([`Fuzz.label`] `mac_ok` / `mac_bad`). `now` is
  injected, so no sleeps.
- `session/sqlite_test.tl`: [`Sqlite.memory()`]; create/load/update/merge of
  disjoint keys from two handles loaded before either saves; regenerate
  removes the old row; expiry; sweep bounded by limit; `destroy_subject`;
  id is unguessable length and the table holds only a hash.
- `session_test.tl`: middleware over a stub handler: no touch -> no
  `Set-Cookie`, no `Vary`; read-only -> no `Set-Cookie`, `Vary: Cookie`;
  write -> one `Set-Cookie`; flash round trip; late write after head raises;
  invalid cookie -> anonymous.
- `csrf_test.tl`: GET passes; POST with `Sec-Fetch-Site: cross-site` is 403;
  `Origin` mismatch; trusted origin; header token; form token; multipart
  first-part token; masked tokens differ per call but both verify; bearer
  exemption keyed on the header; Basic not exempt.
- `cors_test.tl`: preflight allowed/refused; `*` with credentials raises;
  `Vary: Origin`; null origin; port normalization.
- `headers_test.tl`: set-if-absent; HSTS only on https; nonce differs per
  request; CSP formatting.
- `multipart_test.tl` / `multipart_fuzz_test.tl`: browser-shaped bodies
  (Chrome, Firefox boundaries), delimiter split across reads, filename
  `../..\\x\0`, no closing boundary, header too large, `max_parts`.
- `secret_test.tl`: refuse short / low-variety keys; env list parsing.
- Hash: `hash_test.tl` adds `equal` (equal, differing lengths, differing last
  byte).
- `fix --check .` expectations: every exported function used (tree_checks
  "every export earned"), so no speculative helpers; `Input.empty_as_nil`,
  `Cookies.escape_value` and `Session.log_id` are the ones to drop first if
  nothing in cosmic.web uses them.

## Changes to existing files

- cosmic/url.tl: `Pair`, `Query`, `QueryOptions`, `decode_query`,
  `encode_query`, `form_unescape`, `query_first`, `query_last`, `query_all`;
  remove the corresponding roadmap bullet (doc/roadmap.md:243-249 partially).
  The module comment says "Nothing here raises on its text", which stays true.
- cosmic/http/wire.tl:434: join `cookie` with `"; "`.
- cosmic/hash.tl: [`Hash.equal`] (constant-time).
- cosmic/http/multipart.tl: new (section 4; step 7 of ../web.md's order).
- cosmic/http/server.tl: only what core.md section 13 changes for multi-valued
  `Reply.headers` (server.tl:91, :343); nothing else for this file.
  (A `body_ns` for upload deadlines is the existing TODO at :485-489.)
- cosmic/shape.tl (optional, recommended): a way to get the failing path as
  steps, or a collect-all `Shape.into_all` returning every `{path, reason}`;
  see open question 2. Not needed to ship.
- doc/roadmap.md: list of records in forms (`items.0.name`), CSRF cookie
  double-submit mode, AEAD-encrypted cookie sessions, reporting endpoints,
  moving SQLite off the thread.
- `bin/cosmic web secret` (a tiny subcommand or example): prints
  `Secret.generate()`.

## Where this departs from Starlette

- Starlette's `SessionMiddleware` is one signed cookie (itsdangerous),
  `Max-Age` only, no server-side expiry, no rotation; here the payload carries
  its expiry, keys rotate, and a revocable SQLite store exists behind the same
  interface.
- Starlette sessions are an always-loaded dict mutated freely; here the
  session is lazy, tracks modification, and is write-after-head-protected.
- Starlette has no CSRF middleware (apps use `starlette-csrf` or
  `asgi-csrf`) and no form binding; cosmic.web ships both, with form errors
  collected for re-render.
- Starlette's CORS preflight failure is 400 and `allow_methods` defaults to
  GET; ours is 403, and the default is GET, HEAD, POST.
- Starlette decodes forms through python-multipart into an `UploadFile`
  (spooled temp file); same shape here (`Upload.path`), without a
  `SpooledTemporaryFile` memory tier.

## Open questions, with recommendations

1. `Request.scheme` and trusted proxies. Secure cookies, HSTS and the
   CSRF origin comparison all need to know the request was https; the server
   cannot. Decided (../web.md, decision 10): the core adds `Web.app{ trusted_proxy = true }`,
   which makes `Request.scheme`/`host` come from `X-Forwarded-Proto/Host` and
   is off by default; with it off, `Secure` is explicit config and the startup
   warning in section 7 applies.
2. Collect-all and failing-path reporting in cosmic.shape. Web's
   spec-directed binder duplicates Shape's traversal for strings, and JSON
   errors are parsed from a message. Recommendation: ship v1 without a
   shape.tl change; file a follow-up for `Shape.into_all(value, spec): T|nil,
   {{path:Json.Steps, reason:string}}` and a `Shape.coerce = "strings"` mode, at which point
   the binder collapses into Shape and the form coercions live next to the
   spec.
3. Last-wins vs first-wins for a repeated scalar. Recommendation: last (the
   hidden+checkbox idiom); `repeated = "error"` for APIs.
4. Absent boolean is false. Recommendation: keep (the checkbox rule), with
   `optional(boolean)` as the tri-state; alternative `Input.checkbox` marker
   rejected as one more concept.
5. NUL in decoded strings: refused in scalar string fields by the binder,
   allowed in the raw decoder. Recommendation: as written.
6. 400 vs 422 for a value that fails its shape spec. Decided: 422, and 400
   for undecodable input (../web.md, decision 7).
7. Upload deadlines: the `body_ns` TODO in server.tl:485-489 should land
   before docs recommend uploads on the open internet. Recommendation: land
   it with this work (a small `Timed` deadline set at head end).
8. Signed-cookie sessions are readable. Recommendation: document, and add
   AEAD encryption when cosmic has a cipher; do not invent one with HMAC
   stream constructions.
9. CSP reporting (`report-to`, a `/csp-report` endpoint). Recommendation:
   leave out of v1; `csp_report_only` is enough to trial a policy by the
   browser console.
10. [`Hash.equal`] in pure Teal vs a C binding. Decided: a C binding in
    core/hash.c, as only C keeps the compiler from adding an early exit.
11. Should `Session.middleware` fall back to an ephemeral key in dev without
    configuration? Recommendation: only through an explicit
    `Secret.ephemeral()` in the app's own code, never implicitly.
12. Multipart in v1 (section 4). Decided: in v1, last, once the body
    deadline of question 7 has landed (../web.md, decision 8).

[`Codec.base64url`]: ../../../cosmic/codec.tl
[`Codec.unbase64url`]: ../../../cosmic/codec.tl
[`cosmic.codec`]: ../../../cosmic/codec.tl
[`cosmic.hash`]: ../../../cosmic/hash.tl
[`cosmic.http.server`]: ../../../cosmic/http/server.tl
[`cosmic.log`]: ../../../cosmic/log.tl
[`cosmic.shape`]: ../../../cosmic/shape.tl
[`cosmic.url`]: ../../../cosmic/url.tl
[`Fs.rename`]: ../../../cosmic/fs.tl
[`Fuzz.label`]: ../../../build/fuzz/init.tl
[`Hash.digest`]: ../../../cosmic/hash.tl
[`Hash.equal`]: ../../../cosmic/hash.tl
[`Json.decode`]: ../../../cosmic/json.tl
[`Json.encode`]: ../../../cosmic/json.tl
[`Json.from_pointer`]: ../../../cosmic/json.tl
[`Json.null`]: ../../../cosmic/json.tl
[`Poll.delay`]: ../../../cosmic/poll.tl
[`Rand.entropy`]: ../../../cosmic/rand.tl
[`Rand.new`]: ../../../cosmic/rand.tl
[`Server.range`]: ../../../cosmic/http/server.tl
[`Server.Reply`]: ../../../cosmic/http/server.tl
[`Shape.any`]: ../../../cosmic/shape.tl
[`Shape.into`]: ../../../cosmic/shape.tl
[`Shape.map`]: ../../../cosmic/shape.tl
[`Shape.number`]: ../../../cosmic/shape.tl
[`Shape.record_of`]: ../../../cosmic/shape.tl
[`Shape.record`]: ../../../cosmic/shape.tl
[`Spec.kind`]: ../../../cosmic/shape.tl
[`Sqlite.memory()`]: ../../../cosmic/sqlite.tl
[`Sqlite.transact`]: ../../../cosmic/sqlite.tl
[`Sqlite.Value`]: ../../../cosmic/sqlite.tl
[`Stream.create`]: ../../../cosmic/stream.tl
[`Stream.limit`]: ../../../cosmic/stream.tl
[`Stream.read_up_to`]: ../../../cosmic/stream.tl
[`Stream.Reader`]: ../../../cosmic/stream.tl
[`Url.escape`]: ../../../cosmic/url.tl
[`Url.segments`]: ../../../cosmic/url.tl
[`Url.unescape`]: ../../../cosmic/url.tl
[`wire.check`]: ../../../cosmic/http/wire.tl
[`wire.send`]: ../../../cosmic/http/wire.tl
