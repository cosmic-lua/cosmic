modules += build
# One entry: the tree's own module path. The extra $(o)/_build that
# resolved a bare `require("make-help")` is gone with the bare name --
# The derived closures cannot see a require that does not match its
# position, so the name was made to match instead.
build_lua_dirs := $(o)
build_fetch := $(o)/_build/build-fetch.lua
build_stage := $(o)/_build/build-stage.lua
build_untar := $(o)/cosmic/tar.lua # public: cosmic.tar
build_portable := $(o)/_build/portable.lua
build_reporter := $(o)/_build/reporter.lua
build_help := $(o)/_build/make-help.lua
build_pack := $(o)/_build/build-pack.lua
# make-boot runs from SOURCE under the bootstrap (bin/make invokes it
# before any make exists); the compiled copy is built so it gets the
# strict-compile type gate like every other build script.
build_makeboot := $(o)/_build/make-boot.lua
# The module's _files: everything under _build compiled, which is what
# `make files` builds and what the build tests exercise at runtime.
build_files := $(build_fetch) $(build_stage) $(build_untar) $(build_pack) $(build_portable) $(build_reporter) $(build_help) $(build_makeboot)

# Per-consumer runtime closures. build_files conflates "what a
# recipe execs" with "everything here, compiled so it gets the strict
# type gate" — so `make help` compiled ten scripts to run one, and an
# edit to any one of them invalidated the fetch and stage rules. These
# are the actual require closures (build.* only; the cosmic.* halves ride
# $(stdlib_lua), already a prerequisite of both rules):
#   build-fetch -> build.portable
#   build-stage -> build.portable, build.tar
# make-boot is deliberately in NEITHER: bin/make runs it from SOURCE
# before any make exists, so its compiled copy exists only for the gate.
build_fetch_files := $(build_fetch) $(build_portable)
build_stage_files := $(build_stage) $(build_untar) $(build_portable)

