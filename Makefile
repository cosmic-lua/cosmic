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

# PATH, LC_ALL, TZ are clamped in cook.mk (#731) — deliberate, not inherited
export STAGE_O := $(CURDIR)/$(o)/staged
export FETCH_O := $(CURDIR)/$(o)/fetched

## TMP: temp directory for tests (default: /tmp, use TMP=~/tmp for more space)
TMP ?= /tmp
export TMPDIR := $(TMP)

# Platform tag (fetch/stage matching, TEST_PLATFORM); derived, not hardcoded (#721)
platform := $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)

## INCLUDE_DIRS: directories to search for type definitions (repeatable)
INCLUDE_DIRS ?= lib

include_dir_flags := $(foreach d,$(INCLUDE_DIRS),--include-dir $(d))

include cook.mk
include lib/cook.mk
include 3p/cosmos/cook.mk
include 3p/tl/cook.mk


# landlock-make sandbox annotations. IMPORTANT (#716): landlock-make
# only enforces .PLEDGE/.UNVEIL for rules that set .SANDBOXED = 1 —
# nothing here sets it except the sandbox-canary probe, so these
# annotations are documented intent, not active enforcement (and
# cosmopolitan's unveil() no-ops without Landlock). The canary proves
# the mechanism works; see it before flipping enforcement on. NOTE:
# make hands .UNVEIL values to unveil UNEXPANDED — assign with := and
# compose from the shared grant sets in cook.mk (#718).
# global defaults: read-only access, no network, basic stdio
.PLEDGE := stdio rpath
.UNVEIL := $(unveil_base)

.PHONY: help
## Show this help message
help: $(build_files) | $(bootstrap_cosmic)
	@LUA_PATH="$(tree_lua_path)" $(bootstrap_cosmic) $(build_help) $(MAKEFILE_LIST)

## Filter targets by substring (make test only=teal; also narrows fetch/stage)
filter-only = $(if $(only),$(foreach f,$1,$(if $(findstring $(only),$(f)),$(f))),$1)

cp := cp -p

# Copies and compiles run through the build-recipe driver (#732): no
# shell, no host mkdir/cp/cat/cmp/mv (LUA_PATH pins live in cook.mk
# with the family's other pattern vars). .exists orders cold-tree
# copies after o/ exists (unveil skips missing paths silently).
$(o)/%: % $(build_recipe) | $(o)/.exists $(bootstrap_cosmic)
	@$(bootstrap_cosmic) -- $(build_recipe) copy $< $@
$(o)/.exists: ; @mkdir -p $(@D) && touch $@

$(o)/%.lua: %.tl $(types_files) $(tl_files) $(bootstrap_files) $(compile_flag_stamp) $(build_recipe)
	@$(bootstrap_cosmic) -- $(build_recipe) compile $(compile_flag_stamp) $(bootstrap_cosmic) $< $@ $(include_dir_flags)

# tl files: modules declare _tl, derive compiled .lua outputs
all_tl := $(call filter-only,$(foreach x,$(modules),$($(x)_tl)))
all_lua := $(patsubst %.tl,$(o)/%.lua,$(all_tl))

# define *_staged, *_dir for versioned modules (must be before dep expansion)
# modules can override *_dir for post-processing (e.g., nvim bundles plugins)
$(foreach m,$(modules),$(if $($(m)_version),\
  $(eval $(m)_staged := $(o)/$(m)/.staged)\
  $(if $($(m)_dir),,$(eval $(m)_dir := $(o)/$(m)/.staged))))

# modules excluded from file dep expansion
default_deps := bootstrap

# expand module deps: M_files depends on deps' _files and _staged
$(foreach m,$(filter-out $(default_deps),$(modules)),\
  $(foreach d,$($(m)_deps),\
    $(eval $($(m)_files): $($(d)_files))\
    $(if $($(d)_staged),\
      $(eval $($(m)_files): $($(d)_staged)))))

all_versions := $(call filter-only,$(foreach x,$(modules),$($(x)_version)))

# versioned modules: o/module/.versioned -> version.lua
$(foreach m,$(modules),$(if $($(m)_version),\
  $(eval $(o)/$(m)/.versioned: $($(m)_version) $(build_recipe) | $(bootstrap_cosmic) ; @$(bootstrap_cosmic) -- $(build_recipe) link $(CURDIR)/$$< $$@)))
