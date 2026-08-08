# cosmic

cosmic is a batteries-included [Teal](https://github.com/teal-language/tl)
(typed Lua) distribution built on
[Cosmopolitan Libc](https://github.com/jart/cosmopolitan). it ships as a
single fat binary — `cosmic-lua` — that runs on Linux, macOS, Windows,
FreeBSD, OpenBSD, and NetBSD, on both x86_64 and aarch64, with no
installation step and no dependencies.

the binary contains the Lua 5.4 runtime, the Teal compiler and type
checker, a typed standard library (`cosmic.*`: fs, net, fetch, json,
sqlite, crypto hashing, sandboxing, and more), embedded documentation,
and tooling for building your own single-file executables.

## install

download the latest release, make it executable, run it:

```sh
curl -fsSLO https://github.com/whilp/cosmic/releases/latest/download/cosmic-lua
chmod +x cosmic-lua
./cosmic-lua --version
```

to verify the download, fetch `SHA256SUMS` from the same release and
check it:

```sh
curl -fsSLO https://github.com/whilp/cosmic/releases/latest/download/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
```

`cosmic-lua` is an [αcτµαlly pδrταblε
εxεcµταblε](https://justine.lol/ape.html): the same file is a valid
program on every supported OS. one quirk: some Linux systems have a
`binfmt_misc` rule (usually Wine's) that intercepts its MZ header and
fails with `run-detectors: unable to find an interpreter`. run it
through the shell once and the binary self-repairs into a form that
executes directly from then on:

```sh
sh ./cosmic-lua --version
```

each release also includes `cosmic-lua-debug`, the same binary with
symbols and debugging checks.

## hello, world

```teal
-- hello.tl
local json = require("cosmic.json")

local function greet(name: string): string
  return json.encode({hello = name})
end

print(greet(arg[1] or "world"))
```

```sh
$ ./cosmic-lua hello.tl
{"hello":"world"}
```

scripts are type checked as they run; `./cosmic-lua --check types
hello.tl` checks without running. `./cosmic-lua -i` starts a REPL, and
`./cosmic-lua --docs fs` searches the embedded documentation.

## learn more

- [docs/goals.md](docs/goals.md) and
  [docs/decisions/](docs/decisions/) — why cosmic exists, what it
  promises, and the tradeoffs behind it
- [docs/stdlib.md](docs/stdlib.md) — standard library tour and error
  handling conventions
- [docs/architecture.md](docs/architecture.md) — how the binary is put
  together
- [docs/build.md](docs/build.md) — `cosmic --make`: how the build
  system sees a project
- [docs/contributing.md](docs/contributing.md) and
  [AGENTS.md](AGENTS.md) — developing cosmic itself
- [whilp/cosmopolitan](https://github.com/whilp/cosmopolitan) — the
  Cosmopolitan fork that provides the C core

## license

[MIT](LICENSE).
