.SECONDEXPANSION:
.SECONDARY:
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.DEFAULT_GOAL := help

MAKEFLAGS += --no-print-directory
MAKEFLAGS += --no-builtin-rules
MAKEFLAGS += --no-builtin-variables
MAKEFLAGS += --output-sync
MAKEFLAGS += -j$(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)

modules :=
o := o

export PATH := $(CURDIR)/$(o)/bin:$(PATH)
export STAGE_O := $(CURDIR)/$(o)/staged
export FETCH_O := $(CURDIR)/$(o)/fetched

## TMP: temp directory for tests (default: /tmp, use TMP=~/tmp for more space)
TMP ?= /tmp
export TMPDIR := $(TMP)

# Platform for build scripts (all deps use wildcard "*" platform)
platform := linux-x86_64

## INCLUDE_DIRS: directories to search for type definitions (repeatable)
INCLUDE_DIRS ?= lib

include_dir_flags := $(foreach d,$(INCLUDE_DIRS),--include-dir $(d))

include cook.mk
include lib/cook.mk
include 3p/cosmos/cook.mk
include 3p/tl/cook.mk
include 3p/teal-types/cook.mk


# landlock-make sandbox constraints (only effective when using landlock-make)
# global defaults: read-only access, no network, basic stdio
.PLEDGE = stdio rpath
.UNVEIL = \
	rx:$(o)/bootstrap \
	r:lib \
	r:3p

.PHONY: help
## Show this help message
help: $(build_files) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) $(build_help) $(MAKEFILE_LIST)

## Filter targets by pattern (make test only=teal)
filter-only = $(if $(only),$(foreach f,$1,$(if $(findstring $(only),$(f)),$(f))),$1)

cp := cp -p

$(o)/%: %
	@mkdir -p $(@D)
	@$(cp) $< $@

# compile .tl files to .lua (extension changes)
$(o)/%.lua: %.tl $(types_files) $(tl_files) $(bootstrap_files)
	@mkdir -p $(@D)
	@$(bootstrap_cosmic) $(include_dir_flags) --compile $< > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm $@.tmp; else mv $@.tmp $@; fi

# tl files: modules declare _tl, derive compiled .lua outputs
all_tl := $(call filter-only,$(foreach x,$(modules),$($(x)_tl)))
all_lua := $(patsubst %.tl,$(o)/%.lua,$(all_tl))

# define *_staged, *_dir for versioned modules (must be before dep expansion)
# modules can override *_dir for post-processing (e.g., nvim bundles plugins)
$(foreach m,$(modules),$(if $($(m)_version),\
  $(eval $(m)_staged := $(o)/$(m)/.staged)\
  $(if $($(m)_dir),,$(eval $(m)_dir := $(o)/$(m)/.staged))))

# default deps for regular modules (also excluded from file dep expansion)
default_deps := bootstrap test

# expand module deps: M_files depends on deps' _files and _staged
$(foreach m,$(filter-out $(default_deps),$(modules)),\
  $(foreach d,$($(m)_deps),\
    $(eval $($(m)_files): $($(d)_files))\
    $(if $($(d)_staged),\
      $(eval $($(m)_files): $($(d)_staged)))))

all_versions := $(call filter-only,$(foreach x,$(modules),$($(x)_version)))

# versioned modules: o/module/.versioned -> version.lua
$(foreach m,$(modules),$(if $($(m)_version),\
  $(eval $(o)/$(m)/.versioned: $($(m)_version) ; @mkdir -p $$(@D) && ln -sfn $(CURDIR)/$$< $$@)))
all_versioned := $(call filter-only,$(foreach m,$(modules),$(if $($(m)_version),$(o)/$(m)/.versioned)))

