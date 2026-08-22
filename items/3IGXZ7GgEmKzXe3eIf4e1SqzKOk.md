## Evidence

A test cannot locate its own SOURCE directory. `arg[0]` inside a running
test is the COMPILED path under the build directory, so any design that
means "put data beside the test file that owns it" silently resolves
into `o/` — a gitignored tree that `--make clean` wipes and that CI's
fresh container never populates.

Measured 2026-08-22 on `whilp/cosmic` at PR #1308's head `28a3fe3e`,
built and run through the ordinary test path. A probe test placed at
`_fuzz/zzprobe_test.tl` printed:

```
$ o/bin/cosmic --make test _fuzz/zzprobe_test.tl
arg0=o/_fuzz/zzprobe_test.lua
cwd=/home/user/cosmic/o/pr1308
```

`embed/cosmic.mk` is why: the test rule is
`$(O)/%.tl.test.got: $(O)/%.lua ...` with the recipe
`record $(basename $@) $(testrun) $< ...`, so the runner is handed the
compiled artifact. `--make run` behaves the same way
(`arg0=o/_fuzz/zzp.lua`), and `isolate()` in `_fuzz/driver.tl` re-execs
`{cosmic_bin, arg[0]}`, which inherits the same path. The cwd IS the
project root, but nothing maps a compiled path back to its source.

Nothing copies `testdata/` into the build tree either — `testdata/` is
excluded from artifacts by `_make/artifact.tl` and from every `_build`
scan, but no rule stages it — so a file committed at
`_fuzz/testdata/<name>/<sha>` is unreachable from the running test.
Demonstrated end to end: with that file present in the source tree, a
property whose check fails on its bytes still reported
`zzprobe: 2 iterations, seed=1` — the entry was never read.

## Why it matters beyond one item

PR #1308 (board item 3IBFBWtc, fuzz corpus persistence) was rejected on
exactly this: its spec pinned
`fs.join(fs.dirname(arg[0]), "testdata", name)` and described it as
"colocating the corpus with the fuzz test file". The expression is
correct Teal and passes every gate; it just does not point where the
prose says. A reviewer caught it only by running a probe.

The gap is general. Any future feature that wants per-test fixture data
found at runtime — golden files, corpora, recorded transcripts — will
reach for the same expression and land in the same place, and no gate
will say so.

The examples rule already shows the build model KNOWS the source path:
`$(O)/%.tl.example.got` hands the runner `$*.tl` rather than `$<`,
precisely because examples must read their `-- Output:` comments from
source. So the information exists at the make layer; it is simply not
offered to a test.

## Candidate countermeasures, unranked

- A runner-set variable naming the source file (`TEST_SOURCE`, beside
  the existing `TEST_TMPDIR`), read through a `cosmic.*` accessor.
  Cheapest, and `_tool/testrun.tl` already builds the child env.
- A `cosmic.*` function that maps a compiled path back to its source
  using the build root the runner already writes into
  `.test.modules` (`root`/`build` lines are both there).
- Stage `testdata/` into the build tree, so `fs.dirname(arg[0])`
  becomes true rather than being worked around. Touches
  `embed/cosmic.mk`, which is byte-identical for every project.

Which of these is right is a design question, not a defect fix.
