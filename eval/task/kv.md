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

A small project, `kv`, in Teal, using cosmic. It is a key-value store
served over HTTP, with its own client:

- `serve <port>`: serves HTTP/1.1 on 127.0.0.1 at `<port>`; port `0`
  means any free port. Once it is accepting connections it prints
  exactly one line to stdout, `listening on 127.0.0.1:<port>` with the
  actual port, and keeps serving until it is sent SIGTERM or SIGINT,
  when it exits 0. Keys and values live in memory. It answers:
  - `PUT /<key>` with the request body as the value: `204`.
  - `GET /<key>`: `200` with the value as the body, or `404` if unset.
  - `DELETE /<key>`: `204`, or `404` if unset.
  - `GET /`: `200`, every key set, one per line, sorted.
  - Anything else: `400` or `405`.
  Keys are one path segment of letters, digits, `-` and `_`. Every
  response but a `204` carries a correct `Content-Length`. One slow or idle client
  must not hold up the others: while one connection sits open having
  sent half a request, other clients are still answered promptly.
- `put <url> <value>`, `get <url>`, `rm <url>`: the client, where
  `<url>` is like `http://127.0.0.1:8080/name`. `get` prints the value
  to stdout exactly as stored. A `404`, a refused connection or any
  other failure is a message on stderr and a non-zero exit code.
- `help`: prints usage naming every command above, to stdout, and
  exits 0. Run this one with no other arguments.
- Use cosmic's own networking and HTTP support rather than calling
  other programs.

The project must have all four of these:

1. **Tests** of the project's own code, which cosmic runs and passes.
   Show them passing.
2. **Examples**: worked examples of using the project's own code, in
   whatever form cosmic treats as an example, so that cosmic itself
   checks or runs them.
3. **Formatting**: every Teal source formatted the way cosmic itself
   formats Teal.
4. **A binary**: a single standalone executable named `kv`, produced
   by cosmic from this project, that runs the tool above on its own:
   copied alone into an empty directory and run with an empty
   environment (no `PATH`, no `HOME`, no `cosmic` anywhere), it still
   works. Show it running: `./kv serve 0` in one shell and `./kv put`, `./kv get` against it in another.

How cosmic finds tests and examples, formats code, and produces a
binary is for you to find out from the binary.

## Deliverables, all in this directory

1. The project: source, tests, examples, and the produced `kv`
   executable, working as far as you can get them.
2. `JOURNAL.md`, described below.
