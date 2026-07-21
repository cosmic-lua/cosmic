# Iteration 4: replicate PR #746's EXACT in-tree resolution under the sandbox.
#
# #746 compiles with `LUA_PATH=";;"` + an absolute, tree-only `TL_PATH` and
# `--include-dir lib`. Its offline failures were all in one file whose requires
# include a root-dotted `require("lib.docs.publish")` — resolved through the
# `$(CURDIR)/?.tl` entry that #746 introduced. Here every test file requires K
# modules that same way (`require("lib.mods.mK")` -> $(CURDIR)/lib/mods/mK.tl),
# under the r:lib grant, in a fresh sandboxed burst. If a compile reports
# "module not found" for a present, granted module, the offline red is a
# regression in #746's resolution — not #744.

o := o
N ?= 250
K ?= 100
BOOT ?= cosmic

# Byte-for-byte the shape of #746's tree_tl_path (source root + lib + lib/types).
tree_tl_path := $(CURDIR)/?.lua;$(CURDIR)/?/init.lua;$(CURDIR)/lib/?.lua;$(CURDIR)/lib/?/init.lua;$(CURDIR)/lib/types/?.lua;$(CURDIR)/lib/types/?/init.lua

.PLEDGE := stdio rpath wpath cpath proc exec fattr
.UNVEIL := rwc:$(o) r:lib rx:/usr rx:/bin rx:/lib rx:/lib64 rx:/proc r:/etc rw:/dev/null r:/dev/random r:/dev/urandom

tests := $(foreach i,$(shell seq 1 $(N)),$(o)/test-$(i).lua)

.PHONY: all
all: $(o)/canary.lua $(tests)

# Exactly #746's compile invocation: strict, hermetic LUA_PATH, absolute
# tree-only TL_PATH, --include-dir lib.
$(o)/test-%.lua: .SANDBOXED := 1
$(o)/test-%.lua: lib/tests/test-%.tl $(BOOT)
	@if LUA_PATH=";;" TL_PATH="$(tree_tl_path)" ./$(BOOT) --include-dir lib --compile-strict lib/tests/test-$*.tl >$@ 2>$(o)/test-$*.err; then \
	  : ; \
	else \
	  echo COMPILE-FAILED >> $(o)/test-$*.err ; \
	fi

# Enforcement canary: root-dotted require of a module under lib-hidden/, which
# is present but NOT covered by r:lib. Under real Landlock the read is denied ->
# module not found -> ENFORCE=yes.
$(o)/canary.lua: .SANDBOXED := 1
$(o)/canary.lua: canary.tl $(BOOT)
	@if LUA_PATH=";;" TL_PATH="$(tree_tl_path)" ./$(BOOT) --include-dir lib --compile-strict canary.tl >$@ 2>$(o)/canary.err; then \
	  echo ENFORCE=no > $(o)/canary.status ; \
	else \
	  echo ENFORCE=yes > $(o)/canary.status ; \
	fi
