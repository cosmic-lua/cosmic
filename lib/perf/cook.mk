modules += perf
perf_srcs := $(wildcard lib/perf/*.tl) $(wildcard lib/perf/bench/*.tl)
perf_tests := $(filter %_test.tl,$(perf_srcs))
perf_tl := $(filter-out $(perf_tests),$(perf_srcs))
# compiled perf modules are require()d as perf.* via LUA_PATH
perf_lua_dirs := $(o)/lib
perf_deps := cosmic

perf_bench_srcs := $(wildcard lib/perf/bench/*_bench.tl)
perf_bench_mods := $(subst /,.,$(patsubst lib/%.tl,%,$(perf_bench_srcs)))
perf_run := $(o)/lib/perf/run.lua

## PERF_BIN: cosmic binary to benchmark (default: freshly built o/bin/cosmic).
## Point it at another build to measure cosmos/cosmopolitan changes end to end.
PERF_BIN ?= $(cosmic_bin)
## PERF_SAMPLES: timed samples per scenario (default 5)
PERF_SAMPLES ?= 5
## PERF_MIN_SECS: minimum seconds per sample (default 0.15)
PERF_MIN_SECS ?= 0.15
## PERF_ONLY: Lua pattern to filter scenario names (e.g. PERF_ONLY=sqlite)
PERF_ONLY ?=
## PERF_THRESHOLD: minimum regression percent for perf-compare to fail (default 10)
PERF_THRESHOLD ?= 10

perf_only_flag = $(if $(PERF_ONLY),--only $(PERF_ONLY))
perf_cmd = PERF_BIN=$(PERF_BIN) $(PERF_BIN) -- $(perf_run) \
	--samples $(PERF_SAMPLES) --min-secs $(PERF_MIN_SECS) $(perf_only_flag)

perf_sandbox := $(o)/perf

.PHONY: perf perf-baseline perf-compare

perf perf-baseline: .PLEDGE = stdio rpath wpath cpath proc exec
perf perf-baseline: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwcx:$(o) rwc:$(TMP) rx:/usr rx:/proc r:/etc r:/dev/null

## Run perf scenarios and write o/perf/current.json
perf: $$(perf_lua) $(cosmic_bin)
	@mkdir -p $(perf_sandbox)
	@$(perf_cmd) --out $(perf_sandbox)/current.json $(perf_bench_mods)

## Run perf scenarios and save the baseline (o/perf/baseline.json)
perf-baseline: $$(perf_lua) $(cosmic_bin)
	@mkdir -p $(perf_sandbox)
	@$(perf_cmd) --out $(perf_sandbox)/baseline.json $(perf_bench_mods)

perf-compare: .PLEDGE = stdio rpath wpath cpath proc exec
perf-compare: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwcx:$(o) rwc:$(TMP) rx:/usr rx:/proc r:/etc r:/dev/null

perf_compare_cmd = $(PERF_BIN) -- $(perf_run) --compare \
	$(perf_sandbox)/baseline.json $(perf_sandbox)/current.json \
	--threshold $(PERF_THRESHOLD)

## Re-run scenarios and fail on any regression vs the saved baseline
# A failed comparison retries once with fresh measurements so that
# machine noise has to strike twice in the same direction to fail.
perf-compare: perf
	@$(perf_compare_cmd) || { \
		echo "perf-compare: regression flagged; re-measuring once to filter noise"; \
		$(perf_cmd) --out $(perf_sandbox)/current.json $(perf_bench_mods) \
			&& $(perf_compare_cmd); }