# versions get fetched: o/module/.fetched -> o/fetched/module/<ver>-<sha>/<archive>
.PHONY: fetched
all_fetched := $(patsubst %/.versioned,%/.fetched,$(all_versioned))
## Fetch all dependencies only
fetched: $(all_fetched)
# Downloads are integrity-checked against the sha256 pinned in each module's
# version.lua, so TLS here is a transport safeguard, not the trust root. The
# bootstrap cosmic trusts only its embedded CA set by default (upstream's
# anti-MITM opt-in), which is too narrow for github.com's cert chain; trust
# the host's CA store for these fetches so the build works on stock runners
# and behind TLS-intercepting proxies alike. An operator-supplied
# SSL_CERT_FILE bundle is unveiled so the sandboxed fetch can read it.
# Fetch/stage scripts run under the pinned bootstrap but are written
# against THIS tree's cosmic.* APIs (resolved via the exported LUA_PATH).
# Without the compiled stdlib as a prerequisite, a cold parallel build
# could run them mid-compile and require() fell back to the bootstrap's
# embedded older-API stdlib ("attempt to call a nil value (field
# 'fetch')"). Unfiltered on purpose: only= must not shrink the closure.
stdlib_lua := $(patsubst %.tl,$(o)/%.lua,$(filter lib/cosmic/%,$(foreach x,$(modules),$($(x)_tl))))

$(o)/%/.fetched: export SSL_USE_SYSTEM_CERTS = 1
$(o)/%/.fetched: .PLEDGE = stdio rpath wpath cpath inet dns
$(o)/%/.fetched: .UNVEIL = rx:$(o)/bootstrap r:3p rwc:$(o) r:/etc/resolv.conf r:/etc/ssl $(if $(SSL_CERT_FILE),r:$(SSL_CERT_FILE))
$(o)/%/.fetched: $(o)/%/.versioned $(build_files) $(stdlib_lua) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) -- $(build_fetch) $$(readlink $<) $(platform) $@

# versions get staged: o/module/.staged -> o/staged/module/<ver>-<sha>
.PHONY: staged
all_staged := $(patsubst %/.fetched,%/.staged,$(all_fetched))
## Fetch and extract all dependencies
staged: $(all_staged)
$(o)/%/.staged: .PLEDGE = stdio rpath wpath cpath proc exec
$(o)/%/.staged: .UNVEIL = rx:$(o)/bootstrap r:3p rwc:$(o) rx:/usr/bin
$(o)/%/.staged: $(o)/%/.fetched $(build_files) $(stdlib_lua)
	@$(bootstrap_cosmic) -- $(build_stage) $$(readlink $(o)/$*/.versioned) $(platform) $< $@

all_tests := $(call filter-only,$(foreach x,$(modules),$($(x)_tests)))
all_tested := $(patsubst %,$(o)/%.test.got,$(all_tests))

## Run all tests (incremental)
test: $(o)/test-summary.txt

$(o)/test-summary.txt: $(all_tested) | $(cosmic_bin)
	@$(cosmic_bin) --report $^ | tee $@

export TEST_O := $(o)
export TEST_PLATFORM := $(platform)
export TEST_BIN := $(o)/bin
# TEST_TMPDIR is set per-test by cosmic --test command
# LUA_PATH: aggregate _lua_dirs from modules
space := $(subst ,, )
lua_path_dirs := $(foreach m,$(modules),$($(m)_lua_dirs))
export LUA_PATH := $(subst $(space),;,$(foreach d,$(lua_path_dirs),$(CURDIR)/$(d)/?.lua $(CURDIR)/$(d)/?/init.lua));;
export NO_COLOR := 1

# Test rule: execute test via cosmic --test command
$(o)/%.tl.test.got: .PLEDGE = stdio rpath wpath cpath proc exec
$(o)/%.tl.test.got: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwcx:$(o) rwc:$(TMP) rx:/usr rx:/proc r:/etc r:/dev/null

