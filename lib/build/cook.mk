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

# recursive (=): tree_lua_path is computed in the Makefile after the
# includes; recipes expand it at run time (#720)
reporter = LUA_PATH="$(tree_lua_path)" $(bootstrap_cosmic) -- $(build_reporter)
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
	@LUA_PATH="$(tree_lua_path)" $(bootstrap_cosmic) $(build_help) Makefile > $@

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

# Build-sandbox canary (#716). landlock-make enforces .PLEDGE/.UNVEIL
# only for rules that set .SANDBOXED (default off — see the note at the
# Makefile's global defaults), and cosmopolitan's unveil() silently
# no-ops where Landlock is unavailable, so nothing else in this build
# can prove the enforcement mechanism still works. The probe rule opts
# in with .SANDBOXED = 1 and a grant limited to its own directory, then
# attempts a write outside that grant, recording the verdict inside it.
# ENOENT unveil entries are skipped by landlock-make, so the generous
# rx list below is safe across hosts; the probe directory must exist
# BEFORE the sandboxed rule runs (unveil on a missing path is a no-op).
# CI runs this in the privileged enforce job, where Landlock is real.
# .UNVEIL must be := — landlock-make unveils the variable's RAW value
# without expanding it, so a recursive `$(canary_dir)` reaches unveil
# as a literal dollar string and is silently skipped as nonexistent
# (witnessed in CI: the probe was denied writing its own verdict).
# Every enforcement-bound .UNVEIL carrying $(...) needs this spelling.
canary_dir := $(o)/sandbox-canary
canary_escape := $(o)/sandbox-canary-escape.txt
$(canary_dir)/probe.got: .SANDBOXED := 1
$(canary_dir)/probe.got: .PLEDGE := $(pledge_build)
$(canary_dir)/probe.got: .UNVEIL := rwc:$(canary_dir) $(unveil_hostx)
$(canary_dir)/probe.got: .FORCE
	@if echo escaped 2>/dev/null > $(canary_escape); then \
	  echo escaped > $@; \
	else \
	  echo blocked > $@; \
	fi

.PHONY: sandbox-canary
## Verify the build sandbox blocks an out-of-grant write (skips without Landlock)
sandbox-canary: $$(cosmic_bin)
	@rm -f $(canary_escape) $(canary_dir)/probe.got
	@mkdir -p $(canary_dir)
	@if ! $(cosmic_bin) -e 'os.exit(require("cosmic.unveil").available() and 0 or 1)'; then \
	  echo "sandbox-canary: SKIP — Landlock unavailable; the build sandbox cannot enforce on this host"; \
	elif ! $(MAKE) $(canary_dir)/probe.got; then \
	  echo "sandbox-canary: FAIL — the probe rule could not run under the sandbox (grants too tight?)"; \
	  exit 1; \
	elif grep -qs escaped $(canary_dir)/probe.got; then \
	  rm -f $(canary_escape); \
	  echo "sandbox-canary: FAIL — the build sandbox is not enforcing (out-of-grant write succeeded)"; \
	  exit 1; \
	else \
	  echo "sandbox-canary: PASS — out-of-grant write was blocked"; \
	fi

# Minimal reproduction of #744 (sandboxed-compile module-resolution flake).
# Not part of ci — it is a manual investigation harness, and the fault it
# reproduces needs live Landlock (it self-skips otherwise). See the script
# header for the full root-cause analysis.
.PHONY: repro-744
## Reproduce the #744 sandboxed-compile module-resolution fault (skips without Landlock)
repro-744: | $(bootstrap_cosmic)
	@lib/build/repro-744.sh

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

# Environment clamp probe (#731): echoes the env a recipe actually sees.
# Test apparatus like ci-selftest-launder above, not a help target.
.PHONY: env-probe
env-probe:
	@echo "LC_ALL=$$LC_ALL"; echo "TZ=$$TZ"; echo "PATH=$$PATH"

# Gate for the clamp: run a nested make under a hostile caller env — a
# non-C locale, a non-UTC timezone, a poisoned PATH head — and record
# what the probe recipe saw. makefile_test asserts the clamp held; if
# someone reverts the exports in cook.mk this fixture goes hostile and
# the test fails, so the property stays falsifiable (#728).
$(build_make_out)/env-clamp.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; LC_ALL=tr_TR.UTF-8 TZ=Pacific/Kiritimati PATH="/hostile/bin:$$PATH" $(MAKE) -s env-probe >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

build_make_outputs := $(build_make_out)/dry-run.out $(build_make_out)/database.out $(build_make_out)/only-database.out $(build_make_out)/ci-launder.out $(build_make_out)/env-clamp.out

# makefile_test consumes the fixtures in both test lanes
build_makefile_test_got := \
  $(o)/lib/build/makefile_test.tl.test.got \
  $(o)/coverage/lib/build/makefile_test.tl.test.got
$(build_makefile_test_got): $(build_make_outputs)
$(build_makefile_test_got): TEST_DIR := $(build_make_out)

# help_test parses the real Makefile, which the test unveil set does
# not cover (#729 test family)
build_help_test_got := \
  $(o)/lib/build/help_test.tl.test.got \
  $(o)/coverage/lib/build/help_test.tl.test.got
$(build_help_test_got): .UNVEIL := $(unveil_test) r:Makefile
