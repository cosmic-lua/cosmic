# Design — `cosmic --make` as `go build`

status: proposal, for review. not a decision (see
[decisions.md](../decisions.md) for what is settled).

## What exists today

`cosmic --make [dir] [target]` (`lib/cosmic/make.tl`, 234 lines) scans a
directory for `*.tl`, classifies by filename suffix, emits a Makefile as
a string, and pipes it to `io.popen("make -f -")`. The generated rules
cover compile / check / format / test / report. There is no rule that
produces an executable.

Three problems with that shape, independent of the feature ask:

1. **it needs a host `make` and a host shell.** `io.popen` is a shell.
   That contradicts promise 3 (self-sufficiency: "everything you need,
   nothing you install... working offline") for exactly the user cosmic
   is for — someone with one binary in a bare sandbox.
2. **the target string is interpolated into a shell command.** The
   handler carries a `^[%w._/-]+$` guard against `; rm -rf ~`. Injection
   defense is not a thing a build command should need.
3. **it produces build files, not builds.** `go build` has no artifact
   in between; `--make` today has nothing but the artifact-that-isn't.

Everything the requested feature needs already exists as parts:
`--compile-strict` (strict check then generate from the checked AST),
`cosmic.embed` (executable-zip append + atomic rename + the `#687/#690`
entry wrapper that installs the searcher and puts the zip root on
`package.path`), `cosmic.testrun` + the reporter (`.got` files, one
status contract, verdict lines), `cosmic.cli.script_cache`
(content-hashed compile cache). What is missing is a **project model**
and a **fixed pipeline** that wires them.

## What "like `go build`" means here — and what it does not

In scope:

- zero build files. a directory tree is the project.
- convention over configuration: filename suffix decides role, path
  decides import path.
- one command → one self-contained executable.
- `build` type-checks. a program that does not type-check is not built.
- fast no-op rebuild.
- `test` in the same tool, over the same code that ships.

Explicitly **not** in scope (say so now so nobody expects it):

- **no dependency resolution.** no `go.mod`, no proxy, no version
  solving. a project is a tree; dependencies are the cosmic stdlib or
  vendored source. (`cosmic.fetch` exists; wiring it into the build is
  a separate, much larger decision about a trust root for user code.)
- **no cross-compilation flag.** the artifact is a copy of the running
  cosmic binary, so it is already fat across the six supported OSes.
  Architecture is whatever the base binary carries.
- **no dead-code elimination.** the artifact is cosmic (6.5 MB for the
  current `cosmic-lua` release asset) plus the app's compiled Lua.
  Trimming is possible (see phase 3) but is not the default.

## Constraints this design must respect

- **D14 (no self-hosting; pinned make is permanent)** is not re-opened.
  D14 governs *cosmic's own build* and rejects a cosmic-native **graph
  executor** — pattern rules, staleness, jobserver, sandbox
  annotations. This design implements none of that: it is a fixed
  pipeline with a content-hash cache, no user-authored graph, no
  parallel scheduler. D14's own rejection text names `--make` project
  scaffolding as the user-facing answer, which is what this is.
- **the `--embed` contract is reused, not reinvented.** import paths are
  chosen to match what the existing wrapper already puts on
  `package.path` (`/zip/?.lua;/zip/?/init.lua`). No new loader, no new
  resolution rule.
- **reproducibility is a standing property (#733).** the repo's own pack
  clamps mtimes and stores boot-critical Lua uncompressed. Artifacts
  from `--make` must double-build to identical bytes; `embed.run` does
  not set entry mtimes today, so this needs plumbing (below).
- **house rules:** `.tl` files ≤500 lines, `T | nil, string` errors,
  never throw from library code, every `as` justified, docs are
  CI-verified.

## Project model

```
myapp/                        project root (the dir argument, default .)
  main.tl                     entry point (required for `build`)
  util.tl                     require("util")
  pkg/init.tl                 require("pkg")
  pkg/db.tl                   require("pkg.db")
  pkg/db_test.tl              test — never embedded
  pkg/db_example.tl           example — never embedded
  vendor.d.tl                 type-only — on the include path, not embedded
  schema.sql                  asset — embedded verbatim at /zip/schema.sql
  o/                          build output — never an input
```

Rules:

- **import path = path relative to root, `/` → `.`, extension
  dropped.** `pkg/db.tl` → `require("pkg.db")`. `pkg/init.tl` →
  `require("pkg")`. This is exactly what the embed wrapper's
  `package.path` already resolves, so a module resolves identically
  when run from source (`cosmic main.tl`) and from the artifact.
- **role by suffix**, reusing today's `make.scan` classification:
  `_test.tl` → test, `_example.tl` → example, `.d.tl` → type-only,
  other `.tl`/`.lua` → source. Tests and examples are compiled and
  checked but never embedded (this is the `go build` property that
  `_test.go` files do not enter the binary).
- **`.lua` sources are first-class.** a project may be all `.lua`, all
  `.tl`, or mixed; `.lua` files are copied, not compiled. A `foo.tl`
  and `foo.lua` in the same directory is an error, not a precedence
  rule.
- **entry point:** `main.tl`, else `main.lua`, at the root. Absent →
  `build` fails with a message naming the file it wanted; `check` and
  `test` still work (a library project is legitimate).
- **assets:** every non-source, non-ignored regular file is embedded at
  its relative path. Skipped: `o/`, `.git/`, any dotfile or dotdir, and
  anything matched by an optional `.cosmicignore` (literal + `*` globs,
  one per line). Rationale: implicit beats a `//go:embed`-style
  directive for a tool whose users are frequently agents; the escape
  hatch covers the rest.
- **name collisions are refused, not silently resolved.** the wrapper
  *prepends* the zip root to `package.path`, so a project module named
  `cosmic`, `cosmo`, `tl`, or `main.user` shadows the runtime. `--make`
  rejects those import paths up front, listing the offending file. This
  is a "no silent bugs" item, not a nicety.

No manifest file. If a project later needs one (name, version, entry
override), it is `cosmic.toml`-shaped and additive — deliberately out of
this design.

## Pipeline

`cosmic --make [dir] [target]`, targets `build` (default), `check`,
`test`, `fmt`, `run`, `clean`.

```
scan → validate → check → compile → stage → embed → manifest
```

1. **scan** — walk the tree once (`unix.opendir` + `d_type`, as
   `embed.collect_dir` already does), classify, sort. Result is a
   `Project` record: root, entry, sources, tests, examples, types,
   assets.
2. **validate** — entry present (for `build`), no `foo.tl`/`foo.lua`
   collision, no reserved import path, no unreadable file.
3. **check** — strict type-check every `.tl` (sources, tests,
   examples), include dirs = project root + cosmic defaults. Warnings
   are errors, matching `--check-types`. Failures are reported as a
   list and stop the build.
4. **compile** — each source `.tl` → Lua via the same path as
   `--compile-strict` (check, then generate from the checked AST), so
   nothing ships that did not type-check. Cache-keyed (below). `.lua`
   sources pass through.
5. **stage** — write `o/make/<name>/stage/` with the compiled tree:
   entry at `stage/main.lua`, modules at their relative paths, assets
   copied. The staged tree is the unit tests run against.
6. **embed** — `embed.run({stage}, output, arg[-1])`. The existing
   wrapper moves the app entry to `/zip/main.user.lua` and generates
   `/zip/main.lua`. Output name defaults to the project root's basename
   (`go build` behavior), overridable with the existing `--output`.
7. **manifest** — record `sha256(mode, name, content)` per entry plus
   the base binary's sha and the cosmic version, at
   `o/make/<name>.manifest`. A matching manifest with the output still
   present skips steps 3–6 entirely.

Artifact layout, for a reviewer's mental model:

```
/zip/main.lua          generated wrapper (searcher + package.path)
/zip/main.user.lua     compiled main.tl, byte-identical to staged
/zip/pkg/db.lua        compiled project modules
/zip/schema.sql        assets
/zip/.lua/cosmic/…     inherited from the base binary (stdlib)
```

The artifact is the app: it no longer answers `--docs`, `--check-types`,
etc., because its entry is the app's. The embedded stdlib stays
requireable. That is the `go build` bargain and should be documented as
such.

## Caching and incrementality

- **compile cache**: `o/make/cache/<sha>.lua`, key =
  `sha256(rel_path, content, cosmic build id, include dirs, strict
  flag)`. Content-hashed, not mtime-based — the reasoning is already
  written down in `script_cache.tl` (coarse mtime granularity produces
  stale hits). Best-effort: any cache failure is a miss, never an
  error.
- **generalize `cli.script_cache`** rather than writing a second cache:
  it needs a cache-dir parameter and a key-extra parameter. ~15 lines
  changed, one caller updated, no behavior change for the run-time path.
- **no-op rebuild** short-circuits on the manifest, so a second `--make`
  on an unchanged tree does no compiling and no 6.5 MB copy.
- **no parallelism in v1.** single process, in order. The dominant cost
  is Teal compile per file and it is worth measuring before adding
  `child.run` fan-out — which is where D14's "re-implementing
  parallelism is scar tissue" starts to apply and where I would want a
  measured reason.

## Reproducibility

Two builds of the same tree, in different directories, at different
times, must produce byte-identical artifacts.

- entries added by `--make` carry a fixed mtime, not the staging file's:
  `SOURCE_DATE_EPOCH` when set, else the DOS zip floor
  (1980-01-01, 315532800). `cosmo.zip`'s `AddOptions` already has an
  `mtime` field; `embed.run` sets only `mode` and `method` today, so
  this is a plumbing change: an `EmbedOptions` record with an `epoch`
  field, defaulted off.
- `--embed`'s current bytes do not change unless the caller (or
  `SOURCE_DATE_EPOCH`) asks. **Open question 5** below asks whether it
  should instead always clamp.
- entries inherited from the base binary are already reproducible per
  #733.
- gate: a test that builds the same fixture twice into different paths
  and compares sha256.

## Tests and gates for user projects

`cosmic --make . test`:

- runs each `_test.tl` with the **staged tree** on the module path
  (`LUA_PATH=<stage>/?.lua;<stage>/?/init.lua;;`), so tests exercise the
  exact compiled modules the artifact embeds — not a separately
  compiled copy. This is the strongest available version of "the gates
  transfer to user code."
- per-test `TEST_TMPDIR` and `.got`/`.out`/`.err` capture via
  `testrun.run` — the existing contract, unchanged, including
  `status_of` (0 pass / 2 skip / other fail).
- ends with a `make: PASS` / `make: FAIL (n)` verdict line and the
  matching exit code, per the "never launder a gate through a pipe"
  rule.
- `check` = type-check only. `fmt` = `--check-format` over the tree,
  `--fix` under a flag. `run` = build then exec the artifact with the
  remaining argv. `clean` = remove `o/make/`.

## Code shape

`lib/cosmic/make.tl` becomes a directory module (the `fs/`, `doc/`,
`sqlite/` pattern), because the pipeline will not fit in 500 lines:

| file | responsibility | rough size |
|------|---------------|-----------|
| `make/init.tl` | target dispatch, verdicts, exit codes | ~150 |
| `make/scan.tl` | walk, classify, validate, `Project` record | ~200 |
| `make/build.tl` | check → compile → stage → embed → manifest | ~250 |
| `make/test.tl` | test/example execution + reporting | ~150 |
| `make/cache.tl` | content-hash cache + manifest | ~120 |

Other files touched:

- `lib/cosmic/embed.tl` — `EmbedOptions{epoch}` plumbed into
  `AddOptions.mtime`.
- `lib/cosmic/cli/script_cache.tl` — parameterize dir + key extra.
- `lib/cosmic/cli/main_handlers.tl` — `handle_make` dispatches targets;
  drops nothing else.
- `lib/cosmic/cli/main.tl` — the `--make` positional-target scan stays;
  the shell-injection guard in `make.tl` disappears with `io.popen`.
- `sys/help.md` — `--make [dir] [target]` reworded.
- `lib/cosmic/public.tl` — `make` stays **internal** (CLI is the
  surface; promoting later is cheap, the reverse is not). Update the
  evidence line, which currently says "project-scaffolding tooling."
- `skills/cosmic/make.md`, `skills/cosmic/makefile.md`,
  `skills/cosmic/checking.md`, `skills/cosmic/formatting.md` — these
  are also the `--docs guide.make` / `guide.makefile` payloads, and
  `doc/guide_test.tl` asserts `guide.makefile` resolves. Renaming or
  removing a guide is a test-visible change; plan it deliberately.
- `docs/build.md` — a section distinguishing cosmic's own build (pinned
  make, D13/D14) from what `--make` does for user projects, so the two
  are never confused.