# Namespace-exercising tests need to call unshare(CLONE_NEWUSER|NEWNET|...)
# and write /proc/self/{uid,gid}_map. No pledge promise covers unshare,
# and /proc/self needs write access for the id-map bootstrap, so drop
# pledge and broaden unveil for these specific tests. Everything else
# keeps the tight default above.
quicksand_sandbox_tests := \
  $(o)/lib/cosmic/quicksand/netns_test.tl.test.got \
  $(o)/lib/cosmic/quicksand/proxy_test.tl.test.got \
  $(o)/lib/cosmic/quicksand/box/run_test.tl.test.got \
  $(o)/coverage/lib/cosmic/quicksand/netns_test.tl.test.got \
  $(o)/coverage/lib/cosmic/quicksand/proxy_test.tl.test.got \
  $(o)/coverage/lib/cosmic/quicksand/box/run_test.tl.test.got
$(quicksand_sandbox_tests): .PLEDGE =
$(quicksand_sandbox_tests): .UNVEIL =

$(o)/%.tl.test.got: $(o)/%.lua $(test_files) $(o)/bin/cosmic | $(cosmic_bin)
	@mkdir -p $(@D)
	@TEST_DIR=$(TEST_DIR) PATH=$(CURDIR)/$(o)/bin:$$PATH $(cosmic_bin) --test $(basename $@) $(cosmic_bin) $<

# expand test deps: M's tests depend on own _files/_tl plus deps' _dir/_files/_lua
# derive compiled .lua from _tl (first pass: compute all _lua)
$(foreach m,$(filter-out bootstrap,$(modules)),\
  $(if $($(m)_tl),$(eval $(m)_lua := $(patsubst %.tl,$(o)/%.lua,$($(m)_tl)))))
# second pass: set up test dependencies, for both the plain test tree and
# the coverage lane's separate output tree
test_got_dirs := $(o) $(o)/coverage
$(foreach p,$(test_got_dirs),$(foreach m,$(filter-out bootstrap,$(modules)),\
  $(eval $(patsubst %,$(p)/%.test.got,$($(m)_tests)): $($(m)_files) $($(m)_lua))\
  $(eval $(patsubst %,$(p)/%.test.got,$($(m)_tests)): TEST_DEPS += $($(m)_files) $($(m)_lua))\
  $(if $($(m)_dir),\
    $(eval $(patsubst %,$(p)/%.test.got,$($(m)_tests)): $($(m)_dir))\
    $(eval $(patsubst %,$(p)/%.test.got,$($(m)_tests)): TEST_DEPS += $($(m)_dir))\
    $(eval $(patsubst %,$(p)/%.test.got,$($(m)_tests)): TEST_DIR := $($(m)_dir)))\
  $(foreach d,$(filter-out $(m),$(default_deps) $($(m)_deps)),\
    $(if $($(d)_dir),\
      $(eval $(patsubst %,$(p)/%.test.got,$($(m)_tests)): $($(d)_dir))\
      $(eval $(patsubst %,$(p)/%.test.got,$($(m)_tests)): TEST_DEPS += $($(d)_dir)))\
    $(eval $(patsubst %,$(p)/%.test.got,$($(m)_tests)): $($(d)_files) $($(d)_lua)))))

# Coverage lane: the same tests in a separate output tree, run with
# collection enabled, so `bin/make coverage` never invalidates the plain
# `make test` results (and stays incremental itself). Each test leaves
# .cov files in <got>.cov.d; the summary merges them and folds in lib/
# so entirely untested modules still appear.
coverage_got := $(patsubst %,$(o)/coverage/%.test.got,$(all_tests))

.PHONY: coverage
## Run all tests with line coverage and report per-file totals
coverage: $(o)/coverage-summary.txt

$(o)/coverage/%.tl.test.got: .PLEDGE = stdio rpath wpath cpath proc exec
$(o)/coverage/%.tl.test.got: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwcx:$(o) rwc:$(TMP) rx:/usr rx:/proc r:/etc r:/dev/null
$(o)/coverage/%.tl.test.got: $(o)/%.lua $(test_files) $(o)/bin/cosmic | $(cosmic_bin)
	@mkdir -p $(@D)
	@TEST_DIR=$(TEST_DIR) COSMIC_COVERAGE=1 PATH=$(CURDIR)/$(o)/bin:$$PATH $(cosmic_bin) --test $(basename $@) $(cosmic_bin) $<

