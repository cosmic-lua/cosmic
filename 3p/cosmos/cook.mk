modules += cosmos
cosmos_version := 3p/cosmos/cosmos_pin.tl
cosmos_tests := 3p/cosmos/cosmos_test.tl
cosmos_lua_bin = $(cosmos_dir)/lua
cosmos_lua_debug_bin = $(cosmos_dir)/lua-debug
cosmos_zip_bin = $(cosmos_dir)/zip

# cosmos_test reads the staged lua/zip binaries through TEST_DIR.
# cosmos_dir is derived in the Makefile after includes, hence the
# secondary expansion and the recursive (=) TEST_DIR.
cosmos_test_got := $(call test_got,$(cosmos_tests))
$(cosmos_test_got): $$(cosmos_dir)
$(cosmos_test_got): TEST_DIR = $(cosmos_dir)
