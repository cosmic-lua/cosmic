# cosmic

cosmic is a runtime for self-contained command-line software: one file
holds the language, the compiler, the standard library, and the build.
Programs it builds ship the same way, one executable, carrying a
database of compiled modules rather than reading files at run time.

## build

```text
bin/zig build boot
```

`boot` builds the host's core and stages the working database in the
build directory, outside the checkout: `~/.cache/cosmic/trees/<key>`
(under `$XDG_CACHE_HOME` when set), `<key>` the SHA-256 of the checkout's
canonical path, or under the absolute base `COSMIC_BUILD_HOME` names
([`build/paths.tl`]). [`bin/cosmic`] runs the tool built there, from any
directory, and boots first if there is none; `bin/cosmic db` names its
databases. The tool carries the host's core alone; `bin/zig build boot
-Dboot-cores=all` builds every release core, which `cosmic build` needs to write a
program that runs on every target.

## install

cosmic publishes a prerelease of each commit on main that passes CI.
There are no version numbers and no `latest`: a release is promoted by
hand, so pick one yourself from the
[releases page](https://github.com/cosmic-lua/cosmic/releases) or with

```sh
gh release list -R cosmic-lua/cosmic
```

A release is tagged `YYYYMMDD-<sha>`, the UTC date of its commit and
the commit's 40 hex digits (the earlier ones are tagged `next-<sha>`).
Its assets are `cosmic`, the one portable executable for every
platform, `SHA256SUMS` and `source.json`, and they download from

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

Check the download against the release's `SHA256SUMS` before running it:
it names the digest of `cosmic` (`<sha256>  cosmic`). `bin/cosmic release`
does the same from a checkout: it picks a release, verifies it against
its `SHA256SUMS` and `source.json`, and downloads it (`bin/cosmic help
release`).

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

what cosmic is for and how it is built lives in
[doc/design.md](doc/design.md); how this documentation works, and what
its examples promise, is [doc/writing.md](doc/writing.md).

[`bin/cosmic`]: bin/cosmic
[`build/paths.tl`]: build/paths.tl
