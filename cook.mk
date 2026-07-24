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
# Grants derived from the graph (#756 item 4, whilp/cosmopolitan#211):
# landlock-make auto-grants rx on prerequisites and rwc on the target's
# directory, so sandboxed families no longer hand-grant the whole
# output tree — only genuinely-extra paths. fetch writes the archive
# cache; stage reads it and writes the staged tree (their stamps and
# symlinks live in the target's own directory, covered by the
# auto-grant).
unveil_fetch := rx:$(o)/bootstrap r:3p rwc:$(FETCH_O)
unveil_stage := rx:$(o)/bootstrap r:3p r:$(FETCH_O) rwc:$(STAGE_O)
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
# pinned bootstrap's own --build recipe steps (#756 item 3) — direct
# bootstrap execs under the global no-shell default.
$(o)/%.lua: .UNVEIL := r:tlconfig.lua $(unveil_dev)
# .ENV (#756 item 5): the compile child sees ONLY the declared set —
# the three path axes below plus the pinned locale/tz and NO_COLOR
# (deterministic output). A hostile caller variable cannot reach it;
# gate: the env-clamp fixture's clamped probe in lib/build/cook.mk.
$(o)/%.lua: .ENV := LUA_PATH TREE_LUA_PATH TL_PATH LC_ALL TZ NO_COLOR
# LUA_PATH=;; pins the --build dispatcher to the bootstrap's embedded
# stdlib (a caller's LUA_PATH must not redirect its requires); the
# compile child gets ";;" (strict) or TREE_LUA_PATH — the #666 axis,
# one layer down.
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
# De-hosted (#732): these recipes are metacharacter-free argv, so
# make's direct-exec fast path runs them with no shell at all; the
# GLOBAL poisoned SHELL (#756 item 2, set at the bottom of the
# Makefile) is the tripwire that fails loudly if any recipe regresses
# to shell syntax. The LUA_PATH export is deliberately NOT private: a
# private export never reaches the recipe env (witnessed: bootstrap
# fell back to its embedded stdlib); inheritance is benign because
# every compile recipe sets LUA_PATH explicitly. Recursive (=):
# tree_lua_path is computed after the includes (#720).
# .ENV (#756 item 5): fetch declares the network extras — operator
# proxy/CA variables (both cases; this is exactly the "per-rule
# declared extras" shape) — stage only the tree paths. SSL_USE_
# SYSTEM_CERTS rides the fetch rule's own export in the Makefile.
$(o)/%/.fetched: .ENV := LUA_PATH FETCH_O SSL_USE_SYSTEM_CERTS SSL_CERT_FILE \
  HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy \
  LC_ALL TZ NO_COLOR TMPDIR
$(o)/%/.staged: .ENV := LUA_PATH STAGE_O FETCH_O LC_ALL TZ NO_COLOR TMPDIR
$(o)/%/.fetched $(o)/%/.staged: export LUA_PATH = $(tree_lua_path)
# De-hosted (#732): lint runs through the pinned bootstrap's --test
# capture (which mkdtemps under $(TMP)); the .ok alias file is retired —
# the .got IS the target. LUA_PATH points the lint child at this tree's
# compiled style code (the doc/index.tl pattern); the --test wrapper
# sees it too, as the old shell prefix already had it.
$(o)/%.lint.got: .SANDBOXED := 1
$(o)/%.lint.got: .PLEDGE := $(pledge_build)
$(o)/%.lint.got: .UNVEIL := rwc:$(TMP) $(unveil_dev)
$(o)/%.lint.got: .ENV := LUA_PATH TMPDIR LC_ALL TZ NO_COLOR
$(o)/%.lint.got: export LUA_PATH = $(o)/lib/?.lua;$(o)/lib/?/init.lua;;
# Reporter summaries (bootstrap + tee). test/coverage/enforce summaries
# exec $(cosmic_bin) and stay unsandboxed with the test lanes.
reporter_summaries := $(o)/teal-summary.txt $(o)/format-summary.txt \
  $(o)/lint-summary.txt $(o)/example-summary.txt $(o)/benchmark-summary.txt
$(reporter_summaries): .SANDBOXED := 1
$(reporter_summaries): .PLEDGE := $(pledge_build)
# De-hosted (#732): the reporter writes its own summary (--out replaces
# `| tee`), so these recipes are direct bootstrap execs — same no-shell
# fast path + tripwire as fetch/stage above.
$(reporter_summaries): .UNVEIL := $(unveil_dev)
# REPORTER_NOTE: the lint summary's deleted-files note rides the env
$(reporter_summaries): .ENV := LUA_PATH REPORTER_NOTE LC_ALL TZ NO_COLOR
$(reporter_summaries): export LUA_PATH = $(tree_lua_path)

