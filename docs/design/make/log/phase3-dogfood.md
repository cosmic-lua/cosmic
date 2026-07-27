# Design — `cosmic --make`: what phase 3 settled

phase 3 is **dogfood** — building this repo with `--make`. the design
is in [../README.md](../README.md), the plan in [../plan.md](../plan.md), and
phases 1 and 2 of this record in [phase1-2.md](phase1-2.md).

this file holds **3a–3g**, the slices that made the repo describable.
from **3h** on — the entry, the hoist, and the verbs taking over — the
record continues in [phase3-selfbuild.md](phase3-selfbuild.md).

the phase inverts phase 2's risk profile: nothing here is user-facing
and every slice can take the build down, so each lands behind the
existing build and `bin/make ci` stays green through every step.

## 3a — the provider exemption

Measured before slicing the phase, since its whole premise is that
`--make` can describe this repo: `COSMIC_MAKE_ROOT=$PWD/lib cosmic
--make check` reported **290 errors, every one the same class** —
`reserved import path 'cosmic.…'`. Nothing else in the model objected
to this tree, which is the phase's good news as much as its first
blocker: the flatten ahead is a rename, not a redesign.

What it settled:

- **the reserved list was one rule doing two jobs.** `cosmo` is a native
  binding and `main.user` is the wrapper's generated slot: nothing in a
  zip can supply either, so a file landing there is a shadow by
  definition. `cosmic` and `tl` are ordinary Lua trees that happen to
  ship in the base, and the design already requires both to be
  providable — "its own tree provides them", and "any user wanting Teal
  at runtime vendors it the same way". Splitting the list is what lets
  the same rule refuse the first pair unconditionally and ask a question
  about the second.
- **the question is whether the project claims the namespace's root.**
  `cosmic/init.tl` claims `cosmic`; `tl.lua` or `tl/init.tl` claims
  `tl`. Claiming takes the whole namespace. Providing a *piece* without
  the root stays refused, and that is the case the original rule was
  written for: with `cosmic/fs.tl` and no `cosmic/init.tl`,
  `require("cosmic.fs")` resolves to the project while
  `require("cosmic.json")` falls through to the base, so one binary runs
  two standard libraries. The refusal now names the root module to add,
  because "you are halfway" is more useful than "no".
- **the artifact half is what keeps the validator half honest.** A
  claimed namespace drops the base's floor copy, so exactly one
  definition ships instead of the project's winning on `package.path`
  and the base's riding along as dead weight. Without it the exemption
  would be a validator opinion the artifact contradicts — and the
  contradiction would be invisible, since both copies load fine.
- **the floor stays a positive keep-list; claims subtract from it.**
  `embed.run` takes the claimed namespaces and `in_floor` consults
  them, rather than the artifact assembling a bespoke floor. A base that
  grows a directory still cannot silently start shipping it, which is
  the property the keep-list exists for. Only `cosmic` has a floor entry
  to subtract — `tl` is providable but a stripped artifact never keeps
  the base's copy of it, so claiming `tl` has nothing to give back.
- **claiming `cosmic` is all-or-nothing at runtime, not just at the
  validator.** The generated entry wrapper itself runs
  `require("cosmic.searcher").install()` before the project's
  `main.tl`, so a project that takes the namespace inherits the
  obligation to answer that require. Cosmic's own tree meets it by being
  the real thing; the fixture meets it with a stub, which is what made
  the test possible to write at all. Worth knowing before 3d moves the
  base's payload to the same names.
- **the artifact tests were reading the checkout, not the artifact.**
  Found by this slice's own test failing in a way the hand-run did not
  reproduce: `run_artifact` inherited the test lane's `LUA_PATH`, which
  names `lib/` and `o/lib/`, and the artifact's `package.path` searches
  those *before* `/zip/.lua/`. So `require('cosmic.json')` inside a
  freshly stripped artifact resolved to `o/lib/cosmic/json.lua` and
  reported the stdlib present. The existing floor assertions were
  passing partly on that. `run_artifact` now names its environment
  instead of inheriting it, which is what the older tests meant all
  along — an artifact test that can read the tree that built it is not
  testing the artifact.

