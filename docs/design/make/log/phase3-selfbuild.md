# Design — `cosmic --make`: what phase 3 settled (self-build)

phase 3's second half, where `--make` stops describing this repo and
starts building it. the design is in [../README.md](../README.md), the plan in
[../plan.md](../plan.md), phases 1–2 in [phase1-2.md](phase1-2.md),
and slices 3a–3g in [phase3-dogfood.md](phase3-dogfood.md).

split from that file for the same reason it was split from the one
before: the 500-line cap applies to every tracked file, and a record
only grows.

## 3h — the entry and the hoist

`cmd/cosmic/main.tl` is the binary's entry, and `cosmic/_cli/` and
`cosmic/_make/` are now root `_cli/` and `_make/`. Both halves are gaps
the last two standing between `build: PASS (356 files)` and an
`o/bin/cosmic`.

What it settled:

- **the hoist is what makes `cosmic/` mean something.** Before it,
  `cosmic/` was "the standard library, plus whatever else had to ship";
  the `_` prefix marked the difference and nothing enforced it. Moving
  two trees out turned that into a question the validator could ask,
  and it answered with **seven refusals across four modules** — each
  one a module marked internal to `cosmic/` with a caller outside it:

  ```
  make: _cli/driver.tl: imports 'cosmic._build', which is internal to 'cosmic/'
  make: _cli/main_handlers.tl: imports 'cosmic._instrument', ...
  make: _cli/main_handlers.tl: imports 'cosmic._script_cache', ...
  make: _cli/run.tl: imports 'cosmic._require', ...
  make: cmd/cosmic/main.tl: imports 'cosmic._require', ...
  ```

  Fifth application of the rule this phase keeps rediscovering (`cosmic.style`
  in 3c, the searcher in 3g, `cosmic.literal` in 3g, and now these):
  **who requires a module decides whether it is internal.** What is new
  is that a position change is what asked the question — 3c and 3g had
  to notice by hand.

- **four modules, and only three answers, because the floor decides
  which.** A module inside `cosmic/` with a caller outside it is not
  internal to `cosmic/`; whether it *leaves* depends on whether
  something in the strip floor still needs it.

  | module | caller outside `cosmic/` | caller inside | became |
  |---|---|---|---|
  | `cosmic._build` | `_cli/driver.tl` | none | `_cli/build/` |
  | `cosmic._require` | `_cli/run.tl`, the entry | none | `_cli/require_hints.tl` |
  | `cosmic._instrument` | `_cli/main_handlers.tl` | `cosmic.testrun` | `cosmic.instrument`, public |
  | `cosmic._script_cache` | `_cli/main_handlers.tl` | `cosmic.searcher` | `cosmic.script_cache`, public |

  The two that left have no in-`cosmic/` caller, so nothing a stripped
  artifact boots with needs them — and both are build-time surfaces
  anyway. That is a size result as well as a tidiness one: the strip
  floor is `cosmic/**`, so **every artifact anyone builds stops
  carrying the `--build` recipe vocabulary** it had no way to invoke.

  The two that stayed could not leave: `cosmic.testrun` and
  `cosmic.searcher` are public, ship in the floor, and require them.
  Inside `cosmic/` and not internal to it leaves exactly one position,
  which is public — so the question "is this really API?" was answered
  by where its callers are rather than by taste. Both are small and
  their contracts were already stable; `cosmic.instrument` ships its
  parser beside its emitter, which is what makes the `cosmic: key=value`
  line an interface rather than a private convention between two files.

- **and the ratchet that made the promotion cost something.** The
  example-coverage test is closed to new allowlist entries, so a new
  public module fails CI until it has a runnable `*_example.tl`. Both
  got one, and writing them was the check on the decision: a module
  that cannot be demonstrated in four short examples is one to think
  twice about publishing.

- **the pack was enumerating top-level names, and this is the second
  time that silently lost files.** Its comment named the hazard exactly
  — "every top-level name in the staging tree must appear in one of
  these three groups or it is silently not packed" — and recorded that
  3d had already been bitten (`tl.lua` and the type tree left `.lua/`
  and fell out of the archive; the binary built, ran, and failed only
  when something first required `tl`). 3h reproduced it precisely:
  `_cli/` and `_make/` arrived at the root, **no compiled module of
  either was packed**, and the binary built and ran until a `.tl`
  require reached for `_cli.require_hints`:

  ```
  module '_cli.require_hints' not found:
    no file '/zip/_cli/require_hints.lua'
  ```

  So the tree decides now. `build-pack.tl` lists the staging directory
  and splits it in two: the boot-critical names (`cosmic`, `_cli`,
  `main.lua`, `.args`) stored uncompressed, **everything else deflated**.
  A name nobody thought about ships rather than vanishes. The general
  form is worth keeping: *a hazard a comment describes is not a hazard
  the build prevents*, and the fix is almost always to derive the list
  from the thing itself.

