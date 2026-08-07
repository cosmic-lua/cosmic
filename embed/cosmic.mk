# cosmic.mk — the rules for `cosmic --make`.
#
# This file is CONSTANT. It ships inside the cosmic binary and is
# byte-identical for every project: nothing here is generated, and no
# rule is ever emitted per project. What varies is o/project.mk, which
# holds only variable assignments — the file lists cosmic's own walk
# and validator produced. Codegen is therefore "emit a list of
# variables", while discovery and validation stay in Teal, where an
# error can name a path and say what is wrong with it.
#
# Every recipe line is whitespace-split argv whose first word is a
# cosmic verb, run through `cosmic -c`. No quoting, no expansion, no
# pipes, no redirects — the build's entire capability surface is that
# vocabulary. The trailing `;` on each line is load-bearing: make
# execs a line it judges shell-free itself, without consulting SHELL,
# so a line with no metacharacter would never reach cosmic at all.
# `-c` strips exactly one trailing sentinel; a `;` anywhere else is
# still refused.

include o/project.mk

SHELL := $(COSMIC)

# Secondary expansion, declared before the first rule that needs it: a
# prerequisite written `$$(srcdeps_$$*)` resolves on the second pass,
# once the stem is known. It is what lets rules that never change name a
# per-target variable the facts file computed.
.SECONDEXPANSION:

# Not every verb leaves a no-op target's mtime alone -- only three
# things actually do: `write-list` and the makefiles (`o/project.mk`,
# via `write_if_changed`) skip the write entirely when the bytes match,
# and the ARTIFACT itself is swapped in only when it differs
# (`replace_if_changed`), so an unchanged binary never invalidates the
# tree that depends on the tool that built it. Most recipe steps
# (`compile`, `capture`, via `run_into`) instead restamp the target's
# mtime even when the bytes are unchanged -- deliberately, so a target
# make judged out of date does not stay out of date forever -- and
# `tee`/`copy` write unconditionally. Convergence rests on the
# artifact, not on every intermediate staying untouched.
#
# Every graph rule names a TOOL STAMP — `$(O)/.stamp/<tool>`, written
# by materialize before make runs — because a result is only as fresh
# as the tool that produced it: a formatter fix must invalidate every
# `.fmt.got`, or a whole tree reports clean against the formatter it
# replaced. The stamp is a hash of the embedded bytes that run when
# the rule's verb runs (see _make/stamp.tl), NOT the binary itself:
# the binary embeds every module, so naming it invalidated the whole
# graph on any edit anywhere, and made each build's replaced artifact
# re-run the world once more to prove nothing changed.
.DELETE_ON_ERROR:

# ...except the summaries, which are PHONY instead.
#
# A summary's recipe exits nonzero BECAUSE its stage failed, so
# `.DELETE_ON_ERROR` deleted exactly the artifact a consumer opens
# next -- a CI step, `ci` grading its own stages, a person reading `o/`
# after the fact.
#
# `.PRECIOUS` looks like the fix and is a worse bug: make's
# `delete_target` does return early for a precious file, so the summary
# survives -- with a mtime NEWER than the `.got` files it reports on.
# make then calls it up to date and never runs `--report` again, so the
# stage's failure is never re-reported and the verdict reads a stale
# summary forever. Verified both ways against real make.
#
# Phony gets both properties from one word: `delete_target` returns
# early for a phony file too, and a phony target's recipe always runs.
# A summary is a REPORT over targets that already exist -- reading a
# handful of `.got` files -- so always-fresh is what it should have
# been. `tee` writes the summary unconditionally every run (it does not
# compare against the existing file), which is fine precisely because
# the target is phony: nothing depends on the summary's mtime for
# freshness, only on the `.got` files it reads.
.PHONY: $(O)/fmt-summary.txt $(O)/test-summary.txt \
        $(O)/example-summary.txt $(O)/benchmark-summary.txt \
        $(O)/lint-summary.txt $(O)/coverage-summary.txt

.PHONY: all build compile fmt test example benchmark lint coverage

all: build

# ---------------------------------------------------------------- build

compiled := $(patsubst %.tl,$(O)/%.lua,$(tl_sources))
staged := $(patsubst %,$(O)/%,$(lua_sources))

## Compile every source into $(O)
build: compile
compile: $(compiled) $(staged)

