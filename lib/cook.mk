modules += lib
lib_lua_dirs := lib

# type declaration files for teal compilation
types_files := $(wildcard lib/types/*.d.tl lib/types/*/*.d.tl lib/types/*/*/*.d.tl)

include lib/build/cook.mk
include lib/cosmic/cook.mk
include lib/docs/cook.mk
include lib/perf/cook.mk
include lib/types/cook.mk
