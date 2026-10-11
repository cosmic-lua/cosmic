# cosmic.web: templates and htmx

Part of the cosmic.web design: see ../web.md for the overview, decisions and phasing.

Scope: the attribute-dialect mechanism in [`cosmic.template`], the `htmx`
dialect, the URL-component escaper and its safe types, `SafeJson`, the
htmx helpers in `cosmic.web.htmx` (including `Htmx.head`, which writes the
page's one htmx configuration), and how a template reaches reverse routing.
Routing, Request/Response and the error layer are core.md; input, sessions
and security headers are input.md; the vendored htmx, static assets and SSE
are assets.md. This file names them and states what it uses of them (section
9).

Decisions in one place:

- A template opts in with `{{use htmx}}`, an action in the header, after
  `{{type}}` and beside `{{mode}}`. Dialects are a built-in registry inside
  [`cosmic.template`] (data modules under `cosmic/template/dialect/`), not
  resolved from `cosmic.web` or a project module path, and the `htmx`
  dialect's data lives there too; `cosmic.web.htmx` only reuses it (the
  version string, the tests that tie the table to the vendored file).
  Reason: the build compiles templates with a pure `Template.compile(src,
  name)` and the compiler's identity only covers `build.*` and
  `cosmic.template.*` (build/identity.tl:397-402). A dialect anywhere else
  would not regenerate stale templates when it changed.
- The refusals of code-bearing `hx-*` attributes (`hx-on*`, `hx-vars`) are
  always on, with or without `{{use htmx}}`. Only the enabling classes
  (URL, JSON, selector) are opt-in.
- One new URL escaper (`url_part`) serves path segments, query names and
  values, and fragments alike; the tracker does not need to know which
  component a slot is in. It is the escaper `Router:reverse` uses too
  (core.md section 5.7). New types: [`Html.SafeUrlPart`] and
  `Html.SafeJson`. Selector slots use a C escaper that returns an existing
  type (`SafeAttr`).
- `cosmic.web.htmx` holds request parsing, response headers and
  `Htmx.head(opts)`, the single helper that writes the page head: the
  `<meta name="htmx-config">` and the `<script>` tags with SRI for the
  vendored htmx (and the SSE extension when asked). The configuration is
  defined once, in section 6.6; assets.md and input.md refer to it.
  Validation re-renders answer 422, which that configuration swaps.
- Templates reach reverse routing through ordinary stages
  (`{{.item | app.urls.item}}`), not a new action and not a global.

## 1. The dialect mechanism

### 1.1 What exists

`markup.tl` decides a slot's place from the HTML tokenizer state and the
attribute name. The attribute knowledge is three constants and one
prefix rule:

- `URL_ATTRS` (cosmic/template/markup.tl:258): attributes that take one
  URL. A slot there is `"url"`, and only at the start of the value
  (markup.tl:1051).
- `CODE_ATTRS` (markup.tl:280): `style`, `srcdoc`, `srcset`, `ping`,
  `imagesrcset`, each refused with a reason.
- The `on` prefix (markup.tl:1028), refused as script.
- `ACTIVE_TAGS` (markup.tl:274) and the `<script>`, `<meta>` and SVG
  animation rules, which are tag rules, not attribute vocabulary. They stay
  where they are.

Everything else in a quoted value is `"attr"`. That is why `hx-on:click="{{.x}}"`
compiles today with only attribute escaping, which is a script-injection
hole: the browser decodes the entities and htmx evaluates the result
(markup.tl:24-26, init.tl:66-68 document this as "not recognised").

The pipeline is lex, parse, context, codegen (init.tl:98-110).
`Template.compile(src, name)` is called by build/derivation.tl:120 with
nothing but the file's text; the `derived` row is keyed by the template's
hash (derivation.tl:104-108), and the analyzer's identity folds in the
hash of every `cosmic.template.*` module.

### 1.2 Opt-in syntax

```
{{type Page from site.page}}
{{mode html}}
{{use htmx}}
<button hx-post="/items/{{.id}}/done" hx-target="#row-{{.id}}">Done</button>
```

Grammar change in parse.tl (the header loop at parse.tl:289-302): after
`{{type}}`, accept `{{mode X}}` and `{{use NAME}}` actions in any order,
each blank-text-separated, `mode` at most once, a name at most once.
`{{use}}` anywhere else is refused the way `{{mode}}` is
(parse.tl:203-205): "{{use}} must directly follow {{type}}". `{{use}}` in
a `text` template is refused ("a text template has no attributes"). An
unknown name reads `name:line:col: unknown dialect 'x' (known: htmx)`.

