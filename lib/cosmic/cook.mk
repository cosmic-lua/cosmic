modules += cosmic
cosmic_srcs := $(wildcard lib/cosmic/*.tl) $(wildcard lib/cosmic/quicksand/*.tl) $(wildcard lib/cosmic/quicksand/box/*.tl) $(wildcard lib/cosmic/quicksand/proxy/*.tl)
cosmic_tests := $(filter %_test.tl,$(cosmic_srcs))
cosmic_examples := $(filter %_example.tl,$(cosmic_srcs))
cosmic_tl := $(filter-out $(cosmic_tests) $(cosmic_examples) lib/cosmic/main.tl,$(cosmic_srcs))
cosmic_main := $(o)/lib/cosmic/main.lua
cosmic_args := lib/cosmic/.args
cosmic_bin := $(o)/bin/cosmic
cosmic_debug_bin := $(o)/bin/cosmic-debug
cosmic_files := $(cosmic_bin) $(cosmic_debug_bin) $(cosmic_lua)
cosmic_deps := cosmos tl teal-types

cosmic_built := $(o)/cosmic/.built
cosmic_sys := sys/help.md
cosmic_skills := $(wildcard skills/cosmic/*.md)

cosmic_version_lua := $(o)/cosmic/version.lua

$(cosmic_version_lua): .FORCE | $$(cosmos_staged)
	@mkdir -p $(@D)
	@echo "return { cosmic = \"$$(git describe --tags --always --dirty 2>/dev/null || echo unknown)\", cosmos = \"$$($(cosmos_lua_bin) -e "print(dofile('3p/cosmos/version.lua').version)")\" }" > $@.tmp
	@if cmp -s $@.tmp $@ 2>/dev/null; then rm $@.tmp; else mv $@.tmp $@; fi

.PHONY: .FORCE

$(cosmic_bin): $$(cosmic_lua) $(cosmic_main) $(cosmic_args) $$(tl_staged) $$(teal-types_staged) $$(doc_index) $(cosmic_version_lua) $(cosmic_sys) $(cosmic_skills)
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
	@cd $(cosmic_built) && $(CURDIR)/$(cosmos_zip_bin) -qr $(CURDIR)/$@ .lua .tl .docs sys skills
	@$(cosmos_zip_bin) -qj $@ $(cosmic_main) $(cosmic_args)

$(cosmic_debug_bin): $(cosmic_bin)
	@$(cp) $(cosmos_lua_debug_bin) $@
	@chmod +x $@
	@cd $(cosmic_built) && $(CURDIR)/$(cosmos_zip_bin) -qr $(CURDIR)/$@ .lua .tl .docs sys skills
	@$(cosmos_zip_bin) -qj $@ $(cosmic_main) $(cosmic_args)

cosmic: $(cosmic_bin)

cosmic-debug: $(cosmic_debug_bin)

.PHONY: cosmic cosmic-debug
