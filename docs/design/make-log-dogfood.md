# Design — `cosmic --make`: what phase 3 settled

phase 3 is **dogfood** — building this repo with `--make`. the design
is in [make.md](make.md), the plan in [make-plan.md](make-plan.md), and
phases 1 and 2 of this record in [make-log.md](make-log.md).

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
  `require("cosmic._cli.searcher").install()` before the project's
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
  rather than fixed: renaming that module is 3g's business, when the
  generators move.
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
  generated entry wrapper runs `require("cosmic._cli.searcher")` before
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
