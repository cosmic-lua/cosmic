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

- `serve <port> [--max-keys <n>]`: serves HTTP/1.1 on 127.0.0.1 at
  `<port>`; port `0` means any free port. Once it is accepting
  connections it prints exactly one line to stdout,
  `listening on 127.0.0.1:<port>` with the actual port, and keeps
  serving until it is sent SIGTERM or SIGINT, when it exits 0. Keys and
  values live in memory. It answers:
  - `PUT /<key>` with the request body as the value: `204`.
  - `GET /<key>`: `200` with the value as the body, or `404` if unset.
  - `GET /<key>?wait=<seconds>`, `<seconds>` a number from 0 to 60
    (fractions allowed): `200` with the value at once if the key is
    set; otherwise it waits, answering `200` with the value as soon as
    a `PUT` sets the key, or `404` once `<seconds>` have passed with
    it still unset. A waiting request holds up no other client. Any
    other query, or a `wait` that is not such a number: `400`.
  - `DELETE /<key>`: `204`, or `404` if unset.
  - `GET /`: `200`, every key set, one per line, sorted.
  - Anything else: `400` or `405`.
  Keys are one path segment of letters, digits, `-` and `_`. Every
  response but a `204` carries a correct `Content-Length`. One slow or idle client
  must not hold up the others: while one connection sits open having
  sent half a request, other clients are still answered promptly.
- With `--max-keys <n>`, `<n>` a whole number 1 or more, the store holds
  at most `n` keys: a `PUT` of a key not set while `n` keys are set
  first removes the least recently used key. A key is used when a
  `PUT` sets it (new or replaced) and when a `GET` of it answers `200`
  (a waiting one included, as it answers); nothing else uses a key,
  and `DELETE` removes it. Without the option there is no limit. A
  `--max-keys` that is not such a number is an error before serving:
  a message on stderr and a non-zero exit code.
- `put <url> <value>`, `get <url>`, `rm <url>`: the client, where
  `<url>` is like `http://127.0.0.1:8080/name`. `get` prints the value
  to stdout exactly as stored. A `404`, a refused connection or any
  other failure is a message on stderr and a non-zero exit code.
- `help`: prints usage naming every command above and `--max-keys`,
  to stdout, and exits 0. Run this one with no other arguments.
- Use cosmic's own networking and HTTP support rather than calling
  other programs.

The project's library module is named `kv`, `require("kv")`, and
exports at least this API, which the project's own server uses for its
store and which is checked through these names and types:

- `kv.Lru<K, V>`, a generic record: a map from `K` to `V` holding at
  most a fixed number of entries, with these methods, called as
  `lru:get(key)`:
  - `kv.Lru.new(capacity: integer): kv.Lru<K, V>`, an empty one
    holding at most `capacity` (1 or more) entries;
  - `get(key: K): V`, the value, or nil when there is none; finding
    one uses the key;
  - `put(key: K, value: V): K, V` sets the key and uses it, first
    removing the least recently used entry if the key is new and the
    map is full, and answers the key and value removed, or nil;
  - `delete(key: K): boolean` removes the key, answering whether it
    was there;
  - `len(): integer`, how many entries it holds;
  - `keys(): {K}`, every key, the least recently used first.

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