# Strict: --compile-strict type checks and generates from that same
# checked AST, so nothing lands in $(O) that the checker rejected.
# `--include-dir .` is what makes the project root the module root —
# require("pkg.db") resolves to pkg/db.tl and nowhere else.
#
# srcdeps is what makes "strict" mean anything incrementally. A strict
# compile checks against the SOURCES it imports, so a module whose
# contract changed must recompile its importers; without these
# prerequisites the incremental build happily kept output a clean build
# rejects. They are also passed in the line, so the fence grants the
# compiler its own source plus what it imports -- and not the `.`
# include path, which is where it SEARCHES, not what it reads.
#
# $(O)/_types/types_gen.stamp is the same hazard one layer down: every
# compile resolves `cosmo.*` (and `tl`) through o/_types/types_gen on
# its include path, but that directory is generated, not a listed
# source -- so without this prerequisite a cosmos pin bump left every
# already-compiled file's mtime alone and an unchanged file kept
# checking against types the LAST pin left. The stamp is
# content-addressed (`_make.generate`'s stamp_types), so a run that
# regenerates byte-identical declarations does not move its mtime and
# a no-op build stays a no-op.
# The two stamps ride in the line as well as the prerequisite list:
# everything after --deps is an INPUT -- granted by the fence, keyed by
# the step's content skip (_cli/build/work.tl), never forwarded to the
# child. A line that declares its inputs is one the step can prove it
# already ran.
$(O)/%.lua: %.tl $(O)/.stamp/compile $(O)/_types/types_gen.stamp $$(srcdeps_$$*)
	compile $(COSMIC) $< $@ --include-dir . --deps $(srcdeps_$*) $(O)/.stamp/compile $(O)/_types/types_gen.stamp ;

# .lua sources are first-class. They are copied, not compiled; the
# validator has already refused foo.tl beside foo.lua, so these two
# pattern rules can never both apply to one target.
$(O)/%.lua: %.lua $(O)/.stamp/driver
	copy $< $@ ;

# ------------------------------------------------------------------ fmt

fmt_got := $(patsubst %,$(O)/%.fmt.got,$(fmt_sources))

## Check formatting on every .tl source
fmt: $(O)/fmt-summary.txt

$(O)/%.fmt.got: % $(O)/.stamp/fmt
	record $(basename $@) $(COSMIC) --check fmt $< ;

$(O)/fmt-summary.txt: $(fmt_got)
	tee $@ $(COSMIC) --report $(fmt_got) ;

# ----------------------------------------------------------------- test

test_got := $(patsubst %,$(O)/%.test.got,$(tests))

## Run every *_test.tl against the compiled tree
test: $(O)/test-summary.txt

# A test's prerequisites are exactly what it imports, transitively --
# as BUILT paths, since a test runs against compiled Lua. The same list
# goes into the recipe line, feeding the derived fence -- but the fence
# grants a test read access to the whole project ("."), plus the
# runtime paths tests legitimately touch (ptys, /proc/self/fd, resolver
# files), not just what it imports: an import-only read grant did not
# survive contact with real tests (see `_cli/grants.tl`'s "record"
# case). What IS narrow is the write grant: only the test's own `.got`
# base and TMPDIR. One answer, two consumers: the argument positions
# are the declaration.
# Tests exec `$(testrun)`: with root `embed/` payload that is
# `o/.testrun/cosmic` — this cosmic plus the payload at its artifact
# paths, assembled before the graph runs — so `/zip/R` resolves inside
# a test exactly as inside the artifact. Without payload it is
# `$(COSMIC)` and `testrun_dep` is empty: the d17 rule against naming
# the binary as a prerequisite stands, while the runner file is
# content-addressed, so as a prerequisite it moves exactly when the
# toolchain or the payload did.
$(O)/%.tl.test.got: $(O)/%.lua $(O)/.stamp/record $$(deps_$$*) $(testrun_dep)
	record $(basename $@) $(testrun) $< --deps $(deps_$*) ;

# A `.lua` test is a test. The marker suffixes are extension-agnostic
# in the model, so the rules have to be too -- otherwise a Lua-only
# project's tests are listed and never run, which is worse than not
# supporting them.
$(O)/%.lua.test.got: $(O)/%.lua $(O)/.stamp/record $$(deps_$$*) $(testrun_dep)
	record $(basename $@) $(testrun) $< --deps $(deps_$*) ;

$(O)/test-summary.txt: $(test_got)
	tee $@ $(COSMIC) --report $(test_got) ;

# -------------------------------------------------------------- example

example_got := $(patsubst %,$(O)/%.example.got,$(examples))

## Run every *_example.tl against the compiled tree
example: $(O)/example-summary.txt