[`Types.Template`] (types.tl:152) gains `dialects: {string}`, in order.
Compiled output does not change for a template that uses no dialect, so
existing derived rows stay valid in content (they regenerate once anyway
because the compiler's identity moves).

Why an action and not a pragma comment or a file-level setting: it is
visible in the template, per template, and it parses with the grammar that
exists. Why not auto-enable when `hx-` is seen: a classification that
depends on the text it classifies would let `hx-on` on a different
element change how `hx-get` is read; opt-in is explicit and diffable.

### 1.3 The dialect value

New private module `cosmic/template/dialect.tl` (data and one lookup),
registry `cosmic/template/dialects.tl`, and one data module per dialect,
`cosmic/template/dialect/htmx.tl`.

```
local record Dialect
  --- What a slot in a matching attribute is.
  enum Class
    "url"        -- a whole URL or, after literal text, a URL part (as href)
    "url_local"  -- the same, and a plain string must be a same-origin reference
    "json"       -- the whole value, a Html.SafeJson
    "selector"   -- a CSS identifier piece, after `#` or `.` in the value
    "code"       -- refused
  end

  record Rule
    class: Class
    --- For "code": what a slot there would be, for the refusal.
    what: string
  end

  record Prefix
    prefix: string
    rule: Rule
  end

  record Def
    name: string
    --- The htmx version the table was written against ("2.0.x"), for the
    --- tests that tie it to the pinned asset.
    targets: string
    exact: {string: Rule}
    --- Longest prefix wins.
    prefixes: {Prefix}
    --- Attribute families the framework also reads with a `data-` prefix
    --- ("hx-", "sse-", "ws-").
    families: {string}
  end

  --- The merged tables of the dialects a template uses.
  record Table
    classify: function(self: Table, attr: string): Rule | nil
  end

  resolve: function(names: {string}, registry?: {string: Def}): Table | nil, string
end
```

`classify(attr)`: exact match on the lowercase attribute, then longest
prefix; if the attribute starts with `data-` and the rest starts with a
family of any chosen dialect, classify the rest. The tokenizer already
lower-cases attribute names (markup.tl:741).

The always-on part is a base dialect `html` (the existing constants moved
into the same shape, plus the `hx-on` and `hx-vars` code rules below). A
template's table is base plus its chosen dialects. Two dialects giving one
attribute different classes is a registry error caught by a test, not a
runtime check.

### 1.4 The seam for project dialects

`Template.compile(src, name, opts?: { dialects: {string: Dialect.Def} })`
takes an optional registry that replaces the built-in one. Tests inject
dialects through it. It is also the place a later project-level mechanism
plugs in.

Rejected for v1: `{{use myapp.dialect}}` by module path. The build
compiles templates inside `derive_templates` (derivation.tl:109) before or
beside the project's own Teal; running project code in the compiler would
be circular for a project that builds its dialect module in the same pass,
and it makes the compiler non-hermetic. If a project needs its own
(Alpine, Vue), the registry seam above is the first step, and a built-in
`alpine` dialect is a small data file.

### 1.5 Changes to markup.tl

- Signature: `Markup.slot(p, table)`; `Walk` in context.tl carries the
  `Dialect.Table` and passes it (context.tl:173, `walk`/`block`/`range_after`
  thread `Walk` already). [`Context.annotate`] gets the table as a parameter
  (init.tl:105 resolves it from `template.dialects`).
- In `slot` (markup.tl:1026-1059), after the existing `on`/`CODE_ATTRS`
  checks and before `return "attr"`, consult `table:classify(attr)`:
  - `code`: refuse, "a slot in the 'hx-on:click' attribute would be
    script" (same shape as markup.tl:1029).
  - `url` / `url_local`: apply the `ACTIVE_TAGS` refusal (markup.tl:1048),
    then `fresh` gives the whole-URL slot (`"url"` / `"url_local"`) and
    not fresh gives `"urlpart"` (section 3). The built-in `URL_ATTRS`
    take the same path, replacing the refusal and TODO at markup.tl:1051-1055.
  - `json`: require `p.fresh`; the slot is `"json"`. Otherwise refuse,
    "a slot in 'hx-vals' must be the whole value: a JSON object made by
    Html.json".
  - `selector`: require `p.ident` (below); the slot is `"selector"`.
    Otherwise refuse with the rule and its hatch (write the selector as
    literal text, and put only an identifier after `#` or `.`).
- New Place fields, all participating in `copy`, `key`, and (where a bool
  is "any arm") `join`:
  - `ident: boolean`. Cleared when a value opens (markup.tl:760-762). In the
    value branch of `scan` (markup.tl:768-801), after the text up to the
    closing quote is known, find the last byte of it that is not an
    identifier character (`[A-Za-z0-9_-]` or 0x80 and up); if there is one,
    `ident` is whether it is `#` or `.`. If the segment is all identifier
    characters, `ident` keeps its value (a continuation). `wrote` sets it
    true for a selector slot (its output is identifier text) and false for
    any other slot. `join`: both arms must be in an identifier
    (`a.ident and b.ident`).
  - `sole: boolean` and `sole_trail: boolean`. `wrote` sets `sole` for a
    `json` slot; the value branch of `scan` sets `sole_trail` when
    non-blank literal text follows in the same value; both clear at the
    closing quote (as `bare` does at markup.tl:799). `context.walk`
    refuses `sole_trail` the way it refuses `colon` and `rooted`
    (context.tl:163-168): "text after a JSON slot: a JSON slot is the
    whole value". `join`: `or`.
- `alike`/`apart` (markup.tl:342-373) are unchanged: the new fields are
  per-value state like `fresh` and `after_url`, which `join` folds.
- The header comment (markup.tl:17-33, 88-94) and init.tl:66-68 are
  rewritten: URL attributes now take a part after literal text, and the
  vocabulary is a table.

### 1.6 Changes to types.tl and codegen.tl

`types.Slot` (types.tl:21-27) gains `"urlpart"`, `"url_local"`, `"json"`,
`"selector"`. `url_local` shares `_url`'s shape with a different checker, so
the codegen helpers are:

```
text      string | number | html.SafeHtml        _text   (unchanged)
attr      string | number | html.SafeAttr        _attr   (unchanged)
url       string | html.SafeUrl                  _url    html.href
url_local string | html.SafeUrl                  _lurl   html.local_href
urlpart   string | number | html.SafeUrlPart     _part   html.url_part, html.escape
json      html.SafeJson                          _json   html.escape of html.raw_json
selector  string | number                        _sel    html.escape_css_attr
```

Each is one small generated function like the existing four
(codegen.tl:317-338), appended to `HELPER_ORDER` (codegen.tl:78) and to
`RESERVED` (codegen.tl:63). A union of one userdata type with `string` and
`number` is discriminable (codegen.tl:17-21); `json` takes the one type
alone, so there is nothing to discriminate.

Why [`html.escape`] and not `escape_attr` for `urlpart` and `json`: both
produce a quoted-attribute-safe string with the five-entity escaper
(html.tl:58-61 says it is for quoted attribute values too), and the output
stays readable (`%20` is not turned into `&#37;20`). The existing `_url`
helper uses `escape_attr` and may keep it; changing it is a separate
cleanup.

## 2. The htmx dialect

Written against htmx 2.0.x, the version assets.md section 4 pins. All names
below are matched case-insensitively and also as `data-hx-*` (family
`hx-`). Attribute semantics are from the 2.x reference; each decision
below that rests on a specific htmx behavior is flagged so the test in
section 2.4 can pin it to the vendored file.

### 2.1 Classification, attribute by attribute

Request URLs (`url_local`): `hx-get`, `hx-post`, `hx-put`, `hx-patch`,
`hx-delete`. htmx fetches these and swaps the response HTML into the page,
so the URL decides which HTML is inserted into the DOM: a cross-origin or
`//host` URL is a stored-XSS channel by itself. `htmx.config.selfRequestsOnly`
defaults to true in 2.x and blocks cross-origin requests, but it is client
configuration an app may turn off; the dialect adds a same-origin
requirement at the slot. A plain string is checked by [`Html.local_href`]
(section 3.4): relative references only. A deliberate cross-origin URL is a
`SafeUrl` from [`Html.href`] or [`Html.trust_url`], which passes unchanged. The
whole-value and part rules are those of `href`.

History URLs (`url_local`): `hx-push-url`, `hx-replace-url`. Their value is
`true`, `false`, or a URL. A string slot of `"true"` passes `local_href`
(it is a relative reference) and comes out as `true`, which is what htmx
reads. `javascript:` is refused by the same function.

Extension URLs (`url_local`): `sse-connect`, `ws-connect` (htmx-ext-sse and
htmx-ext-ws; assets.md section 4 vendors the SSE extension for v1, and the
`ws-connect` entry costs nothing). `hx-sse` and `hx-ws` were
removed in 2.0 and are not listed.

Code (`code`, always on, refused with a slot): `hx-on` (the 1.x
multi-line form, still read), and every attribute starting `hx-on`:
`hx-on:click`, `hx-on::after-request` (the `::` shorthand for `htmx:`),
`hx-on--after-request` (the dash form for HTML that cannot carry colons).
The prefix rule `hx-on` matches them all, as the HTML rule `on` does.
`hx-vars`: htmx 1.x evaluated its value as JavaScript by default; 2.0
removed it (verify against the pinned file), and the entry stays so an
older page's slot is refused. `hx-trigger`: the grammar allows a filter
in brackets, `click[ctrlKey && target.matches('.x')]`, which htmx
evaluates with `new Function`; a slot anywhere in the value is therefore
code. Refuse it. Triggers are static in practice; a data-driven `every`
interval is a number the author can compute into one of a few literal
variants. This is the largest ergonomic cost in the table and it is
deliberate. (Open question 3.)

JSON (`json`, the whole value, `Html.SafeJson` only): `hx-vals`,
`hx-headers`, `hx-request`. htmx treats a value with a `js:` or
`javascript:` prefix as code and evaluates it (when `allowEval` is on);
otherwise it parses JSON, wrapping a value that does not start with `{` as
`{...}`. A `SafeJson` is JSON text, which cannot begin with those prefixes
(no JSON text starts with `j`), so a slot cannot become code; a literal
`js:` value written in the template is the author's own code, as a literal
`onclick` is. Mixed literal and slot (`'{"id": {{.id}}, "x": 1}'`) is
refused: tracking JSON inside an attribute would be a second tokenizer.
The whole-value rule is what makes SafeJson the right granularity.

Selectors (`selector`): `hx-target`, `hx-select`, `hx-select-oob`,
`hx-include`, `hx-indicator`, `hx-disabled-elt`, `hx-sync`, `hx-swap` (its
`scroll:`/`show:` modifiers take selectors and `swap:`/`settle:` take
times), `hx-swap-oob` (`outerHTML:#sel`), and by prefix `hx-target-`
(htmx-ext-response-targets: `hx-target-422`, `hx-target-error`). These are
not code, but a selector chosen by data retargets where a response lands.
Both shapes of selector use are handled by one rule: a slot is allowed only
inside an identifier introduced by `#` or `.` (`#row-{{.id}}`,
`.tab-{{.name}}`, `closest #card-{{.id}}`), and the slot's value is escaped
as CSS identifier text (section 4.2). A slot at the start of the value
(`hx-target="{{.sel}}"`), after a combinator, a quote, `=` or `:` is
refused. Attribute selectors with data, `[data-id="{{.id}}"]`, need a CSS
string escaper and are not supported in v1; use `#row-{{.id}}`. (Open
question 4.)

Plain attributes (no rule; a slot is attr-escaped text): `hx-confirm` and
`hx-prompt` (shown in a dialog as text), `hx-boost`, `hx-params`,
`hx-encoding`, `hx-ext`, `hx-history`, `hx-history-elt`, `hx-preserve`,
`hx-disable`, `hx-disinherit`, `hx-inherit`, `hx-validate`, `hx-replace-url`
is above, `sse-swap`, `sse-close`, `ws-send`. The test in section 2.4 lists
them so an unclassified `hx-*` name fails the build of the dialect.

`hx-swap-oob` value `true` is a literal in practice; see the OOB pattern in
section 6.

`hx-boost` on `<a>` and `<form>` turns ordinary navigation into AJAX;
`href` and `action` stay governed by the ordinary URL rules.

### 2.2 `data-hx-*` and normalization

`data-hx-get` is read as `hx-get` by htmx. `classify` strips `data-` when
the remainder is in a family. The base rule `on` does not match
`data-hx-on:click`, so normalization has to be part of `classify`, not an
afterthought: a test compiles `data-hx-on:click="{{.x}}"` and
`DATA-HX-ON--click` and requires a refusal.

### 2.3 What stays the author's problem

- A literal `hx-on:click="doThing()"` compiles, like a literal `onclick`.
  CSP without `unsafe-eval` breaks htmx's `new Function` use (hx-on, trigger
  filters, `js:` values) entirely; input.md section 10 owns the CSP
  recommendation, and the configuration `Htmx.head` writes (section 6.6)
  turns `allowEval` off by default.
