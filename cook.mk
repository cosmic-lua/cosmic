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