# An example is a test with a different contract: same staging, same
# closure, same fence, `Example_*` instead of `test_*`. Two differences
# from the test rules above: the flag, and the file handed to the
# runner. Examples carry their expected output in `-- Output:` comments,
# which compilation strips, so the runner reads the SOURCE — handing it
# `$<` silently skipped every output check. The compiled prerequisite
# still gates the run on a clean typecheck.
$(O)/%.tl.example.got: $(O)/%.lua $(O)/.stamp/record $$(deps_$$*) $(testrun_dep)
	record $(basename $@) $(testrun) --check example $*.tl --deps $(deps_$*) ;

$(O)/%.lua.example.got: $(O)/%.lua $(O)/.stamp/record $$(deps_$$*) $(testrun_dep)
	record $(basename $@) $(testrun) --check example $< --deps $(deps_$*) ;

$(O)/example-summary.txt: $(example_got)
	tee $@ $(COSMIC) --report $(example_got) ;

# ------------------------------------------------------------ benchmark

benchmark_got := $(patsubst %,$(O)/%.benchmark.got,$(benchmarks))

## Run every *_benchmark.tl against the compiled tree
benchmark: $(O)/benchmark-summary.txt

# `test`'s third sibling: same staging, same closure, same fence,
# `Benchmark_*` instead of `test_*`. A benchmark is deliberately NOT a
# generation unit — a generator's output is a build INPUT, derived from
# sources and stale when they change, while a measurement is of one
# binary on one machine at one moment and is never stale, just old.
$(O)/%.tl.benchmark.got: $(O)/%.lua $(O)/.stamp/record $$(deps_$$*) $(testrun_dep)
	record $(basename $@) $(testrun) --benchmark $< --deps $(deps_$*) ;

$(O)/%.lua.benchmark.got: $(O)/%.lua $(O)/.stamp/record $$(deps_$$*) $(testrun_dep)
	record $(basename $@) $(testrun) --benchmark $< --deps $(deps_$*) ;

$(O)/benchmark-summary.txt: $(benchmark_got)
	tee $@ $(COSMIC) --report $(benchmark_got) ;

# ----------------------------------------------------------------- lint

lint_got := $(patsubst %,$(O)/%.lint.got,$(lint_sources))

## Style-check every file in the project
lint: $(O)/lint-summary.txt

# The file set is the MODEL's, not git's. `lint_sources` is every file
# the walk found — sources, payload, assets, this makefile's own
# committed twin — which is the tracked-shaped set already, minus `o/`
# and minus what `.cosmicignore` excludes, with no `git ls-files` and so
# no git in the gate at all. A brand-new file is linted the moment it
# exists rather than the moment it is staged.
#
# No compile prerequisite: lint reads the file as bytes. That is why it
# sees a `.md`, a `.mk` and a `.yml`, and why it is a verb of its own
# rather than a stage of `check`.
$(O)/%.lint.got: % $(O)/.stamp/lint
	record $(basename $@) $(COSMIC) --check lint $< ;

$(O)/lint-summary.txt: $(lint_got)
	tee $@ $(COSMIC) --report $(lint_got) ;

# ------------------------------------------------------------- coverage

coverage_got := $(patsubst %,$(O)/.coverage/%.test.got,$(tests))

## Run every test again with line coverage collected
coverage: $(O)/coverage-summary.txt

# A SECOND output tree, so a coverage run never invalidates the plain
# test results and stays incremental itself. Same recipe as the test
# rules; the environment is the whole difference.
#
# Dot-prefixed, because the layout is a MIRROR: `o/<path>` means the
# output for the source at `<path>`, so an engine-owned directory
# `o/coverage/` and a project's own `coverage/` collide -- one path
# claimed by two rules under two environments. The walk never treats a
# dot entry as a project file, so a dot name is one the mirror cannot
# reach, and the reserved set is a rule rather than a word list.
$(O)/.coverage/%.test.got: export COSMIC_COVERAGE := 1

$(O)/.coverage/%.tl.test.got: $(O)/%.lua $(O)/.stamp/record $$(deps_$$*) $(testrun_dep)
	record $(basename $@) $(testrun) $< --deps $(deps_$*) ;

$(O)/.coverage/%.lua.test.got: $(O)/%.lua $(O)/.stamp/record $$(deps_$$*) $(testrun_dep)
	record $(basename $@) $(testrun) $< --deps $(deps_$*) ;

$(O)/coverage-summary.txt: $(coverage_got)
	tee $@ $(COSMIC) --report $(coverage_got) ;