all_versioned := $(call filter-only,$(foreach m,$(modules),$(if $($(m)_version),$(o)/$(m)/.versioned)))

# versions get fetched: o/module/.fetched -> o/fetched/module/<ver>-<sha>/<archive>
.PHONY: fetched
all_fetched := $(patsubst %/.versioned,%/.fetched,$(all_versioned))
## Fetch all dependencies only
fetched: $(all_fetched)
# Downloads are integrity-checked against the sha256 pinned in each
# module's version.lua — TLS is transport, not the trust root — via the
# host CA store (bootstrap CAs are too narrow for github.com; an
# operator SSL_CERT_FILE bundle is unveiled). The scripts run under the
# pinned bootstrap against THIS tree's cosmic.* APIs — the compiled
# stdlib is a prerequisite (a cold parallel build once fell back to the
# bootstrap's embedded stdlib; only= must not shrink it). De-hosted
# (#732): symlink resolution and extraction are in-process, and the
# no-shell/LUA_PATH target variables in cook.mk (with the .SANDBOXED
# flips) make each recipe a direct bootstrap exec — no $(unveil_hostx):
# ONLY the pinned bootstrap executes under these grants.
stdlib_lua := $(patsubst %.tl,$(o)/%.lua,$(filter lib/cosmic/%,$(foreach x,$(modules),$($(x)_tl))))
$(o)/%/.fetched: export SSL_USE_SYSTEM_CERTS = 1
$(o)/%/.fetched: .PLEDGE := $(pledge_build) inet dns
$(o)/%/.fetched: .UNVEIL := $(unveil_dep) $(unveil_dev) r:/etc/resolv.conf r:/etc/hosts r:/etc/ssl $(if $(SSL_CERT_FILE),r:$(SSL_CERT_FILE))
$(o)/%/.fetched: $(o)/%/.versioned $(build_files) $(stdlib_lua) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) -- $(build_fetch) $< $(platform) $@

# versions get staged: o/module/.staged -> o/staged/module/<ver>-<sha>
.PHONY: staged
all_staged := $(patsubst %/.fetched,%/.staged,$(all_fetched))
## Fetch and extract all dependencies
staged: $(all_staged)
$(o)/%/.staged: .PLEDGE := $(pledge_build)
$(o)/%/.staged: .UNVEIL := $(unveil_dep) $(unveil_dev)
$(o)/%/.staged: $(o)/%/.fetched $(build_files) $(stdlib_lua)
	@$(bootstrap_cosmic) -- $(build_stage) $(o)/$*/.versioned $(platform) $< $@

all_tests := $(call filter-only,$(foreach x,$(modules),$($(x)_tests)))
all_tested := $(patsubst %,$(o)/%.test.got,$(all_tests))

## Run all tests (incremental)
test: $(o)/test-summary.txt

$(o)/test-summary.txt: export LUA_PATH := ;;
$(o)/test-summary.txt: private SHELL := /dev/null/enoshell
$(o)/test-summary.txt: private .SHELLFLAGS := -c
$(o)/test-summary.txt: $(all_tested) | $(cosmic_bin) $(build_recipe)
	@$(bootstrap_cosmic) -- $(build_recipe) tee $@ $(cosmic_bin) --report $^

export TEST_O := $(o)
export TEST_PLATFORM := $(platform)
# per-module target-specific TEST_DIR values reach recipe envs via this
export TEST_DIR
export TEST_BIN := $(o)/bin
# TEST_TMPDIR is set per-test by cosmic --test command
# tree_lua_path aggregates _lua_dirs from modules. Deliberately NOT
# exported (#720): the ambient export was the root of the stale-stdlib
# bug class (#666, #608) — recipes opt in via LUA_PATH="$(tree_lua_path)";
# everything else runs against the binary's embedded copy.
empty :=
space := $(empty) $(empty)
lua_path_dirs := $(foreach m,$(modules),$($(m)_lua_dirs))
tree_lua_path := $(subst $(space),;,$(foreach d,$(lua_path_dirs),$(CURDIR)/$(d)/?.lua $(CURDIR)/$(d)/?/init.lua));;
export NO_COLOR := 1
# Tree-only absolute type-resolution path — TL_PATH pins tl.search_module to the tree, never the bootstrap's stale /zip copy (#744; see cook.mk, makefile_test).
tree_tl_path := $(subst $(space),;,$(foreach d,$(CURDIR) $(foreach e,$(INCLUDE_DIRS),$(CURDIR)/$(e)) $(CURDIR)/lib/types,$(d)/?.lua $(d)/?/init.lua))

