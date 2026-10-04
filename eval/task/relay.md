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

A small project, `relay`, in Teal, using cosmic. It is a TCP port
forwarder:

- `relay <listen-port> <target>`, `<target>` written `<host>:<port>`
  with `<host>` a numeric IPv4 address, listens on 127.0.0.1 at
  `<listen-port>`; port `0` means any free port. Once it is accepting
  connections it prints exactly one line to stdout,
  `listening on 127.0.0.1:<port>` with the actual port.
- For each connection it accepts, it connects to `<target>` and copies
  bytes both ways at once, each as soon as it arrives, without waiting
  for more: from the client to the target ("up") and from the target
  to the client ("down"). If the target cannot be reached, the
  client's connection is closed with nothing sent to it, a line on
  stderr says why, and `relay` goes on serving.
- When one side ends what it sends (it closes, or shuts down its
  sending half), `relay` shuts down its own sending half toward the
  other side, after everything the first side sent before its end, and
  goes on
  copying the other way until that ends too; then it closes both
  connections. A connection that fails (reset, refused write) closes
  both at once.
- Many connections are served at once, and none waits on another: a
  client that sends without reading what comes back, or a target that
  is slow, holds up no other connection.
- With `--idle <seconds>`, `<seconds>` a number greater than 0
  (fractions allowed), a pair of connections through which no byte has
  moved either way for that long is closed, both sides. Without it
  there is no limit.
- Sent SIGTERM or SIGINT, it stops accepting, closes every connection,
  prints one line to stdout,
  `relayed <n> connections, <up> bytes up, <down> bytes down` --
  `<n>` the connections it accepted, `<up>` and `<down>` the bytes it
  passed each way -- and exits 0, within two seconds.
- Options may come before or after the other arguments. A missing or
  malformed argument (a port that is not one, a target without a
  numeric host and port, an `--idle` that is not such a number) is an
  error before listening: a message on stderr and a non-zero exit
  code.
- `help`: prints usage naming `--idle`, to stdout, and exits 0. Run this
  one with no other arguments.
- Use cosmic's own networking support rather than calling other
  programs.

The project's library module is named `relay`, `require("relay")`, and
exports at least this API, which the project's own program uses for
each connection and which is checked through these names and types:

- `relay.Options`, a record: `idle_ns: integer`, the idle limit in
  nanoseconds (nil for none).
- `relay.Stats`, a record: `up: integer` and `down: integer`, the bytes
  passed from `a` to `b` and from `b` to `a`, and `idle: boolean`,
  whether the idle limit ended it.
- `relay.pipe(a, b, options: relay.Options): relay.Stats`, where `a`
  and `b` are connected sockets of the type cosmic's networking module
  gives a connection: copies between them as `relay` copies between a
  client (`a`) and its target (`b`), half-closes and idle limit
  included, until both ways have ended, closes both, and answers what
  passed. It runs among cosmic's cooperative tasks, as a connection
  handler of a cosmic server does, and lets the others run while it
  waits.

The project must have all four of these:

1. **Tests** of the project's own code, which cosmic runs and passes.
   Show them passing.
2. **Examples**: worked examples of using the project's own code, in
   whatever form cosmic treats as an example, so that cosmic itself
   checks or runs them.
3. **Formatting**: every Teal source formatted the way cosmic itself
   formats Teal.
4. **A binary**: a single standalone executable named `relay`, produced
   by cosmic from this project, that runs the tool above on its own:
   copied alone into an empty directory and run with an empty
   environment (no `PATH`, no `HOME`, no `cosmic` anywhere), it still
   works. Show it running: `./relay 0 127.0.0.1:<port>` in one shell,
   in front of a server of your own, and a client of yours through it
   in another.

How cosmic finds tests and examples, formats code, and produces a
binary is for you to find out from the binary.

## Deliverables, all in this directory

1. The project: source, tests, examples, and the produced `relay`
   executable, working as far as you can get them.
2. `JOURNAL.md`, described below.
