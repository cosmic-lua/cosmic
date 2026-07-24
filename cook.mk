# cosmic repository module definitions
# This file aggregates all modules for the build system

# Environment clamp (#731): recipes otherwise inherit the caller's full
# environment, so hermeticity would depend on the invoking shell being
# unremarkable. Pin locale and timezone, and construct PATH deliberately
# — o/bootstrap, o/bin (staged tools), then a small, visible host-tool
# surface (#732 shrinks it; HOST_PATH= overrides for unusual hosts).
# Entries are CURDIR-anchored: a relative entry breaks for any recipe
# that cd's (#721). Gate: the env-clamp fixture in lib/build/cook.mk.
export LC_ALL := C
export TZ := UTC
HOST_PATH ?= /usr/bin:/bin
export PATH := $(CURDIR)/$(o)/bootstrap:$(CURDIR)/$(o)/bin:$(HOST_PATH)

# Shared sandbox grant sets (#718): compose per rule, so a deliberate
# deviation reads as `$(unveil_test) r:extra` at the rule instead of a
# wall of near-identical 90-column strings. Defined here (before the
# lib/3p cook.mk includes) so their rules can use them too. Rules MUST
# assign .PLEDGE/.UNVEIL with := — landlock-make hands the values to
# enforcement unexpanded (see the sandbox-canary note in lib/build).
pledge_build := stdio rpath wpath cpath proc exec
unveil_base := rx:$(o)/bootstrap r:lib r:3p
# Device nodes the cosmic runtime itself touches — not host tools, so
# de-hosted rules (#732) grant these without the toolchain surface.
# /dev/null must be writable (recipes redirect to it). mbedtls3's
# non-glibc build cannot use the getrandom syscall, so TLS entropy
# fopens MBEDTLS_PLATFORM_DEV_RANDOM — which defaults to /dev/random,
# not /dev/urandom (platform.h:398) — and fetch SIGILLs under Landlock
# without it; grant both devices. ENOENT entries are skipped, so the
# generous list is safe across hosts.
unveil_dev := rw:/dev/null r:/dev/random r:/dev/urandom
# Host set proven under real enforcement by the sandbox-canary (#724)
# and the enforced families' CI runs: shell + coreutils + loaders.
unveil_hostx := rx:/usr rx:/bin rx:/lib rx:/lib64 rx:/proc r:/etc $(unveil_dev)
unveil_dep := rx:$(o)/bootstrap r:3p rwc:$(o)
# TMP is x: tests exec what they build there — embed outputs, scripts
# under TEST_TMPDIR (proven need: embed/child/testrun under Landlock)
unveil_test := $(unveil_base) rwcx:$(o) rwcx:$(TMP) $(unveil_hostx)
unveil_run := $(unveil_base) rwc:$(o) rwc:$(TMP) $(unveil_hostx)
# Test lanes run sockets, fs-permission, and TLS-touching code: promises
# beyond pledge_build discovered empirically under local seccomp.
pledge_test := $(pledge_build) fattr inet dns unix tty id flock

# First ENFORCED rule family (#729): the .tl compile rule. landlock-make
# auto-grants rx on every prerequisite (source, types, bootstrap, flag
# stamp) and on the recipe shell, merges the global .PLEDGE/.UNVEIL in,
# and always adds the "prot_exec exec" promises — so the target grants
# only add what the defaults lack: write access to the output tree,
# tlconfig.lua (read by strict compiles), and the executable host dirs.
# pledge() enforces everywhere via seccomp; unveil() needs Landlock (CI's
# build job has it, the canary proves it). Requires the assimilated
# bootstrap below: a raw APE exec falls back to extracting a loader into
# $HOME/.ape-*, which no grant covers. Pattern variables attach by
# target NAME, so every *.lua target under $(o) is enforced — including
# the `$(o)/%: %` copies (their `cp -p` needs the fattr promise) and
# the doc index. version.lua opts back out where it is defined: its
# recipe needs git + .git, and its `|| echo unknown` fallback would
# otherwise silently mint an artifact with no version.
$(o)/%.lua: .SANDBOXED := 1
$(o)/%.lua: .PLEDGE := $(pledge_build) fattr
# De-hosted (#732): compiles and the $(o)/%: % copies run through the
# build-recipe driver — direct bootstrap execs under the same no-shell
# fast path + poisoned-SHELL tripwire as fetch/stage. The driver's own
# compile opts back out in lib/build/cook.mk (self-bootstrap exception).
$(o)/%.lua: .UNVEIL := rwc:$(o) r:tlconfig.lua $(unveil_dev)
$(o)/%.lua: private SHELL := /dev/null/enoshell
$(o)/%.lua: private .SHELLFLAGS := -c
# LUA_PATH=;; pins the DRIVER to the bootstrap's embedded stdlib (a
# caller's LUA_PATH must not redirect its requires); the compile child
# gets ";;" (strict) or TREE_LUA_PATH — the #666 axis, one layer down.
$(o)/%.lua: export LUA_PATH := ;;
$(o)/%.lua: export TREE_LUA_PATH = $(tree_lua_path)
$(o)/%.lua: export TL_PATH = $(tree_tl_path)