# Coverage ratchet: the committed baseline records covered/total per
# file; the check fails when coverage declines or the file set drifts.
# Skipped under only= (partial data would read as a huge decline).
coverage_baseline := lib/cosmic/coverage/baseline.txt
coverage_baseline_tool := $(o)/lib/cosmic/coverage/baseline.lua

$(o)/coverage-summary.txt: .PLEDGE = stdio rpath wpath cpath proc exec
$(o)/coverage-summary.txt: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwcx:$(o)
$(o)/coverage-summary.txt: $(coverage_got) | $(cosmic_bin)
	@$(cosmic_bin) --report $(coverage_got) > $(o)/coverage-tests.txt
	@$(cosmic_bin) --coverage-report $(o)/coverage lib | tee $@
	@if [ -n "$(only)" ]; then \
	  echo "coverage ratchet skipped (only=$(only))"; \
	elif [ -f $(coverage_baseline) ]; then \
	  $(cosmic_bin) $(coverage_baseline_tool) check $(coverage_baseline) $(o)/coverage lib; \
	else \
	  echo "coverage ratchet skipped: no $(coverage_baseline); run 'bin/make coverage-baseline' to start it"; \
	fi

.PHONY: casts-baseline
## Rewrite the committed cast-ratchet pin from current per-file `as` counts
casts-baseline: .PLEDGE = stdio rpath wpath cpath proc exec
casts-baseline: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwcx:$(o) rwc:lib/build
casts-baseline: $(build_lint) $(lint_style_lua) | $(bootstrap_cosmic)
	@$(linter) --write-casts-baseline $(shell git ls-files '*.tl')

.PHONY: coverage-baseline
## Rewrite the committed coverage ratchet baseline from the last coverage run
coverage-baseline: .PLEDGE = stdio rpath wpath cpath proc exec
coverage-baseline: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwcx:$(o) rwc:lib/cosmic/coverage
coverage-baseline: $(coverage_got) | $(cosmic_bin)
	@$(cosmic_bin) $(coverage_baseline_tool) write $(o)/coverage lib > $(coverage_baseline).tmp
	@mv $(coverage_baseline).tmp $(coverage_baseline)
	@echo "wrote $(coverage_baseline)"

# Privileged enforcement lane (Phase 1 step 8 prerequisite, audit §5.1).
# The sandbox tests carry "outer sandbox blocked this -> skip" escape hatches,
# so under CI's own landlock-make sandbox their enforcement assertions silently
# degrade to no-ops and nothing alarms when everything skips. This lane runs the
# sandbox-primitive tests with NO outer sandbox (empty .PLEDGE/.UNVEIL, like the
# quicksand namespace tests) and COSMIC_ENFORCE=1, so a test that cannot exercise
# real enforcement fails loudly instead of skipping. The tripwire then fails the
# lane if *nothing* enforced (the "unexpectedly-everything-skipped" alarm), which
# would mean the lane is not actually unsandboxed and is silently a no-op.
enforce_srcs := \
  lib/cosmic/pledge_test.tl \
  lib/cosmic/landlock_test.tl \
  lib/cosmic/unveil_test.tl
enforce_got := $(patsubst %,$(o)/enforce/%.test.got,$(enforce_srcs))

.PHONY: enforce
## Run sandbox enforcement tests unsandboxed with COSMIC_ENFORCE=1 (privileged lane)
enforce: $(o)/enforce-summary.txt

# Drop the outer sandbox for these targets so enforcement actually runs.
$(enforce_got): .PLEDGE =
$(enforce_got): .UNVEIL =

$(o)/enforce/%.tl.test.got: $(o)/%.lua $(cosmic_bin) | $(cosmic_bin)
	@mkdir -p $(@D)
	@TEST_BIN=$(o)/bin COSMIC_ENFORCE=1 PATH=$(CURDIR)/$(o)/bin:$$PATH \
	  $(cosmic_bin) --test $(basename $@) $(cosmic_bin) $<

