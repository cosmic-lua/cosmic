Design settled in conversation; **not yet at the spec bar** — the shape below is
decided, but the sizing is wrong for one PR and several behavioural claims are
readings rather than measurements. Refine and decompose before pulling.

## Change

Let a cosmic project depend on modules published inside another cosmic artifact,
resolved and baked in **at build time**. The consuming project's output stays one
fat binary; nothing is shared at run time.

### What was decided, and what each decision refuses

**Build time only.** A reference is never resolved at run time. No sixth layer is
added to `docs/design/make/resolution.md`'s precedence, no foreign zip is opened by
a running artifact, and D15 and the single-file promise are untouched. The version
skew this would otherwise create becomes a **type error on the consumer's build**
rather than a runtime failure inside a stranger's compiled `.lua`.

**A package is a binary, found by convention in any archive.** Discovery scans an
archive (zip, and the formats `*_pin.tl` already handles) for an export manifest at
a known path. No new build pipeline: the manifest plus a source tree is the whole
opt-in.

**A package carries both compiled modules and its `.tl` sources.** The compiled
`.lua` is what makes the package binary run standalone — its own tests, its own
`--docs`. The sources are what the consumer actually ingests: the consumer compiles
them with its OWN checker against its OWN stdlib, which is what makes skew a
build-time failure. This is exactly cosmic's own payload shape; see the `.tl/**`
entry in `cmd/cosmic/embed_gen.tl`, which exists so `--check types` in a user's
project can resolve `require("cosmic.fs")`.

**A declared export set, not a deny-list.** The package names the namespaces it
offers. Everything else in its zip — `cosmic/**`, `main.lua`, `tl.lua`, `.types`,
`.docs` — is invisible to the consumer. A deny-list would be the "heuristic about
what looks like project metadata" D15 rejected, and would go stale on every payload
change.

**Namespaces are claimed by pins.** A package mounts at its declared namespace, so
`require("acme.http")` works and the package's own internal `require("acme.util")`
resolves unchanged. `_make/validate.tl` grows a third claim category: a namespace
claimed by a pin rather than by a file. Two packages claiming one namespace is a
build error. A package claiming anything in `RESERVED` (`{"cosmic", "cosmo", "tl",
"main.user"}`, `_make/validate.tl:26`) is refused outright, or a dependency can
silently reskin the standard library.

**Dependencies are flat, exact and transitive; a diamond is a loud error.** A
package declares its own package deps as exact pins. Because the output artifact has
ONE module namespace — one path per import in one zip — npm-style nesting is
unavailable and two versions of one namespace cannot coexist. On a conflict the build
fails and names both requirers; a human bumps or forks. No ranges, no solver, no
lockfile: the consuming project's committed pin set IS the lock.