# Second ENFORCED family (#729): every remaining rule that execs the
# assimilated bootstrap — fetch, stage, lint, and the reporter
# summaries. (The check/test rules exec $(cosmic_bin), which must stay
# a fat APE; enforcing them needs an answer for the APE loader first,
# so they are the next family, not this one.) fetch/stage keep their
# annotations at the rules in the Makefile; the flips live here beside
# the grant sets.
$(o)/%/.fetched: .SANDBOXED := 1
$(o)/%/.staged: .SANDBOXED := 1
# De-hosted (#732): these recipes are metacharacter-free argv, so a
# plain -c re-enables make's direct-exec fast path (the global pipefail
# .SHELLFLAGS forces the shell; these recipes have no pipes) and no
# shell runs at all — the poisoned SHELL is the tripwire that fails
# loudly if a recipe ever regresses to shell syntax. private: cold-tree
# prerequisites (stdlib compiles) must not inherit either override —
# but NOT on the export: a private export never reaches the recipe env
# (witnessed: bootstrap fell back to its embedded stdlib); inheritance
# is benign because every compile recipe sets LUA_PATH explicitly.
# Recursive (=): tree_lua_path is computed after the includes (#720).
$(o)/%/.fetched $(o)/%/.staged: export LUA_PATH = $(tree_lua_path)
$(o)/%/.fetched $(o)/%/.staged: private SHELL := /dev/null/enoshell
$(o)/%/.fetched $(o)/%/.staged: private .SHELLFLAGS := -c
# De-hosted (#732): lint runs through the pinned bootstrap's --test
# capture (which mkdtemps under $(TMP)); the .ok alias file is retired —
# the .got IS the target. LUA_PATH points the lint child at this tree's
# compiled style code (the doc/index.tl pattern); the --test wrapper
# sees it too, as the old shell prefix already had it.
$(o)/%.lint.got: .SANDBOXED := 1
$(o)/%.lint.got: .PLEDGE := $(pledge_build)
$(o)/%.lint.got: .UNVEIL := rwc:$(o) rwc:$(TMP) $(unveil_dev)
$(o)/%.lint.got: export LUA_PATH = $(o)/lib/?.lua;$(o)/lib/?/init.lua;;
$(o)/%.lint.got: private SHELL := /dev/null/enoshell
$(o)/%.lint.got: private .SHELLFLAGS := -c
# Reporter summaries (bootstrap + tee). test/coverage/enforce summaries
# exec $(cosmic_bin) and stay unsandboxed with the test lanes.
reporter_summaries := $(o)/teal-summary.txt $(o)/format-summary.txt \
  $(o)/lint-summary.txt $(o)/example-summary.txt $(o)/benchmark-summary.txt
$(reporter_summaries): .SANDBOXED := 1
$(reporter_summaries): .PLEDGE := $(pledge_build)
# De-hosted (#732): the reporter writes its own summary (--out replaces
# `| tee`), so these recipes are direct bootstrap execs — same no-shell
# fast path + tripwire as fetch/stage above.
$(reporter_summaries): .UNVEIL := rwc:$(o) $(unveil_dev)
$(reporter_summaries): export LUA_PATH = $(tree_lua_path)
$(reporter_summaries): private SHELL := /dev/null/enoshell
$(reporter_summaries): private .SHELLFLAGS := -c

# Third ENFORCED family (#729): the teal/format check rules, which exec
# the assimilated $(cosmic_check_bin) duplicate (see lib/cosmic/cook.mk)
# instead of the fat-APE artifact. Failures inside the sandbox surface
# as check failures in the summaries — loud, not silent.
# De-hosted (#732): the checks run through `--test` capture on the
# assimilated check binary — no shell, no redirect plumbing, no host
# grants. testrun mkdtemps the per-check TEST_TMPDIR under $(TMP).
$(o)/%.teal.got: .SANDBOXED := 1
$(o)/%.teal.got: .PLEDGE := $(pledge_build)
$(o)/%.teal.got: .UNVEIL := rwc:$(o) r:tlconfig.lua rwc:$(TMP) $(unveil_dev)
$(o)/%.teal.got: export TL_PATH = $(tree_tl_path)
$(o)/%.teal.got: private SHELL := /dev/null/enoshell
$(o)/%.teal.got: private .SHELLFLAGS := -c
$(o)/%.format.got: .SANDBOXED := 1
$(o)/%.format.got: .PLEDGE := $(pledge_build)
$(o)/%.format.got: .UNVEIL := rwc:$(o) r:tlconfig.lua rwc:$(TMP) $(unveil_dev)
$(o)/%.format.got: private SHELL := /dev/null/enoshell
$(o)/%.format.got: private .SHELLFLAGS := -c