**Measured after, the same way as before.** `COSMIC_MAKE_ROOT=$PWD/lib
cosmic --make check`: 0 validation errors, down from 290, and the verb
now gets far enough to type-check — 347 files, 1 failure. That failure
is the flatten showing through rather than a new problem:
`lib/docs/publish_test.tl` imports `lib.docs.publish`, a path that only
resolves when the root is the *repo* root while everything around it
assumes `lib/`. It is 3b's to fix, and it is the first concrete piece of
evidence that the tree really does have two module roots today.

## 3b — the flatten

`lib/cosmic/` → `cosmic/`, `lib/build/` → `_build/`, `lib/types/` →
`_types/`, `lib/perf/` → `_perf/`, `lib/docs/` → `_docs/`, and
`lib/cook.mk` → `mk/modules.mk`. The repo root is the module root, so a
source's path relative to it *is* its import path.

**`cosmic --make check` at the root: PASS, 349 files.** The design's own
model now describes the repo the design was written for, which is the
whole point of the phase and the thing every later slice builds on.

What it settled:

- **the big rename is the cheap half; the module root is the expensive
  one.** `lib/cosmic/` → `cosmic/` moved 294 files and changed *no*
  import path — every `require("cosmic.…")` is spelled the same before
  and after. The 45 require sites that did change all belong to the four
  small trees, because those are the ones whose *name* changed. Which
  meant the risk was never in the file count.
- **`_cli/` and `_make/` are not part of the flatten.** The plan listed
  them here, and they came out: moving `cosmic/_cli/` to `_cli/` does not
  relocate a directory, it changes what the published API *is*. That is
  3c's question — the one that deletes `public.tl` — and doing it here
  would have mixed a mechanical move with a surface decision, which is
  exactly how a "mechanical" commit stops being reviewable.
- **`r:lib` was load-bearing in two places, and `.` is not a wider
  version of it.** The sandbox grant and the coverage scan both named
  the source tree, and both got `.` in the first pass. The grant became
  "the whole repository, `o/` and `.git` included"; the coverage scan
  walked `o/` and `3p/` and found a source path 117 characters long,
  which Lua's `string.format` rejects outright (`%-117s`: a width field
  is two digits). So a build-system change surfaced as an "invalid
  conversion specification" in the coverage reporter. Both now read one
  `src_dirs` list, stated once with the reason the two must agree.
- **a bare `require` name outlived its directory.** `_build`'s compiled
  modules sit on the module path twice — once as `$(o)` so `_build.x`
  resolves, and once as `$(o)/_build` so the bare `make-help` that the
  Makefile's help target and its test both require still does. Recorded
  rather than fixed: renaming that module was expected to wait for the
  generators. It came sooner — 3f's derived closures cannot see a bare
  require, so the name had to match its position there.
- **path rewrites damage prose that describes paths.** A tree-wide
  `lib/cosmic` → `cosmic` rewrite turned the plan's own "`lib/cosmic/` →
  `cosmic/`" into "`cosmic/` → `cosmic/`", and the make-log's account of
  a bug at `o/lib/cosmic/json.lua` into one at a path that did not exist
  when the bug did. Four spots, all in documents *about* the move. A
  history that silently reflows to match the present is worse than no
  history, so they are back to what was true at the time.
- **three tests knew where the tree was, and each for a good reason.**
  The doc index derived a module's name by stripping `^lib/` and
  `^types/` (now only `^_types/`, since everything else names itself);
  `makefile_test` asserted the tree-only `TL_PATH` contained `/lib/`
  (now the root itself, via `getcwd`); `help_test` required a bare
  module name that resolved through a directory-specific path entry.
  None was wrong — each was reading the layout as it was.

## 3c — `_` replaces `public.tl`

`cosmic/cli/` → `cosmic/_cli/`, `cosmic/make/` → `cosmic/_make/`,
`cosmic/build/` → `cosmic/_build/`, `require.tl` → `_require.tl`, and
the generated version stamp to `cosmic/_version.lua`. `public.tl` — a
hand-maintained list of every top-level module, split into public and
internal — is deleted. Public is now `cosmic.<name>` with no `_`, a rule
that fits in one function (`cosmic/doc/visibility.tl`).

What it settled:

- **the manifest's two ratchets disappear rather than move.** It had a
  test asserting every embedded module appeared on one of its lists, and
  another asserting no list entry had lost its module. Both bugs are
  gone with the list: a module is public because of where it sits, so
  there is nothing to forget and nothing to leave behind. What survives
  in `surface_test.tl` is what the manifest was a *means to* — the
  public modules load, they are documented, and a directory module
  answers to its own name — plus one new test that the rule actually
  partitions, since a rule calling everything internal would satisfy
  every other assertion while saying nothing.
- **`cosmic.style` is public, and the validator is what said so.**
  `--make check` refused `_build/lint.tl` for importing
  `cosmic._cli.style` from outside `cosmic/`. The module's own header
  had been admitting this for as long as it existed: it said it lived
  "under the cosmic.* namespace so require() works" — a module
  explaining why it is reachable from a place the manifest said it was
  not. A manifest can hold that contradiction indefinitely; position
  cannot. So `cosmic/style.tl`, with the example a public module owes
  (the waiver list is closed to new entries, deliberately).
- **the same shape as 3a's searcher, from the other direction.** Who
  requires a module decides whether it is internal. 3a found the embed
  wrapper requiring `cosmic.cli.searcher` in every artifact ever built;
  3c found `_build/lint.tl` requiring the style checks. Both are callers
  the manifest never had to account for, because a manifest lists
  modules rather than edges.
- **the hoist to root `_cli/`/`_make/` is not this slice's.** The plan
  put it here. It belongs with 3d, and the reason is mechanical: the
  generated entry wrapper runs `require("cosmic.searcher")` before
  the project's `main.tl`, and the strip floor is `.lua/cosmic/**`. At
  root, `_cli/` is off the floor and every stripped artifact fails to
  boot. Hoisting is therefore the same change as moving the payload to
  the module root — which is 3d.
- **the coverage ratchet caught a silent behaviour loss.** Renaming the
  version module missed `_perf/run.tl`, whose `pcall(require,
  "cosmic.version")` then failed quietly and left the perf metadata
  without its version stamp — no test asserts that field, so nothing
  failed. Three lines went uncovered and the ratchet reported a 51.1% →
  49.5% decline in a file the change had no business touching. A
  coverage floor is usually read as a quality nag; here it was the only
  thing watching.
- **it only showed up on a clean build.** The incremental run passed:
  the perf metadata path had already been exercised by an earlier build
  in the same tree. Every slice of this phase moves output paths, so
  `bin/make clean && bin/make ci` is the gate, not `bin/make ci`.

## 3d — the pack

`/zip/.lua/cosmic/*` → `/zip/cosmic/*` and `/zip/.lua/tl.lua` →
`/zip/tl.lua`. The zip root is the module root inside the binary, so
"path relative to the root = import path" holds in the artifact the same
way it holds in the tree.

What it settled:

- **`package.path` is part of the layout.** Cosmopolitan's default is
  `/zip/.lua/?.lua;/zip/.lua/?/init.lua;./?.lua;./?/init.lua` — rooted
  at `.lua/`, which is exactly why the payload lived there. Moving it
  means the entry has to put `/zip/?.lua` on the path before its first
  `require`, which is what the generated embed wrapper has always done
  for artifacts. Cosmic's own binary now does the same thing for itself,
  which is the design's "no exception" clause made real.
- **where it inserts is the whole question.** Prepending outright made
  every test load the *binary's* embedded copy instead of the tree's
  compiled output, and coverage collapsed to 0% across thirty files —
  the collector records `@/zip/...` chunk names, which are not tree
  paths, so nothing was attributed. That is #666's stale-stdlib shape
  with a fresh binary instead of a pinned one. The insert goes ahead of
  the `.lua/`-rooted default but *behind* anything `LUA_PATH` set, so an
  in-tree build still wins and a stray `./cosmic/fs.lua` in the cwd
  still does not.
- **the bundled type tree is not a module namespace.** Copied to
  `/zip/_types`, it became reachable as `require("_types.gentype")`
  through the searcher's `/zip` include dir — resolving the *source
  inside the binary* in preference to the tree's compiled output, and
  quietly re-running the whole generator from a different file. It is
  include-path payload, not modules, so it goes to `/zip/.types`
  alongside `.tl/` and `.docs/`: dot-prefixed is precisely the
  convention for "not part of the module root".