# Test rule: execute test via cosmic --test command
$(o)/%.tl.test.got: .PLEDGE := $(pledge_test)
$(o)/%.tl.test.got: .UNVEIL := $(unveil_test)

# teal_config_test reads tlconfig.lua and the Makefile (outside the test unveil)
tlconfig_tests := $(o)/lib/cosmic/teal_config_test.tl.test.got \
  $(o)/coverage/lib/cosmic/teal_config_test.tl.test.got
$(tlconfig_tests): .UNVEIL := $(unveil_test) r:tlconfig.lua r:Makefile

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
$(quicksand_sandbox_tests): .SANDBOXED := 0
$(quicksand_sandbox_tests): .PLEDGE =
$(quicksand_sandbox_tests): .UNVEIL =

$(o)/%.tl.test.got: $(o)/%.lua $(cosmic_bin) $(ape_loader)
	@$(cosmic_bin) --test $(basename $@) $(cosmic_bin) $<

# Test deps beyond the pattern rule (own compiled .lua + $(cosmic_bin))
# live in each module's cook.mk: perf tests attach $(perf_lua), build
# tests $(build_files), docs tests $(docs_files), cosmos/tl tests their
# staged tree + TEST_DIR, cosmic_debug_test the debug binary. Everything
# else rides on $(cosmic_bin), which already depends on the whole
# embedded stdlib, the staged 3p trees, and the type declarations — the
# old per-module foreach/eval expansion here (and its write-only
# TEST_DEPS accumulator) duplicated that transitive closure (#715).

# Coverage lane: the same tests in a separate output tree, run with
# collection enabled, so `bin/make coverage` never invalidates the plain
# `make test` results (and stays incremental itself). Each test leaves
# .cov files in <got>.cov.d; the summary merges them and folds in lib/
# so entirely untested modules still appear.
coverage_got := $(patsubst %,$(o)/coverage/%.test.got,$(all_tests))

.PHONY: coverage
## Run all tests with line coverage and report per-file totals
coverage: $(o)/coverage-summary.txt

$(o)/coverage/%.tl.test.got: .PLEDGE := $(pledge_test)
$(o)/coverage/%.tl.test.got: .UNVEIL := $(unveil_test)
$(o)/coverage/%.tl.test.got: export COSMIC_COVERAGE := 1
$(o)/coverage/%.tl.test.got: $(o)/%.lua $(cosmic_bin) $(ape_loader)
	@$(cosmic_bin) --test $(basename $@) $(cosmic_bin) $<

# Coverage ratchet: the committed baseline records covered/total per
# file; the check fails when coverage declines or the file set drifts.
# Skipped under only= (partial data would read as a huge decline).
coverage_baseline := lib/cosmic/coverage/baseline.txt
coverage_baseline_tool := $(o)/lib/cosmic/coverage/baseline.lua

$(o)/coverage-summary.txt: .PLEDGE := $(pledge_build)
$(o)/coverage-summary.txt: .UNVEIL := $(unveil_base) rwcx:$(o)
$(o)/coverage-summary.txt: $(coverage_got) | $(cosmic_bin) $(build_recipe)
	@$(bootstrap_cosmic) -- $(build_recipe) capture $(cosmic_bin) $(o)/coverage-tests.txt --report $(coverage_got)
	@$(bootstrap_cosmic) -- $(build_recipe) tee $@ $(cosmic_bin) --coverage-report $(o)/coverage lib
	@if [ -n "$(only)" ]; then \
	  echo "coverage ratchet skipped (only=$(only))"; \
	elif [ -f $(coverage_baseline) ]; then \
	  $(cosmic_bin) $(coverage_baseline_tool) check $(coverage_baseline) $(o)/coverage lib; \
	else \
	  echo "coverage ratchet skipped: no $(coverage_baseline); run 'bin/make coverage-baseline' to start it"; \
	fi

