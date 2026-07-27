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

# Content decides, mtime only schedules: every verb writes its output
# only when the bytes change, so a no-op step leaves its target's
# mtime alone and non-changes stop propagating. `--make build` holds
# to it for the ARTIFACT too, which is what makes the next line
# affordable.
#
# $(COSMIC_DEP) — the driver itself — is a prerequisite of every graph
# rule, because a result is only as fresh as the tool that produced it.
# Without it a formatter fix left every `.fmt.got` untouched and a
# whole tree reported clean against the formatter it replaced. It is a
# variable from o/project.mk rather than $(COSMIC) directly so it can
# be empty when the running binary is not a file make can stat.
.DELETE_ON_ERROR:

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
$(O)/%.lua: %.tl $(COSMIC_DEP) $$(srcdeps_$$*)
	compile $(COSMIC) $< $@ --include-dir . --deps $(srcdeps_$*) ;

# .lua sources are first-class. They are copied, not compiled; the
# validator has already refused foo.tl beside foo.lua, so these two
# pattern rules can never both apply to one target.
$(O)/%.lua: %.lua $(COSMIC_DEP)
	copy $< $@ ;

# ------------------------------------------------------------------ fmt

fmt_got := $(patsubst %,$(O)/%.fmt.got,$(fmt_sources))

## Check formatting on every .tl source
fmt: $(O)/fmt-summary.txt

$(O)/%.fmt.got: % $(COSMIC_DEP)
	test $(basename $@) $(COSMIC) --check fmt $< ;

$(O)/fmt-summary.txt: $(fmt_got)
	tee $@ $(COSMIC) --report $(fmt_got) ;

# ----------------------------------------------------------------- test

test_got := $(patsubst %,$(O)/%.test.got,$(tests))

## Run every *_test.tl against the compiled tree
test: $(O)/test-summary.txt

# A test's prerequisites are exactly what it imports, transitively --
# as BUILT paths, since a test runs against compiled Lua. The same list
# goes into the recipe line, so the derived fence grants the test read
# access to what it imports and nothing else. One answer, two
# consumers: the argument positions are the declaration.
$(O)/%.tl.test.got: $(O)/%.lua $(COSMIC_DEP) $$(deps_$$*)
	test $(basename $@) $(COSMIC) $< --deps $(deps_$*) ;

# A `.lua` test is a test. The marker suffixes are extension-agnostic
# in the model, so the rules have to be too -- otherwise a Lua-only
# project's tests are listed and never run, which is worse than not
# supporting them.
$(O)/%.lua.test.got: $(O)/%.lua $(COSMIC_DEP) $$(deps_$$*)
	test $(basename $@) $(COSMIC) $< --deps $(deps_$*) ;

$(O)/test-summary.txt: $(test_got)
	tee $@ $(COSMIC) --report $(test_got) ;

# -------------------------------------------------------------- example

example_got := $(patsubst %,$(O)/%.example.got,$(examples))

## Run every *_example.tl against the compiled tree
example: $(O)/example-summary.txt

# An example is a test with a different contract: same staging, same
# closure, same fence, `Example_*` instead of `test_*`. That is what the
# model says everywhere else, so the rules say it too — the only
# difference from the test rules above is the flag.
$(O)/%.tl.example.got: $(O)/%.lua $(COSMIC_DEP) $$(deps_$$*)
	test $(basename $@) $(COSMIC) --check example $< --deps $(deps_$*) ;

$(O)/%.lua.example.got: $(O)/%.lua $(COSMIC_DEP) $$(deps_$$*)
	test $(basename $@) $(COSMIC) --check example $< --deps $(deps_$*) ;

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
$(O)/%.tl.benchmark.got: $(O)/%.lua $(COSMIC_DEP) $$(deps_$$*)
	test $(basename $@) $(COSMIC) --benchmark $< --deps $(deps_$*) ;

$(O)/%.lua.benchmark.got: $(O)/%.lua $(COSMIC_DEP) $$(deps_$$*)
	test $(basename $@) $(COSMIC) --benchmark $< --deps $(deps_$*) ;

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
$(O)/%.lint.got: % $(COSMIC_DEP)
	test $(basename $@) $(COSMIC) --check lint $< ;

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

$(O)/.coverage/%.tl.test.got: $(O)/%.lua $(COSMIC_DEP) $$(deps_$$*)
	test $(basename $@) $(COSMIC) $< --deps $(deps_$*) ;

$(O)/.coverage/%.lua.test.got: $(O)/%.lua $(COSMIC_DEP) $$(deps_$$*)
	test $(basename $@) $(COSMIC) $< --deps $(deps_$*) ;

$(O)/coverage-summary.txt: $(coverage_got)
	tee $@ $(COSMIC) --report $(coverage_got) ;