- **the pack packs names, not a directory.** zip is invoked three times
  over explicit top-level name lists (stored / deflated / stored), and
  `tl.lua` and the type tree were in none of them once they left
  `.lua/`. The binary built, ran, and passed a sanity check; it failed
  only when something first required `tl`. A name absent from every
  group is silently not packed — worth knowing before 3h moves more
  names around.
- **and one group matching nothing was a hard failure.** zip exits 12
  for "nothing to do", which the pack treated as an error, so a staging
  tree without (say) `skills/` failed the whole build. Only this repo
  happening to contain one of every name hid it; the pack fixture, which
  contains two files, found it immediately. Exit 12 is now a legitimate
  outcome for a group.

## 3e — the compiles take the generated closures

The Makefile `-include`s `o/project.mk` — the facts file `cosmic --make`
generates — and the compile rule takes `$$(srcdeps_$$*)`, the per-file
import closure, as prerequisites.

**The bug it fixes, reproduced in this repo before writing anything.**
Delete an exported function from `cosmic/style.tl` and ask for its
importer:

```
$ make o/_build/lint.lua      # 'o/_build/lint.lua' is up to date.   (exit 0)
$ rm o/_build/lint.lua && make o/_build/lint.lua
_build/lint.tl:220:35: error: invalid key 'check_call_after_define' …
```

Same target, same tree, opposite answers. The compile rule was
`$(o)/%.lua: %.tl $(types_files) $(bootstrap_files)` — a module's output
depended on its own source and nothing it imports — so a strict compile
type-checked against modules that had since changed, and the incremental
build kept output a clean build rejects. This is 2b's finding, arriving
in the repo that has been building this way all along.

What it settled:

- **the bridge has two halves and only one can land now.** The plan said
  the compile family "becomes cosmic.mk's rule". It cannot yet:
  `o/cosmic.mk` defines `all`, `build`, `compile`, `fmt`, `test` and
  `$(O)/test-summary.txt`, and the Makefile defines four of those. An
  `-include` would not error — it would take the *last* recipe, silently
  redefining what `make test` does. So the facts land first and the
  rules wait for 3i, when the Makefile's own targets retire. Recorded
  because "include the generated rules" reads like one step and is two.
- **the generator is a tree script, not a verb.** `--make` computes
  these facts internally, but the recipes here run the *pinned
  bootstrap*, which predates `cosmic._make` entirely — using the verb
  would need a release and a pin bump first, which is the same
  sequencing constraint phase 1 hit with `-c`. So `_build/facts.tl`
  calls the same `cosmic._make` modules out of the tree, with the
  bootstrap as nothing but the interpreter. One generator, no new
  public verb, and it retires with the bridge.
- **make's makefile-remaking does the bootstrapping for free.** The
  first pass has no `o/project.mk`, so every `srcdeps_*` expands empty
  and the compile rule is exactly what it always was — which is how
  `o/_build/facts.lua` gets compiled at all. make then remakes the
  include and re-execs itself with the facts in hand. The circularity
  resolves because the generator's own compile does not need the
  generator's output.
- **write-if-changed is load-bearing here, not tidy.** make re-execs
  whenever an included makefile is remade, so a generator that always
  writes turns every build into two. `facts_test.tl` asserts the mtime
  survives a second run for that reason, alongside the two properties
  the compile rule actually rides on: the closure is transitive, and an
  unrelated module is not in it.

## 3f — tests and examples take their closures

The test and example rules take `$$(deps_$$*)` — the transitive import
closure as *built* paths — and the per-module test dependencies each
`cook.mk` declared by hand retire.

**The gate it closes, reproduced first.** A test resolves an import it
has no prerequisite for through the runtime `.tl` searcher, which
compiles **lax**. So a module that fails its **strict** compile could
still have a passing test:

```
$ make o/_types/gentl.lua                     # warning: unused variable … (exit 2)
$ make o/_types/gentl_test.tl.test.got        # (exit 0)
```

The module does not compile; its test passes. `o/_types/gentl.lua` was
not merely stale — it had never been built at all, by any target, and
nothing noticed because the searcher compiles the source at run time.
With the closure as a prerequisite the test target now fails, which is
the same answer a clean build gives.

What it settled:

- **the hand-declared test dependencies were the drift class, and they
  are gone.** `$(build_test_got): $(build_files)`, `$(docs_test_got):
  $(docs_files)`, `$(perf_test_got): $(perf_lua)` — three blanket
  edges, each a hand-maintained approximation of "what these tests
  import". They are replaced by per-test closures, so a test that
  imports one build tool waits for one, and a test that imports a module
  nobody declared (`_types/gentl_test.tl` did exactly that) waits for it
  too.
- **a require that does not match its position is invisible to the
  derived graph.** `_build/help_test.tl` required the bare name
  `make-help`, which is not an import path in the project model, so the
  closure omitted it and the test broke the moment the blanket edge went
  away. 3b had recorded the bare name as a known oddity; the fix is the
  convention itself — the module is `_build.make-help` now, and the
  extra `$(o)/_build` entry that existed to resolve the bare name is
  gone with it.
- **the handcrafted `.d.tl` went with it, and that was the tell.**
  `_types/make-help.d.tl` existed to give types to a bare require, and
  it published a *different shape* than the source: `Item` as a member
  of the module record, where the source kept it a bare local. Once the
  name matched its position the checker resolved the source directly,
  and the source had to actually expose what the declaration had been
  promising. A hand-written declaration beside a Teal implementation is
  free to be wrong in exactly this way; deleting it is what discovered
  it was.
- **incidental coverage is not coverage.** `cosmic/searcher.tl` sat
  at 17/26 because the repo's own tests reached it by compiling `.tl`
  modules at run time — the very thing this slice stops. Its coverage
  dropped to 4/26, which read as a regression and was really a
  measurement of how the module had been exercised: never on purpose.
  It has a direct test now (the three guarantees it makes over tl's own
  loader) and sits at 20/27, above where it started.

**And the slice found that nothing was watching.** `cosmic --make check`
had never been part of `bin/make ci`, so every slice of this phase was
checking the repo against its own model *by hand* — which meant 3e
regressed it and nobody noticed: the bridge script imported
`cosmic._make.*` from outside `cosmic/`, exactly what the `_` rule
forbids, and CI was green. A design whose central bet is "the tree
describes itself" cannot leave that claim ungated, so `ci` now runs a
`model` stage, and the fix for the violation was the design's own rule
applied to the bridge: the script moved to `cosmic/_make/facts.tl`,
where its inputs are.

## 3g — the searcher is public, and the pins are data

Two things, and the second is the one that mattered.

**The searcher.** `cosmic/_cli/searcher.tl` → `cosmic/searcher.tl`. The
generated embed wrapper runs `require("cosmic.searcher").install()`
before the entry of every artifact anyone builds, so the module with the
widest caller set in the tree was the one marked internal. Third
instance of the rule, found the same way each time: who requires a
module decides whether it is internal. It is also the precondition for
hoisting `_cli/` to the root (3h) — at root the searcher sits outside
the `cosmic/**` strip floor, and every stripped artifact fails to boot.

**The pins, and a plan correction.** `3p/cosmos/version.lua` and
`3p/tl/version.lua` are now `3p/cosmos/cosmos_pin.tl` and
`3p/tl/tl_pin.tl`, read by the same literal grammar `--make fetch` uses.
Before: `pcall(dofile, version_file)` in `build-fetch.tl`, the same in
`build-stage.tl`, and `dofile('3p/cosmos/version.lua')` inside the
version-stamp recipe — the build **executing** the files that say what
it pinned, three times per run. Proven in this repo's own build after
the change:

```
$ make o/tl/.fetched      # after adding os.getenv() to the pin
error: failed to read 3p/tl/tl_pin.tl:
  3p/tl/tl_pin.tl:2: a pin holds literals only; found 'os'
```

`dofile` would have run it.

What it settled:

- **the plan had the pins blocked, and the plan was one step short.**
  The reasoning was: converting the pins means something must read
  them, the only reader is `cosmic._make.pin`, and `_build/` cannot
  import it from outside `cosmic/` — so wait for the fetch verb to
  replace `_build/build-fetch.tl` entirely. All true except the
  conclusion. What the repo needed was not the verb but the **reader**,
  and a reader with callers outside `cosmic/` is by the rule this phase
  has now applied four times not an internal module. `cosmic.literal`
  is public, `cosmic._make.pin` keeps what is specific to a pin (url,
  sha256, `{version}`, output path), and the conversion needed nothing
  from 3i.
