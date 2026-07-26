modules += tl
tl_version := 3p/tl/tl.pin.tl
tl_tests := $(wildcard 3p/tl/*_test.tl)
tl_deps := cosmos

# tl_test loads the staged tl source through TEST_DIR. tl_dir is
# derived in the Makefile after includes, hence the secondary
# expansion and the recursive (=) TEST_DIR.
tl_test_got := $(call test_got,$(tl_tests))
$(tl_test_got): $$(tl_dir)
$(tl_test_got): TEST_DIR = $(tl_dir)
