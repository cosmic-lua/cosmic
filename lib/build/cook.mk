modules += build
build_lua_dirs := $(o)/lib/build
build_fetch := $(o)/lib/build/build-fetch.lua
build_stage := $(o)/lib/build/build-stage.lua
build_untar := $(o)/lib/build/build-untar.lua
build_portable := $(o)/lib/build/portable.lua
build_reporter := $(o)/lib/build/reporter.lua
build_help := $(o)/lib/build/make-help.lua
build_lint := $(o)/lib/build/lint.lua
build_recipe := $(o)/lib/build/build-recipe.lua
build_pack := $(o)/lib/build/build-pack.lua
# make-boot runs from SOURCE under the bootstrap (bin/make invokes it
# before any make exists); the compiled copy is built so it gets the
# strict-compile type gate like every other build script.
build_makeboot := $(o)/lib/build/make-boot.lua
build_audit := $(o)/lib/build/audit-unveil.lua
build_files := $(build_fetch) $(build_stage) $(build_untar) $(build_pack) $(build_portable) $(build_reporter) $(build_help) $(build_lint) $(build_makeboot) $(build_audit)

# Self-bootstrap exception (#732): build-recipe drives the shell-free
# compile/copy/link recipes, so it cannot be compiled by them — this one
# target keeps the old shell recipe (and the host grants + real shell it
# needs), and everything else compiles through the driver. The driver
# runs against the bootstrap's EMBEDDED stdlib (see its header), so the
# bootstrap sha covers its runtime and no tree .lua is required first.
$(build_recipe): private SHELL := /bin/bash
$(build_recipe): private .SHELLFLAGS := -o pipefail -c
$(build_recipe): export LUA_PATH := ;;
$(build_recipe): .UNVEIL := rwc:$(o) r:tlconfig.lua $(unveil_hostx)
$(build_recipe): lib/build/build-recipe.tl $(types_files) $(tl_files) $(bootstrap_files) $(compile_flag_stamp)
	@mkdir -p $(@D)
	@f=$$(cat $(compile_flag_stamp)); if [ "$$f" = "--compile-strict" ]; then export LUA_PATH=";;"; else export LUA_PATH="$(tree_lua_path)"; fi; export TL_PATH="$(tree_tl_path)"; $(bootstrap_cosmic) $(include_dir_flags) $$f $< > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm $@.tmp; else mv $@.tmp $@; fi