# Third ENFORCED family (#729): the teal/format check rules, which exec
# the assimilated $(cosmic_check_bin) duplicate (see lib/cosmic/cook.mk)
# instead of the fat-APE artifact. Failures inside the sandbox surface
# as check failures in the summaries — loud, not silent.
# De-hosted (#732): the checks run through `--test` capture on the
# assimilated check binary — no shell, no redirect plumbing, no host
# grants. testrun mkdtemps the per-check TEST_TMPDIR under $(TMP).
$(o)/%.teal.got: .SANDBOXED := 1
$(o)/%.teal.got: .PLEDGE := $(pledge_build)
$(o)/%.teal.got: .UNVEIL := r:tlconfig.lua rwc:$(TMP) $(unveil_dev)
$(o)/%.teal.got: .ENV := TL_PATH TMPDIR LC_ALL TZ NO_COLOR
$(o)/%.teal.got: export TL_PATH = $(tree_tl_path)
$(o)/%.format.got: .SANDBOXED := 1
$(o)/%.format.got: .PLEDGE := $(pledge_build)
$(o)/%.format.got: .UNVEIL := r:tlconfig.lua rwc:$(TMP) $(unveil_dev)
$(o)/%.format.got: .ENV := TMPDIR LC_ALL TZ NO_COLOR

# Fifth ENFORCED family (#729): examples. Same grant sets as the test
# lanes — examples exercise the same modules (sockets, tty, chmod) and
# embed/deploy examples exec what they build under TEST_TMPDIR. The
# quicksand namespace examples opt out like their tests (no pledge
# promise covers unshare); see lib/cosmic/cook.mk.
$(o)/%.tl.example.got: .SANDBOXED := 1
$(o)/%.tl.example.got: .PLEDGE := $(pledge_test)
$(o)/%.tl.example.got: .UNVEIL := $(unveil_test)

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
$(o)/coverage/%.tl.test.got: .SANDBOXED := 1
$(o)/enforce/%.tl.test.got: export LUA_PATH = $(tree_lua_path)
$(o)/%.tl.benchmark.got: export LUA_PATH = $(tree_lua_path)

# Type definition generation (define early so it's available to all modules).
# Must match MODULES in lib/types/gentype.tl: "cosmo" renders the top-level
# cosmo record (lib/types/cosmo.d.tl); the rest render lib/types/cosmo/<m>.d.tl.
type_modules := cosmo unix path getopt lsqlite3 re argon2 zip repl

# Bootstrap module: setup cosmic-lua for build process
modules += bootstrap
bootstrap_cosmic := $(o)/bootstrap/cosmic
bootstrap_files := $(bootstrap_cosmic)
bootstrap_url := https://github.com/whilp/cosmic/releases/download/2026-07-24-45acffa/cosmic-lua
# SHA-256 of the bootstrap cosmic binary. It compiles the entire project, so
# verify it before executing. Update this when bumping bootstrap_url.
# This pin ships --build (#756 item 3), so every recipe step — compile,
# copy, link, capture, tee, list, remove, require-*, verdict — is the
# bootstrap's own surface and the compiled driver is gone. It also ships
# --compile-strict, so the probe selects hermetic LUA_PATH=";;" compiles
# — a reproducibility requirement (#733): the pre-strict tree-LUA_PATH
# path made compiled output depend on parallel build order (bootstrap's
# embedded stdlib vs the tree's, whichever existed first). LUA_PATH
# governs runtime require; the TYPE-resolution axis (tl.search_module)
# is pinned separately to the tree via TL_PATH in the compile/check
# recipes, so a compile can never type-check against the bootstrap's
# stale embedded source (#744 — see tree_tl_path).
bootstrap_sha256 := 2469fb2f5a9197d8bacdeefd6b99366f318b813a2de48578b047e43c5954158e

# bin/make is the SOLE provisioner of the bootstrap (#756 cleanup): it
# runs before every make invocation, parses the pin above via sed,
# downloads/verifies/assimilates, and re-downloads when the pin moves
# (the .pin stamp beside the binary). Neither rule below downloads, so
# the curl/sha256sum/cmp shell exception this rule carried is retired.
ifeq ($(o),o)
# Canonical tree: only a bypassed bin/make can get here — trip loudly.
$(bootstrap_cosmic):
	$(error $(bootstrap_cosmic) missing — run builds via bin/make, which provisions the trust root)
else
# Non-default output tree (o=o2, the reproducible double-build):
# derive the bootstrap from the canonical tree bin/make provisioned —
# same bytes, argv-only recipe.
$(bootstrap_cosmic): o/bootstrap/cosmic
	@mkdir -p $(@D)
	@cp -p o/bootstrap/cosmic $@
	@ln -sf cosmic $(@D)/lua
endif

# Strict-compile capability probe: newer bootstraps ship --compile-strict
# (strict type check, then generate from that same checked AST, so nothing
# ships that did not typecheck); the pinned bootstrap may predate the flag.
# Probe once and use the best flag it supports — after a bootstrap pin bump
# (or CI's stage1 refresh) in-tree compiles become strict automatically.
# Shell exception (#732): the probe is pre-driver trust machinery — the
# driver's own compile READS this stamp, so probing through the driver
# would cycle. It stays shell, grouped with the bootstrap download.
compile_flag_stamp := $(o)/bootstrap/compile-flag
$(compile_flag_stamp): private SHELL := /bin/bash
$(compile_flag_stamp): private .SHELLFLAGS := -o pipefail -c
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
# Shell exception (#756 item 2): dev-facing regen loop (for/case/redirect);
# the gentype drift test gates its output, not this recipe.
regen-types: private SHELL := /bin/bash
regen-types: private .SHELLFLAGS := -o pipefail -c
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
