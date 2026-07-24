modules += perf
perf_srcs := $(wildcard lib/perf/*.tl) $(wildcard lib/perf/bench/*.tl)
perf_tests := $(filter %_test.tl,$(perf_srcs))
perf_tl := $(filter-out $(perf_tests),$(perf_srcs))
# compiled perf modules are require()d as perf.* via LUA_PATH
perf_lua_dirs := $(o)/lib
perf_deps := cosmic
perf_lua := $(patsubst %.tl,$(o)/%.lua,$(perf_tl))

# perf tests load the compiled perf.* modules at runtime (see
# perf_lua_dirs above), so they need them built and fresh (#715)
perf_test_got := \
  $(patsubst %,$(o)/%.test.got,$(perf_tests)) \
  $(patsubst %,$(o)/coverage/%.test.got,$(perf_tests))
$(perf_test_got): $(perf_lua)

perf_bench_srcs := $(wildcard lib/perf/bench/*_bench.tl)
perf_bench_mods := $(subst /,.,$(patsubst lib/%.tl,%,$(perf_bench_srcs)))
perf_run := $(o)/lib/perf/run.lua

## PERF_BIN: cosmic binary to benchmark (default: freshly built o/bin/cosmic).
## Point it at another build to measure cosmos/cosmopolitan changes end to end.
PERF_BIN ?= $(cosmic_bin)
## COSMO_LUA: locally built cosmopolitan lua binary for perf-bin
## (e.g. ~/cosmopolitan/o/tool/lua/lua; see lib/perf/optimize/cosmopolitan.md)
COSMO_LUA ?=
## PERF_SAMPLES: timed samples per scenario (default 5)
PERF_SAMPLES ?= 5
## PERF_MIN_SECS: minimum seconds per sample (default 0.15)
PERF_MIN_SECS ?= 0.15
## PERF_ONLY: Lua pattern to filter scenario names (e.g. PERF_ONLY=sqlite)
PERF_ONLY ?=
## PERF_THRESHOLD: minimum regression percent for perf-compare to fail (default 10)
PERF_THRESHOLD ?= 10

perf_only_flag = $(if $(PERF_ONLY),--only $(PERF_ONLY))
perf_cmd = PERF_BIN=$(PERF_BIN) LUA_PATH="$(tree_lua_path)" $(PERF_BIN) -- $(perf_run) \
	--samples $(PERF_SAMPLES) --min-secs $(PERF_MIN_SECS) $(perf_only_flag)

perf_sandbox := $(o)/perf
cosmic_local_bin := $(perf_sandbox)/cosmic-local

.PHONY: perf perf-baseline perf-compare perf-bin perf-selfcheck

perf-bin: .PLEDGE := $(pledge_build)
perf-bin: .UNVEIL := $(unveil_test) $(if $(COSMO_LUA),r:$(COSMO_LUA))

## Build o/perf/cosmic-local: the cosmic payload on a local cosmopolitan lua (COSMO_LUA=...)
# The payload rides build-pack like the shipped binaries (#755 moved the
# pack there but left a call to the deleted pack-cosmic define here, so
# perf-bin silently produced a payload-less binary).
# Shell exception (#756 item 2): the COSMO_LUA guard.
perf-bin: private SHELL := /bin/bash
perf-bin: private .SHELLFLAGS := -o pipefail -c
perf-bin: $(cosmic_bin) $(build_pack)
	@test -n "$(COSMO_LUA)" || { \
		echo "perf-bin: set COSMO_LUA=/path/to/cosmopolitan/o/tool/lua/lua" >&2; \
		echo "perf-bin: see lib/perf/optimize/cosmopolitan.md" >&2; exit 1; }
	@mkdir -p $(perf_sandbox)
	@$(pack) --out $(cosmic_local_bin) --base $(COSMO_LUA)
	@echo "built $(cosmic_local_bin) from $(COSMO_LUA)"
	@echo "measure it with: PERF_BIN=$(cosmic_local_bin) bin/make perf-compare"

# Shell exceptions (#756 item 2): every perf recipe runs $(perf_cmd),
# whose PERF_BIN/LUA_PATH env prefixes need a shell (and perf-compare's
# retry/triage chain branches); measurement apparatus, not build logic.
perf perf-baseline perf-compare perf-selfcheck: private SHELL := /bin/bash
perf perf-baseline perf-compare perf-selfcheck: private .SHELLFLAGS := -o pipefail -c
perf perf-baseline: .PLEDGE := $(pledge_build)
perf perf-baseline: .UNVEIL := $(unveil_test)

## Run perf scenarios and write o/perf/current.json
perf: $$(perf_lua) $(cosmic_bin)
	@mkdir -p $(perf_sandbox)
	@$(perf_cmd) --out $(perf_sandbox)/current.json $(perf_bench_mods)

## Run perf scenarios and save the baseline (o/perf/baseline.json)
perf-baseline: $$(perf_lua) $(cosmic_bin)
	@mkdir -p $(perf_sandbox)
	@$(perf_cmd) --out $(perf_sandbox)/baseline.json $(perf_bench_mods)

perf-compare: .PLEDGE := $(pledge_build)
perf-compare: .UNVEIL := $(unveil_test)

perf_compare_cmd = LUA_PATH="$(tree_lua_path)" $(PERF_BIN) -- $(perf_run) --compare \
	$(perf_sandbox)/baseline.json $(perf_sandbox)/current.json \
	--threshold $(PERF_THRESHOLD)

# Final stage: reclassify any surviving regression the current binary
# cannot reproduce against itself (selfcheck-b vs the current run) as
# "noise" rather than a failure — the A/A control, run automatically.
perf_triage_cmd = LUA_PATH="$(tree_lua_path)" $(PERF_BIN) -- $(perf_run) --compare \
	$(perf_sandbox)/baseline.json $(perf_sandbox)/current.json \
	--threshold $(PERF_THRESHOLD) \
	--selfcheck-a $(perf_sandbox)/current.json \
	--selfcheck-b $(perf_sandbox)/selfcheck-b.json

## Re-run scenarios and fail on any regression vs the saved baseline
# A failed comparison retries once with fresh measurements so machine
# noise has to strike twice in the same direction. If a regression still
# stands, one more pass of the same binary drives an automatic A/A
# triage: scenarios that swing past the bar against themselves are
# reclassified "noise" and the gate passes iff a real regression remains.
perf-compare: perf
	@$(perf_compare_cmd) || { \
		echo "perf-compare: regression flagged; re-measuring once to filter noise"; \
		$(perf_cmd) --out $(perf_sandbox)/current.json $(perf_bench_mods) \
			&& $(perf_compare_cmd); } || { \
		echo "perf-compare: regression persists; running A/A self-check to separate real regressions from machine noise"; \
		$(perf_cmd) --out $(perf_sandbox)/selfcheck-b.json $(perf_bench_mods) \
			&& $(perf_triage_cmd); }

perf-selfcheck: .PLEDGE := $(pledge_build)
perf-selfcheck: .UNVEIL := $(unveil_test)

perf_selfcheck_cmd = LUA_PATH="$(tree_lua_path)" $(PERF_BIN) -- $(perf_run) --compare \
	$(perf_sandbox)/selfcheck-a.json $(perf_sandbox)/selfcheck-b.json \
	--threshold $(PERF_THRESHOLD)

## A/A control: measure this machine's noise floor by comparing the SAME
## binary against itself. Anything flagged here moves more than the bar on
## nothing but run-to-run variance, so a like-named "regression" in
## perf-compare is noise, not your change. Use it when perf-compare flags a
## scenario unrelated to your edit (see lib/perf/optimize/measurement.md).
# PERF_ONLY narrows it (e.g. PERF_ONLY=hash bin/make perf-selfcheck) for a
# fast focused check on just the scenario perf-compare flagged.
perf-selfcheck: $$(perf_lua) $(cosmic_bin)
	@mkdir -p $(perf_sandbox)
	@$(perf_cmd) --out $(perf_sandbox)/selfcheck-a.json $(perf_bench_mods)
	@$(perf_cmd) --out $(perf_sandbox)/selfcheck-b.json $(perf_bench_mods)
	@$(perf_selfcheck_cmd) && \
		echo "perf-selfcheck: nothing exceeded the bar — the machine is quiet at this threshold" || \
		echo "perf-selfcheck: the scenarios flagged above vary by more than the bar on noise alone; discount same-named perf-compare regressions"