build_tests := $(wildcard lib/build/*_test.tl)

# lint.lua delegates its shared checks to cosmic.cli.style; LUA_PATH points
# at this tree's freshly compiled modules (the doc/index.tl pattern) so the
# delegation runs THIS tree's style code, not the bootstrap's embedded copy.
lint_style_lua := $(o)/lib/cosmic/cli/style.lua

# build tests exercise the compiled build tools (reporter, lint,
# make-help, ...) at runtime via LUA_PATH=$(o)/lib/build, so they need
# them built and fresh (#715)
build_test_got := \
  $(patsubst %,$(o)/%.test.got,$(build_tests)) \
  $(patsubst %,$(o)/coverage/%.test.got,$(build_tests))
$(build_test_got): $(build_files)

# make-help snapshot: generate actual help output (driver capture, #732)
$(o)/lib/build/make-help.snap: export LUA_PATH := ;;
$(o)/lib/build/make-help.snap: export TREE_LUA_PATH = $(tree_lua_path)
$(o)/lib/build/make-help.snap: Makefile $(build_help) $(build_recipe) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) -- $(build_recipe) capture $(bootstrap_cosmic) $@ $(build_help) Makefile

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
# in with .SANDBOXED = 1, then attempts a write outside its grants,
# recording the verdict beside its target (the derived target-dir
# grant, #756 item 4).
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
# Shell exceptions (#756 item 2): the probe's out-of-grant write attempt
# and the canary's verdict branching are the enforcement test itself.
$(canary_dir)/probe.got sandbox-canary: private SHELL := /bin/bash
$(canary_dir)/probe.got sandbox-canary: private .SHELLFLAGS := -o pipefail -c
$(canary_dir)/probe.got: .SANDBOXED := 1
$(canary_dir)/probe.got: .PLEDGE := $(pledge_build)
# The probe's own-directory grant is gone (#756 item 4): the target-dir
# auto-grant must cover the verdict write, so the canary now ALSO
# proves the derived grant under real Landlock — if the auto-grant
# broke, the probe could not record its verdict and the canary fails.
$(canary_dir)/probe.got: .UNVEIL := $(unveil_hostx)
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

# ci grading self-test stage for the ci-launder.out fixture below:
# writes a clean summary, then fails — the graded verdict must be FAIL
# via the per-stage exit marker, never PASS via the summary text (#714).
# Lives here (not the Makefile) because it is test apparatus, not a
# user-facing target for `make help`.
.PHONY: ci-selftest-launder
ci-selftest-launder: $(o)/ci-selftest-launder-summary.txt

# Shell exception (#756 item 2): deliberately tees a clean summary and
# then fails — the laundering the ci grading gate must catch.
$(o)/ci-selftest-launder-summary.txt: private SHELL := /bin/bash
$(o)/ci-selftest-launder-summary.txt: private .SHELLFLAGS := -o pipefail -c
$(o)/ci-selftest-launder-summary.txt:
	@mkdir -p $(@D)
	@echo "ci grading selftest: 1 passed" | tee $@
	@exit 1

# Red test for ci grading (#714): run the ci harness over the stage
# above; the graded verdict must be FAIL. o= points the nested run at
# its own output tree so its failed/summary/marker files never collide
# with the real ci run that builds this fixture.
# The nested tree has no bootstrap/driver of its own; the ci recipe's
# remove/verdict steps exec them, so the fixture hands in the parent's
# by absolute path (#732) — and marks them -o (old-file: use, never
# remake): without that, a parent-tree bootstrap refresh makes them
# look stale INSIDE the nested run, which then rebuilds the parent's
# own driver in a race against the outer make (witnessed: the nested
# compile's cmp/mv losing its .tmp mid-flight).
$(build_make_out)/ci-launder.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; $(MAKE) ci o=$(o)/citest ci_stages=ci-selftest-launder bootstrap_cosmic=$(CURDIR)/$(bootstrap_cosmic) build_recipe=$(CURDIR)/$(build_recipe) -o $(CURDIR)/$(bootstrap_cosmic) -o $(CURDIR)/$(build_recipe) >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

# Environment clamp probe (#731): echoes the env a recipe actually sees.
# Test apparatus like ci-selftest-launder above, not a help target.
.PHONY: env-probe
# Shell exception (#756 item 2): the probe exists to show the env a
# recipe's shell actually sees.
env-probe: private SHELL := /bin/bash
env-probe: private .SHELLFLAGS := -o pipefail -c
env-probe:
	@echo "LC_ALL=$$LC_ALL"; echo "TZ=$$TZ"; echo "PATH=$$PATH"

# Clamped twin (#756 item 5): .ENV must strip everything undeclared.
# The env-clamp fixture sends a hostile CANARY through make; this
# recipe proves it never reaches a clamped child (env-probe above stays
# unclamped, showing the passthrough behavior for comparison).
# Shell exception: probe apparatus, like env-probe.
.PHONY: env-probe-clamped
env-probe-clamped: .ENV := LC_ALL TZ PATH
env-probe-clamped: private SHELL := /bin/bash
env-probe-clamped: private .SHELLFLAGS := -o pipefail -c
env-probe-clamped:
	@echo "CANARY=$${CANARY:-unset}"; echo "CLAMPED_LC_ALL=$$LC_ALL"

# Gate for the clamp: run a nested make under a hostile caller env — a
# non-C locale, a non-UTC timezone, a poisoned PATH head, and a CANARY
# variable — and record what both probe recipes saw. makefile_test
# asserts the axis clamp held (#731) AND that the CANARY never reached
# the .ENV-clamped probe (#756 item 5); if someone reverts the exports
# in cook.mk or the clamp, this fixture goes hostile and the test
# fails, so both properties stay falsifiable (#728).
$(build_make_out)/env-clamp.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; LC_ALL=tr_TR.UTF-8 TZ=Pacific/Kiritimati PATH="/hostile/bin:$$PATH" CANARY=evil $(MAKE) -s env-probe env-probe-clamped >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

build_make_outputs := $(build_make_out)/dry-run.out $(build_make_out)/database.out $(build_make_out)/only-database.out $(build_make_out)/ci-launder.out $(build_make_out)/env-clamp.out

# Shell exceptions (#756 item 2): the fixture rules above run nested
# makes with exit-code capture and redirects — test apparatus, not build
# logic.
$(build_make_outputs): private SHELL := /bin/bash
$(build_make_outputs): private .SHELLFLAGS := -o pipefail -c

# makefile_test consumes the fixtures in both test lanes
build_makefile_test_got := \
  $(o)/lib/build/makefile_test.tl.test.got \
  $(o)/coverage/lib/build/makefile_test.tl.test.got \
  $(o)/lib/build/makefile_ratchet_test.tl.test.got \
  $(o)/coverage/lib/build/makefile_ratchet_test.tl.test.got
$(build_makefile_test_got): $(build_make_outputs)
$(build_makefile_test_got): TEST_DIR := $(build_make_out)

# help_test parses the real Makefile, which the test unveil set does
# not cover (#729 test family)
build_help_test_got := \
  $(o)/lib/build/help_test.tl.test.got \
  $(o)/coverage/lib/build/help_test.tl.test.got
$(build_help_test_got): .UNVEIL := $(unveil_test) r:Makefile

# Unused-grant audit (whilp/cosmopolitan#210 item 3, #756 item 4).
# Leave-one-out: rebuild a target with one grant entry withheld from a
# shared set; if it still builds, that entry was not needed for that
# rule. Withholding rides make's command-line variable override, so no
# rule here changes — but it also means the audit only reaches grants
# composed from a variable, not per-rule literals.
#
# One representative target per enforced family. They are deliberately
# small and deterministic: the audit rebuilds each one once per grant
# entry, so a slow target multiplies.
audit_targets := \
  $(o)/lib/cosmic/uuid.lua \
  $(o)/lib/cosmic/uuid.tl.teal.got \
  $(o)/lib/cosmic/uuid.tl.format.got \
  $(o)/lib/cosmic/uuid.tl.lint.got \
  $(o)/lib/cosmic/uuid_test.tl.test.got

.PHONY: audit-unveil
## Report .UNVEIL grants no audited rule needs (leave-one-out; needs Landlock)
# Apparatus, not build logic: it execs nested makes and deletes targets,
# so it runs outside the sandbox like the canary and the fixtures.
audit-unveil: .SANDBOXED := 0
audit-unveil: export LUA_PATH = $(tree_lua_path)
audit-unveil: $(build_audit) $$(cosmic_bin)
	@$(cosmic_bin) -- $(build_audit) --make $(MAKE) $(audit_targets:%=--target %)
