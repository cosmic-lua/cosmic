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
# mtime alone and non-changes stop propagating.
.DELETE_ON_ERROR:

.PHONY: all build compile fmt test

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
$(O)/%.lua: %.tl $$(srcdeps_$$*)
	compile $(COSMIC) $< $@ --include-dir . --deps $(srcdeps_$*) ;

# .lua sources are first-class. They are copied, not compiled; the
# validator has already refused foo.tl beside foo.lua, so these two
# pattern rules can never both apply to one target.
$(O)/%.lua: %.lua
	copy $< $@ ;

# ------------------------------------------------------------------ fmt

fmt_got := $(patsubst %,$(O)/%.fmt.got,$(fmt_sources))

## Check formatting on every .tl source
fmt: $(O)/fmt-summary.txt

$(O)/%.fmt.got: %
	test $(basename $@) $(COSMIC) --check-format $< ;

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
$(O)/%.tl.test.got: $(O)/%.lua $$(deps_$$*)
	test $(basename $@) $(COSMIC) $< --deps $(deps_$*) ;

# A `.lua` test is a test. The marker suffixes are extension-agnostic
# in the model, so the rules have to be too -- otherwise a Lua-only
# project's tests are listed and never run, which is worse than not
# supporting them.
$(O)/%.lua.test.got: $(O)/%.lua $$(deps_$$*)
	test $(basename $@) $(COSMIC) $< --deps $(deps_$*) ;

$(O)/test-summary.txt: $(test_got)
	tee $@ $(COSMIC) --report $(test_got) ;