.PHONY: coverage-baseline
## Rewrite the committed coverage ratchet baseline from the last coverage run
coverage-baseline: .PLEDGE := $(pledge_build)
coverage-baseline: .UNVEIL := $(unveil_base) rwcx:$(o) rwc:lib/cosmic/coverage
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
$(enforce_got): .SANDBOXED := 0
$(enforce_got): .PLEDGE =
$(enforce_got): .UNVEIL =

$(o)/enforce/%.tl.test.got: export COSMIC_ENFORCE := 1
$(o)/enforce/%.tl.test.got: $(o)/%.lua $(cosmic_bin)
	@$(cosmic_bin) --test $(basename $@) $(cosmic_bin) $<

# The require-marker line is the tripwire: it fails the lane when no
# enforcement ran (every sandbox test skipped — outer sandbox active?).
$(o)/enforce-summary.txt: export LUA_PATH := ;;
$(o)/enforce-summary.txt: private SHELL := /dev/null/enoshell
$(o)/enforce-summary.txt: private .SHELLFLAGS := -c
$(o)/enforce-summary.txt: $(enforce_got) | $(cosmic_bin) $(build_recipe)
	@$(bootstrap_cosmic) -- $(build_recipe) tee $@ $(cosmic_bin) --report $^
	@$(bootstrap_cosmic) -- $(build_recipe) require-marker enforce-ran: $(o)/enforce

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
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $^

$(o)/%.teal.got: $(o)/% $(cosmic_check_bin) | $(bootstrap_files)
	@$(cosmic_check_bin) --test $(basename $@) $(cosmic_check_bin) $(include_dir_flags) --check-types $<

all_formats := $(patsubst %,%.format.got,$(all_checkable_files))

## Check formatting on all files
format: $(o)/format-summary.txt

$(o)/format-summary.txt: $(all_formats) | $(build_reporter)
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $^

$(o)/%.format.got: $(o)/% $(cosmic_check_bin) | $(bootstrap_files)
	@$(cosmic_check_bin) --test $(basename $@) $(cosmic_check_bin) --check-format $<

# Lint every tracked file (#719). git ls-files fails SILENTLY outside
# a git checkout — an empty list would lint nothing and report green,
# so the summary recipe fails loudly instead. Tracked-but-deleted files
# appear in ls-files but cannot be made: lint what exists, surface the
# skips in the summary, fail if the filter collapses the list. The
# stamp records the linted set so a deletion (which only SHRINKS the
# prerequisite list) still rebuilds the summary instead of staying
# stale-green "up to date".
lint_tracked := $(shell git ls-files 2>/dev/null)
lint_present := $(wildcard $(lint_tracked))
lint_deleted := $(filter-out $(lint_present),$(lint_tracked))
all_linted := $(patsubst %,$(o)/%.lint.got,$(lint_present))

lint_list_stamp := $(o)/lint-files.stamp
$(lint_list_stamp): .FORCE $(build_recipe)
	@$(bootstrap_cosmic) -- $(build_recipe) list $@ $(lint_present)

## Check file length limits on all files
lint: $(o)/lint-summary.txt

$(o)/lint-summary.txt: export REPORTER_NOTE = $(if $(lint_deleted),lint: skipped deleted tracked file(s): $(lint_deleted))
$(o)/lint-summary.txt: $(all_linted) $(lint_list_stamp) | $(build_reporter)
	$(if $(strip $(lint_tracked)),,$(error lint: git ls-files found nothing — not a git checkout?))
	$(if $(strip $(lint_present)),,$(error lint: no tracked file exists on disk — filter collapsed the list?))
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $(all_linted)

$(o)/%.lint.got: % $(build_lint) $(lint_style_lua) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) --test $(basename $@) $(bootstrap_cosmic) -- $(build_lint) $<

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
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $^

$(o)/%.tl.example.got: %.tl $(cosmic_bin) $(ape_loader) | $(bootstrap_files)
	@$(cosmic_bin) --test $(basename $@) $(cosmic_bin) --check-examples $<