- **the grammar is one implementation, enforced identically from both
  sides.** `pin.extract` is a four-line delegation now, passing the noun
  `"pin"` so its complaints still say "a pin holds literals only" rather
  than something generic — the author was writing a pin, and the message
  should know that. pin_test's message assertions pass verbatim, which
  is what made the move safe to do at all.
- **"a config file that cannot do anything" outgrew `--make`.** That
  sentence was written in 2d about pins. It describes something any
  project wants, and this repo turned out to be the first consumer
  outside the verb that coined it.

**And the gate that missed it.** The pin rename broke `bin/make` and
`_build/make-boot.tl`, which name the cosmos pin to bootstrap the build
— and every local gate passed anyway. `bin/make clean` removes `o/`,
but the extracted engine lives at `bin/cosmo-make`, *outside* it, so
the guard `[ ! -f "${MAKE_BIN}" ] || [ <pin> -nt "${MAKE_BIN}" ]` took
neither branch: the file existed, and the `-nt` test against a path
that no longer exists is false. The bootstrap path was simply never
entered. CI has no `bin/cosmo-make`, took the branch, and `dofile`d a
file that was not there — in all five jobs.

So "clean" was not clean. The real cold-start gate is
`rm -rf o bin/cosmo-make`, and it is what should have run before a
commit that renames a file the trust root names by path. Worth knowing
generally: a stale artifact outside `o/` makes a missing-file bug look
like a working build. (Fixed at the cause after 3h: the engine lives at
`o/cosmo-make` now, so `clean` cleans it and the gate is `rm -rf o`.)

That left exactly one `dofile` of a pin, in `make-boot.tl`, which could
not go while `cosmic.literal` was newer than any release: it runs
before the tree is compiled, with `LUA_PATH=";;"` pinning its requires
to the freshly-fetched bootstrap's own embedded stdlib. **A release cut
from this branch closed it.** The bootstrap pin moved to
`2026-07-26-5de5474`, that stdlib gained the reader, and the trust root
now reads the file that names what to download instead of running it:

```
$ rm -rf o bin/cosmo-make && bin/make build   # after adding os.getenv() to the pin
Downloading bootstrap cosmic...
error: failed to read 3p/cosmos/cosmos_pin.tl:
  3p/cosmos/cosmos_pin.tl:6: a pin holds literals only; found 'os'
```

Nothing in the build executes a pin now — not the trust root, not
fetch, not stage, not the version stamp. Worth noting what made the
bump safe rather than a repeat of phase 1's: it was verified from
nothing (`rm -rf o bin/cosmo-make`), which is the gate the 3g follow-up
had just learned to run.

## Fixtures, and what running `--make build` on the repo showed

Committed hello-world projects under `_make/testdata/**` (then
`cosmic/_make/testdata/**`; 3h hoisted the tree), one per
behaviour, each checked/built/run by `fixtures_test.tl`. Written because
the inline fixtures elsewhere answer "does this rule fire", and these
answer a different question: does a project someone would actually write
go from source to a running binary.

- **the artifact is named after its directory**, which the staging path
  quietly decided: copying `hello/` to `fixture-hello/` built
  `o/bin/fixture-hello` and the test asserted on a binary that was not
  the one on disk. Fixtures stage under a parent now, keeping their own
  names.
- **one fixture failed its own type check**, which is the fixtures
  working: `fs.read()` returns `string | nil` and the fixture indexed it.
  A hello-world example that does not type-check is a bad example, and
  `--make check` said so before anyone read it.
- **`testdata/` needed telling twice more.** The source-reachability
  ratchet (#800's, "every `.tl` must be declared by some cook.mk") and
  the coverage scan both swept the fixtures in. Neither is wrong in
  general; both were missing that `testdata/` holds whole projects with
  their own roots, which this repo neither compiles nor ships. They skip
  it now, for that reason rather than by name.

**And the measurement the fixtures were the excuse to take.** `cosmic
--make build` at the repo root: `build: PASS (356 files)`. It already
compiles the entire tree, strictly, with per-file closures — and
produces no binary only because nothing declares an entry. The distance
left to "one command produces cosmic" is therefore not the compiling; it
is the payload a cosmic binary carries beyond its own modules (tl, the
type tree, the docs index, the engine) and where each of those comes
from. That list is what ../payload.md answers, piece by piece with the
evidence for each, rather than a phase name.
