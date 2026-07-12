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
linter := $(bootstrap_cosmic) -- $(build_lint)

# reporter_test needs cosmic binary (in the plain and coverage test lanes)
$(o)/lib/build/reporter_test.tl.test.got $(o)/coverage/lib/build/reporter_test.tl.test.got: $$(cosmic_bin)

# make-help snapshot: generate actual help output
$(o)/lib/build/make-help.snap: Makefile $(build_help) | $(bootstrap_cosmic)
	@mkdir -p $(@D)
	@$(bootstrap_cosmic) $(build_help) Makefile > $@

# makefile validation outputs
build_make_out := $(o)/lib/build/make

$(build_make_out)/dry-run.out: Makefile $(wildcard */*.mk) $(wildcard */*/*.mk)
	@mkdir -p $(@D)
	@code=0; $(MAKE) -n files >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

$(build_make_out)/database.out: Makefile $(wildcard */*.mk) $(wildcard */*/*.mk)
	@mkdir -p $(@D)
	@code=0; $(MAKE) -p -n -q >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

# database dump under an only= filter that matches nothing: artifact
# source lists (doc index, docs) must stay complete while test lists
# empty out (#608)
$(build_make_out)/only-database.out: Makefile $(wildcard */*.mk) $(wildcard */*/*.mk)
	@mkdir -p $(@D)
	@code=0; $(MAKE) -p -n -q only=__no_such_module__ >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

build_make_outputs := $(build_make_out)/dry-run.out $(build_make_out)/database.out $(build_make_out)/only-database.out

# makefile_test consumes the fixtures in both test lanes
build_makefile_test_got := \
  $(o)/lib/build/makefile_test.tl.test.got \
  $(o)/coverage/lib/build/makefile_test.tl.test.got
$(build_makefile_test_got): $(build_make_outputs)
$(build_makefile_test_got): TEST_DIR := $(build_make_out)
