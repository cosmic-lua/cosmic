# cosmic repository module definitions
# This file aggregates all modules for the build system

# Type definition generation (define early so it's available to all modules).
# Must match MODULES in lib/types/gentype.tl: "cosmo" renders the top-level
# cosmo record (lib/types/cosmo.d.tl); the rest render lib/types/cosmo/<m>.d.tl.
type_modules := cosmo unix path getopt lsqlite3 re argon2 zip repl

# Bootstrap module: setup cosmic-lua for build process
modules += bootstrap
bootstrap_cosmic := $(o)/bootstrap/cosmic
bootstrap_files := $(bootstrap_cosmic)
bootstrap_url := https://github.com/whilp/cosmic/releases/download/2026-07-06-9b7f95b/cosmic-lua
# SHA-256 of the bootstrap cosmic binary. It compiles the entire project, so
# verify it before executing. Update this when bumping bootstrap_url.
bootstrap_sha256 := 2217687a73958110ebeae85a2d8b7af401472212bbdd168cd24a06fc37793173

export PATH := $(o)/bootstrap:$(PATH)

$(bootstrap_cosmic):
	@mkdir -p $(@D)
	curl -fsSL -o $@ $(bootstrap_url)
	@echo "$(bootstrap_sha256)  $@" | sha256sum -c - || { rm -f $@; echo "bootstrap cosmic checksum verification failed" >&2; exit 1; }
	chmod +x $@
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