- `hx-swap` modifiers and `hx-params` values are plain text or selector
  identifiers; they change behavior, not execution.
- Inline `<script>` in swapped HTML: htmx executes script tags in swapped
  content when `allowScriptTags` is true (the default). The config meta
  sets it false. A response fragment that includes user data goes through
  the same escaping as a full page; no new trust boundary.

### 2.4 Keeping the table honest

`cosmic/web/htmx_dialect_test.tl` (it lives under `cosmic/web` because it
needs both the dialect and `cosmic.web.htmx`): reads the vendored
`vendor/htmx/dist/htmx.min.js` (assets.md section 4.2; a `reads` input
declared in the test's [`Test.policy`]), extracts every `hx-[a-z-]+`
token, and requires each to be classified in the dialect's `exact`,
covered by a prefix, or listed in the dialect's `plain` list (a field of
`Def` used by this test only). Bumping htmx adds names to the pinned file
and the test fails until a person classifies them. `Def.targets` must equal
`Htmx.version`, the version string `cosmic.web.htmx` exports from the
vendored PIN (a second assertion).

## 3. URL-component escaping

### 3.1 The problem

`href="/a/{{.id}}"` and `hx-get="/items/{{.id}}?q={{.q}}"` are the common
shape and are refused today (markup.tl:1051). The slot is a piece of a
URL. Using [`Html.href`] on a piece is wrong in two directions: it would
accept `a/../../x` and `x?y#z` as pieces (structure injection), and it
passes `javascript:` only as a whole.

### 3.2 One escaper for all components

`Html.url_part(s)` percent-escapes every byte except the unreserved set
(`A-Z a-z 0-9 - . _ ~`), exactly as [`Url.escape`] (cosmic/url.tl:86) does
(the two agree on every byte except the whole values `.` and `..` of 3.3;
`Router:reverse` uses this same escaper, core.md section 5.7, and a test
pins the three together).
That is correct as a path segment, a query name or value, and a fragment
at once, because it encodes `/ ? # & = + : @ % space` and every byte of
0x80 and up. So the tracker does not need to know which component a slot
is in. Space is `%20`, which every query parser decodes as a space; `+` is
never produced. The component-tracking state machine that doc/roadmap.md:300-303
imagined is not needed; the roadmap entry is struck for URLs (it stays for
JS and CSS). The Slot name is `"urlpart"`, not `"urlseg"`, for that reason.

Why a slot cannot complete a scheme or change the host: the only literal
text before a part slot is the author's, and a part contains no `:`, `/`,
`\`, `@` or control byte, so `href="java{{.x}}"` cannot become
`javascript:` and `href="/{{.x}}"` cannot become `//host`. This is why
the existing `colon` and `rooted` text checks (markup.tl:160-168,
context.tl:163-168) are enough for the literal text *after* a slot, and why
nothing new is needed for text before one. The `href` allowlist applies
only to whole-URL slots and is untouched: when the scheme is literal it is
fixed.

Number slots: written with `tostring` (digits, `-`, `.`, `e`, `inf`,
`nan`: all unreserved), as the other helpers do (codegen.tl:15-17).

### 3.3 The dot-segment hole

`/users/{{.name}}` with name `..` is `/users/..`, which a browser
normalizes (WHATWG URL: `..`, `.%2e`, `%2e.`, `%2e%2e` all count) to `/`.
A user who can choose their name can redirect any link. Percent-escaping
cannot fix it, since `%2e%2e` normalizes too. The C escaper therefore
treats a value that is exactly `.` or `..` as unrepresentable and writes
`%252E` / `%252E%252E` (the percent sign itself escaped), so the server
decodes the literal text `%2E`, which matches no record and 404s. That is a
safe failure rather than a silent change to the link's target. It is
documented on [`Html.url_part`], with its limit: the escaper sees the value,
not the template, so author text next to the slot (`/a/.{{.x}}` with `.`)
can still make a dot segment. The compile-time check "literal text ending
in `.` or `/` is fine, ending `.` directly before a part slot is refused"
is cheap (one more `ident`-like bit) and is open question 2.

### 3.4 New C functions in core/html.c

Registered beside the existing ten (html.c module table) with metatables
for two new types, [`cosmic.html.SafeUrlPart`] and [`cosmic.html.SafeJson`],
created like the others (`cosmic_open_html`). Each new function is
`static` with a binding, and each needs a test that enters it
([`build/c_functions.tl`]).

- `url_part(s: string | number): SafeUrlPart`: as above. The same
  "plain input is its own escape" shortcut as `html_escape`
  (core/html.c:51-56).
- `raw_url_part(x): string`. `trust_url_part(s): SafeUrlPart` arrives with
  its first caller: an export nothing uses fails `fix --check`'s
  every-export-earned rule.
- `local_href(s: string): SafeUrl`: `s` if it is a relative reference
  (no scheme: a colon before the first `/`, `?`, `#` is refused), no C0
  control, DEL or edge space, and not beginning with two of `/` and `\`
  (reuse `url_allowed`'s scanning, core/html.c, with an empty scheme
  allowlist); else `about:invalid`. Refactor: `url_allowed` becomes
  `url_allowed(s, len, schemes)`.
- `escape_css_attr(s: string): SafeAttr`: section 4.2.
- `raw_json(x): string`; internal `trust_json(s)`, not exported through
  [`cosmic.html`] (section 5).

Teal in cosmic/html.tl:

```
record Html
  type SafeUrlPart = raw_html.SafeUrlPart
  type SafeJson = raw_html.SafeJson
