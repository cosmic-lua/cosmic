modules += cosmic
cosmic_srcs := $(wildcard lib/cosmic/*.tl)
cosmic_tests := $(filter %_test.tl,$(cosmic_srcs))
cosmic_examples := $(filter %_example.tl,$(cosmic_srcs))
cosmic_tl := $(filter-out $(cosmic_tests) $(cosmic_examples) lib/cosmic/main.tl,$(cosmic_srcs))
cosmic_main := $(o)/lib/cosmic/main.lua
cosmic_args := lib/cosmic/.args
cosmic_bin := $(o)/bin/cosmic
cosmic_files := $(cosmic_bin) $(cosmic_lua)
cosmic_deps := cosmos tl teal-types

cosmic_built := $(o)/cosmic/.built

$(cosmic_bin): $$(cosmic_lua) $(cosmic_main) $(cosmic_args) $$(tl_staged) $$(teal-types_staged) $$(doc_index)
	@rm -rf $(cosmic_built)
	@mkdir -p $(cosmic_built)/.lua/cosmic $(@D)
	@$(cp) $(cosmic_lua) $(cosmic_built)/.lua/cosmic/
	@$(cp) $(cosmic_tl) $(cosmic_built)/.lua/cosmic/
	@$(cp) $(tl_dir)/tl.lua $(cosmic_built)/.lua/
	@cp -r $(teal-types_dir)/types $(cosmic_built)/.lua/teal-types
	@cp -r lib/types $(cosmic_built)/.lua/types
	@mkdir -p $(cosmic_built)/.docs
	@$(cp) $(doc_index) $(cosmic_built)/.docs/index.lua
	@$(cp) $(cosmos_lua_bin) $@
	@chmod +x $@
	@cd $(cosmic_built) && $(CURDIR)/$(cosmos_zip_bin) -qr $(CURDIR)/$@ .lua .docs
	@$(cosmos_zip_bin) -qj $@ $(cosmic_main) $(cosmic_args)

cosmic: $(cosmic_bin)

.PHONY: cosmic
