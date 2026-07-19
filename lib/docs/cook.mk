modules += docs
# no docs_tl - avoid inclusion in all_example_srcs (these are build tools, not library code)
docs_publish := $(o)/lib/docs/publish.lua
docs_files := $(docs_publish)
docs_tests := lib/docs/publish_test.tl
docs_deps := cosmic

# publish_test loads the publisher from the tree at runtime; the
# compiled copy keeps the test rerunning when publish.tl changes (#715)
docs_test_got := \
  $(patsubst %,$(o)/%.test.got,$(docs_tests)) \
  $(patsubst %,$(o)/coverage/%.test.got,$(docs_tests))
$(docs_test_got): $(docs_files)