New tests: fixture-project end-to-end (build → run artifact → assert
output), reproducibility double-build, cache hit/miss, name-collision
refusal, missing-entry error text, `.lua`-only project, mixed project,
asset embedding, test-target pass/fail/skip exit codes, `.cosmicignore`.
Plus the coverage ratchet.

## Phasing

Reviewable in four PRs, each independently useful:

1. **model + check + test.** scan/validate/`check`/`test` targets, no
   artifact yet. Deletes the Makefile generator and `io.popen`.
2. **build.** compile → stage → embed, `--output`, manifest no-op,
   default output name. `EmbedOptions{epoch}` + reproducibility gate.
3. **cache + polish.** generalized content-hash cache, `run`, `clean`,
   `fmt`, `.cosmicignore`, docs and guides.
4. **optional: `--minimal`.** an app that never compiles `.tl` at
   runtime does not need `/zip/.lua/tl.lua`, `/zip/.lua/types/`,
   `/zip/.tl/cosmic/`, `/zip/.docs/`, `/zip/skills/`. The appender can
   `remove` them. Gated on a measured size delta and on proving the
   searcher's lazy paths degrade loudly, not silently — which is
   exactly the kind of thing that turns into a silent bug. Opt-in only.

## Open questions

1. **entry convention** — root `main.tl` only, or also `cmd/<name>/` for
   multi-binary projects? *Recommend root-only now, reserve `cmd/`.*
2. **assets** — implicit (everything not source/ignored) or explicit
   (`--data <path>`)? *Recommend implicit + `.cosmicignore`.*
3. **Makefile generation** — drop it, or keep behind
   `--make --emit-makefile`? *Recommend drop (D10), with the guides
   rewritten in the same change.*
4. **test module path** — staged tree (ships-what-you-test) or source
   tree (faster, no stage needed for `test`)? *Recommend staged.*
5. **`--embed` reproducibility default** — clamp always (changes
   existing `--embed` output bytes once, makes every artifact
   reproducible) or only under `--make` / `SOURCE_DATE_EPOCH`?
   *Recommend clamp always, as a deliberate one-time byte change.*
6. **strictness** — is `build` allowed to succeed on a tree that fails
   `--check-types`? *Recommend no; `go build` type-checks, and a
   `--lax` escape hatch would immediately become the default anyone
   copies.*