end

function Html.url_part(s: string | number): Html.SafeUrlPart
function Html.url_query(pairs: {{string}}): Html.SafeUrlPart | nil, string
function Html.raw_url_part(x: Html.SafeUrlPart): string
function Html.local_href(s: string): Html.SafeUrl
function Html.escape_css_attr(s: string | number): Html.SafeAttr
function Html.json(value: any): Html.SafeJson | nil, string
function Html.json_text(text: string): Html.SafeJson | nil, string
function Html.raw_json(x: Html.SafeJson): string
```

`Html.url_query({{"q", "a b"}, {"tag", "x&y"}})` is `q=a%20b&tag=x%26y` as a
`SafeUrlPart`: names and values through the same escaper, joined with `=`
and `&`, order kept, a repeated name allowed (checkbox lists). It returns
`nil, reason` for a pair that is not two strings. It is how a query string
built by code goes into `href="/search?{{.query}}"`; its `&` is entity
escaped by the slot (`&amp;`), which the browser decodes. A map-shaped
convenience can be added when a caller wants sorted keys; not in v1.

A `SafeUrlPart` slot is not a whole-URL slot: it never goes through
`href`. Nothing in it can be a scheme because `:` is escaped.

### 3.5 Interaction summary

- `href="{{.u}}"` (fresh): whole URL, [`Html.href`] allowlist. Unchanged.
- `href="/a/{{.id}}"`: literal `/a/`, then a part. New.
- `href="{{.base}}{{.id}}"`: first a whole URL (fresh), second a part
  (not fresh). The second contains no `:` `/` `\`, so nothing the first
  allowed can be completed into a scheme or `//host` by it; the literal
  checks after the first slot still run.
- `hx-get="/items/{{.id}}"` (htmx dialect): same, class `url_local`:
  part after text, [`Html.local_href`] for a whole string.
- A `SafeUrl` in a part position is a type error (the helper accepts
  `string | number | SafeUrlPart`): a whole URL is not a part.
- `{{range}}` bodies are walked twice and `fresh` is already joined that
  way (context.tl:67-78): a part slot in a loop is `urlpart` on the second
  walk, and the first walk's `fresh` slot had to already agree. The
  existing walk-twice logic needs no change, but the test suite adds the
  case `<a href="{{range .l}}{{.}}{{end}}">` (refused or accepted as
  today, unchanged by this) and `<a href="/x/{{range .l}}{{.}}{{end}}">`
  (accepted, part).

## 4. Selector escaping

### 4.1 Why selectors need an escaper at all

A selector value in `hx-target` is parsed by `querySelector`. No script
runs, but an unescaped slot (`#row-{{.id}}` with id `x, body`) retargets a
swap onto another element, and with an HTML-returning endpoint that is
overwriting arbitrary parts of the page. Escaping the slot as CSS
identifier text makes it unable to end the identifier.

### 4.2 `Html.escape_css_attr`

The semantics are those of `CSS.escape` (CSSOM) restricted to what can
appear after `#` or `.`: bytes `[A-Za-z0-9_-]` and 0x80 and up pass; every
other byte becomes a backslash and its code point in lowercase hex and a
trailing space (`\2c ` for `,`); NUL becomes U+FFFD. A leading digit is
hex-escaped (`\31 `) even though the slot is usually mid-identifier:
over-escaping is harmless (`#row-\31 23` selects `row-123`) and the
escaper does not know where it is. The explicit space terminator is
always emitted: a following literal space (a descendant combinator) is
then a second space, so it still means a combinator. The result is then
HTML-escaped with `escape_attr` (a backslash becomes `&#92;`), so the
function returns a `SafeAttr` and the generated `_sel` is
`html.raw_attr(html.escape_css_attr(v))`. One C function, no new type,
because the output has only the one place it can go.

Not covered: the contents of a CSS string (`[data-id="..."]`), `:is()`
arguments, and namespace separators. A slot there is refused by the
`ident` rule, not escaped wrongly.

## 5. SafeJson

### 5.1 Type and constructors

`Html.SafeJson` is a userdata like the other safe types (user value is
the string, no operators, `__metatable = false`). It is JSON text.

- `Html.json(value)`: `Json.encode(value)` (cosmic/json.tl:458), then wrap
  with the internal `trust_json`. `nil, reason` when encoding fails
  (function, cycle, NaN: the message names the JSON Pointer).
- `Html.json_text(text)`: already-encoded text, wrapped only when
  `Json.check(text)` (json.tl:473) accepts it; else `nil, reason`.

There is deliberately no unchecked `trust_json`. For a type whose job is
"this is a JSON document, not code", validation is cheap and makes the
type stronger than the three trust-door types: the one unchecked door is a
C function that [`cosmic.html`] does not re-export, and the Teal constructors
are the only callers. The wrapping lives in Teal because the encoder is
`cosmic.json`, which [`cosmic.html`] already can `require` (it requires
[`cosmic.internal.html`] the same way, html.tl:33-41); the C part is the
type, `raw_json`, and the internal door.

### 5.2 In a slot

Class `json`, whole value, `html.SafeJson` only (a string or a table is a
type error naming the template line). Output is
`html.raw(html.escape(html.raw_json(v)))`: `"` becomes `&quot;`, so the
attribute round-trips through the browser to the original JSON text for
either quote style. JSON text from [`Json.encode`] contains no raw control
bytes. An example:

```
local vals = assert(Html.json({ id = item.id, kind = "note" }))
-- template: <button hx-post="/x" hx-vals='{{.vals}}'>
-- output:   hx-vals='{&quot;id&quot;:7,&quot;kind&quot;:&quot;note&quot;}'
```

`hx-headers` is the second major use: a CSRF token header on `<body>`
(`<body hx-headers='{{.csrf_headers}}'>` with
`{ ["X-CSRF-Token"] = token }`), which the CSRF middleware (input.md
section 8) reads. `hx-request` takes `{"timeout": 5000}`-style config.

JSON in `<script type="application/json">` (a common htmx page pattern)
needs `</script>`-safe encoding and is a `<script>` slot, which stays
refused (init.tl:79-82 roadmap); not part of this.

### 5.3 JSON for headers (HX-Trigger and friends)

HTTP header values are bytes, and `XMLHttpRequest.getResponseHeader` reads
them as Latin-1, so UTF-8 in a header becomes mojibake before htmx parses
the JSON. Header JSON must be ASCII with `\uXXXX` escapes. Small change to
an existing module: [`Json.EncodeOptions`] (json.tl:123) gains
`ascii: boolean` (default false), passed to the core's encoder (core/json.c), which writes every non-ASCII
character as `\uXXXX` escapes, beside `pretty` (json.tl:462-464 passes `opts.pretty, opts.max_depth` to
`raw.encode`; the third flag is one more argument). Built as the C
option; no Teal post-pass exists.

## 6. cosmic.web htmx support

New module `cosmic/web/htmx.tl` (name `cosmic.web.htmx`). It depends on
core.md's `Request` and `Response` types only through the accessors listed in
section 9.

### 6.1 Reading the request

```
local record Htmx
  record Request
    active: boolean          -- HX-Request: true
    boosted: boolean         -- HX-Boosted: true
    history_restore: boolean -- HX-History-Restore-Request: true
    target: string | nil     -- HX-Target (element id)
    trigger: string | nil    -- HX-Trigger (element id)
    trigger_name: string | nil -- HX-Trigger-Name
    current_url: string | nil  -- HX-Current-URL
    prompt: string | nil     -- HX-Prompt (hx-prompt answer)
  end

  request: function(req: Web.Request): Htmx.Request
  partial: function(req: Web.Request): boolean
end
```

