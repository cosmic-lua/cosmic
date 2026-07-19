modules += build
build_lua_dirs := $(o)/lib/build
build_fetch := $(o)/lib/build/build-fetch.lua
build_stage := $(o)/lib/build/build-stage.lua
build_portable := $(o)/lib/build/portable.lua
build_reporter := $(o)/lib/build/reporter.lua
build_help := $(o)/lib/build/make-help.lua
build_lint := $(o)/lib/build/lint.lua
build_files := $(build_fetch) $(build_stage) $(build_portable) $(build_reporter) $(build_help) $(build_lint)
build_tests := $(wildcard lib/build/*_test.tl)

reporter := $(bootstrap_cosmic) -- $(build_reporter)
# lint.lua delegates its shared checks to cosmic.cli.style; LUA_PATH points
# at this tree's freshly compiled modules (the doc/index.tl pattern) so the
# delegation runs THIS tree's style code, not the bootstrap's embedded copy.
lint_style_lua := $(o)/lib/cosmic/cli/style.lua
linter := LUA_PATH="$(o)/lib/?.lua;$(o)/lib/?/init.lua;;" $(bootstrap_cosmic) -- $(build_lint)

# build tests exercise the compiled build tools (reporter, lint,
# make-help, ...) at runtime via LUA_PATH=$(o)/lib/build, so they need
# them built and fresh (#715)
build_test_got := \
  $(patsubst %,$(o)/%.test.got,$(build_tests)) \
  $(patsubst %,$(o)/coverage/%.test.got,$(build_tests))
$(build_test_got): $(build_files)

# make-help snapshot: generate actual help output
$(o)/lib/build/make-help.snap: Makefile $(build_help) | $(bootstrap_cosmic)
	@mkdir -p $(@D)
	@$(bootstrap_cosmic) $(build_help) Makefile > $@

# makefile validation outputs
build_make_out := $(o)/lib/build/make
# Every makefile the fixtures snapshot. Root cook.mk has no directory
# component, so it needs its own $(wildcard *.mk) — the bare */*.mk
# pair missed it and makefile_test validated stale snapshots (#717).
build_make_srcs := Makefile $(wildcard *.mk) $(wildcard */*.mk) $(wildcard */*/*.mk)

$(build_make_out)/dry-run.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; $(MAKE) -n files >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

$(build_make_out)/database.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; $(MAKE) -p -n -q >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

# database dump under an only= filter that matches nothing: artifact
# source lists (doc index, docs) must stay complete while test lists
# empty out (#608)
$(build_make_out)/only-database.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; $(MAKE) -p -n -q only=__no_such_module__ >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

# ci grading self-test stage for the ci-launder.out fixture below:
# writes a clean summary, then fails — the graded verdict must be FAIL
# via the per-stage exit marker, never PASS via the summary text (#714).
# Lives here (not the Makefile) because it is test apparatus, not a
# user-facing target for `make help`.
.PHONY: ci-selftest-launder
ci-selftest-launder: $(o)/ci-selftest-launder-summary.txt

$(o)/ci-selftest-launder-summary.txt:
	@mkdir -p $(@D)
	@echo "ci grading selftest: 1 passed" | tee $@
	@exit 1

# Red test for ci grading (#714): run the ci harness over the stage
# above; the graded verdict must be FAIL. o= points the nested run at
# its own output tree so its failed/summary/marker files never collide
# with the real ci run that builds this fixture.
$(build_make_out)/ci-launder.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; $(MAKE) ci o=$(o)/citest ci_stages=ci-selftest-launder >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

build_make_outputs := $(build_make_out)/dry-run.out $(build_make_out)/database.out $(build_make_out)/only-database.out $(build_make_out)/ci-launder.out

# makefile_test consumes the fixtures in both test lanes
build_makefile_test_got := \
  $(o)/lib/build/makefile_test.tl.test.got \
  $(o)/coverage/lib/build/makefile_test.tl.test.got
$(build_makefile_test_got): $(build_make_outputs)
$(build_makefile_test_got): TEST_DIR := $(build_make_out)
