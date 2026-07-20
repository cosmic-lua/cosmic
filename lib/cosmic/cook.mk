modules += cosmic
cosmic_srcs := $(wildcard lib/cosmic/*.tl) $(wildcard lib/cosmic/cli/*.tl) $(wildcard lib/cosmic/coverage/*.tl) $(wildcard lib/cosmic/fs/*.tl) $(wildcard lib/cosmic/child/*.tl) $(wildcard lib/cosmic/doc/*.tl) $(wildcard lib/cosmic/fetch/*.tl) $(wildcard lib/cosmic/format/*.tl) $(wildcard lib/cosmic/net/*.tl) $(wildcard lib/cosmic/sqlite/*.tl) $(wildcard lib/cosmic/quicksand/*.tl) $(wildcard lib/cosmic/quicksand/box/*.tl) $(wildcard lib/cosmic/quicksand/proxy/*.tl)
cosmic_tests := $(filter %_test.tl,$(cosmic_srcs))
cosmic_examples := $(filter %_example.tl,$(cosmic_srcs))
cosmic_tl := $(filter-out $(cosmic_tests) $(cosmic_examples) lib/cosmic/cli/main.tl,$(cosmic_srcs))
cosmic_main := $(o)/lib/cosmic/cli/main.lua
cosmic_args := lib/cosmic/.args
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
cosmic_debug_test_got := \
  $(o)/lib/cosmic/cosmic_debug_test.tl.test.got \
  $(o)/coverage/lib/cosmic/cosmic_debug_test.tl.test.got
$(cosmic_debug_test_got): $(cosmic_debug_bin)

cosmic_built := $(o)/cosmic/.built
cosmic_sys := sys/help.md
cosmic_skills := $(wildcard skills/cosmic/*.md)
# lib/types is copied wholesale into the binary (.lua/types); without this
# dependency, editing the type generator or a .d.tl leaves a stale binary.
cosmic_types := $(wildcard lib/types/*.tl) $(wildcard lib/types/*.d.tl) $(wildcard lib/types/cosmo/*.d.tl)

cosmic_version_lua := $(o)/cosmic/version.lua

# Reproducible pack (#733): zip entries carry the staged files' mtimes —
# build time, not source state — so two builds of the same tree differed
# byte-for-byte. Clamp the whole staging tree to SOURCE_DATE_EPOCH (the
# source commit date: deliberate input, like version.lua's git describe)
# before packing. main.lua and .args are staged into the tree first so
# the clamp reaches them (the old -j0 add from o/ paths could not be
# clamped without touching build intermediates make still tracks).
# Gate: the reproducible CI job double-builds and cmps.
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || echo 0)

# Pack the cosmic payload into the binary given as $(1). The boot-critical
# Lua — .lua/cosmic/* modules, main.lua and .args — is inflate()d on EVERY
# invocation (29 inflate() calls at boot; see whilp/cosmic#487, backlog 24), so store
# it uncompressed to skip the decompress. The rest (tl.lua, the type
# declarations, docs, .tl source, skills) is either large or lazy-loaded and
# not on the startup path, so keep it deflated to hold the size cost down.
# -X strips the Unix extra fields (atime/mtime/uid/gid): zip reading a
# staged file bumps its atime to pack time, which leaked into local
# headers even with mtimes clamped. Entry mtimes stay as (clamped) DOS
# timestamps; mode bits live in the central attrs and survive -X.
define pack-cosmic
	@find $(cosmic_built) -exec touch -d @$(SOURCE_DATE_EPOCH) {} +
	@cd $(cosmic_built) && $(CURDIR)/$(cosmos_zip_bin) -qr0X $(CURDIR)/$(1) .lua/cosmic
	@cd $(cosmic_built) && $(CURDIR)/$(cosmos_zip_bin) -qrX $(CURDIR)/$(1) .lua .tl .docs sys skills -x '.lua/cosmic/*'
	@cd $(cosmic_built) && $(CURDIR)/$(cosmos_zip_bin) -q0X $(CURDIR)/$(1) main.lua .args
endef

# Opt out of the enforced *.lua pattern family (#729): git describe
# reads .git (never unveiled), and this recipe's `|| echo unknown`
# fallback would swallow the denial into a silently version-less
# artifact. Target-specific wins over pattern-specific.
$(cosmic_version_lua): .SANDBOXED := 0
$(cosmic_version_lua): .FORCE | $$(cosmos_staged)
	@mkdir -p $(@D)
	@echo "return { cosmic = \"$$(git describe --tags --always --dirty 2>/dev/null || echo unknown)\", cosmos = \"$$($(cosmos_lua_bin) -e "print(dofile('3p/cosmos/version.lua').version)")\" }" > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm $@.tmp; else mv $@.tmp $@; fi

.PHONY: .FORCE

$(cosmic_bin): $$(cosmic_lua) $(cosmic_main) $(cosmic_args) $$(tl_staged) $$(doc_index) $(cosmic_version_lua) $(cosmic_sys) $(cosmic_skills) $(cosmic_types)
	@rm -rf $(cosmic_built)
	@mkdir -p $(cosmic_built)/.lua/cosmic $(cosmic_built)/.tl/cosmic $(@D)
	@for f in $(cosmic_lua); do \
		rel="$${f#$(o)/lib/cosmic/}"; \
		dst="$(cosmic_built)/.lua/cosmic/$$rel"; \
		mkdir -p "$$(dirname "$$dst")"; \
		$(cp) "$$f" "$$dst"; \
	done
	@for f in $(cosmic_tl); do \
		rel="$${f#lib/cosmic/}"; \
		dst="$(cosmic_built)/.tl/cosmic/$$rel"; \
		mkdir -p "$$(dirname "$$dst")"; \
		$(cp) "$$f" "$$dst"; \
	done
	@$(cp) $(cosmic_version_lua) $(cosmic_built)/.lua/cosmic/version.lua
	@$(cp) $(tl_dir)/tl.lua $(cosmic_built)/.lua/
	@cp -r lib/types $(cosmic_built)/.lua/types
	@mkdir -p $(cosmic_built)/.docs
	@$(cp) $(doc_index) $(cosmic_built)/.docs/index.lua
	@mkdir -p $(cosmic_built)/sys
	@$(cp) $(cosmic_sys) $(cosmic_built)/sys/
	@mkdir -p $(cosmic_built)/skills/cosmic
	@$(cp) $(cosmic_skills) $(cosmic_built)/skills/cosmic/
	@$(cp) $(cosmic_main) $(cosmic_built)/main.lua
	@$(cp) $(cosmic_args) $(cosmic_built)/.args
	@$(cp) $(cosmos_lua_bin) $@
	@chmod +x $@
	$(call pack-cosmic,$@)

$(cosmic_debug_bin): $(cosmic_bin)
	@$(cp) $(cosmos_lua_debug_bin) $@
	@chmod +x $@
	$(call pack-cosmic,$@)

# Assimilated duplicate for sandboxed build-time exec (#729, third
# family): the teal/format check rules exec cosmic hundreds of times,
# and a raw APE exec falls back to loader paths (~/.ape-*) no grant
# covers. Same bytes as the artifact, converted in place to a native
# ELF like the bootstrap; the shipped $(cosmic_bin) stays a fat APE
# (the cross-OS smoke lanes cover real-APE behavior).
cosmic_check_bin := $(o)/bin/cosmic-check
$(cosmic_check_bin): $(cosmic_bin)
	@$(cp) $< $@
	@$@ --assimilate
	@printf '\177ELF' | cmp -s - <(head -c 4 $@) || { echo "cosmic-check assimilation failed: still an APE" >&2; exit 1; }

# The APE loader, staged where the clamped PATH can see it (#729 test
# family): the APE shell stub prefers `exec ape "$o" "$@"` for any
# loader named ape on PATH, before falling back to extracting one into
# ${TMPDIR:-$HOME}/.ape-<version> — a path no sandbox grant covers.
# With o/bin/ape staged, every fat-APE exec (the test lanes running
# $(cosmic_bin), embed-test children, ...) resolves through granted
# paths; and since the loader maps-and-jumps rather than re-execing,
# test-created APEs in TMP need only read access. Extraction: run the
# fat artifact once with TMPDIR pointed at o/bin, then rename the
# cache file the stub writes.
ape_loader := $(o)/bin/ape
$(ape_loader): $(cosmic_bin)
	@rm -f $(@D)/.ape-*
	@PATH="$(HOST_PATH)" TMPDIR=$(@D) $< -e 'return' >/dev/null
	@set -- $(@D)/.ape-*; [ -x "$$1" ] || { echo "ape loader extraction failed" >&2; exit 1; }; mv -f "$$1" $@

cosmic: $(cosmic_bin)

cosmic-debug: $(cosmic_debug_bin)

.PHONY: cosmic cosmic-debug
