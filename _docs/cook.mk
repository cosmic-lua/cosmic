modules += docs
# no docs_tl - avoid inclusion in all_example_srcs (these are build tools, not library code)
docs_publish := $(o)/_docs/publish.lua
docs_files := $(docs_publish)
# _srcs, not _tl: _tl would pull these build tools into the pipelines
# the comment above rules out, while _srcs only adds them to the type
# and format gates.
docs_srcs := $(wildcard _docs/*.tl)

docs_tests := _docs/publish_test.tl
docs_deps := cosmic

# publish_test loads the publisher from the tree at runtime; the
# closure in o/project.mk names it, so the rule needs no hand-declared
# dependency.
docs_test_got := $(call test_got,$(docs_tests))
