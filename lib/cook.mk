modules += lib
lib_lua_dirs := lib

# type declaration files for teal compilation
types_files := $(wildcard lib/types/*.d.tl lib/types/*/*.d.tl lib/types/*/*/*.d.tl)

include lib/build/cook.mk
include lib/cosmic/cook.mk
include lib/docs/cook.mk
include lib/perf/cook.mk
include lib/types/cook.mk

# A committed foo.lua beside a module's foo.tl would shadow the .tl at
# require time (package.path tries .lua first), and invites stale-copy
# confusion in o/ — refuse to configure (#721). (The make-side half of
# this hazard — a $(o)/%: % copy rule competing with the %.tl compile
# rule for the same target — is gone with the copy rule itself, #775.)
tl_shadowed := $(wildcard $(patsubst %.tl,%.lua,$(foreach m,$(modules),$($(m)_tl))))
$(if $(tl_shadowed),$(error committed .lua beside .tl source: $(tl_shadowed)))
