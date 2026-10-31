# Task

You have one tool you have never seen before: `cosmic`, a runtime for
command-line programs written in Teal (typed Lua). It is on your PATH.
The binary is the only source of information about it: there is no
documentation, repository, website, or package index for it, and you
must not use skills, plugins, web search, or any prior knowledge of a
project called "cosmic". Treat it as unknown. Anything the binary itself
tells you (help text, error messages, output of any command you can
think of running against it, or inspecting the file itself) is fair game.

Work only inside this directory. Do not read or write anything outside it
except the `cosmic` binary and scratch files under `$TMPDIR`, which is
yours for anything temporary.

## What to build

A small project, `mirror`, in Teal, using cosmic. It is a static file
server over HTTP/1.1 and a client that mirrors a directory from one:

- `serve <source> <port>`: serves the files of `<source>` on 127.0.0.1
  at `<port>`; port `0` means any free port. Once it is accepting
  connections it prints exactly one line to stdout,
  `listening on 127.0.0.1:<port>` with the actual port, and keeps
  serving until it is sent SIGTERM or SIGINT, when it exits 0.
  `<source>` is a directory, or an archive file whose name ends in
  `.tar`, `.tar.gz`, `.tgz` or `.zip`, served read-only as if it were
  the directory its entries were made from: an entry `sub/b.bin` is
  served at `/sub/b.bin` (as is an entry `./sub/b.bin`), and `sub` is
  a directory whether or not the archive holds an entry of its own for
  it. Entries other than files and directories are left out. A source that is neither, or an
  archive that cannot be read or holds an entry whose path starts with
  `/` or has a `..` part, is an error before serving: a message on
  stderr and a non-zero exit code. Below, `<dir>` is the source's
  directory. It answers:
  - `GET` and `HEAD` of a URL path naming a regular file under `<dir>`
    (percent-encoded bytes decoded): `200` with the file's bytes, and
    an `ETag` header, a strong entity tag made of the lowercase hex
    SHA-256 of the file's contents in double quotes. `HEAD` answers
    the headers `GET` would, with no body.
  - `If-None-Match` carrying the file's current tag: `304`, no body.
  - `Range: bytes=<first>-<last>`, `bytes=<first>-` or
    `bytes=-<suffix length>` (one range): `206` with just those bytes
    and `Content-Range: bytes <first>-<last>/<size>`; a range starting
    at or past the end of the file: `416` with
    `Content-Range: bytes */<size>`.
  - A request whose `Accept-Encoding` includes `gzip`, for a file over
    1024 bytes and without a `Range`: the body gzip-compressed, with
    `Content-Encoding: gzip`. Files of 1024 bytes or fewer, and every
    other request, are sent as they are, with no `Content-Encoding`.
  - A URL path naming a directory under `<dir>` (`/` is `<dir>`
    itself), with or without a trailing `/`: `200` with a JSON array
    listing its entries sorted by name, each
    `{"name": ..., "type": "file", "size": <bytes>, "sha256": <hex>}`
    for a regular file or `{"name": ..., "type": "dir"}` for a
    directory.
  - A path that would reach outside `<dir>` (`..` segments, encoded
    or not): `403` or `404`, never anything outside `<dir>`. A path
    naming nothing: `404`. Any method but `GET` and `HEAD`: `405`.
  Every response with a body carries a correct `Content-Length`, and
  a request carrying `Connection: close` has its connection closed
  after the response. One slow or idle client must not hold up the
  others: while one connection sits open having sent half a request,
  other clients are still answered promptly.
- `pull <url> <dest>`: mirrors the directory a `serve` serves at
  `<url>` (like `http://127.0.0.1:8080/`, `http://127.0.0.1:8080` or
  `http://127.0.0.1:8080/sub`)
  into `<dest>`, recursively, creating directories as needed. A file
  already in `<dest>` whose SHA-256 matches the listing's is skipped;
  any other is downloaded and checked against the listing's `sha256`.
  It prints one line per file to stdout, `fetched <path>` or
  `skipped <path>`, with `<path>` relative to `<dest>`, `/` between
  parts. A file whose bytes do not match the listing's hash is an
  error naming the file, and leaves nothing of it in `<dest>`, not
  even a partial or temporary file. Any failure is a message on stderr
  and a non-zero exit code.
- `help`: prints usage naming `serve` and `pull`, to stdout, and exits
  0. Run this one with no other arguments.
- Use cosmic's own networking, HTTP, hashing, compression and archive
  support rather than calling other programs.

The project's library module is named `mirror`, `require("mirror")`,
and exports at least this API, which the project's own program uses and
which is checked through these names and types. A path here is
relative to the source's top, its parts joined by `/`, with no `/` at
either end: `""` is the top itself, `"sub/b.bin"` a file under it. A
path with an empty, `.` or `..` part names nothing.

- `mirror.Kind`: an enum of `"file"` or `"dir"`.
- `mirror.Info`: a record with `kind: mirror.Kind`, and `size: integer`,
  a file's length in bytes (0 for a directory).
- `mirror.Source`: an interface, which both kinds of source implement,
  with these methods, each answering nil and a message for a path
  that names nothing of that kind:
  - `stat(path: string): mirror.Info | nil, string`;
  - `list(path: string): {string} | nil, string`, the names of a
    directory's entries, sorted bytewise;
  - `read(path: string): string | nil, string`, a file's bytes.
- `mirror.open(path: string): mirror.Source | nil, string`: the source
  at `path`, a directory or an archive as `serve` takes one, or nil and
  why it is neither.
- `mirror.listing(source: mirror.Source, path: string): string | nil,
  string`: the JSON listing `serve` answers for the directory at
  `path` of any source that implements the interface above, the
  project's own or another.

The project must have all four of these:

1. **Tests** of the project's own code, which cosmic runs and passes.
   Show them passing.
2. **Examples**: worked examples of using the project's own code, in
   whatever form cosmic treats as an example, so that cosmic itself
   checks or runs them.
3. **Formatting**: every Teal source formatted the way cosmic itself
   formats Teal.
4. **A binary**: a single standalone executable named `mirror`,
   produced by cosmic from this project, that runs the tool above on
   its own: copied alone into an empty directory and run with an empty
   environment (no `PATH`, no `HOME`, no `cosmic` anywhere), it still
   works. Show it running: `./mirror serve somedir 0` in one shell and
   `./mirror pull` against it into an empty directory, twice, in
   another.

How cosmic finds tests and examples, formats code, and produces a
binary is for you to find out from the binary.

## Deliverables, all in this directory

1. The project: source, tests, examples, and the produced `mirror`
   executable, working as far as you can get them.
2. `JOURNAL.md`, described below.
