.SECONDEXPANSION:
.SECONDARY:
# Parse-time shell: $(shell) queries here and in the includes (nproc,
# uname, git) read this value DURING parsing — poisoning it here empties
# them silently (witnessed: an empty SOURCE_DATE_EPOCH in the pack).
# Recipes get the no-shell default at the BOTTOM of this file (#756).
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

# Test lanes (#778): the plain and coverage lanes run the SAME tests in
# separate output trees, so a per-test exception (grant, prerequisite,
# TEST_DIR) applies to both — modules name the source once. NOTE the lane
# patterns NEST, so a grant on the plain pattern reaches all three lanes;
# docs/build.md has the details and why enforce must EMPTY its grants.
test_lane_dirs := $(o) $(o)/coverage
test_got = $(foreach d,$(test_lane_dirs),$(patsubst %,$(d)/%.test.got,$1))

include cook.mk
include lib/cook.mk
include 3p/cosmos/cook.mk
include 3p/tl/cook.mk


# landlock-make sandbox annotations. These are ENFORCED, not intent
# (#729): every rule family CI exercises sets .SANDBOXED := 1 in
# cook.mk, so an undeclared read or write in one of their recipes fails
# on a Landlock host. The .SANDBOXED ratchet in
# lib/build/makefile_ratchet_test.tl pins the enforced set and the
# exceptions both ways; losing a flip is otherwise silent. Details in
# docs/build.md. NOTE: make hands .UNVEIL values to unveil UNEXPANDED —
# assign with := and compose from the grant sets in cook.mk (#718).
# global defaults: read-only access, no network, basic stdio
.PLEDGE := stdio rpath
.UNVEIL := $(unveil_base)

.PHONY: help
## Show this help message
help: export LUA_PATH = $(tree_lua_path)
help: $(build_help) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) $(build_help) $(MAKEFILE_LIST)

## Filter targets by substring (make test only=teal; also narrows fetch/stage)
filter-only = $(if $(only),$(foreach f,$1,$(if $(findstring $(only),$(f)),$(f))),$1)
# INVARIANT (#608, #777): only= narrows which CHECKS RUN — never what an
# ARTIFACT CONTAINS. Every $(call filter-only,...) below sits INSIDE a
# target-list derivation, so the source lists stay complete by
# construction. Before #777 the filter was applied to the source lists
# and each artifact input needed an unfiltered twin (all_module_srcs vs
# all_tl, doc_index_example_srcs vs all_example_srcs) plus a comment
# saying which to reach for; forgetting shipped a truncated binary.
# Keep new filter calls at the target-list level and the class stays shut.

# Compiles are the pinned bootstrap's --build steps (#732, #756 item 3):
# no shell, no host mkdir/cat/cmp/mv (LUA_PATH pins live in cook.mk with
# the family's other pattern vars). The `$(o)/%: %` source-copy rule that
# used to sit here is retired (#775): teal/format read sources directly
# now, as lint always has. tl resolves through $(bootstrap_files)'s
# embedded copy; the old $(tl_files) prereq was never defined, ever empty.
$(o)/%.lua: %.tl $(types_files) $(bootstrap_files)
	@$(bootstrap_cosmic) --build compile $(bootstrap_cosmic) $< $@ $(include_dir_flags)

# tl files: modules declare _tl, derive compiled .lua outputs
all_tl := $(foreach x,$(modules),$($(x)_tl))
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

# versioned modules: o/module/.versioned -> version.lua
$(foreach m,$(modules),$(if $($(m)_version),\
  $(eval $(o)/$(m)/.versioned: $($(m)_version) | $(bootstrap_cosmic) ; @$(bootstrap_cosmic) --build link $(CURDIR)/$$< $$@)))
all_versioned := $(foreach m,$(modules),$(if $($(m)_version),$(o)/$(m)/.versioned))

include mk/deps.mk

all_tests := $(foreach x,$(modules),$($(x)_tests))
all_tested := $(patsubst %,$(o)/%.test.got,$(call filter-only,$(all_tests)))

## Run all tests (incremental)
test: $(o)/test-summary.txt

$(o)/test-summary.txt: export LUA_PATH := ;;
$(o)/test-summary.txt: $(all_tested) | $(cosmic_bin)
	@$(bootstrap_cosmic) --build tee $@ $(cosmic_bin) --report $^

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

include mk/test.mk

include mk/check.mk

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

include mk/run.mk

include mk/docs.mk

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
	@$(bootstrap_cosmic) --build list $@

.PHONY: ci
## Run the full gate in parallel (format, teal, test, example, lint, coverage)
# De-hosted (#732): the grading loop lives in the driver's verdict mode
# (same #714 semantics — summary text AND exit marker — gated by the
# ci-launder fixture); `-` on the sub-make replaces `|| true`.
ci: export LUA_PATH := ;;
ci: | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) --build remove $(ci_summaries) $(ci_marks)
	-@$(MAKE) --keep-going $(ci_marks)
	@$(bootstrap_cosmic) --build verdict $(o) $(ci_stages)

# No-shell DEFAULT (#756 item 2, inverting #732's per-family opt-in).
# Set LAST so the parse-time $(shell) queries above ran under the real
# shell; recipes read SHELL's FINAL value, so this reaches every rule.
# A recipe is a shell-free argv line (make's direct-exec fast path
# spawns no shell); one that regresses to shell syntax fails loudly on
# every host, Landlock or not. Rules that genuinely need a shell
# override SHELL/.SHELLFLAGS per rule with `private` (the grant must
# not leak to prerequisites); makefile_test ratchets that list.
#
# cosmic, not the old /dev/null/enoshell poison: the fail-closed
# property is identical -- neither can run shell syntax -- but a line
# that regresses now reports WHICH character it was and that recipes
# are argv, instead of "not a directory". It also makes the SHELL slot
# the same one a generated cosmic.mk uses, so a recipe can eventually
# be a bare verb (`copy $< $@ ;`) rather than an explicit exec of the
# driver. .SHELLFLAGS stays `-c`: that is cosmic's recipe flag too.
SHELL := $(bootstrap_cosmic)
.SHELLFLAGS := -c