`request` reads the lowercased headers (server.tl:48 gives headers by
lowercased name) and is pure; the middleware in 6.6 caches the record under
`Htmx.KEY`. `partial(req)` is the fragment predicate:
`active and not history_restore and not boosted`. History restore and
boosted navigations are both swapped into a full-page position and must be
answered with a full page. (htmx 2: a history cache miss re-requests the
URL with `HX-Request: true` and `HX-History-Restore-Request: true` and
expects a whole document. A boosted request swaps `<body>`; returning the
full page is the simple and correct answer.)

Every one of these is a client-controlled header. Documentation states it
in the function comment: they select a presentation, never authorize
anything. They are also not a CSRF defense by themselves. A cross-site
page cannot add custom headers to a simple request without a CORS
preflight, so `HX-Request: true` is in practice a weak signal, but the
CSRF middleware (input.md section 8) uses a token; `hx-headers` carries it.
`current_url` is untrusted text; [`Html.local_href`] it before using it as a
redirect.

### 6.2 Writing the response: `Htmx.Reply`

A builder record applied to a `Web.Response`, so a handler states effects
in one place and ordering of header writes does not matter:

```
record Htmx.Event
  name: string
  --- Becomes event.detail. nil sends an empty detail.
  detail: any
end

record Htmx.Location
  path: string
  target: string
  swap: string
  select: string
  source: string
  event: string
  values: any
  headers: any
end

record Htmx.Reply
  redirect: string | Html.SafeUrl   -- HX-Redirect
  location: string | Htmx.Location  -- HX-Location
  push_url: string | boolean        -- HX-Push-Url ("false" suppresses)
  replace_url: string | boolean     -- HX-Replace-Url
  refresh: boolean                  -- HX-Refresh
  retarget: string                  -- HX-Retarget (a CSS selector)
  reswap: string                    -- HX-Reswap
  reselect: string                  -- HX-Reselect
  trigger: {Htmx.Event}             -- HX-Trigger
  trigger_after_swap: {Htmx.Event}  -- HX-Trigger-After-Swap
  trigger_after_settle: {Htmx.Event} -- HX-Trigger-After-Settle
end

apply: function(resp: Web.Response, reply: Htmx.Reply): Web.Response | nil, string
```

`apply` returns `nil, reason` for a value it refuses, never writes a
partial set, and never raises on data. Rules:

- Event lists: if no event has a detail, the header is the plain
  comma-separated names (`showMessage, closeModal`); otherwise a JSON
  object `{"showMessage": {"level": "info"}, "closeModal": {}}` through
  [`Json.encode`] with `ascii = true` (section 5.3). An event name with a
  comma, a quote, a control byte or empty is refused.
- URL fields: `redirect` is navigated to by script (`window.location`), so
  a `javascript:` URL here is an XSS and an attacker-chosen URL is an open
  redirect. A `string` goes through [`Html.local_href`] and a value that
  comes back as `about:invalid` is refused (`nil, "htmx: redirect is not a
  same-origin reference"`); an external destination is a `SafeUrl` (made by
  [`Html.href`], an allowlist, or [`Html.trust_url`]). The same for `location`
  (its `path`), `push_url` and `replace_url` (browsers refuse cross-origin
  `pushState`, but the check is free). `push_url = false` writes the
  literal `false`.
- `retarget`, `reselect`: any non-empty string with no CR, LF or NUL; the
  server's header validation (server.tl:73) would reject those later, but a
  helper's error names the field.
- `reswap`: must start with one of `innerHTML outerHTML textContent
  beforebegin afterbegin beforeend afterend delete none` (htmx 2) then
  optional modifiers; else refused.
- `location` as a `Htmx.Location` is JSON (`ascii = true`), as htmx's
  documented object form.

One-line helpers over `apply` for the common cases, so handlers read:
`Htmx.redirect(resp, "/items")`, `Htmx.push_url(resp, url)`,
`Htmx.trigger(resp, "itemSaved", { id = 7 })`, `Htmx.retarget(resp, "#errors",
"innerHTML")`, `Htmx.refresh(resp)`. Each is `apply` with one field.

### 6.3 Redirects for htmx requests

An `XMLHttpRequest` follows a 302 by itself and htmx would swap the
target page's full HTML into the target element. For an htmx request the
redirect has to be a 200 (or 204) with `HX-Redirect`:

```
Htmx.redirect_to(req, url): Web.Response | nil, string
```

If `Htmx.request(req).active` and not `boosted`: status 200, empty body,
`HX-Redirect: url`. Else: the ordinary redirect response of the core
section (303 for POST so the next request is a GET). For a boosted
request a 303 is right: htmx's XHR follows it and swaps the body, and
`HX-Push-Url` is set from the final URL by htmx (the response URL is used
for history). Same URL validation as 6.2.

### 6.4 Fragment versus full page; layout composition

Template composition already exists as stages that name another template's
`render` (init.tl:30-33). Three patterns, in order of recommendation:

1. **Same row template everywhere.** A fragment is a template that takes
   its own record; a list page includes it per element; the POST that adds
   or edits a row returns just it.

   ```
   -- items/row.tmpl:   {{type Row from items.views}}
   --   <tr id="row-{{.id}}"> ... <button hx-delete="/items/{{.id}}"
   --        hx-target="#row-{{.id}}" hx-swap="outerHTML">Delete</button></tr>
   -- items/list.tmpl:  {{use htmx}} ... {{range .rows}}{{. | items.row.render}}{{end}}
   ```

   (`SafeHtml` from a stage lands in a text slot as it is, init.tl:40-46.)

2. **Fragment or page by header.** One handler, two answers:

   ```
   Htmx.page(req: Web.Request, content: Html.SafeHtml,
     wrap: function(Html.SafeHtml): Html.SafeHtml): Web.Response
   ```

   Partial request: `content` as `text/html; charset=utf-8`. Otherwise
   `wrap(content)`, usually `layout.render({ title = ..., body = content })`.
   Both answers carry `Vary: HX-Request, HX-History-Restore-Request,
   HX-Boosted` (a browser or proxy that caches `/items` once as a fragment
   would otherwise show the fragment on Back, the classic htmx caching
   bug). Each token is added with `Web.add_header(resp, "Vary", token)`
   (core.md section 3), which merges it into any existing `Vary` line.
   `Htmx.page` also sets `Cache-Control: no-cache` unless the response
   already has one: validators still work (ETag/304 per representation),
   and Back never shows a stale fragment.

3. **Always full, select on the client.** `<body hx-boost="true">` for
   navigation, and for in-page swaps `hx-select="#main"` with the full
   page returned. No `Vary`, no second code path, full-page bytes on each
   swap. Recommended starting point for apps with cheap layouts; pattern 2
   is for when layout cost or size matters. `hx-boost` plus full pages
   covers history restore and Back with no work.

A fragment that changes the title includes a `<title>` element; htmx 2
reads it out of the response and sets `document.title`. `<title>{{.t}}</title>`
is an `rtext` slot (escaped, no markup), fine in a fragment.

### 6.5 Out-of-band swaps

Out-of-band content is more top-level elements in the response with
`hx-swap-oob="true"` (or `outerHTML:#sel`), composed with [`Html.concat`]:

```
local main = row.render(r)
local badge = cart_badge.render(cart)   -- <span id="cart-count" hx-swap-oob="true">{{.n}}</span>
return Response.html(Html.raw(Html.concat({ main, badge })))
```

No new API: the types already say each part is markup. Two htmx rules go
in the docs: an OOB element must be a top-level child of the response, and
a table row or cell OOB must be wrapped in `<template>` (the HTML parser
drops a bare `<tr>` outside a table). A test checks that
[`Html.concat`] of two template outputs is what a client expects.

