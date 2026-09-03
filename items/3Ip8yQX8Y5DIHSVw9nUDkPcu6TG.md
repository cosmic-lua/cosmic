## Change

`_make/graph.tl:194-196` appends `o/bin/cosmic` to `deps_<stem>` for every test under `_make/**`, `_cli/**` or in `_make/engine.tl`'s list, with no check that the project has a binary named `cosmic`. A leading `_` only marks a tree internal (AGENTS.md, "Repository Layout"), so a downstream project with `_cli/foo_test.tl` gets a prerequisite make cannot build.

1. `_make/project.tl` (481 lines: `git show origin/main:_make/project.tl | wc -l`): add and export `has_binary(proj: Project, name: string): boolean` — a linear scan of `proj.binaries` (`_make/types.tl:62-70`, `Binary.name` is the `o/bin/<name>` stem) — with a doc comment. Put it here, not in `_make/engine.tl`, so this item stays file-disjoint from the engine-dependency item that edits `engine.tl`.
2. `_make/graph.tl:194`: change the condition to `if f.kind == "test" and engine.exercises_the_engine(f.path) and project.has_binary(proj, "cosmic") then`. Shorten the comment at 186-193 by two lines to say the guard exists; the file is at 491 of the 500-line cap (`wc -l`), so measure after editing.
3. `_make/graph_test.tl`: two cases using its `fixture()` helper (lines 23-34): (a) `["_cli/foo_test.tl"] = "assert(true)\n"` plus `["main.tl"]` and no `cmd/cosmic` — assert `project_mk` output has a line `deps__cli/foo_test :=` that does NOT contain `o/bin/cosmic`; (b) the same files plus `["cmd/cosmic/main.tl"] = "print('x')\n"` — assert the line DOES contain `o/bin/cosmic`. Pattern to follow: `test_project_mk_carries_per_test_closures` (lines 107-127).
4. Fixture-shaped proof: add `_make/testdata/tooling/` with `cmd/app/main.tl` (`print("hello from tooling")`) and `_cli/foo_test.tl` (`assert(true)`), and in `_make/fixtures_test.tl` (251 lines) a `fixture("tooling", {app = "hello from tooling"})` call — that helper runs check+build+run — followed by `local code, out = make(root, "test"); assert(code == 0, out)` on a `staged("tooling")` copy, so the fixture's `--make test` is what proves the guard.

## Evidence

The unguarded site (`git show origin/main:_make/graph.tl | sed -n 194,196p`):
```
      if f.kind == "test" and engine.exercises_the_engine(f.path) then
        built[#built + 1] = project.out_dir("bin/cosmic")
      end
```
`deps_<stem>` is a plain prerequisite of the test record (`git show origin/main:embed/cosmic.mk | sed -n 188,189p`):
```
$(O)/%.tl.test.got: $(O)/%.lua $(O)/.stamp/record $$(deps_$$*) $(testrun_dep)
	record $(basename $@) $(testrun) $< --deps $(deps_$*) ;
```
No rule produces `o/bin/cosmic` in a project without `cmd/cosmic/main.tl` (binaries come only from `entry` files, `_make/project.tl:372-380`). No existing fixture has such a directory (`git ls-tree -r --name-only origin/main -- _make/testdata | grep -E '/_(cli|make)/'` prints nothing — which establishes only that the six fixtures do not, not that the layout is refused anywhere).

**Prediction to verify first** (no build was run while drafting): stage the `tooling` fixture on the current `o/bin/cosmic` and run `o/bin/cosmic --make test` in it; the expected failure is make's `*** No rule to make target 'o/bin/cosmic', needed by 'o/_cli/foo_test.tl.test.got'.  Stop.` Paste the real line into the fixture test's comment; if it passes instead, the guard is still right but the fixture must assert something else (the `deps__cli/foo_test` line in `o/project.mk`).

## Non-goals

Which tests count as engine tests (`_make/engine.tl`) is unchanged here; widening that set is the sibling item.