- **the endpoint, measured.** `cosmic --make build` at the repo root:

  ```
  $ cosmic --make build
  make: o/bin/cosmic
  build: PASS (359 files, 1 binary)
  $ o/bin/cosmic --help | head -1
  cosmic-lua: cosmopolitan lua with bundled libraries
  ```

  One command, this repo's own model, a running binary. The dispatcher
  is the entry, the stdlib resolves out of the zip root, and `--help`
  reads `sys/help.md` — which ships because it is an asset at its
  relative path, with nothing enumerating it.

### What the self-built binary is missing, and one gap the table did not have

The artifact that comes out is incomplete on purpose — gaps 3–7 are
3i's — but it is worth recording what that looks like from the outside
rather than from the plan:

- `--version` prints `Lua 5.4`, not `cosmic-lua …`: no
  `cosmic/_version.lua`, because the version stamp is still a shell
  recipe (gap 7).
- no `tl.lua`, no `.types/`, no `.docs/index.lua`, no `/zip/cosmic.mk`,
  no `/zip/make` — so no type checking, no docs, and no `--make` inside
  the binary `--make` built (gaps 3–6).

And the one that was not in the table: **it ships the repo.** Every
non-source file is an asset at its relative path, so `Makefile`, `mk/`,
`docs/`, `3p/`, `cook.mk` and both agent files land in the artifact.
Asset weight by top-level name, from the built binary:

```
   1592465  bin        <- bin/cosmo-make, the extracted make engine
    436476  cosmic
    159138  docs
     91465  _perf
     60304  _build
```

`bin/cosmo-make` is 1.59 MB of build engine that the trust root
extracts from `cosmos.zip` **into the source tree** rather than into
`o/`, so the model sees an ordinary untracked file and ships it. The
design's rule — "nothing generated is committed; it all lives in `o/`"
— has a corollary it never stated: *nothing generated may live outside
`o/` at all*, or an artifact will carry it.

## The engine moves into `o/` — a 3h follow-up

`bin/cosmo-make` → `o/cosmo-make`. The corollary above, applied at the
cause rather than papered over with an ignore entry. **−751 KB from the
artifact**, and the remaining asset weight is small enough to stop being
the headline: `docs` 169 KB, `_perf` 91 KB, `_build` 60 KB, `mk` 23 KB.

What made it worth doing beyond the bytes: `bin/cosmo-make` is where 3g
lost half a day. `bin/make clean` removes `o/`, the engine lived
*outside* it, and the trust root's guard —

```sh
if [ ! -f "${MAKE_BIN}" ] || [ "${pin}" -nt "${MAKE_BIN}" ]; then
```

— took neither branch: the file existed, and `-nt` against a path that
no longer existed was false. So a rename that broke the bootstrap passed
every local gate and failed all five CI jobs. The log's conclusion then
was "the real cold-start gate is `rm -rf o bin/cosmo-make`". That was
the right workaround and the wrong fix: **`clean` should be able to
clean.** It can now, and the cold-start gate is `rm -rf o` again.

Two grants went with it. `$(make_graph_tests): .UNVEIL := $(unveil_test)
rx:bin` is gone — the test lane already grants `rwcx:$(o)` — and with it
three entries from the hostx ratchet's allowlist. A hand-written grant
that becomes a derived one is the direction phase 4 is headed anyway.

What is left of item 9 is the open design question, unchanged: an
ignore entry removes a path from the **model**, not just from the
artifact, so ignoring `docs/` would also hide it from `check`, `lint`
and the coverage scan. Whether "not shipped" and "not seen" should be
the same knob is undecided, and is 3i's to settle.

### Not fixed here, and named so it is not lost — since closed

`cosmic.searcher` and `_cli/main_handlers.tl` run the same
compile-with-cache loop over `cosmic.script_cache` — the searcher for a
required `.tl` module, the handler for a `.tl` script run directly. They
differ in error policy (raise vs return) and in shebang handling (blank
the line, keeping line numbers, vs strip it), which is why they are two
loops and not one. A `cosmic.teal.compile_cached` would hold the shared
half, and it is the kind of change that belongs in its own commit
rather than inside a slice that moves files.

**Closed in 18c94c6.** `cosmic.teal.compile_cached` holds the shared
half, both callers were converted, and the cache went back to being
internal (`cosmic/_script_cache.tl`) — the public surface is
`compile_cached`, not the cache. The later security fix to that cache
(a per-user directory, refusing a shared one) landed in one place
because of this, rather than two.
