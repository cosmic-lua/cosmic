# cosmic repository module definitions
# This file aggregates all modules for the build system

# Type definition generation (define early so it's available to all modules)
type_modules := unix path getopt lsqlite3 re argon2 zip
type_gen_outputs := $(patsubst %,lib/types/cosmo/%.d.tl,$(type_modules))

# Bootstrap module: setup cosmic-lua for build process
modules += bootstrap
bootstrap_cosmic := $(o)/bootstrap/cosmic
bootstrap_files := $(bootstrap_cosmic)
bootstrap_url := https://github.com/whilp/cosmic/releases/download/2026-03-08-ac3a5d5/cosmic-lua

export PATH := $(o)/bootstrap:$(PATH)

$(bootstrap_cosmic):
	@mkdir -p $(@D)
	curl -fsSL -o $@ $(bootstrap_url)
	chmod +x $@
	@ln -sf cosmic $(@D)/lua