$(o)/enforce-summary.txt: $(enforce_got) | $(cosmic_bin)
	@$(cosmic_bin) --report $^ | tee $@
	@if ! grep -rqs "enforce-ran:" $(o)/enforce/; then \
	  echo "enforce tripwire: no enforcement ran — every sandbox test skipped."; \
	  echo "  the privileged lane is not exercising enforcement (outer sandbox still active?)."; \
	  exit 1; \
	fi

all_built_files := $(call filter-only,$(foreach x,$(modules),$($(x)_files)))
all_built_files += $(all_lua)
all_source_files := $(call filter-only,$(foreach x,$(modules),$($(x)_tests)))
all_source_files += $(call filter-only,$(filter-out ,$(foreach x,$(modules),$($(x)_version))))
all_source_files += $(call filter-only,$(foreach x,$(modules),$($(x)_srcs)))
all_source_files += $(all_tl)
all_checkable_files := $(addprefix $(o)/,$(all_source_files))

.PHONY: files
## Build all module files
files: $(all_built_files)

all_teals := $(patsubst %,%.teal.got,$(all_checkable_files))

.PHONY: check
## Run Teal type checking
check: teal

## Run teal type checker on all files
teal: $(o)/teal-summary.txt

$(o)/teal-summary.txt: $(all_teals) | $(build_reporter)
	@$(reporter) --dir $(o) $^ | tee $@

$(o)/%.teal.got: $(o)/% $(cosmic_bin) | $(bootstrap_files)
	@mkdir -p $(@D)
	-@$(cosmic_bin) $(include_dir_flags) --check-types $< > $(basename $@).out 2> $(basename $@).err; STATUS=$$?; echo $$STATUS > $@

all_formats := $(patsubst %,%.format.got,$(all_checkable_files))

## Check formatting on all files
format: $(o)/format-summary.txt

$(o)/format-summary.txt: $(all_formats) | $(build_reporter)
	@$(reporter) --dir $(o) $^ | tee $@

$(o)/%.format.got: $(o)/% $(cosmic_bin) | $(bootstrap_files)
	@mkdir -p $(@D)
	-@$(cosmic_bin) --check-format $< > $(basename $@).out 2> $(basename $@).err; STATUS=$$?; echo $$STATUS > $@

all_linted := $(patsubst %,$(o)/%.lint.ok,$(shell git ls-files 2>/dev/null))

## Check file length limits on all files
lint: $(o)/lint-summary.txt

$(o)/lint-summary.txt: $(all_linted) | $(build_reporter)
	@$(reporter) --dir $(o) $(patsubst %,%.got,$(basename $(all_linted))) | tee $@

$(o)/%.lint.ok: % $(build_lint) $(lint_style_lua) lib/build/casts.txt | $(bootstrap_cosmic)
	@mkdir -p $(@D)
	-@$(linter) $< > $(basename $@).out 2> $(basename $@).err; STATUS=$$?; echo $$STATUS > $(basename $@).got; cp $(basename $@).got $@

.PHONY: clean
## Remove all build artifacts
clean:
	@rm -rf $(o)

.PHONY: bootstrap
## Bootstrap build environment
bootstrap: $(bootstrap_files)

.PHONY: build
## Build cosmic binary
build: cosmic

.PHONY: stage1
## CI stage 1: build cosmic and refresh bootstrap with updated bundled types
stage1: $(cosmic_bin)
	@cp $(cosmic_bin) $(bootstrap_cosmic)
	@echo "Bootstrap refreshed from $(cosmic_bin)"

.PHONY: stage2
## CI stage 2: type check and test with refreshed bootstrap (alias for ci)
stage2: ci

# Example testing - run Example_* functions in _example.tl files
all_example_srcs := $(call filter-only,$(foreach m,$(modules),$($(m)_examples)))
all_examples := $(patsubst %.tl,$(o)/%.tl.example.got,$(all_example_srcs))

