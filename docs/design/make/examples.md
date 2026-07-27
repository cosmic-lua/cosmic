# Worked examples

What the model looks like on real trees: this repo after migration, a
single-binary user project, a multi-binary one, and the committed
fixtures that pin each behaviour down.

**This repo, after migration**

```
bin/cosmic                  fetch pinned cosmic, exec it
cosmic/                     PUBLIC API — this directory is the interface
  fs/init.tl  fs/path.tl  fs/fs_test.tl
  json.tl  json_test.tl  json_example.tl
  net/  sqlite/  fetch/  …
_cli/  args.tl  help.tl  run.tl  build/   the dispatcher, internal
_build/  _make/  _perf/
_types/types_gen.tl         → o/_types/cosmo*.d.tl, o/_types/tl.d.tl
cmd/cosmic/main.tl          the binary → o/bin/cosmic
3p/tl/tl_pin.tl  3p/cosmos/cosmos_pin.tl
bootstrap/cosmic_pin.tl
sys/  skills/  docs/  .github/
o/                          everything generated
```

**A single-binary user project**

```
myapp/
  main.tl                   → o/bin/myapp
  config.tl                 require("config")
  db/init.tl  db/query.tl   require("db"), require("db.query")
  db/query_test.tl          reads staged db/**, writes TEST_TMPDIR
  db/testdata/fixture.json  readable by the test, never embedded
  _internal/util.tl         require("_internal.util"), private
  schema.sql                asset
  3p/lpeg/lpeg_pin.tl       cosmic --make fetch
```

```
o/bin/myapp  →  /zip/main.lua          generated wrapper
                /zip/main.user.lua     compiled main.tl
                /zip/config.lua
                /zip/db/init.lua  /zip/db/query.lua
                /zip/_internal/util.lua
                /zip/schema.sql
                /zip/cosmic/**         the floor
                /zip/usr/share/ssl/**  the floor
```

**Multi-binary**

```
tools/
  cmd/fetchit/main.tl
  cmd/servit/main.tl  cmd/servit/routes.tl
  shared/http.tl            require("shared.http")
  _internal/log.tl
```

`o/bin/fetchit` embeds `shared/**`, `_internal/**`, `cmd/fetchit/**`;
`o/bin/servit` the same roots plus `cmd/servit/**`. Neither can import
the other's `cmd` directory.

## What this repo looks like afterward

| today | becomes |
|---|---|
| `cook.mk`, `mk/*.mk` | conventions |
| `lib/cosmic/`, `lib/build/`, … | `cosmic/`, `_build/`, … (root = module root) |
| `public.tl` | the `_` prefix; the tree is the manifest |
| `pack_copies` enumeration | the artifact layout rule |
| `3p/*/version.lua` | `*_pin.tl`, statically extracted (done, 3g) |
| `gentype`/`gentl` rules | generation units, one directory each |
| doc index, version stamp | a generation unit; committed data + env |
| `.PLEDGE`/`.UNVEIL`/`.ENV` | derived grants, enforced by cosmic-as-`SHELL` |
| `.SANDBOXED`, hostx, recipe-scan ratchets | mostly unnecessary; the vocabulary is closed |
| ratchet tests reading the tree | moved to the root, where their inputs are |
| coverage/enforce/reproducible/offline | policy verbs |
| `bin/make ci` | `bin/cosmic --make ci` |

`-include cosmic.mk` is the migration bridge only. What stays bespoke:
the first-fetch shell in `bin/cosmic`.
## Fixtures

`_make/testdata/**` holds hello-world-sized projects, one per
behaviour, each checked, built and *run* by `fixtures_test.tl`:

| fixture | what it pins down |
|---|---|
| `hello/` | the smallest project that is one: entry → `o/bin/hello` |
| `pkg/` | import path is position (`greet/init.tl` is `greet`) |
| `multi/` | two `cmd/` binaries, shared root packages, no cross-imports |
| `luaonly/` | `.lua` sources are first-class |
| `assets/` | an asset ships at its relative path; `testdata/` never ships |

They are committed rather than written inline by the test because they
double as the examples a person reads, and they are built with the same
two commands a user would type. Being real projects under `testdata/`,
they are invisible to this repo's own model — which is what `testdata/`
is for, and is now also why the source-reachability ratchet and the
coverage scan skip it.