# Benchmark testing - run Benchmark_* functions in .tl files (exclude test files)
all_benchmark_srcs := $(call filter-only,$(foreach m,$(modules),$(filter-out $($(m)_tests),$($(m)_tl))))
all_benchmarks := $(patsubst %.tl,$(o)/%.tl.benchmark.got,$(all_benchmark_srcs))

.PHONY: benchmark
## Run all benchmarks
benchmark: $(o)/benchmark-summary.txt

$(o)/benchmark-summary.txt: $(all_benchmarks) | $(build_reporter)
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $^

$(o)/%.tl.benchmark.got: .PLEDGE := $(pledge_build)
$(o)/%.tl.benchmark.got: .UNVEIL := $(unveil_run)
$(o)/%.tl.benchmark.got: %.tl $(cosmic_bin) | $(bootstrap_files)
	@$(cosmic_bin) --test $(basename $@) $(cosmic_bin) --benchmark $<

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

# $(MAKEFILE_LIST) — the Makefile and every included cook.mk — is a
# prerequisite so trees whose index was poisoned by a filtered rebuild
# (the mtime trap in #608: the broken index is newer than every source,
# and .SECONDARY blocks rebuild-on-delete) self-heal when this fix — or
# any future build-logic change — arrives; a bare Makefile prereq missed
# cook.mk edits (#717). The write-if-changed dance below keeps the
# binary from re-embedding when the regenerated content is identical
$(doc_index): export TREE_LUA_PATH = $(o)/lib/?.lua;$(o)/lib/?/init.lua;;
$(doc_index): $(doc_index_srcs) $(doc_index_lua) $(doc_index_script) $(build_recipe) $(MAKEFILE_LIST) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) -- $(build_recipe) capture $(bootstrap_cosmic) $@ $(doc_index_script) $(doc_index_srcs)

.PHONY: doc-index
## Generate serialized documentation index
doc-index: $(doc_index)

.PHONY: doc-publish
## Publish docs to git branch (SOURCE_SHA required, uses $(o)/docs)
doc-publish: .PLEDGE := $(pledge_build) inet dns
doc-publish: .UNVEIL := $(unveil_run) rwc:.git rwc:. r:/home r:/root
doc-publish: $(all_docs) $(docs_publish) | $(bootstrap_cosmic)
	@test -n "$(SOURCE_SHA)" || { echo "SOURCE_SHA required"; exit 1; }
	@LUA_PATH="$(tree_lua_path)" $(bootstrap_cosmic) -- $(docs_publish) $(SOURCE_SHA) $(o)/docs $(or $(DOCS_BRANCH),docs)

# CI stages
ci_stages := format teal test example lint coverage
ci_summaries := $(foreach s,$(ci_stages),$(o)/$(s)-summary.txt)
ci_marks := $(foreach s,$(ci_stages),$(o)/ci-ok-$(s))

# Per-stage exit marker: made only after the stage's entire subtree
# succeeded. Grading below reads it so a recipe that fails AFTER writing
# a clean summary still fails the stage (#714: the coverage ratchet
# laundered its exit status through the already-tee'd summary). All
# markers build in ONE sub-make, so stages keep sharing the target graph
# and run in parallel without racing on common prerequisites.
$(o)/ci-ok-%: %
	@mkdir -p $(@D)
	@touch $@

.PHONY: ci
## Run CI checks (format, teal, test, example, lint) in parallel
ci:
	@rm -f $(o)/failed $(ci_summaries) $(ci_marks)
	@$(MAKE) --keep-going $(ci_marks) || true
	@for s in $(ci_stages); do \
		echo "::group::$$s"; \
		if [ -f $(o)/$$s-summary.txt ]; then \
			cat $(o)/$$s-summary.txt; \
			if grep -qE "[1-9][0-9]* failed" $(o)/$$s-summary.txt; then \
				echo $$s >> $(o)/failed; \
			elif [ ! -f $(o)/ci-ok-$$s ]; then \
				echo "$$s (exit)" >> $(o)/failed; \
			fi; \
		else \
			echo "$$s: no summary produced"; \
			echo $$s >> $(o)/failed; \
		fi; \
		echo "::endgroup::"; \
	done
	@if [ -f $(o)/failed ]; then echo "ci: FAIL ($$(paste -sd' ' $(o)/failed))"; exit 1; else echo "ci: PASS"; fi