### 6.6 Middleware and `Htmx.head`

```
Htmx.middleware(): Web.Middleware
```

`function(Handler): Handler` (core.md section 7): parses `Htmx.request(req)`
once and stores it under the exported key `Htmx.KEY` (`Web.Key<Htmx.Request>`,
`req:set(Htmx.KEY, ...)`; core.md section 2.3); if the reply is for an htmx
request and carries a redirect status (301/302/303/307/308) and no body it
cannot be served to htmx correctly, rewrites it to 200 with `HX-Redirect`
(6.3) so a handler that returns a plain redirect keeps working; nothing
else. It is optional; every function above also works without it.

```
record Htmx.HeadOptions
  --- Also load the SSE extension. The page still writes `hx-ext="sse"`
  --- (the extension registers itself by name).
  sse: boolean
  --- Overrides of the configuration below; nil keeps each default.
  config: Htmx.Config   -- fields: allow_eval (false), allow_script_tags
                        -- (false), history_cache_size (htmx's default)
  --- A CSP nonce for the tags (`req:get(Headers.NONCE)`, input.md section
  --- 10); also written as the config's `inlineScriptNonce`.
  nonce: string
  --- URL prefix; default "" (the files are served under "/_web/").
  prefix: string
end

Htmx.head(opts?: Htmx.HeadOptions): Html.SafeHtml
```

`Htmx.head` is the one place the page head for htmx is written: the
`<meta name="htmx-config" content='...'>` first, then
`<script src="/_web/htmx-2.0.11.min.js" integrity="sha384-..."
crossorigin="anonymous" defer></script>`, then the same for the SSE
extension when `sse` is set. The paths, versions and SRI values are the
vendored files' (assets.md sections 4.3 and 4.4, read through
`Store.web_asset`); nothing in the tag comes from user data, so the
function's [`Html.trust`] is justified and is the only one in `cosmic.web`
for it. `crossorigin` is harmless on a same-origin script and keeps the tag
valid if an app later serves the file from a CDN. A layout that writes its
own tags uses `Htmx.path()` and `Htmx.integrity()`; `Htmx.version` is the
version string the dialect's test ties to (2.4).

The configuration, defined here and nowhere else (assets.md and input.md
refer to it). The content is `Html.json(...)`, entity-escaped:

```
{ "allowEval": false,
  "allowScriptTags": false,
  "includeIndicatorStyles": false,
  "selfRequestsOnly": true,
  "responseHandling": [
    {"code": "204", "swap": false},
    {"code": "[23]..", "swap": true},
    {"code": "422", "swap": true, "error": true},
    {"code": "[45]..", "swap": false, "error": true},
    {"code": "...", "swap": false} ] }
```

- `allowEval: false` breaks literal `hx-on`, trigger filters and `js:` values,
  and is what lets a CSP omit `'unsafe-eval'`; an app that wants them sets
  it true in `HeadOptions.config` and adds `'unsafe-eval'` to its CSP
  knowingly. `allowScriptTags: false` stops htmx running `<script>` in
  swapped HTML, so a server rendering user content does not rely on
  escaping alone.
- `includeIndicatorStyles: false`: htmx otherwise injects a `<style>` for
  `.htmx-indicator`, which a strict `style-src` blocks. The rules ship as
  `Htmx.indicator_css(): string` for the app's stylesheet (or the
  `static/` file the layout links).
- `selfRequestsOnly: true` is the htmx 2 default, written explicitly so
  that nothing loosens it by accident; a cross-origin `hx-get` is refused by
  the client as well as by the dialect's `url_local` rule.
- `responseHandling` swaps 2xx and 422 and not 204, and marks 422 and the
  other 4xx/5xx as errors (`htmx:responseError` still fires for 422).
- `nonce`, when given, adds `inlineScriptNonce`; `HeadOptions.config` can set
  `history_cache_size` (the `historyCacheSize` key). No other key is
  touched.

These keys are htmx 2.0 `htmx.config` names; the dialect test (2.4) also
asserts each key appears in the vendored file.

### 6.7 Errors htmx swaps

htmx's defaults (2.x): 2xx swaps (204 does not); 3xx are followed by the
XHR; 4xx and 5xx are not swapped and fire `htmx:responseError`. A form
that re-renders with validation errors therefore cannot just return 400.

Recommendation:

1. **Validation errors: 422 with the form re-rendered**, swapped because
   the configuration `Htmx.head` writes (6.6) marks 422 as `swap: true,
   error: true`. The status is honest (logs, API clients, tests), the form
   fragment replaces itself with errors, and `htmx:responseError` still fires
   for anyone listening. Input that fails a route's specs is a 400 in v1
   (core.md section 6.4; whether it should be 422 is the overview's open
   question 1), and 400 is not swapped; so a form route supplies
   `on_invalid`, which core calls with the request and the `Input.Invalid`
   (input.md section 2), and which renders the form fragment with the errors
   and answers 422. The same hook can branch on `Htmx.request(req).active`
   to give an htmx request the fragment and a browser or API client the
   default page or problem body.
2. **Fallback without `Htmx.head`'s meta tag: 200 with the form
   re-rendered.** Cheap and works with stock htmx, wrong for non-browser
   clients. Offered as the documented alternative for people who cannot set
   the meta.
3. **Server and not-found errors** stay unswapped (the default), and the
   exception layer (core.md section 8.2) for an htmx request adds `HX-Trigger:
   {"cosmic:error": {"status": 500}}` (ASCII JSON) so the page shows a
   toast through one `htmx:...`-free listener. htmx processes `HX-Trigger`
   before it decides to swap; verify this against the pinned file before
   relying on it (open question 5). `HX-Retarget` on such a response is
   useless when the status is not swapped.
4. **Not the `response-targets` extension** in v1: it is another asset to
   pin and its attributes (`hx-target-422`) are classified by the dialect
   anyway, so an app that adds it works.

### 6.8 Polling and 286

`hx-trigger="every 2s"` polls; a response with status 286 is swapped and
stops the poll. `Htmx.stop_polling(body?)` returns a 286 response. The
server's reply check accepts statuses 200-999 (server.tl:336); the reason
phrase for 286 comes from [`wire.reason`], which has none; to be confirmed
in wire.tl: an unknown status gets a generic reason ("Stop Polling" by
convention). A poll that wants to continue returns 200.

### 6.9 History

`hx-push-url` pushes a snapshot; htmx stores snapshots of the DOM in
`localStorage`. A page showing private data must opt out with
`hx-history="false"` on an element (or the whole body), and an app should
clear the cache on logout (`htmx.config.historyCacheSize = 0` is in
`Htmx.Config` as `history_cache_size`, default unchanged). The docs list this
under private pages. The request side is the
`history_restore` flag in 6.1.

## 7. url_for in templates

Needs: `hx-get="{{...}}"` for a named route with its params, with the
escaping rules above, no hidden global.

Recommended: **stages over an application module**. A route table is a
value in code; the application keeps it in a module (`app.routes`) that
exports it, and a small typed module of builders next to it:

```
-- app/urls.tl
local Routes = require("app.routes")
local Html = require("cosmic.html")
local urls = {}
function urls.item(i: Item): Html.SafeUrl
  return Html.trust_url(assert(Routes.app:url_for("item", { id = i.id })))
end
return urls

-- template
<a href="{{.item | app.urls.item}}">  <button hx-delete="{{.item | app.urls.item}}">
```

Reasons:

- A stage already is "a function by import path" and a template already
  composes that way (parse.tl:12-17); no grammar and no engine.
- It is typed: the builder takes the record it needs; a missing field is a
  type error at the stage, not an empty hole.
