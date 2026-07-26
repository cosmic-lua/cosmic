# The root IS the module root now: a source at cosmic/fs.tl
# is require("cosmic.fs"), and nothing sits between the two. The old
# `lib` module existed only to name that middle directory.
modules += root
root_lua_dirs := .

# type declaration files for teal compilation
types_files := $(wildcard _types/*.d.tl _types/*/*.d.tl _types/*/*/*.d.tl)

include _build/cook.mk
include cosmic/cook.mk
include _docs/cook.mk
include _perf/cook.mk
include _types/cook.mk

# A committed foo.lua beside a module's foo.tl would shadow the .tl at
# require time (package.path tries .lua first), and invites stale-copy
# confusion in o/ — refuse to configure. (The make-side half of
# this hazard — a $(o)/%: % copy rule competing with the %.tl compile
# rule for the same target — is gone with the copy rule itself.)
tl_shadowed := $(wildcard $(patsubst %.tl,%.lua,$(foreach m,$(modules),$($(m)_tl))))
$(if $(tl_shadowed),$(error committed .lua beside .tl source: $(tl_shadowed)))