# Fifth ENFORCED family (#729): examples. Same grant sets as the test
# lanes — examples exercise the same modules (sockets, tty, chmod) and
# embed/deploy examples exec what they build under TEST_TMPDIR. The
# quicksand namespace examples opt out like their tests (no pledge
# promise covers unshare); see lib/cosmic/cook.mk.
$(o)/%.tl.example.got: .SANDBOXED := 1
$(o)/%.tl.example.got: .PLEDGE := $(pledge_test)
$(o)/%.tl.example.got: .UNVEIL := $(unveil_test)
$(o)/%.tl.example.got: private SHELL := /dev/null/enoshell
$(o)/%.tl.example.got: private .SHELLFLAGS := -c

# Fourth ENFORCED family (#729): the plain and coverage test lanes,
# running the real fat-APE $(cosmic_bin) via the staged o/bin/ape
# loader (see lib/cosmic/cook.mk) — the APE stub prefers a loader
# named ape on PATH over extracting one into unveil-able-nowhere
# ~/.ape-*. The quicksand namespace tests and the privileged enforce
# lane opt back out where their empty grant overrides live in the
# Makefile: they exercise unshare and real self-sandboxing, which no
# outer sandbox can permit.
# The test/coverage/enforce recipes are shell-free too (#732): the env
# prefixes became target-scoped exports (TEST_DIR is exported globally
# in the Makefile so per-module target values reach recipe envs; the
# PATH prefix was redundant since the #731 clamp already puts o/bin on
# PATH). Their grants are unchanged — tests legitimately exec host
# tools (sh, etc.) under $(unveil_test).
$(o)/%.tl.test.got: .SANDBOXED := 1
$(o)/%.tl.test.got: export LUA_PATH = $(tree_lua_path)
$(o)/%.tl.test.got: private SHELL := /dev/null/enoshell
$(o)/%.tl.test.got: private .SHELLFLAGS := -c
$(o)/coverage/%.tl.test.got: .SANDBOXED := 1
$(o)/enforce/%.tl.test.got: export LUA_PATH = $(tree_lua_path)
$(o)/%.tl.benchmark.got: export LUA_PATH = $(tree_lua_path)
$(o)/%.tl.benchmark.got: private SHELL := /dev/null/enoshell
$(o)/%.tl.benchmark.got: private .SHELLFLAGS := -c

# Type definition generation (define early so it's available to all modules).
# Must match MODULES in lib/types/gentype.tl: "cosmo" renders the top-level
# cosmo record (lib/types/cosmo.d.tl); the rest render lib/types/cosmo/<m>.d.tl.
type_modules := cosmo unix path getopt lsqlite3 re argon2 zip repl

# Bootstrap module: setup cosmic-lua for build process
modules += bootstrap
bootstrap_cosmic := $(o)/bootstrap/cosmic
bootstrap_files := $(bootstrap_cosmic)
bootstrap_url := https://github.com/whilp/cosmic/releases/download/2026-07-19-5c6bce5/cosmic-lua
# SHA-256 of the bootstrap cosmic binary. It compiles the entire project, so
# verify it before executing. Update this when bumping bootstrap_url.
# This pin ships --compile-strict, so the probe selects hermetic
# LUA_PATH=";;" compiles — a reproducibility requirement (#733): the
# pre-strict tree-LUA_PATH path made compiled output depend on parallel
# build order (bootstrap's embedded stdlib vs the tree's, whichever
# existed first). LUA_PATH governs runtime require; the TYPE-resolution
# axis (tl.search_module) is pinned separately to the tree via TL_PATH in
# the compile/check recipes, so a compile can never type-check against the
# bootstrap's stale embedded source (#744 — see tree_tl_path).
bootstrap_sha256 := 6c2a0afe6c942560ce2a0d796ddf8f8df096ce2c92b8ce142c28da59ecac6dc6

