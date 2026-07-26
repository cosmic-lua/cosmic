# One rule family per mk/*.mk; the Makefile keeps aggregation and the
# shared path variables. Include order is load-bearing: pattern-specific
# variables and their nesting depend on where this is included.
#
# the run lanes: examples and benchmarks.

# Example testing - run Example_* functions in _example.tl files
all_example_srcs := $(foreach m,$(modules),$($(m)_examples))
all_examples := $(patsubst %.tl,$(o)/%.tl.example.got,$(call filter-only,$(all_example_srcs)))

.PHONY: example
## Run all example tests
example: $(o)/example-summary.txt

$(o)/example-summary.txt: $(all_examples) | $(build_reporter)
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $^

# Examples take their import closure too: an example RUNS, so what
# it imports must compile first — the same gate the test rule gained.
$(o)/%.tl.example.got: %.tl $$(deps_$$*) $(cosmic_bin) $(ape_loader) | $(bootstrap_files)
	@$(cosmic_bin) --test $(basename $@) $(cosmic_bin) --check examples $<

# Benchmark testing - run Benchmark_* functions in .tl files (exclude test files)
all_benchmark_srcs := $(foreach m,$(modules),$(filter-out $($(m)_tests),$($(m)_tl)))
all_benchmarks := $(patsubst %.tl,$(o)/%.tl.benchmark.got,$(call filter-only,$(all_benchmark_srcs)))

.PHONY: benchmark
## Run all benchmarks
benchmark: $(o)/benchmark-summary.txt

$(o)/benchmark-summary.txt: $(all_benchmarks) | $(build_reporter)
	@$(bootstrap_cosmic) -- $(build_reporter) --dir $(o) --out $@ $^

$(o)/%.tl.benchmark.got: .PLEDGE := $(pledge_build)
$(o)/%.tl.benchmark.got: .UNVEIL := $(unveil_run)
$(o)/%.tl.benchmark.got: %.tl $(cosmic_bin) | $(bootstrap_files)
	@$(cosmic_bin) --test $(basename $@) $(cosmic_bin) --benchmark $<