- No hidden global: the module value is the router, as everywhere else.
- `Router:reverse(name, params, query?)` and `app:url_for` (core.md section
  5.7) percent-escape params with exactly the escaper [`Html.url_part`] uses
  (one C escaper; [`Url.escape`] and [`Html.url_part`] agree on every byte but
  the `.`/`..` case of 3.3, and a test pins the three together on a table of
  hostile values, section 8), refuse a missing param by `nil, reason`, and
  honor Mount prefixes, so a sub-app mounted under `/admin` produces
  `/admin/items/7`. A mount with a reverse resolver, such as the static
  files', answers `url_for("static", { path = "app.css" })` with the
  fingerprinted URL (assets.md section 3.4).
- A builder that returns a plain `string` instead of `SafeUrl` is also fine
  for a `url` slot (checked by [`Html.href`], `//` refused). In an htmx
  attribute (`url_local`) a plain string is checked by [`Html.local_href`].
  `trust_url` here asserts that `url_for` escaped the parts, which is the
  one place a human vouches.

Rejected: a `{{url "name" ...}}` action. The route table is built at
run time from code, so the compiler cannot check a route name or its
params; the action would be a stringly typed hole that the stage form
does not have. If file-based routing later generates the table, the same
generator can emit a typed `urls.tl` of builders, which is the right
place for compile-time route checking (roadmap, with the routing layer).

Multi-parameter routes: the stage takes one value, so a builder takes the
record that carries its params (`i: Item`, or a `{id, slug}` view record),
as a stage taking one dot always has.

## 8. Tests

Conventions: `*_test.tl`, top-level `local function test_*`, no top-level
`return`, small regressions that fail for the bug. Tests that start a
server declare `Test.policy { loopback = { "127.0.0.1" } }` and talk to it
with [`cosmic.http`]; the template and html tests need no policy.

[`cosmic/html_test.tl`] (extended) and [`cosmic/html_fuzz_test.tl`]:

- `url_part` equals [`Url.escape`] for every byte value 0-255 and for UTF-8
  strings (an oracle test between a C function and a Teal one); `.` and
  `..` give the `%25` forms; the output matches `^[A-Za-z0-9._~%-]*$`;
  `Url.unescape(url_part(s)) == s` except for the two dot cases.
- A fuzz property: a `url_part` placed in `/a/<p>/b?<p>#<p>` parses with
  [`Url.parse`] to a path of three segments, a query of the exact value and a
  fragment of the exact value. (Fuzz runs only when `FUZZ_ITERS` > 0;
  properties `requires` the labels they exercise, per AGENTS.md.)
- `url_query` structure: names and values with `& = # + %` round-trip.
- `local_href`: relative passes, `http:`, `javascript:`, `//h`, `\\h`,
  tab/newline, edge space, colon-before-slash all `about:invalid`.
- `escape_css_attr`: a reference CSS unescaper in the test file (hex
  escapes with space terminator, NUL) round-trips every byte; no output
  byte is `,`, `>`, ` ` (other than as an escape terminator after hex),
  `"`, `'`, `<`, `&`, `[`, `]`, `(`, `)`.
- `json` and `json_text`: object, array, string beginning `js:` (encoded as
  a quoted string), an invalid document refused, NaN refused, never begins
  with `j`. The type is opaque (a table or string is a type error; follow
  the existing opaqueness tests).

`cosmic/template_dialect_test.tl` (new), using [`Template.compile`]:

- `{{use htmx}}` accepted after `{{type}}`, before or after `{{mode}}`;
  refused in `{{mode text}}`; unknown name refused with line and column;
  duplicate refused.
- Without `{{use}}`: `hx-get="{{.u}}"` compiles as `attr` (unchanged
  behavior); `hx-on:click="{{.x}}"`, `hx-on::after-request`,
  `hx-on--x`, `hx-on`, `data-hx-on:click`, `hx-vars` are refused with and
  without `use`.
- With `use htmx`: `hx-get="{{.u}}"` is `url_local`; `hx-get="/items/{{.id}}"`
  is `urlpart`; `hx-get="//{{.h}}"` literal compiles (the author wrote it)
  but `hx-get="{{.u}}"` with the string `//evil` renders `about:invalid`
  (a generated-code assertion plus a run of the generated function when the
  test can load it, as template_build_test does).
- `hx-vals='{{.v}}'` needs `SafeJson` (type error test via the build path in
  template_build_test.tl); `hx-vals='{"a":{{.v}}}'` refused; text after the
  JSON slot refused; two JSON slots refused.
- `hx-trigger="click[{{.x}}]"` and `hx-trigger="{{.t}}"` refused.
- Selector: `hx-target="#row-{{.id}}"` compiles to `_sel`;
  `hx-target="{{.sel}}"`, `hx-target="body, #x{{.id}}"` after a comma,
  `hx-target="[data-id='{{.id}}']"` refused; `hx-target="#a-{{.x}}{{.y}}"`
  compiles; the `{{if}}` arms agree/disagree on `ident`.
- Generated output renders: a compiled-and-loaded template with hostile
  values (`"><script>`, `,body`, `../`, ` `, non-UTF-8) produces
  output that, parsed by the repo's HTML tokenizer test helper
  (cosmic/template_html5lib_tokenizer_test.tl has one), yields one tag and
  one attribute with the expected decoded value.
- A property in `template_fuzz_test.tl`: for random attribute names drawn
  from the dialect's names, case variants, and `data-` prefix variants, a
  compile that succeeds with a slot in a `code`-class attribute is a bug.
- The existing suites (template_go_test, html5lib tree and tokenizer
  tests, markup_test) must be unchanged except where a previously refused
  URL part now compiles; update those expectations in the same change.
- `cosmic/template_dialect_htmx_test.tl`: the pinned-file completeness test
  of 2.4.

`cosmic/web/htmx_test.tl`:

- `request` on header maps: each flag and value; absent headers; values other
  than `true`; `partial` truth table (active, boosted, history_restore).
- `apply`: each field becomes the right header; events with and without
  details; non-ASCII detail is `\u` escaped; `redirect` with `javascript:`,
  `//host`, a tab, a newline is `nil, reason`; a `SafeUrl` external
  passes; bad `reswap` refused; no partial writes on refusal (headers
  unchanged).
- `redirect_to` for plain, htmx, boosted requests.
- `page`: partial returns content bare; full returns `wrap`; `Vary`
  includes all three names and merges with an existing one; history restore
  gets the full page.
- `Htmx.head`: the meta content parses back with [`Json.decode`] and equals
  the section 6.6 configuration (including the 422 rule, `allowEval` false
  and `includeIndicatorStyles` false); the script tag's `integrity` equals an
  independent SHA-384 of the vendored file; `sse = true` adds the extension's
  tag; a nonce appears on the tags and as `inlineScriptNonce`.
- `Router:reverse`, [`Html.url_part`] and [`Url.escape`] agree byte for byte on
  every byte value 0-255 and a table of hostile strings (the `.`/`..`
  exception included): the test that pins the one escaper (it needs
  `cosmic.web` and [`cosmic.html`], so it lives in `cosmic/web`).
- An integration test over loopback (`Test.policy { loopback = ... }`)
  runs a `cosmic.web` app with a route, sends requests with and without
  `HX-Request`, `HX-Boosted` and `HX-History-Restore-Request`, and checks
  the body, status, `Vary` and `HX-Redirect` headers on the wire.

C functions: every new function in core/html.c is entered by the tests
above; `bin/cosmic fix` runs the C rules (core/html.c is checked: the
`url_part` buffer handling follows `html_escape_attr`'s pattern, an
`luaL_Buffer` with only `luaL_addvalue` above it); none of the new
functions is an allocation-failure path beyond the buffer, which
core/allocation_test.tl already walks for the module.