.PHONY: example
## Run all example tests
example: $(o)/example-summary.txt

$(o)/example-summary.txt: $(all_examples) | $(build_reporter)
	@$(reporter) --dir $(o) $^ | tee $@

$(o)/%.tl.example.got: .PLEDGE = stdio rpath wpath cpath proc exec
$(o)/%.tl.example.got: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwc:$(o) rwc:$(TMP) rx:/usr rx:/proc r:/etc r:/dev/null
$(o)/%.tl.example.got: %.tl $(cosmic_bin) | $(bootstrap_files)
	@mkdir -p $(@D)
	@set +e; $(cosmic_bin) --check-examples $< > $(basename $@).out 2> $(basename $@).err; echo $$? > $@

# Benchmark testing - run Benchmark_* functions in .tl files (exclude test files)
all_benchmark_srcs := $(call filter-only,$(foreach m,$(modules),$(filter-out $($(m)_tests),$($(m)_tl))))
all_benchmarks := $(patsubst %.tl,$(o)/%.tl.benchmark.got,$(all_benchmark_srcs))

.PHONY: benchmark
## Run all benchmarks
benchmark: $(o)/benchmark-summary.txt

$(o)/benchmark-summary.txt: $(all_benchmarks) | $(build_reporter)
	@$(reporter) --dir $(o) $^ | tee $@

$(o)/%.tl.benchmark.got: .PLEDGE = stdio rpath wpath cpath proc exec
$(o)/%.tl.benchmark.got: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwc:$(o) rwc:$(TMP) rx:/usr rx:/proc r:/etc r:/dev/null
$(o)/%.tl.benchmark.got: %.tl $(cosmic_bin) | $(bootstrap_files)
	@mkdir -p $(@D)
	@set +e; $(cosmic_bin) --benchmark $< > $(basename $@).out 2> $(basename $@).err; echo $$? > $@

# Type definition regeneration.
# The generated .d.tl files are a pure function of (lib/types/gentype*.tl, the
# definitions.lua embedded in the pinned cosmos release). This target runs the
# CURRENT generator from the freshly built cosmic binary against the CURRENT
# pin, so regen is reproducible: bump 3p/cosmos/version.lua, run
# `bin/make regen-types`, commit. The gentype drift test fails until you do.
# Module list ($(type_modules)) defined in cook.mk

.PHONY: regen-types
## Regenerate .d.tl type definitions from the pinned cosmos definitions.lua
regen-types: $(cosmic_bin)
	@echo "Regenerating type definitions from the pinned cosmos definitions.lua..."
	@for mod in $(type_modules); do \
		case $$mod in \
			cosmo) out=lib/types/cosmo.d.tl ;; \
			*) out=lib/types/cosmo/$$mod.d.tl ;; \
		esac; \
		echo "  $$out"; \
		$(cosmic_bin) -e "local r = require('types.gentype').run('$$mod'); assert(r.success, r.error); io.write(r.output)" > $$out.tmp && mv $$out.tmp $$out || { rm -f $$out.tmp; exit 1; }; \
	done
	@echo "Type definitions regenerated. Verify with: bin/make test only=gentype"

# Documentation generation - render .tl files as markdown
# Module sources for docs: all _tl files (excludes tests and examples).
# Deliberately NOT filter-only'd: these feed artifacts (published docs and
# the doc index embedded in the binary). only= filters which tests and
# checks run; it must never change what artifacts contain (#608).
all_module_srcs := $(foreach m,$(modules),$($(m)_tl))
all_docs := $(patsubst %.tl,$(o)/docs/%.md,$(all_module_srcs))

