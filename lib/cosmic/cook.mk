modules += cosmic
cosmic_srcs := $(wildcard lib/cosmic/*.tl) $(wildcard lib/cosmic/cli/*.tl) $(wildcard lib/cosmic/fs/*.tl) $(wildcard lib/cosmic/child/*.tl) $(wildcard lib/cosmic/doc/*.tl) $(wildcard lib/cosmic/docs/*.tl) $(wildcard lib/cosmic/fetch/*.tl) $(wildcard lib/cosmic/format/*.tl) $(wildcard lib/cosmic/net/*.tl) $(wildcard lib/cosmic/sqlite/*.tl) $(wildcard lib/cosmic/quicksand/*.tl) $(wildcard lib/cosmic/quicksand/box/*.tl) $(wildcard lib/cosmic/quicksand/proxy/*.tl)
cosmic_tests := $(filter %_test.tl,$(cosmic_srcs))
cosmic_examples := $(filter %_example.tl,$(cosmic_srcs))
cosmic_tl := $(filter-out $(cosmic_tests) $(cosmic_examples) lib/cosmic/cli/main.tl,$(cosmic_srcs))
cosmic_main := $(o)/lib/cosmic/cli/main.lua
cosmic_args := lib/cosmic/.args
cosmic_bin := $(o)/bin/cosmic
cosmic_debug_bin := $(o)/bin/cosmic-debug
cosmic_files := $(cosmic_bin) $(cosmic_debug_bin) $(cosmic_lua)
cosmic_deps := cosmos tl teal-types

cosmic_built := $(o)/cosmic/.built
cosmic_sys := sys/help.md
cosmic_skills := $(wildcard skills/cosmic/*.md)
# lib/types is copied wholesale into the binary (.lua/types); without this
# dependency, editing the type generator or a .d.tl leaves a stale binary.
cosmic_types := $(wildcard lib/types/*.tl) $(wildcard lib/types/*.d.tl) $(wildcard lib/types/cosmo/*.d.tl)

cosmic_version_lua := $(o)/cosmic/version.lua

# Pack the cosmic payload into the binary given as $(1). The boot-critical
# Lua — .lua/cosmic/* modules, main.lua and .args — is inflate()d on EVERY
# invocation (29 inflate() calls at boot; see whilp/cosmic#487, backlog 24), so store
# it uncompressed to skip the decompress. The rest (tl.lua, the type
# declarations, docs, .tl source, skills) is either large or lazy-loaded and
# not on the startup path, so keep it deflated to hold the size cost down.
define pack-cosmic
	@cd $(cosmic_built) && $(CURDIR)/$(cosmos_zip_bin) -qr0 $(CURDIR)/$(1) .lua/cosmic
	@cd $(cosmic_built) && $(CURDIR)/$(cosmos_zip_bin) -qr $(CURDIR)/$(1) .lua .tl .docs sys skills -x '.lua/cosmic/*'
	@$(cosmos_zip_bin) -qj0 $(1) $(cosmic_main) $(cosmic_args)
endef

$(cosmic_version_lua): .FORCE | $$(cosmos_staged)
	@mkdir -p $(@D)
	@echo "return { cosmic = \"$$(git describe --tags --always --dirty 2>/dev/null || echo unknown)\", cosmos = \"$$($(cosmos_lua_bin) -e "print(dofile('3p/cosmos/version.lua').version)")\" }" > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm $@.tmp; else mv $@.tmp $@; fi

.PHONY: .FORCE

$(cosmic_bin): $$(cosmic_lua) $(cosmic_main) $(cosmic_args) $$(tl_staged) $$(teal-types_staged) $$(doc_index) $(cosmic_version_lua) $(cosmic_sys) $(cosmic_skills) $(cosmic_types)
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
	@cp -r $(teal-types_dir)/types $(cosmic_built)/.lua/teal-types
	@cp -r lib/types $(cosmic_built)/.lua/types
	@mkdir -p $(cosmic_built)/.docs
	@$(cp) $(doc_index) $(cosmic_built)/.docs/index.lua
	@mkdir -p $(cosmic_built)/sys
	@$(cp) $(cosmic_sys) $(cosmic_built)/sys/
	@mkdir -p $(cosmic_built)/skills/cosmic
	@$(cp) $(cosmic_skills) $(cosmic_built)/skills/cosmic/
	@$(cp) $(cosmos_lua_bin) $@
	@chmod +x $@
	$(call pack-cosmic,$@)

$(cosmic_debug_bin): $(cosmic_bin)
	@$(cp) $(cosmos_lua_debug_bin) $@
	@chmod +x $@
	$(call pack-cosmic,$@)

cosmic: $(cosmic_bin)

cosmic-debug: $(cosmic_debug_bin)

.PHONY: cosmic cosmic-debug
