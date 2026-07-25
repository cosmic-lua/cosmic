modules += docs
# no docs_tl - avoid inclusion in all_example_srcs (these are build tools, not library code)
docs_publish := $(o)/_docs/publish.lua
docs_files := $(docs_publish)
# _srcs, not _tl: _tl would pull these build tools into the pipelines
# the comment above rules out, while _srcs only adds them to the type
# and format gates (#800).
docs_srcs := $(wildcard _docs/*.tl)

docs_tests := _docs/publish_test.tl
docs_deps := cosmic

# publish_test loads the publisher from the tree at runtime; the
# compiled copy keeps the test rerunning when publish.tl changes (#715)
docs_test_got := $(call test_got,$(docs_tests))
$(docs_test_got): $(docs_files)
