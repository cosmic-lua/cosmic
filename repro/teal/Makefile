# Iteration 3: reproduce #744 with the REAL teal compiler under a sandboxed
# burst — the one thing iterations 1 & 2 did not replicate.
#
# N test files each `require` K synthetic modules resolved ONLY via the global
# `r:mods` grant (like lib/cosmic/*.tl under `r:lib`) — never a prerequisite,
# so the pinned bootstrap's tl.search_module must find them by grant. If a
# sandboxed `--compile-strict` intermittently reports "module not found" for a
# present, granted module (or falls to the bootstrap's stale /zip), that is
# #744 reproduced in a minimal harness.

o := o
N ?= 250
K ?= 100
BOOT ?= cosmic

.PLEDGE := stdio rpath wpath cpath proc exec fattr
# r:mods is the grant the require()s depend on; tests/ + BOOT are prereqs
# (auto-granted rx); the rest is the cosmopolitan runtime's host surface.
.UNVEIL := rwc:$(o) r:mods r:tests rx:/usr rx:/bin rx:/lib rx:/lib64 rx:/proc r:/etc rw:/dev/null r:/dev/random r:/dev/urandom

tests := $(foreach i,$(shell seq 1 $(N)),$(o)/test-$(i).lua)

.PHONY: all
all: $(o)/canary.lua $(tests)

# Each compile: the assimilated bootstrap type-checks a test file whose K
# requires resolve to mods/*.tl via `--include-dir .`, reachable only through
# the global r:mods grant. On failure the error (with any "module not found")
# lands in the .err file.
$(o)/test-%.lua: .SANDBOXED := 1
$(o)/test-%.lua: tests/test-%.tl $(BOOT)
	@if LUA_PATH=";;" ./$(BOOT) --include-dir . --compile-strict tests/test-$*.tl >$@ 2>$(o)/test-$*.err; then \
	  : ; \
	else \
	  echo COMPILE-FAILED >> $(o)/test-$*.err ; \
	fi

# Enforcement canary: require a module in hidden-mods/, which EXISTS on disk
# but is NOT unveiled. Under real Landlock the read is denied, so teal reports
# "module not found" and the compile fails -> ENFORCE=yes. If it compiles, the
# sandbox is not restricting reads and the run is inconclusive.
$(o)/canary.lua: .SANDBOXED := 1
$(o)/canary.lua: canary.tl $(BOOT)
	@if LUA_PATH=";;" ./$(BOOT) --include-dir . --compile-strict canary.tl >$@ 2>$(o)/canary.err; then \
	  echo ENFORCE=no > $(o)/canary.status ; \
	else \
	  echo ENFORCE=yes > $(o)/canary.status ; \
	fi
