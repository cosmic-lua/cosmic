# cosmic.web: assets, vendored htmx, SSE and runtime

Part of the cosmic.web design: see ../web.md for the overview, decisions and phasing.

This file covers static assets (the project convention, the build, the
store, `StaticFiles`), the pinned htmx and its SSE extension, server-sent
events with an in-process channel and hub, the runtime facts a web author
must know (cooperative tasks, SQLite, shutdown, a dev loop), and the one
server seam WebSockets will need.

core.md owns the router, `Request`/`Response`, middleware, `url_for` and
the shutdown mechanism; input.md the sessions, CSRF, CORS and security
headers; templates.md the `htmx` dialect and `Htmx.head`. Where this file
needs something from them it says what in a sentence and cites the file and
section.

Code is cited as `path:line` from the tree at the time of writing.

## 0. Decisions at a glance

- Static files live in a top-level `static/` directory of a project
  (`Layout.static`). They are staged by the build like a `.tmpl`, recorded
  with their SHA-256, and carried in the project's one executable in the
  `payload` table the schema already reserves
  (build/schema.tl:74-78, doc/design.md:412). They are read at run time
  through the project's database; a dev mode reads the directory instead.
- `StaticFiles` (`cosmic.web.static`) is a `Mount`-able handler built on a
  new `Assets` source (`cosmic.web.assets`). It answers GET and HEAD with strong ETags from the build-time
  hash, `If-None-Match` through `Server.none_match`, `Range` through
  `Server.range`, a stored gzip variant, immutable fingerprinted URLs
  (`/static/app.3f9a1c8e2b.css`), and refuses traversal through
  `Url.segments`.
- htmx 2.0.11 (`dist/htmx.min.js`, 0BSD) and htmx-ext-sse 2.2.4
  (`dist/sse.min.js`, 0BSD) are vendored as `vendor/htmx/` and
  `vendor/htmx-ext-sse/` with PINs, built into the binary's own database
  (a new `web_assets` table beside `zoneinfo`) and served by `cosmic.web`
  at versioned fixed paths under the reserved `/_web/` prefix with a SHA-384
  SRI value computed at build time; `Htmx.head` (templates.md section 6.6)
  writes the page's tags and the one htmx configuration.
  htmx 4.0.0 exists on npm as the `next` tag; v1 stays on 2.x (section 4.7).
- There is no condition variable in cosmic.poll today. SSE needs one, so
  this file adds `Poll.Notifier` (about 50 lines in cosmic/poll.tl),
  a new small module `cosmic.channel` built on it, and `Sse.Hub` /
  `Sse.EventStream` (`cosmic.web.sse`) on top of that.
- SSE needs one change to cosmic/http/server.tl (forward `on_stop`, core.md
  section 9.3 and 13.7) and a second seam (`Reply.take`) that WebSockets will
  also use. Heartbeats
  detect a gone client in v1; `take` makes it prompt later.
- A dev supervisor (`cosmic.web.dev`) restarts the app on source changes
  and a tiny script reloads the browser; static changes reload without a
  restart. Nothing in the repo watches files today.

## 1. The static assets convention

### 1.1 Layout

Add one field to `Layout` (cosmic/layout.tl:7-66):

```teal
  --- a static asset: any file under the top-level `static/` directory
  --- is carried verbatim in the project's executable and served by
  --- [`cosmic.web`]'s `StaticFiles`. `static/css/app.css` is the asset
  --- `css/app.css`. A `static/` directory is never a module namespace:
  --- a `.tl` or `.tmpl` under it is an asset, not a module, so it is not
  --- compiled, tested or required
  static: string
```

and `static = "static"` in the table at cosmic/layout.tl:61-64. As with
every other field the value is the name of the convention, and the
convention is that the directory is `static/` at the project root. There
is no configuration: a second root (`public/`) is two ways to say one
thing. An app that wants another mount URL names it in the router
(`Mount("/assets", StaticFiles{...})`), not in the file layout.

Why a top-level directory and not "any file next to a module": the build
stages inputs by extension today (build/identity.tl:186-200 admits `.tl`,
`.tmpl` and doc guides only), so a data file anywhere would be an
unbounded new input class. One reserved directory keeps the rule one
line, keeps `static/` out of the module namespace (so
`static/app.tl` cannot become `require("static.app")` by accident), and
lets the walk skip it cheaply everywhere else.

`static/` is not a Starlette concept (Starlette serves an arbitrary
directory path at run time). The departure is deliberate: cosmic ships one
executable, so the files must be in it.

### 1.2 Staging

`identity.is_input(file, own_tree)` (build/identity.tl:186) answers true
for a file under `static/` when `own_tree` is false (a project, not
cosmic's own tree, whose `static`-named directories, if any, are not
this convention). The walk already reaches every non-hidden file
(`identity.skip_input` at build/identity.tl:140 skips only hidden names
and `not_input` top-level directories), so no walk change is needed;
`is_input` is the filter.

Consequence: every asset becomes a `files` row (path, size, mtime, sha256,
data) in the working database through the staging in build/work.tl:821
(`work.stage`), with the unchanged-file stat shortcut that applies to all
inputs. The `sha256` column is already the content hash the ETag and the
fingerprint need; nothing extra is computed for them.

Rules checked at staging, each a build error naming the file:

- Size: a file over 16 MiB is refused ("static/video.mp4: 21 MiB is past
  the 16 MiB limit for an embedded asset; serve it from disk or object
  storage"). 16 MiB is the Artifact tool's order of magnitude and well
  under SQLite's blob limit; the real cost is memory (section 1.5). The
  total is warned about, not refused, past 256 MiB.
- Names: a path component beginning with `.` is already skipped by the
  walk. A name with a byte under 0x20, a `\`, a `%`, a `?` or a `#` is
  refused: such a name needs escaping in every URL and tag the app
  writes, and nothing legitimate needs it. A path longer than 255 bytes is
  refused. Case-colliding names (`App.css` and `app.css`) are refused so
  a tree builds the same on a case-insensitive disk.
- Symlinks: `Fs.walk_following` (build/work.tl:906) follows links. A link
  out of the tree would make the executable depend on files outside the
  checkout; it is refused for `static/`, as for a link escaping the root
  elsewhere (to confirm in `link_files.skipper`, build/work.tl:847).

### 1.3 The projection and the executable

`cosmic.db` is "a pure function of the tree, byte-identical from any
build" (build/work.tl:3-13). So the rows are computed from `files`
alone, in build/writer.tl beside the `modules` copy (the queries at
build/writer.tl:558-620), not from anything host-dependent.

Reuse the reserved but unwritten `payload` table. Today it is
`(path TEXT PRIMARY KEY, data BLOB NOT NULL)` with a TODO that nothing
writes it (build/schema.tl:74-78). Change it to:

```
payload(path TEXT PRIMARY KEY,   -- relative to static/, "css/app.css"
        data BLOB NOT NULL,      -- the bytes
        sha256 TEXT NOT NULL,    -- lowercase hex, from files.sha256
        type TEXT NOT NULL,      -- the content type (section 1.4)
        gzip BLOB)               -- NULL, or the gzip of data (section 3.6)
```

The `type` column is a function of the extension and fixed in the
build, so the same table serves a program that never loads `cosmic.web`.
`gzip` is written when the file is a compressible type, over 1 KiB, and
the gzip is at least 10% smaller. `Compress.deflate("gzip", data, 9)`
(cosmic/compress.tl:90) writes a header with mtime 0 (compress.tl:128-130),
so the output is deterministic and the projection stays byte-identical.
The deflate runs once per changed file because it is a derived row keyed
by `from_hash` like the template rows are (build/derivation.tl:109-140
keys on `sha256` and skips files that already have a `derived` row).
Put the generation in build/derivation.tl as `derive_assets`, next to
`derive_templates`, appended to the step list at build/derivation.tl:575,
writing derived rows of kind `asset`; the writer then copies them into
`payload`. The TODO at build/schema.tl:74 is deleted by this change.

`build/embed.tl` (the `cosmic build` verb) copies the project's rows into
the executable's database (build/embed.tl:170-215 shows the `ATTACH
project` pattern for modules). Add one statement there: `INSERT INTO
main.payload SELECT * FROM project.payload`. Tests and examples are
dropped from the executable, assets are not.

Doc update: doc/design.md:412 changes from "for an embed-built executable,
the user's files" to the actual contract: the files under `static/`, with
the columns above.

### 1.4 Content types

One function in `cosmic.web` and one table in the build, which must agree
(the build stores the result, the dev-mode directory source recomputes it).
To avoid two tables, put the function in a small module the build can
require without loading the web stack: `cosmic/web/mime.tl`, exporting
`Mime.of(path: string): string`, required by both build/derivation.tl and
`cosmic.web`. The tree's contracts need the build to require only
standard-library modules in the tool's closure; `cosmic.web.mime` is one.

The table (lowercase extension to type):

- text: `html htm` text/html; `css` text/css; `js mjs` text/javascript;
  `json map` application/json; `txt` text/plain; `xml` application/xml;
  `svg` image/svg+xml; `webmanifest` application/manifest+json;
  `csv` text/csv; `md` text/markdown. Every `text/*`, plus json, js, svg
  and xml, gets `; charset=utf-8`.
- images: `png jpg jpeg gif webp avif ico bmp`.
- fonts: `woff` font/woff, `woff2` font/woff2, `ttf` font/ttf, `otf` font/otf.
- other: `wasm` application/wasm, `pdf`, `zip`, `gz` application/gzip,
  `mp3`, `mp4`, `webm`, `ogg`, `wav`.
- anything else: `application/octet-stream`.

Content is never sniffed. Every static response carries
`X-Content-Type-Options: nosniff`. A `.svg` carries
`Content-Security-Policy: sandbox` unless the app overrides it, so an
uploaded or third-party SVG cannot run script when navigated to (an SVG
in an `<img>` never runs script; this guards the direct-navigation case).
An `.html` under `static/` is served as given: the app wrote it.

### 1.5 Reading at run time

`Assets` is the one read interface; `StaticFiles` and the htmx route
use it, and so can an app (an `Assets` is how a handler reads a bundled
file, a favicon or a font to embed in a PDF).

```teal
local record Assets
  --- One file of the source, immutable once returned: `data` is the
  --- bytes whatever mode the source reads in.
  record Asset
    --- The path under the source's root, "css/app.css": no leading
    --- slash, no empty, "." or ".." component.
    path: string
    data: string
    size: integer
    --- Lowercase hex SHA-256 of `data`.
    sha256: string
    --- The strong ETag `"<first 32 hex>"` (quotes included).
    etag: string
    --- Content type as `Mime.of` gives it.
    type: string
    --- The gzip of `data` when the build stored one, else nil. Its
    --- ETag is `etag` with "-gzip" before the closing quote.
    gzip: string
    --- `sha256-` / `sha384-` SRI value, base64 (section 4.4), computed
    --- on first use and kept.
    integrity: function(Asset, algorithm?: "sha256" | "sha384" | "sha512"): string
    --- Directory mode only: the file's mtime in seconds, for
    --- Last-Modified; 0 for an embedded asset (the build is
    --- reproducible and so carries no time).
    mtime: integer
  end

  --- Where assets come from. `get` answers nil for a path the source
  --- does not hold and never raises for one; `paths` lists them sorted.
  interface Source
    get: function(Source, path: string): Asset | nil
    paths: function(Source): {string}
    --- True when `get` may answer differently later (directory mode):
    --- `StaticFiles` then does not trust a fingerprint it computed
    --- earlier.
    dynamic: function(Source): boolean
  end

  embedded: function(): Source
  directory: function(root: string): Source
  memory: function(files: {string:string}): Source
  --- The default for an app: see section 1.6.
  default: function(opts?: Assets.DefaultOptions): Source
end
```

Embedded source: one prepared statement against the project's database
(`Store.databases()`, cosmic/store.tl:111, whose first handle is the
project's own, ahead of the binary's) selecting
`data, sha256, type, gzip FROM payload WHERE path = ?`. Hits are cached
in a Lua table keyed by path for the life of the process, so a hot asset
costs one SQLite call ever. The cache holds whole files (limit above is
16 MiB each); the process's memory is bounded by the total of `static/`,
which the 256 MiB warning makes visible. `Store.databases()` is the only
door: no new C and no `cosmic.internal.store` change. SQLite calls block
every task (section 6.2), but an embedded read is a primary-key lookup in
a local file, microseconds for small assets; a 16 MiB blob read is
milliseconds, once.

Directory source: `Fs.stat` on every request (one `stat` per request is
cheap against a socket round trip), re-reading and re-hashing only when
`mtime_ns`/`size` change. It never lists the directory on the hot path.
Paths come from `Url.segments` (section 3.7) and are joined to the root
with `/`; `Fs` is not asked to resolve symlinks, so a link under the
directory that points out is followed. In dev mode that is the
developer's own tree, accepted; section 3.7 says why it must not be used
to serve an uploads directory.

Memory source: for tests and generated assets. `memory({["a.css"] =
"..."})`.

Sealed test workers: a sandboxed test worker without `store = true` runs
on a sealed database that holds only its closure's modules
(AGENTS.md, "A worker whose module declares neither `store` nor
`tool`"), so `payload` rows are not there. Tests of `StaticFiles` use
`Assets.memory` or `Assets.directory(tmp)`; the one test of the embedded
source is a `store = true` test in a module of its own (as AGENTS.md
asks for such tests) that builds a project in a temp directory
(`build.confine`/project fixtures), runs `cosmic build` on it and
queries `payload` of the result.

### 1.6 Dev mode reading from disk

`Assets.default(opts)` picks the source:

1. if `opts.dev` (set by `Web.app{ dev = true }`, which defaults from the
   environment variable `COSMIC_WEB_DEV` being `1`), the directory
   source on `opts.root` ("static" resolved against the process's working
   directory, which for `cosmic app.tl` and the dev supervisor is the
   project root);
2. else the embedded source if `payload` has any row;
3. else the directory source, with a one-time log line, so a project run
   from a checkout works before it is built.

Why not "always directory when the directory exists": a built executable
run in a directory that happens to hold an unrelated `static/` would serve
the wrong files. Embedded wins unless dev is asked for.

## 2. Data flow, end to end

- Edit time: a file in `static/` is a file on disk. In dev mode the app
  reads it from there.
- Build: `work.stage` reads it into `files`; `derive_assets` adds its
  type and gzip; the writer puts a `payload` row in `cosmic.db`;
  `cosmic build` copies the row into the executable's database.
- Run: `Assets.default()` selects embedded or directory; `StaticFiles`
  answers requests from it; templates ask `url_for` for fingerprinted
  names.
- The vendored htmx follows the same road from `vendor/htmx` to the
  binary's own `web_assets` table, and is served through the same
  `StaticFiles` code from an in-memory source.

## 3. `StaticFiles`

### 3.1 API

```teal
local record StaticFiles
  record Options
    --- Where the files come from; nil for `Assets.default()`.
    source: Assets.Source
    --- Cache-Control for an asset requested by its plain name
    --- (default "public, no-cache": cache, revalidate by ETag every
    --- time).
    cache_control: string
    --- Cache-Control for a fingerprinted name (default "public,
    --- max-age=31536000, immutable").
    immutable_control: string
    --- Serve `index.html` for a directory path ("/docs/" -> docs/index.html);
    --- default false. A request for a directory without it is 404.
    html: boolean
    --- 404 page for a missing file: a `Handler`-shaped fallback
    --- (the router's), default a plain 404 through the app's error
    --- handler.
    not_found: Handler
    --- Headers added to every response (a CORS or security default).
    headers: {string:string}
    --- Disable the stored gzip variant; default false.
    gzip: boolean
  end

  --- A handler for a Mount: the Mount strips its prefix, so the handler
  --- sees "/css/app.css".
  handler: function(opts?: Options): Handler
  --- The Route for `prefix`: `Web.mount_handler` over `handler(opts)`,
  --- named "static", with the reverse resolver below.
  mount: function(prefix: string, opts?: Options): Web.Route
  --- The mount's reverse target: "/static/css/app.3f9a1c8e2b.css".
  --- `prefix` is the mount's full prefix. nil and why for a path not in
  --- the source.
  url: function(self: StaticFiles, prefix: string, path: string): string | nil, string
end
```

`Handler`, `Request` and `Response` are core.md section 2 and 3's types
(`function(Web.Request): Web.Response`). All that this file needs of
`Request` is the method, the path relative to the mount (after the mount
stripped its prefix and before the percent-decoding that `Url.segments`
does), and header access by lowercase name. All it needs of `Response` is a
status, headers and a string or Reader body; headers are appended with
`Web.add_header` (core.md section 3), so `Vary` merges.

Usage:

```teal
local app = Web.app{
  routes = {
    StaticFiles.mount("/static", {}),            -- named "static"
    Web.get("/", home),
  },
}
```

and the handler passes the URL to its template, which writes it in an
`href` slot (templates.md section 7):
`app:url_for("static", { path = "css/app.css" })` gives
`/static/css/app.3f9a1c8e2b.css`.

`StaticFiles.mount(prefix, opts?)` returns the Route that
`Web.mount_handler(prefix, StaticFiles.handler(opts), { name = "static",
reverse = ... })` builds (core.md sections 5.6 and 5.7). The reverse
resolver it passes is `function(prefix, params) return
StaticFiles.url(self, prefix, params.path) end`, so
`app:url_for("static", { path = "css/app.css" })` reaches `StaticFiles:url`
and returns the fingerprinted name.

### 3.2 Methods

Only GET and HEAD. Any other method answers 405 with `Allow: GET, HEAD`.
An OPTIONS to a static path is answered by the CORS middleware if it is
installed, else 405 (the router's usual behavior for an unlisted method).
HEAD runs the same code as GET and returns the same headers with no body;
the server drops the body of a HEAD reply and keeps the headers, including
the Content-Length the GET would have (cosmic/http/server.tl:30-37), so the
handler returns the same `Response` for both. For a 304 or 416 nothing
changes.

### 3.3 Algorithm, in order

For a request whose relative path is `/css/app.3f9a1c8e2b.css`:

1. Method check as above.
2. `Url.segments(path)` (cosmic/url.tl:131-153). On `nil, why` answer 404
   (not 400: a probing client learns nothing). It already rejects a `..`
   segment (also as `%2e%2e`), an escaped `/`, a NUL, a malformed escape,
   and drops empty and `.` segments, so `//` and `/./` normalize.
3. Join the segments with `/` into `rel`. If `rel` is empty, the request
   was for the mount root: 404, or `index.html` when `html`.
4. Reject (404) any segment that begins with `.` (dotfiles) and any
   `rel` over 255 bytes. Both are already impossible in an embedded
   source; in directory mode they stop `/.git/config`.
5. Look up `rel` in the source. If found, it is a plain-name request.
   If not found, try the fingerprint form (section 3.4). If neither, call
   the app's `not_found` or answer 404.
6. Build validators: `etag` (or the gzip etag, step 8).
7. Preconditions: if `If-None-Match` is present, `Server.none_match(header,
   etag)` (cosmic/http/server.tl:747) decides; true answers 304 with
   `ETag`, `Cache-Control` and `Vary` and no body, for both GET and HEAD.
   `If-Modified-Since` is not implemented in v1 (embedded assets have no
   time; an ETag-less client is rare); a TODO notes `Time.parse_http` as
   the missing piece (check it exists before relying on it).
8. Encoding: if the asset has a `gzip` and the request has no `Range`
   and `Accept-Encoding` lists `gzip` (token match, `q=0` honored), serve
   the gzip bytes with `Content-Encoding: gzip`, the gzip ETag and `Vary:
   Accept-Encoding`. `Vary: Accept-Encoding` is sent on every response for
   an asset that has a gzip variant, whichever encoding was chosen, so a
   cache keys correctly.
9. Range: only for GET, only for the identity encoding.
   `Server.range(header, size)` (cosmic/http/server.tl:678). If the request
   has `If-Range`, it is honored only when it is a strong entity tag equal
   to the current `etag`; any other value (a date, a mismatched tag)
   discards the Range, per RFC 9110 13.1.5. Kinds: "whole" answers 200;
   "span" answers 206 with `Content-Range: bytes first-last/size`; and
   "unsatisfiable" answers 416 with `Content-Range: bytes */size`. Always
   `Accept-Ranges: bytes`. A multi-range request is answered whole, which
   is what `Server.range` does for it (cosmic/http/server.tl:650-680).
10. Headers: `Content-Type`, `ETag`, `Cache-Control` (immutable form for a
    fingerprint hit, otherwise `cache_control`), `X-Content-Type-Options:
    nosniff`, the SVG CSP, `opts.headers`, and `Last-Modified` in directory
    mode only. The body is the string (a slice for a span). The server
    adds `Content-Length` and `Date` (cosmic/http/server.tl:61-76).

Large embedded files: the whole `data` string is already in memory
(section 1.5), so a body is a string and no Reader is involved. In
directory mode a file over 1 MiB is served as a `Stream.open(path)` Reader
(cosmic/stream.tl:563) with `length` set, so dev mode does not hold big
files (and a span uses `Reader:skip`, present on file readers,
cosmic/stream.tl:504). The ETag then is a weak-by-construction mtime/size
value rather than a content hash (hashing 200 MB per request is not
acceptable): `W/"<size-hex>-<mtime_ns-hex>"`.

### 3.4 Fingerprinted names

A fingerprint is the first 10 hex digits of the asset's SHA-256, inserted
before the last extension: `app.css` becomes `app.3f9a1c8e2b.css`; a name
with no extension gets `.hash` appended (`LICENSE.3f9a1c8e2b`). Ten hex
digits are 40 bits: collisions between two versions of one file are not a
concern, it is not a security boundary, and it keeps URLs short.

Resolution on a miss in step 5: match `^(.+)%.(%x%x%x%x%x%x%x%x%x%x)(%.[^./]*)$`
(or without the third group), rebuild the plain name, look it up, and
serve only if the asset's digest starts with the 10 digits. A mismatch
(a stale URL from an older build) answers 404, not the new content:
serving different bytes at an immutable URL would pin them in caches. The
404 for a stale fingerprint carries `Cache-Control: no-store` so a CDN
does not cache it as a final answer across a deploy. A real file whose
literal name already looks like a fingerprint wins over the rewrite
(the plain lookup runs first).

`StaticFiles:url(prefix, "css/app.css")` computes the same name and returns
`prefix .. "/css/app.3f9a1c8e2b.css"`; it is the mount's reverse resolver. In directory mode (dev) the digest
is recomputed when the file's stat changes, so a new page render after an
edit points at a new URL and the browser fetches it with no hard reload.
In embedded mode the digests are fixed for the process, so `url` memoizes.
`url` for a path the source lacks returns `nil, "no such asset: x"`; core's
`url_for` returns that, and a template's builder turns it into a render error rather than a silent
404 link (the safe choice: a typo'd `<link>` is found in the first
request).

CSS that refers to other assets (`url(../img/a.png)`) is not rewritten.
That is what a bundler does and is out of scope; relative references to the
plain name work, revalidated by ETag. An app that wants immutable images
in CSS names them with `url_for` in a template-generated stylesheet.

### 3.5 Cache-Control defaults, and why

- Plain name: `public, no-cache`. A browser may store it but must
  revalidate; the revalidation is a 304 for the size of a header. This is
  the safe default for a file that changes with deploys. (`max-age=0` is the
  same; `no-cache` says it clearly.)
- Fingerprint: `public, max-age=31536000, immutable`.
- A request that carries `Authorization` or a session cookie is
  still `public`: `StaticFiles` serves non-secret bytes by contract
  (they are in the executable). If an app puts private data under `static/`
  that is a bug in the app; the docs say so. A CDN in front must not vary on cookies for this
  prefix.
- The htmx route (section 4) is fingerprinted by version in its fixed
  name and so uses the immutable form.

### 3.6 Precompressed gzip

Included, because the cost is a build step and a branch: the htmx file
alone goes from 52 182 to 16 838 bytes (measured with `gzip -9` on the
npm tarball's `htmx.min.js`; the npm package itself ships a `.gz`).
Brotli is not available in the compress module (formats are zlib, gzip,
xz and bz2, cosmic/compress.tl:28-32) and is out of scope. The negotiation
in step 8 is minimal: if `Accept-Encoding` contains the token `gzip` (or
`*`) with a q-value other than 0, send gzip.

Dynamic gzip of responses is the gzip middleware's job (middleware
section). `StaticFiles` marks its encoded responses `Content-Encoding:
gzip` so that middleware skips them. It must also skip `text/event-stream`
(section 5.3).

### 3.7 Safety summary

- Embedded mode has no filesystem path at all: a request path is a key
  into a table. Traversal needs no `..` defense beyond the key not
  existing.
- Directory mode joins `Url.segments` output to the root. The function's
  own comment says a symlink inside `root` can still climb out
  (cosmic/url.tl:121-126). Directory mode is therefore a development
  feature and `Assets.directory` documents that it must never serve
  directories that contain user-supplied files. The Landlock-style sandbox
  of the process is the second defense, not the first.
- Case: embedded lookup is exact. On a case-insensitive disk (macOS dev
  mode) `/CSS/App.css` would hit the file; the 404-on-fingerprint-mismatch
  rule makes this harmless.
- Only GET/HEAD; no directory listings, ever.
- Lookup is by exact normalized path, so `a%2Fb` (escaped slash) is
  already rejected by `Url.segments`, and a double-encoded `%252e%252e`
  stays a literal segment `%2e%2e`, which names no file.

## 4. Vendored htmx and the SSE extension

### 4.1 What is vendored

Facts checked on 2026-10-10:

- npm `htmx.org` `latest` is 2.0.11; the `next` tag is 4.0.0. 2.0.11 is
  published as license `0BSD`; the LICENSE file in the tarball is
  "Zero-Clause BSD". It needs no notice, but cosmic's BOM carries the text
  anyway (build/bom.tl `notice`), which also records provenance.
- npm `htmx-ext-sse` `latest` is 2.2.4, "BSD Zero Clause License,
  Copyright (c) 2023, Alexander Petros". Its package.json depends on
  `htmx.org ^2.0.2`.
- Pulled from the registry and measured here:
  `htmx.org-2.0.11.tgz` has sha256
  `165a2655073e9e6e55e307a7c74e8ebcdb76afb7701f9c16cfd106a13add408e`;
  `dist/htmx.min.js` is 52 182 bytes (sha256
  `d6fdc75f204e6bdefa99b69bf1e6d4ac69b8a364f77929f45c13476b4000f717`,
  sha384 `2OatzQy1H+Zd/IIrjr1TcuDGqLXeHhbooAyJY1KdQMKnr4LZ22k31GBLdYKHmVjg`).
  `htmx-ext-sse-2.2.4.tgz` has sha256
  `90b46f5ab915ba2f64e6348448c8dba509277a47e15c125ffb65754eb4f6b5dc`;
  `dist/sse.min.js` is 2 853 bytes (sha384
  `A986SAtodyH8eg8x8irJnYUk7i9inVQqYigD6qZ9evobksGNIXfeFvDwLSHcp31N`).

The SRI values above are for the spike; the build computes them (section
4.4) and a test asserts the build's value equals the independent
`openssl dgst -sha384` of the same file.

The htmx source repository also commits `dist/`, but the npm tarball is a
stable, content-addressed file with a published checksum, a license file,
and `dist/htmx.min.js` at a fixed path, which is what the PIN grammar
(build/vendor.tl:1-40) wants.

### 4.2 Where it lives

Following the existing "kind data" trees (`vendor/cacert/PIN`,
`vendor/tzdata/PIN`) and the PIN grammar `build/vendor.tl:1-40` (`url`,
`sha256`, `strip`, `keep`, `drop`; `bin/vendor` fetches into the cache
with a checksum and unpacks with `cosmic.archive`, which reads `.tgz`):

`vendor/htmx/PIN`:

```
version 2.0.11
url https://registry.npmjs.org/htmx.org/-/htmx.org-2.0.11.tgz
sha256 165a2655073e9e6e55e307a7c74e8ebcdb76afb7701f9c16cfd106a13add408e
strip package/
keep LICENSE
keep dist/htmx.min.js
kind data
license 0BSD
notice LICENSE
```

`vendor/htmx-ext-sse/PIN`:

```
version 2.2.4
url https://registry.npmjs.org/htmx-ext-sse/-/htmx-ext-sse-2.2.4.tgz
sha256 90b46f5ab915ba2f64e6348448c8dba509277a47e15c125ffb65754eb4f6b5dc
strip package/
keep LICENSE
keep dist/sse.min.js
kind data
license 0BSD
notice LICENSE
```

`bin/vendor htmx htmx-ext-sse` refetches both. No file under `vendor/` is
edited by hand (AGENTS.md). `patch/htmx/` does not exist: the library is
used as shipped. If a patch were ever needed, the records live in
`patch/htmx/01-....txt` in the `file:` / `note:` / `--- find` /
`--- replace` / `--- end` format of patch/miniz/01-invalid-code-decode.txt.

The BOM (`cosmic bom`) picks the components up from the PINs (build/bom.tl
reads `license`, `notice`, `kind`), so the 0BSD text and the version travel
with every executable (build/embed.tl:157-165 copies `components` and
`notices`). Zero-Clause BSD requires no attribution. cosmic still keeps the
file because the BOM promises "the notices their licenses ask to travel".

`cosmic refresh` (build/refresh.tl:105-210) updates `cacert` and `tzdata`
datasets from their upstreams. htmx is not added to it in v1: a major
library bump deserves a human reading the release notes. A `TODO:` in
vendor handling is not needed; a line in doc/roadmap.md ("refresh
htmx and htmx-ext-sse from npm's `dist-tags`") covers it.

### 4.3 How it reaches the store

Mirror `zoneinfo` exactly, because it is the same shape (a data tree read
at boot, kept in the binary's database, carried by `cosmic build`):

- A new table in build/schema.tl beside `zoneinfo` (schema.tl:80-83):

  ```
  web_assets(name TEXT PRIMARY KEY,   -- "htmx.min.js", "htmx-ext-sse.min.js"
             data BLOB NOT NULL,
             sha256 TEXT NOT NULL,
             sha384 TEXT NOT NULL,    -- base64, the SRI value
             version TEXT NOT NULL)
  ```

- build/boot.tl:164-172 reads `vendor/tzdata/zoneinfo` with
  `work.read_zoneinfo` and `work.put_zoneinfo` into the working database;
  add `work.read_web_assets` / `work.put_web_assets` for the two PIN trees
  beside them, hashing as it reads. `build/reboot.tl:256-260` (a Teal-only
  rebuild carries the running binary's rows over) gets the same line.
  build/embed.tl:205 (`copy_rows ... "zoneinfo"`) gets one for
  `web_assets`.
- The hash is computed here, at boot, from the vendored bytes, with
  `Hash.digest("sha384", data)` and `Codec.base64` (cosmic/hash.tl:77,
  cosmic/codec.tl:210). `sha384` is in `Hash.Algorithm`
  (cosmic/hash.tl, the enum). A mismatch between the PIN's archive checksum and
  the bytes cannot arise: `bin/vendor` verified the archive.
- Read side: `Store.web_asset(name): {data: string, sha256: string,
  sha384: string, version: string} | nil, string`, next to
  `Store.zoneinfo` (cosmic/store.tl:119), backed by a new function in the
  internal store (`cosmic.internal.store`, C, like `zoneinfo`) or, if the
  team prefers no C for this, a query over `Store.databases()`'s last
  handle (the binary's own), exactly the technique section 1.5 uses for
  `payload`. Recommendation: the query; the core's database access is
  already a handle, and zoneinfo is C only because `core/` needs it before
  Lua starts.

The size cost is 55 KB per executable (and the stdlib's database grows by
that). Executables that never load `cosmic.web` carry it anyway, as they
carry the zone database and CA roots; `cosmic build` could omit it when
the project does not require `cosmic.web` (the same closure computation it
does for modules). Recommendation: carry always in v1; omit as a later
optimization (a `TODO:` in embed.tl).

### 4.4 Serving it and the SRI hash

`cosmic.web` registers two routes automatically in the app (not as part of
the user's table; `Web.app` takes `builtin = true`, default true, to turn
that off; core.md section 5.5 reserves the `/_web/` prefix so no user route
can collide):

```
GET /_web/htmx-2.0.11.min.js
GET /_web/htmx-ext-sse-2.2.4.min.js
```

The path contains the version, so the content at a path never changes
and the response carries the immutable cache header. The fixed `/_web/`
prefix is reserved: the router refuses a user route under it (an `App`
construction error, core.md section 5.5). Responses carry `Content-Type:
text/javascript; charset=utf-8`, `ETag`, `Cache-Control: public,
max-age=31536000, immutable`, `Cross-Origin-Resource-Policy: same-origin`
and `X-Content-Type-Options: nosniff`. Both are served from a
`memory` `Assets.Source` built from `Store.web_asset`, so `StaticFiles`'s
whole algorithm applies unchanged (ETag, 304, Range, gzip computed once at
first use with `Compress.deflate` and kept).

The page head. `Htmx.head(opts)` (templates.md section 6.6) is the one
helper that writes the `<meta name="htmx-config">` and the `<script>` tags
with SRI for these two files; this file supplies what it reads. From
`Store.web_asset` (4.3) it takes each file's path, version and SHA-384 SRI
value; `Htmx.path()` ("/_web/htmx-2.0.11.min.js") and `Htmx.integrity()`
("sha384-...") expose them for a layout that writes its own tag, and
`Htmx.head{ sse = true }` adds the extension's tag. The tag is
`<script src="/_web/htmx-2.0.11.min.js" integrity="sha384-2Oat..."
crossorigin="anonymous" defer></script>`. `crossorigin="anonymous"` is
required for SRI on a cross-origin script only; here it is same-origin,
where it is harmless and keeps the tag valid if an app later puts the file
on a CDN host. The integrity attribute on a same-origin script is a defense
in depth against a corrupted cache or a tampered proxy, and a check that a
deploy served the right file.

The htmx configuration is defined once, in templates.md section 6.6, and not
restated here: `allowEval` and `allowScriptTags` off, `includeIndicatorStyles`
off, `selfRequestsOnly` on, and `responseHandling` swapping 2xx and 422 but
not 204. This file's part of it is the stylesheet half of
`includeIndicatorStyles: false`: htmx otherwise injects an inline `<style>`
at startup (htmx.js:118) which a strict `style-src` CSP blocks, so
`cosmic.web.htmx` ships the `.htmx-indicator` rules as `Htmx.indicator_css()`
for the app's own stylesheet (a `static/` file). (The defaults in the
vendored file are `allowEval` true, htmx.js:154, and `selfRequestsOnly`
true, htmx.js:241.)

### 4.6 Use of the SSE extension

`hx-ext="sse"` on an element, `sse-connect="/events/orders"` to open an
`EventSource`, `sse-swap="order-added"` to swap the HTML of an event with
that name into the element, `sse-close="done"` to close on an event
named `done`. Checked against the shipped sse.js (lines 184-235):

- It creates `new EventSource(url, { withCredentials: true })`: cookies
  go with the request, a header like `X-CSRF-Token` cannot be added, and
  an EventSource only issues GET. The SSE route is therefore a GET that
  reads, never a state change, and authentication is by session cookie
  (input.md section 7). Query-string tokens are a bad idea (logged,
  cached in history); a cookie is right.
- It has its own reconnect for the case where the browser's `EventSource`
  ends up `CLOSED` (a non-200 status or a response whose content type is
  not `text/event-stream` makes the browser give up and not retry). Then
  the extension waits `retryCount * 500` ms (doubling, at most 64 s) and
  makes a NEW `EventSource`. A new object does not send `Last-Event-ID`.
- For a clean network drop of an established stream the browser itself
  reconnects (readyState `CONNECTING`) after the `retry:` delay and sends
  `Last-Event-ID` automatically. This is the case Last-Event-ID is for.

Server consequences: send `retry: 3000` at the start of every stream (so
the browser's default of a few seconds is explicit); answer a refusal as
a non-200 only when giving up is intended (a 401 means "stop", the extension
retries at backoff; a 503 for overload also retries); end a stream that
should not reconnect by sending the `sse-close` event the page listens
for, and then closing.

Browsers allow six HTTP/1.1 connections per origin: one tab with three
`sse-connect` elements uses half of them. The docs recommend one stream
per page that multiplexes topics with event names, and the server limits
streams per client (section 5.7).

### 4.7 htmx 4.0.0 (not adopted in v1)

`htmx.org@4.0.0` is the registry's `next` tag at the time of writing,
released with a built-in SSE (no extension), `fetch` instead of
`XMLHttpRequest`, and a changed attribute set (`BSD-0-Clause` license).
Decided: htmx 2.x. The `htmx` dialect's attribute table is data in
cosmic.template (templates.md section 1.3), so a 4.x move is a PIN bump plus
a table edit, not a rewrite. Recommendation: stay on 2.0.11 for v1 and add a
roadmap line to revisit once 4.x is `latest`. Open question 1.

## 5. Server-sent events

### 5.1 What exists, and what does not

- `Server.Reply.body` may be a `Stream.Reader`; the server writes the head
  first (cosmic/http/wire.tl:866-889, `wire.send` writes `head` before
  `copy_body`), then pulls the Reader, framing each non-empty chunk as an
  HTTP chunk (wire.tl:820-860: a chunk must be non-empty, or the reply is
  cut short as a Reader fault) until the Reader returns nil, `""`.
  Without `Content-Length`, an HTTP/1.1 reply is `Transfer-Encoding:
  chunked`; for HTTP/1.0 the body is delimited by closing the connection.
  So an SSE response needs no server change to be streamed.
- The Reader's `read` runs in the connection's task. A `read` that waits
  through `Poll` (a delay, a descriptor, a join) lets the other tasks
  run (cosmic/poll.tl:560-570 `Poll.delay`; cosmic/http/server.tl:586-596
  on handlers). `timeout_ns` (30 s) is each socket read/write's timeout
  (cosmic/http/server.tl:99-103) and does not cap a Reader's own waiting;
  `idle_ns` (5 s) applies only to the wait for the first byte of the NEXT
  request (cosmic/http/server.tl:490-500). So a stream whose Reader waits
  a long time is not killed by the server's timeouts, as long as every
  write completes within `timeout_ns`.
- There is no channel, queue, condition variable or event in cosmic.poll
  (checked: its waits are descriptor, timer and join, cosmic/poll.tl:102-130;
  `rg 'Queue|Channel|Latch|Cond'` over cosmic/*.tl finds nothing). A
  Reader fed by another task therefore needs a primitive first.

### 5.2 `Poll.Notifier`

Add to cosmic/poll.tl a wait for "something happened" among tasks of one
run. It is the one place that touches the scheduler; everything else in
this file is ordinary Lua above it.

```teal
--- A place tasks wait for a notice from another. One notifier belongs to
--- the run it was made in.
interface Poll.Notifier
  --- Waits for `notify`: true and "" once one came, false and
  --- [`Poll.TIMEOUT`] after `timeout_ns` (no limit when nil), false
  --- and [`Poll.CANCELLED`] once the task is cancelled. A notice sent
  --- before the call is not remembered: a caller checks its condition
  --- first, then waits, and the checks and the wait are not interleaved with
  --- another task (tasks switch only at waits), so none is lost.
  wait: function(Notifier, timeout_ns?: integer): boolean, string
  --- Wakes every task waiting now; a no-op when none waits. Callable
  --- from a task or from a `<close>` handler (it never waits).
  notify: function(Notifier)
  --- How many tasks wait now.
  waiting: function(Notifier): integer
end
function Poll.notifier(): Poll.Notifier
```

Implementation sketch, from `State:join` (cosmic/poll.tl:596-605) and
`unjoin`/`finish`/`wake` (poll.tl:330-366): a `Wait` gets a field `gate:
Notifier`; `wait` creates `{ task = task, gate = self }`, appends it to
`self.waiters`, and `park`s it with the timeout; `notify` walks a copy of
`waiters` and `wake(w, true, "")`s each; `finish` removes a wait from its
gate's list when it ends another way (timeout, cancel, kill), as it does
for `joined`. Since `wake` appends to `loop.ready` and the woken tasks run
on the next turn, `notify` from a `<close>` handler does not violate the
"cannot wait, spawn or kill" rule (poll.tl: Task.kill docs).

Hazards documented on the type: a notifier is one-run; calling `wait`
outside a task raises as `Poll.delay` does; a notice is not stored, so
the pattern is "while not condition do wait() end".

Tests (cosmic/poll_notifier_test.tl): wake all; wake none; timeout; cancel
while waiting; kill while waiting removes the waiter; notify from a
`<close>` handler; notify before wait is not remembered; a wait and
immediate notify in one turn.

### 5.3 `cosmic.channel`

A new small module (cosmic/channel.tl): a bounded FIFO between tasks.
Generic because worker pools, job queues and the hub all need it, and a
queue is the correct name for what the web hub builds per subscriber.

```teal
local record Channel<T>
  enum Overflow
    "block"        -- send waits for room
    "drop_oldest"  -- discard the oldest queued item
    "drop_newest"  -- discard the item being sent
    "close"        -- close the channel (a slow consumer is cut off)
  end
  record Options
    capacity: integer       -- default 256, at least 1
    overflow: Overflow      -- default "block"
  end
  new: function(opts?: Options): Channel<T>
  --- Queues `item`. For "block", waits for room (false, TIMEOUT or
  --- CANCELLED are possible). Returns false and "closed" once closed.
  send: function(self: Channel<T>, item: T, timeout_ns?: integer): boolean, string
  --- Never waits: true, or false and why ("full", "closed").
  try_send: function(self: Channel<T>, item: T): boolean, string
  --- The next item, waiting up to `timeout_ns`; nil and "" once the
  --- channel is closed and drained; nil and TIMEOUT / CANCELLED.
  recv: function(self: Channel<T>, timeout_ns?: integer): T | nil, string
  close: function(self: Channel<T>)
  len: function(self: Channel<T>): integer
  closed: function(self: Channel<T>): boolean
  --- How many items were dropped by overflow, for logging.
  dropped: function(self: Channel<T>): integer
end
```

Two `Notifier`s inside (not-empty, not-full). `close` notifies both. No
`select` in v1 (a hub does not need it); `Poll.notifier` is the building
block when it does. Generic records in Teal are fine (`Channel<T>`) but
the repo's contracts (build/contracts.tl) must be consulted for generic
records in the standard library; if they forbid it, specialize to
`{any}`-free `Channel` over `string` events, which is all this file
uses. Open question 2.

### 5.4 Events and formatting

```teal
record Sse.Event
  --- The `id:` field: the client echoes the last one it saw in
  --- `Last-Event-ID`. Must not hold CR, LF or NUL (raises).
  id: string
  --- The `event:` field (default "message"): htmx's `sse-swap="name"`
  --- listens for it. Must not hold CR or LF (raises).
  event: string
  --- The `data:` field; any line ending (LF, CR, CRLF) splits it into
  --- one `data:` line each, so a client rejoins them with LF. For
  --- htmx, an HTML fragment.
  data: string
  --- The `retry:` field in milliseconds, 0 or nil for none.
  retry: integer
  --- A comment line (`: text`), sent as a heartbeat; when set with no
  --- data, the event is only the comment.
  comment: string
end

function Sse.format_event(ev: Event): string
```

Format, per the WHATWG spec: lines are `field: value\n`, an event ends with
a blank line. `data` with embedded newlines becomes several `data:` lines;
a data string ending in a newline yields an empty trailing `data:` line (the
client strips exactly one trailing LF, so this round-trips: the formatter
emits `data: ` for the empty tail). A UTF-8 BOM is not written. Bytes must
be valid UTF-8 (the spec says the stream is UTF-8; invalid bytes become
U+FFFD at the client): not validated, documented.

Helpers:

- `Sse.Event.html(name, safe_html)`: the data is the rendered fragment,
  typed `SafeHtml` so a handler cannot send an unescaped string as markup
  by accident.
- `Sse.Event.json(name, value)`: `Json.encode(value)`.
- `Sse.Event.text(name, s)`.

Property test (a fuzz-style round-trip, since the formatter's input is
untrusted data, using build.fuzz `run`): for random strings `data`,
`parse(format{data=data})` through a reference line parser in the test
returns the same data modulo CR/CRLF normalized to LF. Another: no output
byte sequence of `format_event` contains a blank line before the end
unless it ended the event (no data can end the event early; the classic
SSE injection of `\n\n`). This is the security property; it is what the
newline splitting exists for.

### 5.5 The response and the Reader

```teal
--- A streaming SSE response. `source` yields events; the stream ends
--- when it returns nil and "". `req` gives it the app (`req.app`): the
--- stream budget of 5.9 and the stop hook of core.md section 9.3 (the
--- stream's `source:close()` is registered with `app:on_stop`).
function Sse.EventStream(req: Web.Request, source: Sse.EventSource, opts?: Sse.EventStreamOptions): Web.Response

interface Sse.EventSource
  --- The next event, waiting at most `timeout_ns`; nil and TIMEOUT when
  --- none came in time (the stream then sends a heartbeat), nil and ""
  --- at the end of the stream, nil and why when it failed.
  next: function(self, timeout_ns: integer): Event | nil, string
  close: function(self)
end

record Sse.EventStreamOptions
  --- A heartbeat comment every this many ns without an event
  --- (default 15 s; 0 disables).
  heartbeat_ns: integer
  --- The `retry:` sent first, in ms (default 3000; 0 sends none).
  retry_ms: integer
  --- Events sent before the first of `source` (the hub's replay).
  initial: {Event}
  --- Headers added to the response (strings or lists, as `Reply.headers`).
  headers: {string: string | {string}}
  --- Called once when the stream ends or the client is gone, with why
  --- ("end", "client", "closed"): for a log line or a counter.
  on_close: function(why: string)
end
```

Response: status 200, `Content-Type: text/event-stream`, `Cache-Control:
no-cache, no-transform`, `X-Accel-Buffering: no` (nginx), no
`Content-Length`, `Connection` left to the server. The body is a
`Stream.Reader` (cosmic/stream.tl `interface Reader`: `read`, `close`):

- The first `read` returns `retry: N\n\n` (and the `initial` events), so the
  client has bytes at once and the proxy sees the response start.
- Each `read(max)`: if formatted text is pending, return up to `max`
  bytes of it (the Reader contract is "at most max_bytes", and an empty
  chunk would end a chunked reply early: wire.tl:836-842). Else
  `ev, why = source:next(heartbeat_ns)`; an event is formatted into
  pending; a TIMEOUT answers `": ping\n\n"`; `nil, ""` answers `nil, ""`
  (the server writes the last chunk and closes: with `s.stopping` the
  connection is closed after, cosmic/http/server.tl:430-ff); a failure
  answers `nil, why` after one `event: error`? No: a failure ends the
  stream; the client sees a clean end, reconnects, and the server logs
  `why` through `on_close`.
- `close()` calls `source:close()` and `on_close`. The server calls it
  after every reply, delivered or failed (cosmic/http/wire.tl:880-886).
  Safe to call twice (the Reader contract).
- If the task is killed (the grace period ends, cosmic/net.tl:1103 spawns
  the grace task which kills the connection tasks), `wire.send` never
  returns and `close()` is never called. The Reader therefore keeps its
  unsubscribe in a `<close>` variable local to `read`'s frame while it is
  waiting: `Task.kill` closes the pending `<close>` variables of the
  killed coroutine (cosmic/poll.tl: kill docs), and an unsubscribe only
  removes a table entry, which a `<close>` handler may do (it cannot wait).

HTTP/1.0 clients: close-delimited, works; a heartbeat still helps. No
action.

Compression middleware must not touch `text/event-stream` (it would buffer
and defeat streaming); the gzip middleware that core.md names (its open
question 13) must skip it. Logging
middleware must log the status at head time rather than after the body
(the body lasts an hour).

### 5.6 Heartbeats and the server's timeouts

- Heartbeat default 15 s. Reasons: common proxies cut idle HTTP at 30 to
  60 s (nginx `proxy_read_timeout` 60 s; many load balancers 30 to 60 s),
  and a write is also how a gone client is found (section 5.8). 15 s is
  under all of those and it costs 8 bytes.
- `Server.timeout_ns` (30 s) bounds each write. A client that stops reading
  while its kernel buffer fills makes the write wait up to 30 s and then fail
  (`Poll.TIMEOUT` from `conn:write`); `wire.send` returns with a write
  failure, the connection closes, and `close()` unsubscribes it. So a
  stalled client costs a task for at most `timeout_ns` after its buffer
  is full.
- `Server.idle_ns` does not apply during a reply.
- `head_ns` does not apply.
- There is no total-lifetime limit for a stream. Add `max_age_ns` to
  `EventStreamOptions` (default nil): the Reader ends the stream cleanly
  after it, and the browser reconnects with `Last-Event-ID`. This is the
  standard way to rotate streams across deploys, to refresh a session
  check, and to bound a leak: recommend an hour for an authenticated stream.

### 5.7 Hub: fan-out

```teal
record Sse.Hub
  record Options
    --- Events kept per topic for `Last-Event-ID` replay (default 256, 0
    --- for none).
    replay: integer
    --- Each subscriber's queue (default 256).
    queue: integer
    --- What happens when a subscriber's queue is full: "close" (default:
    --- the subscriber is dropped and the browser reconnects with its
    --- last id and replays), "drop_oldest" (a live view that only wants
    --- the latest), "drop_newest".
    overflow: Channel.Overflow
    --- Subscribers per topic and per hub; past it `subscribe` answers
    --- nil and "full" (the route answers 503 with Retry-After).
    max_per_topic: integer
    max_total: integer
  end

  new: function(opts?: Options): Hub
  --- Delivers `ev` to every subscriber of `topic`, assigns it the next
  --- id when `ev.id` is nil (a hub-wide monotonic integer, as text),
  --- and returns how many subscribers it reached. Never waits.
  publish: function(self: Hub, topic: string, ev: Event): integer
  --- A subscription for the topics, starting after `after` (the
  --- request's Last-Event-ID) when the hub still holds it. nil and why
  --- when over a limit or the hub is closed.
  subscribe: function(self: Hub, topics: {string}, opts?: SubscribeOptions): Subscription | nil, string
  subscribers: function(self: Hub, topic?: string): integer
  --- Closes every subscription: their streams end, and the browsers
  --- reconnect (to this process or its successor). Call it from the app's
  --- shutdown hook (section 6.3). A closed hub refuses `subscribe`.
  close: function(self: Hub)
  --- Registers `close` with the app's stop hook (`app:on_stop`, core.md
  --- section 9.3); `Web.app{ hubs = { hub } }` does the same.
  attach: function(self: Hub, app: Web.App)
end

record Sse.Subscription is Sse.EventSource
  --- True when `after` was older than the replay buffer held: the stream
  --- must tell the page to resync (see below).
  gap: boolean
end
```

`publish` never waits: it walks the topic's subscribers and `try_send`s
each (a subscriber's `Channel` has the hub's overflow policy), so a
slow client never slows a publisher, and a publisher can be a request
handler, a timer task or a SQLite-writing background task. This is the
property that makes the hub safe in a cooperative runtime.

Replay: each topic keeps a ring of its last `replay` events with their ids.
`subscribe{ after = last_id }` finds `last_id` in the ring and queues
everything after it first. If the id is not in the ring (older than the
buffer, or from before a restart), `gap = true` and the Subscription's
first event is a synthetic `event: reset` with the new head id; the page
listens for it (`hx-trigger="sse:reset"` re-fetches the full fragment, or
`sse-swap="reset"`). A silent miss would show stale state; the reset
turns every restart or overflow into a refetch. A client's `Last-Event-ID`
is untrusted text: it is compared to ids by string equality only, never
parsed as a number, never used in a path or query.

Authorization is the caller's: the route handler checks the session and
decides the topics (`"user:" .. session.user_id`) before subscribing. The
Hub does not know about users. A topic name is never read from the client
unchecked.

A topic is also a good unit for "notify, then fetch" (the pattern the
docs push): the event data is small (`order 17 changed`), the page does
`hx-get` for the fragment. That keeps rendered HTML out of the replay ring
and the per-user permission check in one place (the GET).

Usage:

```teal
local hub = Sse.Hub.new{}

local function events(req: Web.Request): Web.Response
  local user = Session.of(req):get_string("user")   -- input.md section 7
  if user == nil then return Web.text("sign in", { status = 401 }) end
  local sub, why = hub:subscribe({ "user:" .. user },
    { after = req.headers["last-event-id"] })
  if sub == nil then
    return Web.text(why, { status = 503, headers = { ["Retry-After"] = "5" } })
  end
  return Sse.EventStream(req, sub, { heartbeat_ns = Clock.seconds(15) })
end

local function add_order(req: Web.Request): Web.Response
  local order = ...  -- insert (a short SQLite call)
  hub:publish("user:" .. order.user,
    Sse.Event.html("order-added", render_row(order)))
  return Web.redirect("/orders")
end
```

and the page: `<div hx-ext="sse" sse-connect="/events" sse-swap="order-added"
hx-swap="beforeend">`.

The hub is in one process. Two processes behind a balancer do not share
it. The roadmap line: a SQLite-table or Unix-socket-backed hub for
multi-process deployments. v1 says so plainly.

### 5.8 Disconnect detection and cleanup

- During a write: a gone client makes the next write fail (`EPIPE` or
  `ECONNRESET`, the first write after RST, or a timeout if the peer
  vanished without RST): `wire.send` returns with `write_failure`, the
  server closes the connection and calls `reader:close()` (wire.tl:880).
  The Subscription unsubscribes in `close`.
- While waiting: nothing reads the socket, so a client that closed
  cleanly (FIN) is not seen until the next write, at most one heartbeat
  later (15 s). The subscriber holds one queue (a few KB) and one task for
  that long. That is acceptable for v1 and is stated, not hidden.
- Prompt detection needs the connection, which the handler does not have.
  The `Reply.take` seam (section 7) gives it: a hijacked SSE stream may
  spawn a watcher task that waits for the descriptor's EOF
  (`conn:read` returning nil, "") and wakes the writer through a
  `Notifier`. It is left for after v1 and listed in open questions.
- Kill and shutdown: section 5.5 and 6.3.
- Leak check: `hub:subscribers()` returns to 0 in tests after clients
  close; a test asserts it (section 9).

### 5.9 Connection limits and long-lived streams

`Server.ServeSpec.Limits.connections` is 256 (cosmic/http/server.tl:112-116,
default at line 571-575). `Net.serve` accepts nothing at the limit: new
connections wait in the backlog (cosmic/net.tl:190-198). Each open SSE
stream keeps its connection for its whole life, so 256 browsers with one
tab each saturate the server and the 257th page load hangs. This is the
most likely operational surprise of SSE on this server.

Mitigations, all in `cosmic.web`:

- A stream budget: `Web.app{ max_streams = n }` (core.md section 9.1;
  default: half of `limits.connections`). An `EventStream` acquires a slot at response
  creation; over budget it answers `503 Service Unavailable` with
  `Retry-After: 5` and no stream. The budget is a counter in the App (not
  a global), released by the Reader's `close` and by the `<close>` guard.
  Ordinary requests therefore keep at least half the capacity.
- Per-client cap: at most 4 streams per session or client address (header
  `x-forwarded-for` is the trusted-proxy question of core.md section 2.2), over which the
  oldest is closed (the browser tab that was left open).
- A recommendation in the docs: set `limits.connections` to 1024 or more
  for an SSE app, and raise `ulimit -n` accordingly. The server's cost per
  idle stream is a task, a socket and a few KB of Lua; 10 000 would be
  fine on memory but `poll(2)` is O(n) per turn (cosmic/poll.tl:731
  `poll_once` builds the descriptor array), so thousands of idle
  streams slow every turn. Honest numbers will come from a benchmark in
  the checked-in `doc/performance` style (a TODO, section 11). Roadmap:
  epoll/kqueue.
- HTTP/2 would remove the per-origin six-connection browser limit; the
  server speaks HTTP/1.1 only. Not in scope.

### 5.10 Backpressure

Producers never wait on consumers (publish is `try_send`). The overflow
policy decides what a slow consumer costs, in order of preference for
SSE: "close" (default; the client reconnects and replays, so no loss and
bounded memory), "drop_oldest" (a "latest value" feed, such as a progress
bar, where history is useless), "drop_newest" (rarely right). "block"
exists in `Channel` for worker pools and is not offered by the Hub
because a blocked publisher is a blocked request handler.

A single large event (a 1 MB fragment) is written with one `conn:write`
and its wait is bounded by `timeout_ns`. The Hub rejects an event whose
data is over `max_event_bytes` (default 64 KiB) in `publish` (raises: a
programming error, not a runtime one).

## 6. Runtime notes

### 6.1 Cooperative tasks

All handlers of one `Server.serve` run in one OS thread, each in a task
of one `Poll.run`. Tasks switch only at waits: a socket read or write, a
`Poll.delay`, a `join`, a `Notifier`/`Channel` wait. A handler that
computes for 200 ms stalls every other connection for 200 ms. This is the
cost of the model and the benefit is the absence of data races: a hub
needs no locks, `publish` is atomic with respect to other tasks.

Guidance for the docs ("what blocks"): CPU-bound loops, `Http.get` and
`Http.request` to another server (cosmic/http/server.tl:571-595 TODO),
`cosmic.sqlite` calls, `Child.run`'s synchronous form and file reads of
large files. Use `Poll.delay(0)` to yield in a long loop; use the
task-aware forms (`Child.start` with `wait`) for processes.

### 6.2 SQLite

A SQLite call blocks the thread until it returns (cosmic/http/server.tl:
590-596). For a small app that is acceptable, and the rules that keep it so:

- One writer connection per process, opened once at startup, with
  `PRAGMA journal_mode = WAL`, `synchronous = NORMAL`, `foreign_keys =
  ON`. Reads can be a second connection; WAL lets a reader proceed beside
  a writer (also across processes).
- Short statements and short transactions. No `Poll` wait (a socket read,
  a `delay`, a `Channel` wait, a `render` that waits) inside a
  transaction: a wait lets another task start a statement on the same
  connection, interleaving two requests into one transaction. The web
  docs show the shape: read the request body, validate it (waits), THEN
  open a transaction and do all the SQL with no wait inside. A transaction
  helper `Db.transaction(db, fn)` is the pattern; whether a lock
  that makes a violation an error (not a silent interleave) can be added
  with `Notifier` is an open question (3).
- `busy_timeout`: the sqlite busy handler SLEEPS the thread
  (`handle:busy_timeout(ns)`, cosmic/sqlite.tl:56-57, 499). With one
  writer connection per process there is nothing to be busy about except a
  second process. Set it small (50 to 250 ms) so a stuck external writer
  stalls the server briefly and surfaces as an error. A 5 s timeout, the
  copy-pasted default elsewhere, would freeze every connection for 5 s.
- Long queries (reports) belong in a child process or a thread-less
  worker: `Child.start` a `cosmic` subprocess that opens the database
  read-only and writes JSON, awaited through the poll-aware `wait`. A
  worker pool (a Channel of jobs to N children) is a later module; the
  `Channel` type is its foundation.
- Readonly `Sqlite.open` with no lock exists for snapshot reads
  (cosmic/sqlite.tl:191-193): not for a live app.

### 6.3 Graceful shutdown

SIGINT/SIGTERM stop the server: `Net.serve` closes the listeners, calls
`on_stop` once, drains the connections and, past `grace_ns`, closes them
and kills their tasks (cosmic/net.tl:203-228, 1103). In `Server.serve`,
`on_stop` closes the idle connections (cosmic/http/server.tl:597-603)
and marks `stopping`, so each reply in flight is answered with `Connection:
close`.

Problems with open SSE streams. The mechanism that solves them is core.md
section 9.3, and this is its streaming half:

1. A stream is "in flight" for its whole life, so the server's default
   `grace_ns` (nil, wait for every request) would hang a deploy for ever.
   `Web.serve` defaults `grace_ns` to 10 s.
2. Even with the grace, every deploy would cost 10 s unless the streams end
   at once. `Server.serve` forwards a caller's `on_stop` (core.md section
   13.7), and `Web.serve` uses it to flip `app:stopping()` and run every
   function registered with `app:on_stop(fn)`.
3. Every `Sse.Hub` and every `Sse.EventStream` registered with the App closes
   its streams from that hook. A Hub registers with `hub:attach(app)` or
   `Web.app{ hubs = { hub } }`; an `Sse.EventStream` registers when it is made
   from a request (`Sse.EventStream(req, source, opts)` reaches the app
   through `req.app`). A `Subscription:next` on a closed hub returns
   `nil, ""`, which the Reader turns into the end of the stream: a clean
   last chunk, and the browsers reconnect to the next process within the
   `retry:` delay. The lifespan's shutdown function (core.md section 9.3)
   runs after `Server.serve` returns, so it sees the streams already closed.
4. A stream whose Reader never returns (a custom `EventSource` that ignores
   close and does not poll `app:stopping()`) is killed at the grace and its
   `<close>` guard runs (section 5.5).

Test: start the server with a stream open, call stop, assert the client
sees the end of the stream well before `grace_ns`, `subscribers()` is 0,
and the process returns.

### 6.4 A dev loop

What exists: nothing. `cosmic app.tl` (the file-run verb,
build/dispatch.tl:297, 354) builds the working directory's tree for the
run and then runs the file; a second invocation after an edit rebuilds
incrementally (AGENTS.md: "a run after a small edit takes seconds").
There is no file watcher in the tree: nothing in `cosmic.fs`,
`cosmic.sys` (core/syscalls.h: no inotify/kqueue binding;
`rg -i 'inotify|kqueue|fswatch' core cosmic doc` finds only unrelated
mentions), no `cosmic dev` or `watch` verb (build/verb_list.tl:33-52).

Template and Teal changes need a rebuild: templates compile to modules at
build time (build/derivation.tl:109-140), so "live reload of a template"
is "restart the process on the rebuilt tree". Design, in three parts:

1. `cosmic.web.dev`, a library function (no new verb in v1):

   ```teal
   function dev.supervise(opts: {
     command: {string},     -- default { Env.program(), "app.tl" }
     watch: {string},       -- directories, default { ".", } minus build output
     ignore: {string},      -- globs: ".git", "*.db", "*-wal"
     interval_ns: integer,  -- poll period, default 300 ms
     grace_ns: integer,     -- SIGTERM wait before SIGKILL, default 3 s
   }): boolean, string
   ```

   run as `cosmic dev.tl` where dev.tl is two lines. It starts the child
   with `Child.start` (cosmic/child.tl:4013) and env `COSMIC_WEB_DEV=1`,
   `COSMIC_WEB_BOOT=<n>` (n increments per start), forwards its output, and
   every `interval_ns` stats the watched files with `Fs.walk` +
   `Fs.stat` (cosmic/fs.tl:612, 313) comparing mtime and size to the last
   pass; this is what the build's own staging does (build/work.tl
   `moved`), and for a project of hundreds of files it is a millisecond or
   two. On a change it sends SIGTERM (graceful: section 6.3), waits, and
   starts the next. A compile error makes the child exit non-zero at once;
   the supervisor prints it, waits for the next change, and does not
   restart-loop. `kqueue`/`inotify` is a later improvement (a `TODO:` in the
   supervisor naming the missing `cosmic.fs` watch binding).
2. Browser reload without a proxy. In dev mode only, the App adds:
   `GET /_web/dev.js` (a 30-line script, static file, no inline script so
   a strict CSP is fine), `GET /_web/dev/events` (an SSE stream on a
   dedicated Hub, first event `boot` with `COSMIC_WEB_BOOT`) and, through a
   middleware `Dev.reload()` in `cosmic.web.dev` (added to the App's stack in
   dev mode), one
   `<script src="/_web/dev.js" defer>` tag appended before `</body>` of
   string `text/html` responses. The script opens an `EventSource`;
   on `error` it polls `/_web/dev/events` with `fetch` every 300 ms until
   it answers, then `location.reload()` if the boot number changed. The
   supervisor therefore needs no knowledge of the browser, and a restarted
   process needs no proxy to hold connections open across restarts. A
   `css` event (below) swaps `<link rel=stylesheet>` hrefs without a reload.
3. Static changes without a restart: in dev mode the App spawns a watcher
   task that stats `static/` every 250 ms (`Poll.delay`) and publishes `css`
   when only `.css` files moved, `reload` otherwise, on the dev hub. The
   directory source (1.6) already serves the new bytes with a new
   fingerprint; the script does the rest. Templates changes still restart
   (the process is replaced). Editing a `static/` file therefore never
   rebuilds anything.

The dev flag also turns on: full error pages with stack, `no-store` on
static, and htmx `htmx.logAll()` is NOT turned on (noise). The dev pieces
must be off in a built executable: `dev` defaults to the environment only,
a production `cosmic build` binary with `COSMIC_WEB_DEV=1` set by accident
would expose the stack traces, so the `/_web/dev*` routes and error pages
are refused unless the listener address is loopback (`127.0.0.0/8`, `::1`
is refused by the sandbox anyway). The check is made in `Web.serve`, where
the listener addresses are known.

Live reload of the htmx page uses htmx's own boost where possible; the
reload script is deliberately plain.

## 7. WebSockets: the seam in cosmic/http/server.tl

Built later; v1 leaves one hook. The shape is "take the connection": after
the handler answers, the server writes the status line and headers of the
reply, then hands the raw `Net.Conn` and any bytes already read past the
request to a callback and stops serving that connection as HTTP.

```teal
record Reply
  ...
  --- Hands the connection over once the head is written: the server
  --- writes `status` and `headers` (a 101 with its `Upgrade` and
  --- `Connection: Upgrade` headers; or a 200 for a raw stream), no
  --- `Content-Length`, no chunking, no body, then calls `take(conn, rest)`
  --- in the connection's task. `rest` is the bytes the server read past
  --- the request, none for an ordinary upgrade (the client waits for the
  --- 101). The server reads and writes the connection no more, sets its
  --- timeout to nil, and closes it when `take` returns or raises (a raise
  --- goes to `on_error`). `body` and `length` must be nil.
  take: function(conn: Net.Conn, rest: string)
end
```

Changes in cosmic/http/server.tl and wire.tl:

- `reply_trouble` / `wire.check` (server.tl:326-365, wire.tl:750): allow
  status 101 and a `Connection` header when `take` is set; otherwise the
  checks stay (status 200 to 999, no `Connection`, no
  `Transfer-Encoding`).
- `wire.send` (wire.tl:866): a `head_only` path: write `head_text` with no
  framing and return; the `close` flag is forced.
- `exchange` (server.tl:378): after `wire.send` for a `take` reply, drain
  nothing, take `wire.buffered`'s bytes as `rest`, call `take(conn, rest)`
  in an `xpcall` like the handler (server.tl:392), and return false (the
  connection serves nothing more).
- The server tracks taken connections in a set like `s.idle`; `on_stop`
  closes them (a WebSocket would be sent a close frame by its owner first
  through `ServeSpec.on_stop`, section 6.3), and they count toward
  `limits.connections` for free as they remain tasks of `Net.serve`.
- `idle_ns`, `head_ns`, `timeout_ns` stop applying. A WebSocket sets its own
  ping interval and read deadline.

What a WebSocket module (`cosmic.web.ws`) would then need:

- The handshake: validate `Upgrade: websocket`, `Connection: Upgrade`,
  `Sec-WebSocket-Version: 13`, a 16-byte base64 `Sec-WebSocket-Key`;
  answer 101 with `Sec-WebSocket-Accept` = base64(SHA-1(key + GUID)) (both
  `Hash.digest("sha1")` and `Codec.base64` exist). A wrong Origin is refused
  (cross-site WebSocket hijacking is the web analogue of CSRF; cookies
  authenticate the handshake): an allowlist in the App.
- A frame codec (RFC 6455): mask/unmask (client frames are masked),
  fragmentation and continuation, control frames (ping, pong, close with
  code and reason), a max message size, UTF-8 validation of text
  frames. A fuzz test (`*_fuzz_test.tl` driving build.fuzz, as the
  repo requires for a parser of untrusted bytes) and the Autobahn
  testsuite offline.
- A task structure: the reader loop in the connection's task, a writer
  fed by a `Channel` (a `send` from any task must not interleave frames),
  ping every N seconds, close handshake with a timeout.
- Routing: a `WebSocketRoute(path, handler)` in the router's table. A
  handler gets the `Request` (session, headers, path params) and a `ws`
  with `receive()` and `send()`, so it looks like the HTTP handlers.
- permessage-deflate: not in v1 of ws either (it needs a streaming
  deflater with a shared window; `Compress.deflater` exists but a
  no-context-takeover mode first).

Estimate: the seam is about 60 lines plus tests; the ws module about
600 lines plus tests. SSE is not blocked by any of it.

## 8. Changes to existing modules

All small; each with its reason.

- cosmic/layout.tl: `Layout.static` and its value (section 1.1).
- build/identity.tl `is_input` (line 186): accept `static/` files for a
  project tree.
- build/derivation.tl: `derive_assets` (type, gzip, size limits, name rules)
  appended to the step list (line 575).
- build/schema.tl: `payload` gets `sha256`, `type`, `gzip` (line 74-78),
  and a `web_assets` table (near line 80). Delete the payload TODO.
- build/writer.tl: copy asset rows into `payload` (near 558-620).
- build/embed.tl: copy `payload` and `web_assets` (near 170-215).
- build/boot.tl, build/reboot.tl, build/work.tl: read the two vendored
  trees into `web_assets` (like `zoneinfo`).
- vendor/htmx/PIN, vendor/htmx-ext-sse/PIN and the trees `bin/vendor`
  writes; doc/design.md:412 (payload) and a `web_assets` line next to
  `zoneinfo`.
- cosmic/store.tl: `Store.web_asset` beside `Store.zoneinfo` (line 119).
- cosmic/poll.tl: `Poll.Notifier`, `Poll.notifier`.
- cosmic/channel.tl: new.
- cosmic/http/server.tl: forward `on_stop` in `ServeSpec` and
  `Server.serve` (line 106-146, 597; core.md section 13.7); `Reply.take`
  seam later.
- cosmic/web/mime.tl, cosmic/web/assets.tl (support modules),
  cosmic/web/static.tl (`cosmic.web.static`), cosmic/web/sse.tl
  (`cosmic.web.sse`: `Event`, `EventStream`, `Hub`, `Subscription`) and
  cosmic/web/dev.tl (`cosmic.web.dev`): new, under the `cosmic.web`
  namespace. `cosmic/web/init.tl` re-exports. `Htmx.head`, `Htmx.path`,
  `Htmx.integrity` and `Htmx.indicator_css` are in cosmic/web/htmx.tl
  (templates.md section 6.6), reading `Store.web_asset`.
- AGENTS.md: a sentence on `static/` in the layout paragraph (documentation
  only).
- doc/roadmap.md: epoll/kqueue, multi-process hub, WebSockets, brotli,
  htmx refresh, request-level `Last-Modified`.

Each module that is new needs `*_test.tl`; each exported symbol must be
used or earn its export (`build/tree_checks.tl`'s every-export-earned rule).
Because new C is avoided, none of the C rules apply.

## 9. Tests

Conventions from AGENTS.md: `*_test.tl` with top-level `local function
test_*`; no `return`; every test calls `assert`; loopback addresses are
declared with `Test.policy { loopback = {"127.0.1.1"} }` and the server
runs on `127.0.0.1`-range addresses only.

- cosmic/poll_notifier_test.tl: as in 5.2.
- cosmic/channel_test.tl: FIFO order; capacity; each overflow policy;
  close wakes receivers and senders; timeout; cancel; drop counter.
- cosmic/web/mime_test.tl: the table, charset, unknown, case.
- cosmic/web/assets_test.tl: memory and directory sources, hit/miss,
  re-read on change, symlink behavior documented, hash and etag, gzip,
  integrity value equals a fixed known SHA-384 of fixed bytes.
- cosmic/web/static_test.tl: against `Assets.memory`, driven through the
  handler directly (no socket): 200, HEAD, 304 by ETag and `*` and weak
  match, 206/416/whole by Range and `If-Range`, traversal inputs
  (`/..%2f`, `/%2e%2e/`, `//`, `/./`, NUL, over-long, dotfile), fingerprint
  rewrite and the stale-digest 404, gzip negotiation (`gzip;q=0`),
  method 405, the SVG CSP, no `Content-Length` conflicts. One socket test
  per behavior that crosses the server (a HEAD's Content-Length, Range on a
  real connection) with a loopback server.
- cosmic/web/sse_event_test.tl and sse_event_fuzz_test.tl: formatter cases and the
  round-trip/injection properties (5.4).
- cosmic/web/sse_hub_test.tl: subscribe/publish/unsubscribe, replay with and
  without a gap, overflow close, limits, `close()`, ids.
- cosmic/web/sse_test.tl: a loopback server with a raw client (`Net.connect`
  to the server): the headers (content type, no `Content-Length`,
  `Transfer-Encoding: chunked`), `retry:` first, an event arrives within a
  poll of publish, a heartbeat arrives with `heartbeat_ns` of 50 ms,
  client close then `subscribers() == 0` after at most two beats, stop with
  an open stream ends in under `grace_ns`, stream budget 503.
- build tests (in build/): staging admits `static/` and refuses the rules
  in 1.2; the projection is byte-identical across two builds
  (the existing determinism tests); `payload` rows and the gzip column;
  `cosmic build` carries them; the `web_assets` table holds the two files,
  and `sha384` equals an independent computation; a `store = true`
  test reads them through `Store.web_asset`.
- vendor: `build/vendor_test.tl` already exercises PIN parsing; add the two
  PINs to whatever list asserts every `vendor/*/PIN` has `license` and
  `notice` (bom).
- sealed workers: the web tests that need no store rows stay sealed;
  `Test.policy` for the loopback ones only; the test that needs
  `payload` and `web_assets` sits in its own `store = true` module with
  the reason above its declaration (AGENTS.md).

## 10. Security

- Path traversal: section 3.7; `Url.segments` is the only decoder; the
  embedded source has no path at all.
- Stale immutable content: the fingerprint is verified, never trusted.
- MIME confusion: types from a fixed table, `nosniff`, SVG sandboxed.
- Cache poisoning/leaks: `Vary: Accept-Encoding` where encodings vary;
  distinct ETags per encoding; `public` only for non-secret bytes, which
  everything in `static/` is by definition.
- SSE injection: the formatter splits on every line ending, so event data
  cannot add a field or end an event; `id` and `event` with a CR or LF
  raise. Tested as a property.
- SSE authz: the route decides topics from the session; a client-supplied
  topic must be validated (an allowlist or a prefix computed from the
  session). `Last-Event-ID` is opaque text.
- SSE and CSRF: GET only, cookies sent (`withCredentials`), so the stream
  must never carry state changes, and because an EventSource ignores the
  CORS-less cross-site rule only with credentials set by the page, an
  attacker page cannot read a cross-origin stream (the browser blocks the
  response without CORS headers); the CORS middleware must not reflect
  arbitrary origins for `text/event-stream` routes.
- Resource exhaustion: stream budget, per-client cap, queue bound, event
  size bound, `max_age_ns`, replay ring bound, header writes bounded.
- htmx config: the one defined in templates.md section 6.6 (`allowEval`,
  `allowScriptTags` and `includeIndicatorStyles` off, `selfRequestsOnly`
  on), written by `Htmx.head`; SRI on the tag; vendored bytes verified by
  PIN checksum at `bin/vendor` and by a test of the stored digest.
- Dev: loopback only and environment-gated (section 6.4).
- Supply chain: the PIN's checksum and the BOM entry; the licence is 0BSD
  and carries no obligation.

## 11. TODOs this work expects to leave in code

Each belongs in the code the moment it is due (AGENTS.md):

- `TODO:` in cosmic/web/static.tl for `If-Modified-Since`, once
  `Time.parse_http` (confirm it exists) is available.
- `TODO:` in cosmic/web/dev.tl for inotify/kqueue, once `cosmic.fs` has a
  watch binding.
- `TODO:` in cosmic/web/sse.tl for prompt disconnect detection, once
  `Reply.take` exists.
- `TODO:` in build/embed.tl: omit `web_assets` for a project that does not
  require `cosmic.web`.
- `TODO:` in cosmic/web/sse.tl: a hub that spans processes.
- `TODO:` in the stream budget: benchmark `poll_once` at several thousand
  idle streams, once doc/performance has a harness for it.

Not TODOs, because no caller needs them yet (doc/roadmap.md): brotli,
epoll/kqueue, WebSocket module, CSS `url()` rewriting, ranges over multiple
parts, multi-process hub.

## 12. Open questions, with recommendations

1. htmx 2.0.11 or 4.0.0? Decided: 2.x, and 4.0.0 is only the `next`
   tag. Recommend 2.0.11 with SSE as an extension; revisit when 4.x is
   `latest` and has a stable SSE contract.
2. Generic `Channel<T>`: does build/contracts.tl allow generic records in
   the standard library? Recommend generic if allowed, else a `Channel` of
   `string`.
3. Should a SQLite transaction wrapper detect a wait inside a transaction
   (an interleaving hazard, section 6.2)? Recommend yes, later, with a
   per-connection Notifier-based lock; for v1 document the rule.
4. Name and home of `Poll.Notifier`. Recommend `Poll.notifier()` in
   cosmic.poll (it needs the scheduler's internals); the alternative of a
   polling `Poll.delay` loop is wasteful and rejected.
5. `payload` repurposed vs a new `assets` table. Recommend reusing
   `payload` (it is reserved and documented for exactly this) and changing
   its columns; the table has never been written, so nothing migrates.
6. Embed `web_assets` in every executable (recommended, 55 KB) or only
   when `cosmic.web` is required.
7. A single cap of 16 MiB per embedded file, and whole-file memory
   caching. Recommend yes; large media belongs elsewhere. An incremental
   blob API could stream big embedded files later.
8. Reserved prefix `/_web/` for built-in routes. Decided: the router refuses
   user routes under it (core.md section 5.5).
9. Dev supervision as a library (`cosmic dev.tl`) vs a verb (`cosmic
   web dev`). Recommend library in v1: a verb needs a `Cli` entry, a
   guide and tests (build/verb_list.tl header) for little gain.
10. `Reply.take` shape (callback) vs `Request.conn`. Recommend the callback:
    the server keeps ownership of the connection's lifetime, and the head is
    validated by the same `wire.check` rules.
11. Prompt disconnect detection for SSE: ship v1 with heartbeats (<=15 s
    lag) or pull `Reply.take` forward. Recommend v1 with heartbeats.
12. A Mount's reverse resolver, so `url_for("static", ...)` reaches
    `StaticFiles:url`. Decided: `reverse` on `Web.mount_handler`'s options
    (core.md section 5.7).
13. `If-Modified-Since` and `Last-Modified` for embedded assets: omitted by
    design (reproducible builds have no time). Recommend omit.
14. Should `Hub` be per-App or global? Recommend explicit values (no
    hidden globals), registered with the App for shutdown.