Docs: `bin/cosmic docs cosmic.html` for the new functions; init.tl:66-68,
the markup.tl header, doc/plans/template.md "As built" bullets (URL slot
rule, the dialect section), and doc/roadmap.md:296-303 are updated in the
same change.

## 9. What this file uses of the others

- Request (core.md section 2): `req.headers` keyed by lowercased name
  (server.tl:48), `req:get(KEY)`/`req:set(KEY, v)` for the one key it adds
  (`Htmx.KEY`); the htmx headers are single-valued, so the `", "` join does
  not matter here.
- Response (core.md section 3): `Web.html`, `Web.redirect(url, opts?)` and
  `Web.add_header` (which merges `Vary` and appends `Set-Cookie`); the
  widened `Reply.headers` of core.md section 13.1.
- Router (core.md section 5.7): `Router:reverse(name, params, query?)` and
  `app:url_for`, with per-segment escaping equal to [`Html.url_part`] and Mount
  prefixes included; and the reserved prefix `/_web/` where the vendored
  files are served.
- Middleware shape is `function(Handler): Handler` (core.md section 7).
- Routes' `on_invalid` (core.md section 6.4) and `Input.Invalid` (input.md
  section 2) for the 422 re-render of 6.7.
- Assets (assets.md sections 4.2 to 4.4): the vendored `htmx.min.js` and
  its path under `vendor/`, the version string, and the SRI values, read
  through `Store.web_asset`.
- Security (input.md sections 8 and 10): CSRF token delivery via
  `hx-headers` (this file supplies `SafeJson`), the CSP `script-src` /
  `style-src` choices that follow from `allowEval` and indicator styles, and
  `Headers.NONCE`.

## 10. Order of work

1. `cosmic.html`: `url_part`, `SafeUrlPart`, `url_query`, `local_href`,
   `escape_css_attr`, `SafeJson`, `json`, `json_text` (C and Teal) with
   tests. Independent of everything else.
2. Template: slot kinds, codegen helpers, markup `urlpart` (struck TODO at
   markup.tl:1052), tests. This alone makes `href="/a/{{.id}}"` work.
3. Dialect plumbing: `{{use}}`, `Dialect`, registry, `ident`/`sole`
   places; `html` base dialect holding the always-on `hx-on` refusals.
4. The `htmx` dialect data and its tests, including the pinned-file test
   once the vendored file exists (assets.md section 4.2).
5. [`Json.EncodeOptions.ascii`] (core/json.c and json.tl).
6. `cosmic.web.htmx` once the core types exist; `Htmx.head` once the
   vendored files and `Store.web_asset` exist (assets.md section 4).

## 11. Open questions

1. Should the always-on `hx-on*`/`hx-vars` refusal also ship without
   `{{use htmx}}`? Decided: yes (../web.md, decision 9). It makes
   already-compiling templates with a slot in `hx-on:*` stop compiling,
   which is the point; the tree has none (grep of cosmic/ and doc/ shows
   only comments).
2. Dot-segment next to a part slot: refuse a literal `.` immediately
   before a `urlpart` slot at compile time? Recommend yes, a small check
   (one boolean on Place set by the value scanner, like `rooted`), because
   `%252E` only covers the case where the whole value is dots. Cost: a
   rare literal like `/v1.{{.minor}}` is refused; the author writes
   `/v1/{{.minor}}` or builds the URL in a stage.
3. Refuse every slot in `hx-trigger`? Recommend yes in v1. A later
   `SafeTrigger` (a record that renders a trigger spec from typed fields:
   event, delay, `every` interval, no filter) would cover data-driven
   intervals without a code escaper.
4. Attribute selectors with data (`[data-id="{{.id}}"]`) and a slot that is
   a whole selector from trusted code. Recommend leaving both refused in v1
   and adding a CSS string escaper beside the JS and CSS escapers on the
   roadmap (the same item), plus a `SafeSelector` typed value if the whole-
   selector case is asked for.
5. Does htmx 2.0.x process `HX-Trigger` response headers on a response that
   is not swapped (4xx/5xx)? From memory it does (the header handlers run
   before `shouldSwap` is decided), but this must be confirmed against the
   pinned file before the exception layer's `HX-Trigger` (6.7) depends on it. Same check for
   `hx-vars` removal and for the `responseHandling` option names.
6. [`Html.local_href`] as the default checker for htmx request URLs, versus
   reusing [`Html.href`] plus relying on `selfRequestsOnly`. Recommend
   `local_href`: an app that turns `selfRequestsOnly` off to call an API
   keeps the template-level guard, and passes a `SafeUrl` where it means it.
7. Should `Htmx.page` set `Cache-Control: no-cache`? Recommend yes by
   default (it prevents the fragment-on-Back bug even when a proxy ignores
   `Vary`), overridable by the handler setting its own.
8. [`Json.EncodeOptions.ascii`] in the core encoder (section 5.3) versus a
   Teal post-pass. Decided: the core option, one flag in the C
   encoder; there is no Teal fallback.
9. Names: `urlpart` vs `url_part`; `url_local` vs `local_url`; whether
   `Html.json` should live on [`cosmic.html`] (needs `cosmic.json`) or on
   `cosmic.web`. Recommend [`cosmic.html`], because the template's generated
   code requires only [`cosmic.html`] and the type must be creatable by any
   handler, with or without `cosmic.web`.

`TODO:` comments this work leaves in the code (to be written when the code
is):

- In the htmx dialect: attribute selectors with data and a whole-selector
  hatch, waiting on a CSS string escaper (roadmap item for JS and CSS).
- In the htmx dialect: `hx-trigger` slots, waiting on a `SafeTrigger`.
- In the template's `ident` rule: `\`-escaped identifiers written in the
  literal text are treated as the end of an identifier; waiting on a
  CSS-aware scan if anyone writes them.

[`build/c_functions.tl`]: ../../../build/c_functions.tl
[`Context.annotate`]: ../../../cosmic/template/context.tl
[`cosmic.html.SafeJson`]: ../../../cosmic/html.tl
[`cosmic.html.SafeUrlPart`]: ../../../cosmic/html.tl
[`cosmic.html`]: ../../../cosmic/html.tl
[`cosmic.http`]: ../../../cosmic/http/init.tl
[`cosmic.internal.html`]: ../../../cosmic/internal/html.d.tl
[`cosmic.template`]: ../../../cosmic/template/init.tl
[`cosmic/html_fuzz_test.tl`]: ../../../cosmic/html_fuzz_test.tl
[`cosmic/html_test.tl`]: ../../../cosmic/html_test.tl
[`Html.concat`]: ../../../cosmic/html.tl
[`html.escape`]: ../../../cosmic/internal/html.d.tl
[`Html.href`]: ../../../cosmic/html.tl
[`Html.local_href`]: ../../../cosmic/html.tl
[`Html.SafeUrlPart`]: ../../../cosmic/html.tl
[`Html.trust_url`]: ../../../cosmic/html.tl
[`Html.trust`]: ../../../cosmic/html.tl
[`Html.url_part`]: ../../../cosmic/html.tl
[`Json.decode`]: ../../../cosmic/json.tl
[`Json.encode`]: ../../../cosmic/json.tl
[`Json.EncodeOptions.ascii`]: ../../../cosmic/json.tl
[`Json.EncodeOptions`]: ../../../cosmic/json.tl
[`Template.compile`]: ../../../cosmic/template/init.tl
[`Test.policy`]: ../../../cosmic/test.tl
[`Types.Template`]: ../../../cosmic/template/types.tl
[`Url.escape`]: ../../../cosmic/url.tl
[`Url.parse`]: ../../../cosmic/url.tl
[`wire.reason`]: ../../../cosmic/http/wire.tl
