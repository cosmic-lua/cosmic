# Included from the top-level Makefile at the position this block used to
# occupy, so parse order — and therefore every pattern-specific variable
# and its nesting — is unchanged (#786). The Makefile keeps aggregation
# and the shared path variables; each mk/*.mk holds one rule family.
#
# the three test lanes (plain, coverage, enforce) and the coverage ratchet.

# Test rule: execute test via cosmic --test command
$(o)/%.tl.test.got: .PLEDGE := $(pledge_test)
$(o)/%.tl.test.got: .UNVEIL := $(unveil_test)

# teal_config_test reads tlconfig.lua and the Makefile (outside the test unveil)
tlconfig_tests := $(call test_got,lib/cosmic/teal_config_test.tl)
$(tlconfig_tests): .UNVEIL := $(unveil_test) r:tlconfig.lua r:Makefile

# Namespace-exercising tests need to call unshare(CLONE_NEWUSER|NEWNET|...)
# and write /proc/self/{uid,gid}_map. No pledge promise covers unshare,
# and /proc/self needs write access for the id-map bootstrap, so drop
# pledge and broaden unveil for these specific tests. Everything else
# keeps the tight default above.
quicksand_sandbox_tests := $(call test_got,\
  lib/cosmic/quicksand/netns_test.tl \
  lib/cosmic/quicksand/proxy_test.tl \
  lib/cosmic/quicksand/box/run_test.tl)
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
coverage_got := $(patsubst %,$(o)/coverage/%.test.got,$(call filter-only,$(all_tests)))

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

# De-shelled (#756 item 1): the skip/check branching lives in the
# baseline tool's gate mode; --only=$(only) stays one argv token even
# when the filter is empty, so no quoting and no shell.
$(o)/coverage-summary.txt: .PLEDGE := $(pledge_build)
$(o)/coverage-summary.txt: .UNVEIL := $(unveil_base) rwcx:$(o)
$(o)/coverage-summary.txt: $(coverage_got) | $(cosmic_bin)
	@$(bootstrap_cosmic) --build capture $(cosmic_bin) $(o)/coverage-tests.txt --report $(coverage_got)
	@$(bootstrap_cosmic) --build tee $@ $(cosmic_bin) --coverage-report $(o)/coverage lib
	@$(cosmic_bin) $(coverage_baseline_tool) gate $(coverage_baseline) --only=$(only) $(o)/coverage lib

.PHONY: coverage-baseline
## Rewrite the committed coverage ratchet baseline from the last coverage run
coverage-baseline: .PLEDGE := $(pledge_build)
coverage-baseline: .UNVEIL := $(unveil_base) rwcx:$(o) rwc:lib/cosmic/coverage
coverage-baseline: $(coverage_got) | $(cosmic_bin)
	@$(bootstrap_cosmic) --build capture $(cosmic_bin) $(coverage_baseline) $(coverage_baseline_tool) write $(o)/coverage lib
	@echo wrote $(coverage_baseline)

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
$(o)/enforce-summary.txt: $(enforce_got) | $(cosmic_bin)
	@$(bootstrap_cosmic) --build tee $@ $(cosmic_bin) --report $^
	@$(bootstrap_cosmic) --build require-marker enforce-ran: $(o)/enforce
