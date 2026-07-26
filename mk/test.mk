# One rule family per mk/*.mk; the Makefile keeps aggregation and the
# shared path variables. Include order is load-bearing: pattern-specific
# variables and their nesting depend on where this is included.
#
# the three test lanes (plain, coverage, enforce) and the coverage ratchet.

# Test rule: execute test via cosmic --test command
$(o)/%.tl.test.got: .PLEDGE := $(pledge_test)
$(o)/%.tl.test.got: .UNVEIL := $(unveil_test)

# teal_config_test reads tlconfig.lua and the Makefile (outside the test unveil)
tlconfig_tests := $(call test_got,cosmic/teal_config_test.tl)
$(tlconfig_tests): .UNVEIL := $(unveil_test) r:tlconfig.lua r:Makefile

# graph_test asserts the rules file packed at /zip/cosmic.mk is the one
# in the tree, byte for byte -- so it reads embed/cosmic.mk. That is
# PAYLOAD, not source: the shared test grant covers $(src_dirs), and
# `embed/` is deliberately not one of them (it is what the artifact
# carries, not what it is compiled from). Same shape as tlconfig above.
graph_tests := $(call test_got,_make/graph_test.tl)
$(graph_tests): .UNVEIL := $(unveil_test) r:embed

# pins_test resolves the REAL committed pins. `3p/` holds them and is
# not a source dir either -- it is what the build fetches INTO, so the
# shared test grant does not cover it. Same shape as the two above.
pins_tests := $(call test_got,_make/pins_test.tl)
$(pins_tests): .UNVEIL := $(unveil_test) r:3p

# Tests that drive a BUILD OF THIS PROJECT read the whole repository --
# Makefile, docs/, embed/, mk/, skills/, sys/, tlconfig.lua and the rest
# -- not just $(src_dirs). `r:.` is the honest grant for "everything a
# build of this project reads", and it stays read-only: these write only
# under $(TMP) and $(o), which the shared grant already covers.
#
# The tell is spawning `--make` or a generator with the repo as cwd: the
# child walks the project root, and the walk is what the default grant
# denies. A host without Landlock cannot see this (`bin/make
# sandbox-canary` reports whether it can), so it surfaces only in CI. If
# you add a test that builds this project, add it here at the same
# time.
#
#   fixpoint_test  copies the tree and builds cosmic from the copy, twice
#   generate_test  runs cmd/cosmic/embed_gen.tl against the real tree
selfbuild_tests := $(call test_got,\
  _make/fixpoint_test.tl \
  _make/generate_test.tl)
$(selfbuild_tests): .UNVEIL := $(unveil_test) r:.

# Namespace-exercising tests need to call unshare(CLONE_NEWUSER|NEWNET|...)
# and write /proc/self/{uid,gid}_map. No pledge promise covers unshare,
# and /proc/self needs write access for the id-map bootstrap, so drop
# pledge and broaden unveil for these specific tests. Everything else
# keeps the tight default above.
quicksand_sandbox_tests := $(call test_got,\
  cosmic/quicksand/netns_test.tl \
  cosmic/quicksand/proxy_test.tl \
  cosmic/quicksand/box/run_test.tl)
$(quicksand_sandbox_tests): .SANDBOXED := 0
$(quicksand_sandbox_tests): .PLEDGE =
$(quicksand_sandbox_tests): .UNVEIL =

# $$(deps_$$*) is the test's transitive import closure as BUILT paths,
# from o/project.mk. It makes each test depend on the compile of what it
# imports, which is what keeps the strict compile honest: a test can
# resolve an unlisted import through the runtime .tl searcher, which
# compiles LAX, so without this a module that fails its STRICT compile
# could still have a passing test.
$(o)/%.tl.test.got: $(o)/%.lua $$(deps_$$*) $(cosmic_bin) $(ape_loader)
	@$(cosmic_bin) --test $(basename $@) $(cosmic_bin) $<

# What each cook.mk declares is what a closure cannot see: the
# cosmos/tl staged trees and TEST_DIR, the debug binary, and grants.

# Coverage lane: the same tests in a separate output tree, run with
# collection enabled, so `bin/make coverage` never invalidates the plain
# `make test` results (and stays incremental itself). Each test leaves
# .cov files in <got>.cov.d; the summary merges them and folds in lib/
# so entirely untested modules still appear.
coverage_got := $(patsubst %,$(o)/coverage/%.test.got,$(call filter-only,$(all_tests)))

.PHONY: coverage
## Run all tests with line coverage and report per-file totals
coverage: $(o)/coverage-summary.txt

