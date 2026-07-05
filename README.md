# cosmic

cosmic is a batteries-included Lua distribution that runs on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD from a single executable. It ships Lua 5.4, the [Teal](https://github.com/teal-language/tl) typed-Lua compiler, and a rich standard library (`cosmic.*`) for networking, filesystem, JSON, SQLite, crypto, and more. Executables are built on [Cosmopolitan Libc](https://github.com/jart/cosmopolitan) and run natively on every target without any install or interpreter.

## Install

Download the latest release from the [releases page](https://github.com/whilp/cosmic/releases):

```sh
# download
curl -fsSL -o cosmic-lua \
  https://github.com/whilp/cosmic/releases/latest/download/cosmic-lua

# verify checksum (optional but recommended)
curl -fsSL -o SHA256SUMS \
  https://github.com/whilp/cosmic/releases/latest/download/SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS

# make executable
chmod +x cosmic-lua

# run
./cosmic-lua --help
```

### APE binfmt quirk (Linux)

`cosmic-lua` is an [Actually Portable Executable](https://justine.lol/ape.html). On Linux systems without `binfmt_misc` registered for the APE format, the first run may fail. Work around it by running through `sh` once:

```sh
sh ./cosmic-lua --help
```

After that first invocation the kernel binfmt cache is primed and `./cosmic-lua` works directly. Alternatively, register the APE binfmt once at boot:

```sh
echo ':APE:M::MZqFpD::/usr/bin/ape:' | sudo tee /proc/sys/fs/binfmt_misc/register
```

## Hello, World

```teal
-- hello.tl
print("hello, world")
```

```sh
./cosmic-lua hello.tl
```

Or use `cosmic.proc.is_main()` to write a file that works both as a script and as an importable module:

```teal
-- greet.tl
local proc = require("cosmic.proc")

local function greet(name: string): string
  return "hello, " .. name
end

if proc.is_main() then
  print(greet(arg[1] or "world"))
end

return { greet = greet }
```

```sh
./cosmic-lua greet.tl        # prints: hello, world
./cosmic-lua greet.tl Alice  # prints: hello, Alice
```

## Standard Library

```teal
local fetch  = require("cosmic.fetch")
local json   = require("cosmic.json")
local fs     = require("cosmic.fs")
local sqlite = require("cosmic.sqlite")
```

See [`docs/stdlib.md`](docs/stdlib.md) for the full module reference.

## Links

- [Standard library reference](docs/stdlib.md)
- [Contributing / build instructions](AGENTS.md)
- [Releases](https://github.com/whilp/cosmic/releases)
- [Teal language](https://github.com/teal-language/tl)
- [Cosmopolitan Libc](https://github.com/jart/cosmopolitan)