$(bootstrap_cosmic):
	@mkdir -p $(@D)
	curl -fsSL -o $@ $(bootstrap_url)
	@echo "$(bootstrap_sha256)  $@" | sha256sum -c - || { rm -f $@; echo "bootstrap cosmic checksum verification failed" >&2; exit 1; }
	chmod +x $@
	@$@ --assimilate
	@printf '\177ELF' | cmp -s - <(head -c 4 $@) || { echo "bootstrap assimilation failed: $@ is still an APE — sandboxed rules need a native ELF (no loader grants)" >&2; exit 1; }
	@ln -sf cosmic $(@D)/lua

# Strict-compile capability probe: newer bootstraps ship --compile-strict
# (strict type check, then generate from that same checked AST, so nothing
# ships that did not typecheck); the pinned bootstrap may predate the flag.
# Probe once and use the best flag it supports — after a bootstrap pin bump
# (or CI's stage1 refresh) in-tree compiles become strict automatically.
compile_flag_stamp := $(o)/bootstrap/compile-flag
$(compile_flag_stamp): $(bootstrap_files)
	@mkdir -p $(@D)
	@printf 'print("probe")\n' > $@.probe.tl
	@if LUA_PATH=";;" $(bootstrap_cosmic) --compile-strict $@.probe.tl >/dev/null 2>&1; then \
		echo --compile-strict > $@; \
	else \
		echo --compile > $@; \
	fi
	@rm -f $@.probe.tl

# Type definition regeneration.
# The generated .d.tl files are a pure function of (lib/types/gentype*.tl, the
# definitions.lua embedded in the pinned cosmos release). This target runs the
# CURRENT generator against the CURRENT pin, so regen is reproducible: bump
# 3p/cosmos/version.lua, run `bin/make regen-types`, commit. The gentype drift
# test fails until you do. Module list ($(type_modules)) defined above.
#
# gentype runs under the STAGED cosmos lua binary — whose embedded
# /zip/.lua/definitions.lua IS the pinned source of truth — with LUA_PATH
# limited to gentype's compiled require closure. Depending on $(cosmic_bin)
# here would compile the WHOLE tree against the old committed .d.tl,
# deadlocking any pin bump that lands together with code already using the
# new bindings (#711). The closure below is the transitive requires of
# types.gentype; if it drifts, the recipe fails loudly with "module not
# found" — extend the list, and do NOT swap in $(stdlib_lua) (that
# re-creates the deadlock).
#
# The staged cosmos/tl trees are checked at RECIPE time, not as
# prerequisites: the .staged targets themselves depend on $(stdlib_lua)
# (their fetch/stage scripts run against the tree's cosmic.* APIs), so a
# make-graph dependency on them would re-import the whole-tree compile
# this target exists to avoid. On a cold tree, run `bin/make staged`
# once first.
gentype_closure_tl := \
  $(wildcard lib/types/gentype*.tl) \
  lib/cosmic/init.tl lib/cosmic/proc.tl lib/cosmic/errno.tl \
  lib/cosmic/fd.tl lib/cosmic/stream.tl \
  lib/cosmic/fs/init.tl lib/cosmic/fs/file.tl lib/cosmic/fs/ops.tl \
  lib/cosmic/fs/path.tl lib/cosmic/fs/tree.tl lib/cosmic/fs/types.tl \
  lib/cosmic/fs/walk.tl
gentype_closure_lua := $(patsubst %.tl,$(o)/%.lua,$(gentype_closure_tl))

.PHONY: regen-types
## Regenerate .d.tl type definitions from the pinned cosmos definitions.lua
regen-types: $(gentype_closure_lua)
	@test -x $(cosmos_lua_bin) || { echo "regen-types: staged cosmos missing; run 'bin/make staged' first"; exit 1; }
	@test -f $(tl_dir)/tl.lua || { echo "regen-types: staged tl missing; run 'bin/make staged' first"; exit 1; }
	@echo "Regenerating type definitions from the pinned cosmos definitions.lua..."
	@for mod in $(type_modules); do \
		case $$mod in \
			cosmo) out=lib/types/cosmo.d.tl ;; \
			*) out=lib/types/cosmo/$$mod.d.tl ;; \
		esac; \
		echo "  $$out"; \
		LUA_PATH="$(o)/lib/?.lua;$(o)/lib/?/init.lua;$(tl_dir)/?.lua;;" $(cosmos_lua_bin) -e "local r = require('types.gentype').run('$$mod'); assert(r.success, r.error); io.write(r.output)" > $$out.tmp && mv $$out.tmp $$out || { rm -f $$out.tmp; exit 1; }; \
	done
	@echo "Type definitions regenerated. Verify with: bin/make test only=gentype"