$(o)/coverage/%.tl.test.got: .PLEDGE := $(pledge_test)
$(o)/coverage/%.tl.test.got: .UNVEIL := $(unveil_test)
$(o)/coverage/%.tl.test.got: export COSMIC_COVERAGE := 1
$(o)/coverage/%.tl.test.got: $(o)/%.lua $$(deps_$$*) $(cosmic_bin) $(ape_loader)
	@$(cosmic_bin) --test $(basename $@) $(cosmic_bin) $<

# Coverage ratchet: the committed baseline records covered/total per
# file; the check fails when coverage declines or the file set drifts.
# Skipped under only= (partial data would read as a huge decline).
coverage_baseline := .coverage
coverage_baseline_tool := $(o)/cosmic/coverage/baseline.lua

# De-shelled: the skip/check branching lives in the
# baseline tool's gate mode; --only=$(only) stays one argv token even
# when the filter is empty, so no quoting and no shell.
$(o)/coverage-summary.txt: .PLEDGE := $(pledge_build)
# `.coverage` is at the ROOT now (the `--make` convention), which the
# source-dir grants do not cover: name it.
$(o)/coverage-summary.txt: .UNVEIL := $(unveil_base) rwcx:$(o) r:$(coverage_baseline)
$(o)/coverage-summary.txt: $(coverage_got) | $(cosmic_bin)
	@$(bootstrap_cosmic) --build capture $(cosmic_bin) $(o)/coverage-tests.txt --report $(coverage_got)
	@$(bootstrap_cosmic) --build tee $@ $(cosmic_bin) --coverage-report $(o)/coverage $(src_dirs)
	@$(cosmic_bin) $(coverage_baseline_tool) gate $(coverage_baseline) --only=$(only) $(o)/coverage $(src_dirs)

.PHONY: coverage-baseline
## Rewrite the committed coverage ratchet baseline from the last coverage run
coverage-baseline: .PLEDGE := $(pledge_build)
coverage-baseline: .UNVEIL := $(unveil_base) rwcx:$(o) rwc:$(coverage_baseline)
coverage-baseline: $(coverage_got) | $(cosmic_bin)
	@$(bootstrap_cosmic) --build capture $(cosmic_bin) $(coverage_baseline) $(coverage_baseline_tool) write $(o)/coverage $(src_dirs)
	@echo wrote $(coverage_baseline)

# Privileged enforcement lane. The sandbox tests carry "outer sandbox blocked this -> skip" escape hatches,
# so under CI's own landlock-make sandbox their enforcement assertions silently
# degrade to no-ops and nothing alarms when everything skips. This lane runs the
# sandbox-primitive tests with NO outer sandbox (empty .PLEDGE/.UNVEIL, like the
# quicksand namespace tests) and COSMIC_ENFORCE=1, so a test that cannot exercise
# real enforcement fails loudly instead of skipping. The tripwire then fails the
# lane if *nothing* enforced, which would mean the lane is not actually
# unsandboxed and is silently a no-op.
enforce_srcs := \
  cosmic/pledge_test.tl \
  cosmic/landlock_test.tl \
  cosmic/unveil_test.tl \
  _cli/fence_test.tl
enforce_got := $(patsubst %,$(o)/enforce/%.test.got,$(enforce_srcs))

.PHONY: enforce
## Run sandbox enforcement tests unsandboxed with COSMIC_ENFORCE=1 (privileged lane)
enforce: $(o)/enforce-summary.txt

# Drop the outer sandbox for these targets so enforcement actually runs.
$(enforce_got): .SANDBOXED := 0
$(enforce_got): .PLEDGE =
$(enforce_got): .UNVEIL =

$(o)/enforce/%.tl.test.got: export COSMIC_ENFORCE := 1
# $(cosmic_check_bin) — the ASSIMILATED duplicate — because the fence
# canary execs a cosmic under a real fence, and a raw APE exec falls
# back to loader paths (~/.ape-*) that no grant covers. That is the same
# reason this binary exists at all (cosmic/cook.mk) and the same reason
# `bin/make` assimilates the bootstrap; the fenced recipes have always
# used an ELF. Nothing noticed the lane lacked it because until the
# canary asserted that a fenced child SUCCEEDS, every test here passed
# whether or not its child could exec -- one expects a denial, the
# other's verb records rather than grades.
$(o)/enforce/%.tl.test.got: $(o)/%.lua $(cosmic_bin) $(cosmic_check_bin)
	@$(cosmic_bin) --test $(basename $@) $(cosmic_bin) $<

# The require-marker line is the tripwire: it fails the lane when no
# enforcement ran (every sandbox test skipped — outer sandbox active?).
$(o)/enforce-summary.txt: export LUA_PATH := ;;
$(o)/enforce-summary.txt: $(enforce_got) | $(cosmic_bin)
	@$(bootstrap_cosmic) --build tee $@ $(cosmic_bin) --report $^
	@$(bootstrap_cosmic) --build require-marker enforce-ran: $(o)/enforce