# Documentation from .d.tl type definition files (cosmo modules)
dtl_files := $(wildcard lib/types/cosmo/*.d.tl)
dtl_docs := $(patsubst lib/types/cosmo/%.d.tl,$(o)/docs/cosmo/%.md,$(dtl_files))
all_docs += $(dtl_docs)

.PHONY: docs
## Generate documentation from source
docs: $(all_docs)

$(o)/docs/%.md: %.tl $(cosmic_bin) | $(bootstrap_files)
	@mkdir -p $(@D)
	@$(cosmic_bin) lib/cosmic/doc/gendoc.tl $< > $@

$(o)/docs/cosmo/%.md: lib/types/cosmo/%.d.tl $(cosmic_bin) | $(bootstrap_files)
	@mkdir -p $(@D)
	@$(cosmic_bin) lib/cosmic/doc/gendoc.tl $< > $@

# Generate serialized doc index for embedding (uses bootstrap cosmic to avoid circular dep)
# Include both module sources and example files for the index
# LUA_PATH points at the freshly compiled modules so the index generator uses
# this tree's cosmic.doc code, not the bootstrap's embedded (older) copy
# Example sources for the index are expanded unfiltered here (unlike
# all_example_srcs, which only= legitimately filters as test targets):
# the embedded index must always describe every module (#608)
doc_index_example_srcs := $(foreach m,$(modules),$($(m)_examples))
doc_index_srcs := $(all_module_srcs) $(doc_index_example_srcs) $(dtl_files)
doc_index_lua := $(patsubst %.tl,$(o)/%.lua,$(all_module_srcs))
doc_index := $(o)/docs/.index.lua
doc_index_script := lib/cosmic/doc/index.tl

# Makefile is a prerequisite so trees whose index was poisoned by a
# filtered rebuild (the mtime trap in #608: the broken index is newer
# than every source, and .SECONDARY blocks rebuild-on-delete) self-heal
# when this fix — or any future Makefile change — arrives; the
# write-if-changed dance below keeps the binary from re-embedding when
# the regenerated content is identical
$(doc_index): $(doc_index_srcs) $(doc_index_lua) $(doc_index_script) Makefile | $(bootstrap_cosmic)
	@mkdir -p $(@D)
	@LUA_PATH="$(o)/lib/?.lua;$(o)/lib/?/init.lua;;" $(bootstrap_cosmic) $(doc_index_script) $(doc_index_srcs) > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm $@.tmp; else mv $@.tmp $@; fi

.PHONY: doc-index
## Generate serialized documentation index
doc-index: $(doc_index)

.PHONY: doc-publish
## Publish docs to git branch (SOURCE_SHA required, uses $(o)/docs)
doc-publish: .PLEDGE = stdio rpath wpath cpath proc exec inet dns
doc-publish: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwc:$(o) rwc:$(TMP) rx:/usr rx:/proc r:/etc r:/dev/null rwc:.git rwc:. r:/home r:/root
doc-publish: $(all_docs) $(docs_publish) | $(bootstrap_cosmic)
	@test -n "$(SOURCE_SHA)" || { echo "SOURCE_SHA required"; exit 1; }
	@$(bootstrap_cosmic) -- $(docs_publish) $(SOURCE_SHA) $(o)/docs $(or $(DOCS_BRANCH),docs)

# CI stages
ci_stages := format teal test example lint coverage
ci_summaries := $(foreach s,$(ci_stages),$(o)/$(s)-summary.txt)

.PHONY: ci
## Run CI checks (format, teal, test, example, lint) in parallel
ci:
	@rm -f $(o)/failed
	@$(MAKE) --keep-going $(ci_stages) || true
	@for s in $(ci_stages); do \
		echo "::group::$$s"; \
		if [ -f $(o)/$$s-summary.txt ]; then \
			cat $(o)/$$s-summary.txt; \
			if grep -qE "[1-9][0-9]* failed" $(o)/$$s-summary.txt; then \
				echo $$s >> $(o)/failed; \
			fi; \
		else \
			echo "$$s: no summary produced"; \
			echo $$s >> $(o)/failed; \
		fi; \
		echo "::endgroup::"; \
	done
	@if [ -f $(o)/failed ]; then echo "failed:"; cat $(o)/failed; exit 1; fi

debug-modules:
	@echo $(modules)

