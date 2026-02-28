modules += docs
# no docs_tl - avoid inclusion in all_example_srcs (these are build tools, not library code)
docs_publish := $(o)/lib/docs/publish.lua
docs_files := $(docs_publish)
docs_tests := lib/docs/publish_test.tl
