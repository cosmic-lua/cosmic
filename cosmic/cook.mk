modules += cosmic
cosmic_srcs := $(wildcard cosmic/*.tl) $(wildcard cosmic/_cli/*.tl) $(wildcard cosmic/coverage/*.tl) $(wildcard cosmic/fs/*.tl) $(wildcard cosmic/_build/*.tl) $(wildcard cosmic/child/*.tl) $(wildcard cosmic/doc/*.tl) $(wildcard cosmic/embed/*.tl) $(wildcard cosmic/fetch/*.tl) $(wildcard cosmic/format/*.tl) $(wildcard cosmic/_make/*.tl) $(wildcard cosmic/net/*.tl) $(wildcard cosmic/sqlite/*.tl) $(wildcard cosmic/quicksand/*.tl) $(wildcard cosmic/quicksand/box/*.tl) $(wildcard cosmic/quicksand/proxy/*.tl)
cosmic_tests := $(filter %_test.tl,$(cosmic_srcs))
cosmic_examples := $(filter %_example.tl,$(cosmic_srcs))
cosmic_tl := $(filter-out $(cosmic_tests) $(cosmic_examples) cosmic/_cli/main.tl,$(cosmic_srcs))
cosmic_main := $(o)/cosmic/_cli/main.lua
cosmic_args := cosmic/.args
cosmic_bin := $(o)/bin/cosmic
cosmic_debug_bin := $(o)/bin/cosmic-debug
# cosmic_files deliberately carries only the binaries: the compiled
# stdlib below reaches everything through $(cosmic_bin)'s own prereqs
# (the old trailing $(cosmic_lua) here always expanded empty — it was
# not defined until after the includes)
cosmic_files := $(cosmic_bin) $(cosmic_debug_bin)
cosmic_deps := cosmos tl
cosmic_lua := $(patsubst %.tl,$(o)/%.lua,$(cosmic_tl))

# cosmic_debug_test runs o/bin/cosmic-debug; every other test needs only
# $(cosmic_bin) (a pattern-rule prerequisite), so the debug binary is
# attached to just this test instead of all cosmic tests (#715)
cosmic_debug_test_got := $(call test_got,cosmic/cosmic_debug_test.tl)
$(cosmic_debug_test_got): $(cosmic_debug_bin)

# The --make graph tests drive a REAL make over fixture projects, so
# they exec the extracted engine at bin/cosmo-make — the one path
# outside the standard test grant they need. Everything that make then
# runs is $(o)/bin/cosmic and fixture trees under $(TMP), both granted.
make_graph_tests := $(call test_got,cosmic/_make/build_test.tl \
  cosmic/_make/artifact_test.tl)
$(make_graph_tests): .UNVEIL := $(unveil_test) rx:bin

cosmic_built := $(o)/cosmic/.built
cosmic_sys := sys/help.md
# The constant rules file `cosmic --make` drives make with. It ships in
# the binary at /zip/cosmic.mk and is byte-identical for every project;
# graph.tl copies it out to o/cosmic.mk. A source file, not generated.
cosmic_mk := cosmic/_make/cosmic.mk
# The graph engine itself (2e, amending D13): the pinned make from the
# sha-pinned cosmos.zip, shipped at /zip/make and extracted to o/make on
# first use. D13 rejected embedding it, but reasoned from THIS repo,
# where both pins are already in hand -- that argument does not survive
# the user case, where one binary in a bare sandbox has nothing to find
# and nothing to fetch with. Cost, stated plainly: ~760 KB compressed on
# every release, and NOT paid for by stripping (see 2c -- Appender:remove
# leaves dead space). Accepted deliberately: a build system that cannot
# build without a host toolchain is not one.
cosmic_make_bin = $(cosmos_dir)/make
cosmic_skills := $(wildcard skills/cosmic/*.md)
# _types is copied wholesale into the binary (.lua/types); without this
# dependency, editing the type generator or a .d.tl leaves a stale binary.
cosmic_types := $(wildcard _types/*.tl) $(wildcard _types/*.d.tl) $(wildcard _types/cosmo/*.d.tl)

cosmic_version_lua := $(o)/cosmic/_version.lua

# Reproducible pack (#733): zip entries carry the staged files' mtimes —
# build time, not source state — so two builds of the same tree differed
# byte-for-byte. Clamp the whole staging tree to SOURCE_DATE_EPOCH (the
# source commit date: deliberate input, like version.lua's git describe)
# before packing. main.lua and .args are staged into the tree first so
# the clamp reaches them (the old -j0 add from o/ paths could not be
# clamped without touching build intermediates make still tracks).
# Gate: the reproducible CI job double-builds and cmps.
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || echo 0)
# flatten NOW (parse time, real shell): a recursive value would expand
# inside pack recipes, where $(shell) runs under the poisoned no-shell
# SHELL and silently yields an empty epoch (#732)
SOURCE_DATE_EPOCH := $(SOURCE_DATE_EPOCH)

# De-hosted pack (#732): staging, the SOURCE_DATE_EPOCH mtime clamp,
# and the zip pipeline live in build-pack.tl (which owns the pack
# policy: store boot-critical Lua, deflate the rest, -X for #733
# reproducibility). Make stays the source of truth for WHAT ships —
# every file is an explicit --copy SRC DST pair below; the zip tool is
# the pinned cosmos binary, not a host tool. Recursive (=): expanded at
# recipe time, after the includes define tl_dir/doc_index.
pack_copies = \
  $(foreach f,$(cosmic_lua),--copy $(f) .lua/cosmic/$(patsubst $(o)/cosmic/%,%,$(f))) \
  $(foreach f,$(cosmic_tl),--copy $(f) .tl/cosmic/$(patsubst cosmic/%,%,$(f))) \
  $(foreach f,$(cosmic_sys),--copy $(f) sys/$(notdir $(f))) \
  $(foreach f,$(cosmic_skills),--copy $(f) skills/cosmic/$(notdir $(f))) \
  --copy $(cosmic_version_lua) .lua/cosmic/_version.lua \
  --copy $(tl_dir)/tl.lua .lua/tl.lua \
  --copy $(doc_index) .docs/index.lua \
  --copy $(cosmic_main) main.lua \
  --copy $(cosmic_args) .args \
  --copy $(cosmic_mk) cosmic.mk \
  --copy $(cosmic_make_bin) make \
  --copytree _types .lua/types
pack = $(bootstrap_cosmic) -- $(build_pack) --built $(cosmic_built) \
  --epoch $(SOURCE_DATE_EPOCH) --zip $(cosmos_zip_bin) $(pack_copies)

# Opt out of the enforced *.lua pattern family (#729): git describe
# reads .git (never unveiled), and this recipe's `|| echo unknown`
# fallback would swallow the denial into a silently version-less
# artifact. Target-specific wins over pattern-specific.
$(cosmic_version_lua): .SANDBOXED := 0
# Shell exception (#732/#756 item 2): git describe + cosmos version
# interpolation; a deliberate host dependency, alongside its sandbox
# opt-out above.
$(cosmic_version_lua): private SHELL := /bin/bash
$(cosmic_version_lua): private .SHELLFLAGS := -o pipefail -c
$(cosmic_version_lua): .FORCE | $$(cosmos_staged)
	@mkdir -p $(@D)
	@echo "return { cosmic = \"$$(git describe --tags --always --dirty 2>/dev/null || echo unknown)\", cosmos = \"$$($(cosmos_lua_bin) -e "print(dofile('3p/cosmos/version.lua').version)")\" }" > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm $@.tmp; else mv $@.tmp $@; fi

.PHONY: .FORCE

$(cosmic_bin) $(cosmic_debug_bin): export LUA_PATH = $(tree_lua_path)
$(cosmic_bin): $$(cosmic_lua) $(cosmic_main) $(cosmic_args) $$(tl_staged) $$(doc_index) $(cosmic_version_lua) $(cosmic_sys) $(cosmic_skills) $(cosmic_mk) $(cosmic_types) $(build_pack) $$(cosmos_staged) | $(bootstrap_cosmic)
	@$(pack) --out $@ --base $(cosmos_lua_bin)

$(cosmic_debug_bin): $(cosmic_bin) $(build_pack)
	@$(pack) --out $@ --base $(cosmos_lua_debug_bin)

# Assimilated duplicate for sandboxed build-time exec (#729, third
# family): the teal/format check rules exec cosmic hundreds of times,
# and a raw APE exec falls back to loader paths (~/.ape-*) no grant
# covers. Same bytes as the artifact, converted in place to a native
# ELF like the bootstrap; the shipped $(cosmic_bin) stays a fat APE
# (the cross-OS smoke lanes cover real-APE behavior).
cosmic_check_bin := $(o)/bin/cosmic-check
# --assimilate is handled by the APE shell stub, which a direct (no
# shell) exec bypasses — the pinned cosmos assimilate tool converts in
# place instead, keeping this recipe shell-free (#732).
# remove the previous run's backup first: assimilate writes $@.bak and
# refuses to overwrite one, so a rebuild over yesterday's assimilation
# failed with "File exists" (witnessed after a bootstrap refresh).
$(cosmic_check_bin): $(cosmic_bin) | $$(cosmos_staged)
	@$(bootstrap_cosmic) --build copy $< $@
	@$(bootstrap_cosmic) --build remove $@.bak
	@$(cosmos_dir)/assimilate $@
	@$(bootstrap_cosmic) --build require-elf $@

# The APE loader, staged where the clamped PATH can see it (#729 test
# family): the APE shell stub prefers `exec ape "$o" "$@"` for any
# loader named ape on PATH, before falling back to extracting one into
# ${TMPDIR:-$HOME}/.ape-<version> — a path no sandbox grant covers.
# With o/bin/ape staged, every fat-APE exec (the test lanes running
# $(cosmic_bin), embed-test children, ...) resolves through granted
# paths; and since the loader maps-and-jumps rather than re-execing,
# test-created APEs in TMP need only read access. Extraction: run the
# fat artifact once with TMPDIR pointed at a fresh absolute mktemp dir
# (the exact flow every pre-#742 runner exec used), then move the cache
# file the stub writes into place. A relative TMPDIR segfaulted on the
# runner.
# Shell exception (#732): extraction IS the APE shell-stub flow — a
# direct cosmopolitan exec maps the binary and never writes the .ape-*
# cache (witnessed), so this recipe must go through a real shell.
ape_loader := $(o)/bin/ape
$(ape_loader): private SHELL := /bin/bash
$(ape_loader): private .SHELLFLAGS := -o pipefail -c
$(ape_loader): $(cosmic_bin)
	@t=$$(mktemp -d) && PATH="$(HOST_PATH)" TMPDIR=$$t $(CURDIR)/$< -e 'return' >/dev/null && \
	  set -- $$t/.ape-*; [ -x "$$1" ] || { echo "ape loader extraction failed" >&2; exit 1; }; \
	  mv -f "$$1" $@ && rmdir "$$t"

cosmic: $(cosmic_bin)

cosmic-debug: $(cosmic_debug_bin)

.PHONY: cosmic cosmic-debug

# tty_test opens pty pairs; the pty multiplexer and slave directory are
# outside the shared test unveil set (#729 test family)
cosmic_tty_test_got := $(call test_got,\
  cosmic/tty_test.tl cosmic/tty_pty_test.tl)
$(cosmic_tty_test_got): .UNVEIL := $(unveil_test) rw:/dev/ptmx rw:/dev/pts

# Namespace-exercising examples opt out of the enforced example family
# like the quicksand tests: unshare has no pledge promise (#729)
quicksand_sandbox_examples := \
  $(o)/cosmic/quicksand/netns_example.tl.example.got \
  $(o)/cosmic/quicksand/proxy_example.tl.example.got
$(quicksand_sandbox_examples): .SANDBOXED := 0
$(quicksand_sandbox_examples): .PLEDGE =
$(quicksand_sandbox_examples): .UNVEIL =
