# Worked examples

what the model looks like on real trees: this repo, a single-binary
project, a multi-binary one, and the committed fixtures that pin each
behaviour down, for a contributor checking a convention against a
concrete layout.

**this repo**

```text
bin/cosmic  bin/cosmic.pin   fetch the pinned cosmic into o/bootstrap/, exec it
cosmic/                      PUBLIC API: this directory is the interface
  fs/init.tl  fs/path.tl  fs/fs_test.tl
  json.tl  json_test.tl  json_example.tl
  net/  sqlite/  fetch/  …
_cli/  args.tl  help.tl  run.tl  build/   the dispatcher, internal
_build/  _make/  _perf/  _tool/  _docs/
_types/types_gen.tl          -> o/_types/types_gen/{cosmo*,tl}.d.tl
cmd/cosmic/main.tl           the binary -> o/bin/cosmic
cmd/cosmic/embed_gen.tl      its payload -> o/cmd/cosmic/embed_gen/{embed/,base}
embed/cosmic.mk              payload: the rules file, at /zip/cosmic.mk
3p/tl/tl_pin.tl  3p/cosmos/cosmos_pin.tl
sys/  docs/  .github/        assets and dotfiles: never in the artifact
o/                           everything generated
```

**a single-binary user project**

```text
myapp/
  cmd/myapp/main.tl         -> o/bin/myapp
  config.tl                 require("config")
  db/init.tl  db/query.tl   require("db"), require("db.query")
  db/query_test.tl          reads staged db/**, writes TEST_TMPDIR
  db/testdata/fixture.json  readable by the test, never embedded
  _internal/util.tl         require("_internal.util"), private
  schema.sql                an asset: part of the project, not of the
                            artifact. it does NOT ship
  embed/schema.sql          move it here and it does, at /zip/schema.sql
  3p/lpeg/lpeg_pin.tl       cosmic --make fetch
```

```text
o/bin/myapp  ->  /zip/main.lua          generated wrapper
                 /zip/main.user.lua     compiled main.tl
                 /zip/config.lua
                 /zip/db/init.lua  /zip/db/query.lua
                 /zip/_internal/util.lua
                 /zip/schema.sql        because it is under embed/
                 /zip/cosmic/**         the floor
                 /zip/usr/share/ssl/**  the floor
```

**multi-binary**

```text
tools/
  cmd/fetchit/main.tl
  cmd/servit/main.tl  cmd/servit/routes.tl
  shared/http.tl            require("shared.http")
  _internal/log.tl
```

`o/bin/fetchit` embeds `shared/**`, `_internal/**` and `cmd/fetchit/**`.
`o/bin/servit` embeds the same roots plus `cmd/servit/**`. neither can
import the other's `cmd` directory.

what stays bespoke in this repo is the first-fetch shell in
`bin/cosmic`. everything else is the conventions.

## fixtures

`_make/testdata/**` holds hello-world-sized projects, one per
behaviour. `_make/fixtures_test.tl` checks, builds and runs each one:

| fixture | what it pins down |
|---|---|
| `hello/` | the smallest project that is one: entry to `o/bin/hello` |
| `pkg/` | import path is position (`greet/init.tl` is `greet`) |
| `multi/` | two `cmd/` binaries, shared root packages, no cross-imports |
| `luaonly/` | `.lua` sources are first-class, tests included |
| `assets/` | `embed/**` ships at its path under `embed/`; a bare asset and `testdata/` never ship; the test runner carries the root payload |
| `runner/` | a runner-mode `*_test.tl` passes `check` from a tree that has never built |

they are committed rather than written inline by the test because
they double as the examples a person reads, and they are built with
the same two commands a user types. being real projects under
`testdata/`, they are invisible to this repo's own model, which is
what `testdata/` is for, and why the source-reachability ratchet and
the coverage scan skip it. they are also the fastest way to try a
`--make` change by hand:

```bash
cp -r _make/testdata/hello /tmp/h && cd /tmp/h
$OLDPWD/o/bin/cosmic --make build && ./o/bin/hello
```
