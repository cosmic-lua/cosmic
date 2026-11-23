# cosmic

cosmic is a runtime for self-contained command-line programs. One
executable holds the language, the compiler, the standard
library and the build. A program that cosmic builds is also one
executable. It carries a database of its compiled modules, and reads no
source files when it runs.

## build

```text
bin/zig build boot
```

`boot` builds the core for this host and stages the working database.
Both go in the build directory, outside the checkout:
`~/.cache/cosmic/trees/<key>`, where `<key>` is the SHA-256 of the
checkout's canonical path. When `$XDG_CACHE_HOME` is set, the build
directory is `$XDG_CACHE_HOME/cosmic/trees/<key>`. When
`COSMIC_BUILD_HOME` is set, it must be an absolute path, and the build
directory is under it ([`build/paths.tl`]).

[`bin/cosmic`] runs the tool from the build directory, from any
directory. It boots first if there is no tool yet. `bin/cosmic db` says
what the build directory's databases hold.

The tool holds the core for this host only. To build a program that
runs on every target, `cosmic build` needs every release core.
`cosmic build` boots them itself the first time, or you can run
`bin/zig build boot -Dboot-cores=all`.

## install

cosmic publishes a prerelease for most commits on main after CI passes
on them. A commit has none when its run was cancelled or GitHub did not
let the job tag it. There are no version numbers and no `latest`: a
release is promoted by hand. Pick a release
from the [releases page](https://github.com/cosmic-lua/cosmic/releases)
or with

```sh
gh release list -R cosmic-lua/cosmic
```

A release's tag is `YYYYMMDD-<sha>`: the UTC date of its commit and the
commit's 40 hex digits. Older releases have the tag `next-<sha>`. Each
release has three assets: `cosmic`, one executable for every platform;
`SHA256SUMS`; and `source.json`. They download from

```text
https://github.com/cosmic-lua/cosmic/releases/download/<tag>/cosmic
https://github.com/cosmic-lua/cosmic/releases/download/<tag>/SHA256SUMS
```

for example, with `<tag>` as `20261018-0123456789abcdef0123456789abcdef01234567`:

```sh
tag=20261018-0123456789abcdef0123456789abcdef01234567
base=https://github.com/cosmic-lua/cosmic/releases/download/$tag
curl -fsSLO "$base/cosmic" -O "$base/SHA256SUMS"
sha256sum -c SHA256SUMS   # shasum -a 256 -c SHA256SUMS on macOS
chmod +x cosmic
./cosmic help
```

Check the download against `SHA256SUMS` before you run it. Its line
for the executable is `<sha256>  cosmic`. From a checkout,
`bin/cosmic release` does these steps for you: it picks a release,
downloads it, and checks it against `SHA256SUMS` and `source.json`
(`bin/cosmic help release`).

## run a file

```sh
echo 'print("hello from the database")' > hello.tl
bin/cosmic hello.tl
```

```output
hello from the database
```

## learn more

cosmic's code is Teal, typed Lua: see [teal-language.org](https://teal-language.org).
The tool documents itself, in a release binary too:

- `cosmic help` lists every verb, and `cosmic help <verb>` describes one.
- `cosmic docs` lists the standard library and the guides, and
  `cosmic docs <name or words>` shows one or searches them all.
- `cosmic docs quickstart` is a tour of the standard library, and
  `cosmic docs project` builds a first project: its files, tests,
  program, and the verbs that run them. Their sources are
  [doc/guides/quickstart.md](doc/guides/quickstart.md) and
  [doc/guides/project.md](doc/guides/project.md).

## design

[doc/design.md](doc/design.md) says what cosmic is for and how it is
built. [doc/writing.md](doc/writing.md) says how this documentation is
written and what its examples promise.

[`bin/cosmic`]: bin/cosmic
[`build/paths.tl`]: build/paths.tl