**Nothing foreign executes during the build, and fetch never follows a foreign pin.**
Modules and payload cross the boundary; `*_gen.tl` generators do not. A package's own
dep declarations are data that a deliberate resolve step reads to PROPOSE pins the
human commits — `--make fetch` only ever fetches what is committed in the consumer's
own tree. This is what keeps D16 ("every build input is enumerable from committed
files") true rather than true-of-somebody-else's-files.

**Payload is prefixed.** A package may ship `embed/**` assets, but payload paths are
a flat namespace, so each package's payload lands under a per-package prefix or two
packages shipping `embed/schema.sql` collide.

**Foreign sources compile strict, warnings pass.** Same rule
`docs/design/make/resolution.md` already sets for tree modules at layer 3: "Strict
here means type errors, not warnings... The gate stays the gate." A package that does
not type-check against the consumer's stdlib fails the build — that is the skew
detector. A package with a shadowed local does not.

**Repo-local gates do not cross.** `fmt`, the 500-line cap (D39), the naming charter
(D20) and coverage are house rules for the tree. Staged foreign sources under `o/`
are not the tree, and every gate must be taught to skip them.

### The real cost, measured

The expensive part is not reading a zip. It is that **staged pin content has never
been part of the import graph**:

```
$ grep -cE "3p" _make/graph.tl _make/imports.tl _make/deps.tl
_make/graph.tl:0
_make/imports.tl:0
_make/deps.tl:0
```

Pins land beside themselves under `o/3p/<name>/` and reach cosmic's binary only
because `cmd/cosmic/embed_gen.tl` hand-maps them into the payload
(`PINNED = {{"tl.lua", "o/3p/tl/tl.lua"}, ...}`). A tree-wide sweep for who names
that directory finds generators, tests, `_make/patch.tl`, `_make/clean.tl` and that
payload generator — never the graph:

```
$ grep -rln "o/3p" --include=*.tl . | grep -v "^\./o/"
./cosmic/teal_closure_test.tl   ./_types/tl_conformance_test.tl
./_types/tlast.tl               ./_types/gentype_defs.tl
./_types/tlast_test.tl          ./_types/gentl_test.tl
./cmd/cosmic/embed_gen.tl       ./_make/patch.tl
./_make/pin_test.tl             ./_make/check_test.tl
./_make/fixpoint_test.tl        ./_make/patch_test.tl
./_make/clean_test.tl           ./_make/generate_test.tl
./_make/clean.tl                ./3p/cosmos/cosmos_test.tl
./3p/tl/tl_test.tl
```

So packages mean foreign bytes become graph NODES — compiled, tracked in
`srcdeps_<stem>`, fenced, staged. The model's founding sentence is "import path =
path relative to the root" (`docs/design/make/model.md`); a package is the first
import path with no file in the tree, and that is the concept being added.

A second measured fact bounds how general "scan any binary" can be: a default user
binary contains compiled `.lua` and nothing else. `_make/artifact.tl:34` states the
payload kinds as "Kinds a binary carries. Its MODULES plus `embed/**`, and nothing
[else]", staging `o/<path>.lua` to `<import>/<name>.lua`. No fixture project ships a
payload generator — a wide sweep over every fixture finds one payload DIRECTORY and
no generator at all:

```
$ ls -d _make/testdata/*/cmd/*/
_make/testdata/assets/cmd/assets/   _make/testdata/hello/cmd/hello/
_make/testdata/luaonly/cmd/luaonly/ _make/testdata/multi/cmd/one/
_make/testdata/multi/cmd/two/       _make/testdata/pkg/cmd/pkg/
_make/testdata/runner/cmd/runner/
$ find _make/testdata -name "*_gen*" -o -name "embed*"
_make/testdata/assets/embed
```

Cosmic's `.tl/**` tree is its own payload generator's choice, not a property binaries
have. So "any binary is a package" is false today: publishing is an opt-in, and the
opt-in is shipping sources plus the manifest.

### Surface to decompose into siblings

Each is plausibly its own item; the order below is roughly the dependency order.

1. A package pin kind in `*_pin.tl` plus archive/manifest reading in the fetch path.
2. Staged foreign modules as first-class graph nodes (`_make/graph.tl`,
   `_make/imports.tl`, `_make/deps.tl`), with fence grants and `srcdeps`.
3. Pin-claimed namespaces in `_make/validate.tl`, including the `RESERVED` refusal
   and the two-claimants error.
4. The export manifest's own format, and the publishing side that emits it plus the
   `.tl` source tree.
5. The resolve step that reads transitive dep declarations and proposes pins,
   including diamond detection that names both requirers.
6. Per-package payload prefixing.
7. Teaching `fmt`, `lint`, the line cap and coverage to skip staged foreign trees.

## Non-goals

- **No runtime linkage.** A built artifact never opens another artifact's zip. This
  was considered and dropped: Lua's `package.loaded` is one global table keyed by
  module name, so two versions of a module cannot coexist in one state without a
  private per-package registry, and the memory and C-binding-state cost of that
  buys nothing once the closure is baked in anyway.
- **No content-addressed store.** A Nix-style store is what makes Nix's dedup work,
  and it is an install step, a GC-root problem and a missing-directory failure mode
  on six operating systems. The Nix-shaped half worth having — exact, content-hashed,
  enumerable pins — is already what `*_pin.tl` and D16 do.
- **No registry and no ranges.** Packages are named by url and sha256, as pins are.
- **No solver.**
- **No stdlib shadowing.** A package can never provide `cosmic.*`.

## Why this is blocked

D10 is *right to break*. A package system converts every stdlib break into a break in
code the project does not own, discovered in a build the project does not run. Until a
compatibility commitment bounds D10, this feature is a mechanism for distributing
future breakage. The blocker item carries that record.
