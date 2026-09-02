# Add a pinned dependency

steps to add a third-party asset the build fetches by digest, for a
contributor who needs a release archive or binary the tree does not
carry.

## 1. write the pin

1. create `3p/<name>/<name>_pin.tl`. the `_pin.tl` suffix is the whole
   registration: `--make fetch` finds it by name.
2. write one `return { ... }` of literals:

   ```lua
   return {
     version = "1.0.0",
     format = "tar.gz",
     strip_components = 1,
     url = "https://example.com/releases/{version}/mylib.tar.gz",
     platforms = {
       ["*"] = {
         sha = "0000000000000000000000000000000000000000000000000000000000000000",
       },
     },
   }
   ```

3. fill the fields:

   | field | required | meaning |
   |---|---|---|
   | `url` | yes | where the bytes come from. `{version}` and `{platform}` are the only substitutions the grammar allows |
   | a digest | yes | the sha256 of the downloaded bytes, lowercase hex: `sha256` at the top level, or `sha` on a `platforms` row |
   | `platforms["*"]` | | the row for bytes that are the same on every host: a fat binary, a source tarball |
   | `platforms["<os>-<arch>"]` | | one row per host when the bytes differ. the matched tag replaces `{platform}` in the url |
   | `version` | no | replaces `{version}` in the url. a bump changes this line and the digest |
   | `format` | no | `"zip"` or `"tar.gz"`. with it, `fetch` unpacks the archive after the digest matches. without it, the pin is a file |
   | `strip_components` | no | leading path segments to drop when unpacking, for an archive wrapped in a release-named directory |

the grammar admits literals only: no concatenation, no variables, no
calls. `cosmic.literal` reads the file as data and `_make/pin.tl`
resolves it; a pin that computes anything fails to parse. a pin without
a digest is a download, and the point of a pin is that the bytes are
named.

## 2. get the digest

1. download the asset once and hash it:

   ```bash
   curl -fsSL https://example.com/releases/1.0.0/mylib.tar.gz | sha256sum
   ```

2. write the printed hex into the pin.

## 3. fetch it

1. run the one verb with a network:

   ```bash
   bin/cosmic --make fetch
   ```

2. read where the bytes landed. `fetch` puts them under `o/`, mirroring
   the pin's position: `3p/<name>/<name>_pin.tl` lands in `o/3p/<name>/`,
   the way `3p/tl/tl_pin.tl` lands in `o/3p/tl/` with `tl.lua` inside.

`fetch` verifies before it unpacks. bytes that do not hash to the pin
are never written, because an archive is a program for a decompressor.
a second `fetch` on a satisfied pin downloads nothing.

## 4. give the tree the edge

nothing declares a dependency on a pin. no manifest lists it, and
`fetch` resolves every `*_pin.tl` it finds.

1. write `3p/<name>/<name>_test.tl` beside the pin. `3p/tl/tl_test.tl`
   is the model: it loads the fetched `o/3p/tl/tl.lua` and asserts on
   it, so a broken fetch fails a test by name.
2. name the fetched file in the payload generator of the binary that
   ships it. `cmd/cosmic/embed_gen.tl` copies `o/3p/tl/tl.lua` to
   `tl.lua` at the artifact root, which is how `require("tl")` resolves
   inside the binary. an artifact carries its modules plus what its
   generator names, and nothing else.

## 5. carry a patch when the bytes need one

a small deliberate edit to a fetched file is declared as data beside
the pin, the way `3p/tl/tl_patch/` does for the Teal checker.

1. write each edit as an exact `find` string replaced by an exact
   `replace` string in one unpacked file.
2. keep `find` unique. it must occur exactly once in the target, so a
   later bump that moves the anchor fails loudly instead of drifting.
3. run `bin/cosmic --make fetch` again. application is idempotent, and
   `fetch` re-verifies it the way it re-verifies the digest.

[bump-pin.md](bump-pin.md) has the steps for moving a pin later.
`../../reference/make.md` has the `fetch` verb beside the others.