# The recipe steps (copy/compile/capture/tee/...) are the pinned
# bootstrap's own `--build` surface: _cli.build ships EMBEDDED in the
# bootstrap, so the bootstrap sha covers the driver's entire runtime and
# no tree .lua has to be built first.
#
# _srcs (not _tl) so these are type- and format-checked without also
# entering the docs/benchmark pipelines, which key off _tl.
build_srcs := $(wildcard _build/*.tl)

build_tests := $(wildcard _build/*_test.tl)

# lint.lua delegates its shared checks to cosmic.style; LUA_PATH points
# at this tree's freshly compiled modules (the doc/index.tl pattern) so the
# delegation runs THIS tree's style code, not the bootstrap's embedded copy.

# Import edges are derived: the test rule takes $$(deps_$$*) from
# o/project.mk, so each test names the build tools it actually imports
# and one that imports none waits for none -- rather than a blanket
# `$(build_test_got): $(build_files)`.
build_test_got := $(call test_got,$(build_tests))

# make-help snapshot: generate actual help output (driver capture)
$(o)/_build/make-help.snap: export LUA_PATH := ;;
$(o)/_build/make-help.snap: export TREE_LUA_PATH = $(tree_lua_path)
$(o)/_build/make-help.snap: $(MAKEFILE_LIST) $(build_help) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) --build capture $(bootstrap_cosmic) $@ $(build_help) $(MAKEFILE_LIST)

# makefile validation outputs
build_make_out := $(o)/_build/make
# Every makefile the fixtures snapshot. Root cook.mk has no directory
# component, so it needs its own $(wildcard *.mk) — the bare */*.mk
# pair missed it and makefile_test validated stale snapshots.
build_make_srcs := Makefile $(wildcard *.mk) $(wildcard */*.mk) $(wildcard */*/*.mk)

$(build_make_out)/dry-run.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; $(MAKE) -n files >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

$(build_make_out)/database.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; $(MAKE) -p -n -q >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

# database dump under an only= filter that matches nothing: artifact
# source lists (doc index, docs) must stay complete while test lists
# empty out
$(build_make_out)/only-database.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; $(MAKE) -p -n -q only=__no_such_module__ >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

# Build-sandbox canary. landlock-make enforces .PLEDGE/.UNVEIL
# only for rules that set .SANDBOXED (default off — see the note at the
# Makefile's global defaults), and cosmopolitan's unveil() silently
# no-ops where Landlock is unavailable, so nothing else in this build
# can prove the enforcement mechanism still works. The probe rule opts
# in with .SANDBOXED = 1, then attempts a write outside its grants,
# recording the verdict beside its target (the derived target-dir
# grant item 4).
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
# Shell exceptions: the probe's out-of-grant write attempt
# and the canary's verdict branching are the enforcement test itself.
$(canary_dir)/probe.got sandbox-canary: private SHELL := /bin/bash
$(canary_dir)/probe.got sandbox-canary: private .SHELLFLAGS := -o pipefail -c
$(canary_dir)/probe.got: .SANDBOXED := 1
$(canary_dir)/probe.got: .PLEDGE := $(pledge_build)
# The probe's own-directory grant is gone: the target-dir
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
# via the per-stage exit marker, never PASS via the summary text.
# Lives here (not the Makefile) because it is test apparatus, not a
# user-facing target for `make help`.
.PHONY: ci-selftest-launder
ci-selftest-launder: $(o)/ci-selftest-launder-summary.txt

# Shell exception: deliberately tees a clean summary and
# then fails — the laundering the ci grading gate must catch.
$(o)/ci-selftest-launder-summary.txt: private SHELL := /bin/bash
$(o)/ci-selftest-launder-summary.txt: private .SHELLFLAGS := -o pipefail -c
$(o)/ci-selftest-launder-summary.txt:
	@mkdir -p $(@D)
	@echo "ci grading selftest: 1 passed" | tee $@
	@exit 1

# Red test for ci grading: run the ci harness over the stage
# above; the graded verdict must be FAIL. o= points the nested run at
# its own output tree so its failed/summary/marker files never collide
# with the real ci run that builds this fixture.
# The nested tree has no bootstrap of its own; the ci recipe's --build
# steps exec it, so the fixture hands in the parent's by absolute path
# — and marks it -o (old-file: use, never remake): without that,
# a parent-tree bootstrap refresh makes it look stale INSIDE the nested
# run, racing the outer make. There is no compiled-driver handoff to
# order against, and so no cold-tree ENOENT hazard:
# bin/make provisions the bootstrap before any rule
# runs, so it always exists.
$(build_make_out)/ci-launder.out: $(build_make_srcs) | $(bootstrap_cosmic)
	@mkdir -p $(@D)
	@code=0; $(MAKE) ci o=$(o)/citest ci_stages=ci-selftest-launder bootstrap_cosmic=$(CURDIR)/$(bootstrap_cosmic) -o $(CURDIR)/$(bootstrap_cosmic) >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

# Environment clamp probe: echoes the env a recipe actually sees.
# Test apparatus like ci-selftest-launder above, not a help target.
.PHONY: env-probe
# Shell exception: the probe exists to show the env a
# recipe's shell actually sees.
env-probe: private SHELL := /bin/bash
env-probe: private .SHELLFLAGS := -o pipefail -c
env-probe:
	@echo "LC_ALL=$$LC_ALL"; echo "TZ=$$TZ"; echo "PATH=$$PATH"

# Clamped twin: .ENV must strip everything undeclared.
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
# asserts the axis clamp held AND that the CANARY never reached
# the .ENV-clamped probe; if someone reverts the exports
# in cook.mk or the clamp, this fixture goes hostile and the test
# fails, so both properties stay falsifiable.
$(build_make_out)/env-clamp.out: $(build_make_srcs)
	@mkdir -p $(@D)
	@code=0; LC_ALL=tr_TR.UTF-8 TZ=Pacific/Kiritimati PATH="/hostile/bin:$$PATH" CANARY=evil $(MAKE) -s env-probe env-probe-clamped >$@.tmp 2>&1 || code=$$?; echo "exit:$$code" >> $@.tmp; mv $@.tmp $@

build_make_outputs := $(build_make_out)/dry-run.out $(build_make_out)/database.out $(build_make_out)/only-database.out $(build_make_out)/ci-launder.out $(build_make_out)/env-clamp.out

# Shell exceptions: the fixture rules above run nested
# makes with exit-code capture and redirects — test apparatus, not build
# logic.
$(build_make_outputs): private SHELL := /bin/bash
$(build_make_outputs): private .SHELLFLAGS := -o pipefail -c

# makefile_test consumes the fixtures in both test lanes
build_makefile_test_got := $(call test_got,\
  _build/makefile_test.tl _build/makefile_ratchet_test.tl)
$(build_makefile_test_got): $(build_make_outputs)
$(build_makefile_test_got): TEST_DIR := $(build_make_out)

# The lint-file-list ratchet in makefile_test reads mk/check.mk SOURCE,
# which the test unveil set does not cover. It cannot use the database
# fixture like its neighbours: lint_files is :=, so the database records
# the expanded file list rather than the git flags being guarded. Only
# makefile_test needs this, not the ratchet test beside it, so the grant
# stays as narrow as the allowlist entries it costs.
build_makefile_src_test_got := $(call test_got,_build/makefile_test.tl)
$(build_makefile_src_test_got): .UNVEIL := $(unveil_test) r:mk

# help_test parses the real Makefile, which the test unveil set does
# not cover (test family)
build_help_test_got := $(call test_got,_build/help_test.tl)
$(build_help_test_got): .UNVEIL := $(unveil_test) r:Makefile r:mk

# workflows_test ratchets the CI environment pins across the workflow
# files. Dot-prefixed directories are outside the project model (the
# walk never sees them), so this grant is the only way it reads them.
build_workflows_test_got := $(call test_got,_build/workflows_test.tl)
$(build_workflows_test_got): .UNVEIL := $(unveil_test) r:.github
