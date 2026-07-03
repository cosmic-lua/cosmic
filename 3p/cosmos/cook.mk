modules += cosmos
cosmos_version := 3p/cosmos/version.lua
cosmos_tests := 3p/cosmos/cosmos_test.tl 3p/cosmos/sandbox_test.tl
cosmos_lua_bin = $(cosmos_dir)/lua
cosmos_lua_debug_bin = $(cosmos_dir)/lua-debug
cosmos_zip_bin = $(cosmos_dir)/zip

# Vendored cosmo.sandbox Lua modules, embedded into the cosmic binary at
# /zip/.lua/cosmo/sandbox/. These moved here from whilp/cosmopolitan (see
# whilp/cosmopolitan#123): the C fork keeps only the syscall primitives
# (unshare, setns, pivot_root, mount, landlock, ...) and this pure-Lua
# orchestration layer lives with its consumer. Appended zip entries replace
# same-name entries in the base binary, so these win over any copy still
# embedded in the pinned cosmos release.
cosmos_sandbox_lua := $(wildcard 3p/cosmos/sandbox/*.lua)
