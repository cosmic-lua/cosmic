# One rule family per mk/*.mk; the Makefile keeps aggregation and the
# shared path variables. Include order is load-bearing: pattern-specific
# variables and their nesting depend on where this is included.
#
# documentation: rendered markdown, the embedded index, and publishing.

# Documentation generation - render .tl files as markdown. $(all_tl) is
# complete by construction, so docs and the embedded index read it
# directly, with no unfiltered twin list to keep beside it.
all_docs := $(patsubst %.tl,$(o)/docs/%.md,$(all_tl))

# Documentation from .d.tl type definition files (cosmo modules)
dtl_files := $(wildcard _types/cosmo/*.d.tl)
dtl_docs := $(patsubst _types/cosmo/%.d.tl,$(o)/docs/cosmo/%.md,$(dtl_files))
all_docs += $(dtl_docs)

.PHONY: docs
## Generate documentation from source
docs: $(all_docs)

# De-shelled: the driver's capture mode owns the output
# file (and its parent directory) — no mkdir, no redirect.
$(o)/docs/%.md: %.tl $(cosmic_bin) | $(bootstrap_files)
	@$(bootstrap_cosmic) --build capture $(cosmic_bin) $@ cosmic/doc/gendoc.tl $<

$(o)/docs/cosmo/%.md: _types/cosmo/%.d.tl $(cosmic_bin) | $(bootstrap_files)
	@$(bootstrap_cosmic) --build capture $(cosmic_bin) $@ cosmic/doc/gendoc.tl $<

# Generate serialized doc index for embedding (uses bootstrap cosmic to avoid circular dep)
# Include both module sources and example files for the index
# LUA_PATH points at the freshly compiled modules so the index generator uses
# this tree's cosmic.doc code, not the bootstrap's embedded (older) copy.
# Both source lists are complete by construction — the embedded
# index must always describe every module.
doc_index_srcs := $(all_tl) $(all_example_srcs) $(dtl_files)
doc_index_lua := $(patsubst %.tl,$(o)/%.lua,$(all_tl))
doc_index := $(o)/docs/.index.lua
doc_index_script := cosmic/doc/index.tl

# $(MAKEFILE_LIST) — the Makefile and every included cook.mk — is a
# prerequisite so trees whose index was poisoned by a filtered rebuild
# (the mtime trap in the broken index is newer than every source,
# and .SECONDARY blocks rebuild-on-delete) self-heal when this fix — or
# any future build-logic change — arrives; a bare Makefile prereq missed
# cook.mk edits. The write-if-changed dance below keeps the
# binary from re-embedding when the regenerated content is identical
$(doc_index): export TREE_LUA_PATH = $(o)/?.lua;$(o)/?/init.lua;;
$(doc_index): $(doc_index_srcs) $(doc_index_lua) $(doc_index_script) $(MAKEFILE_LIST) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) --build capture $(bootstrap_cosmic) $@ $(doc_index_script) $(doc_index_srcs)

.PHONY: doc-index
## Generate serialized documentation index
doc-index: $(doc_index)

.PHONY: doc-publish
## Publish docs to git branch (SOURCE_SHA required, uses $(o)/docs)
# Shell exception: SOURCE_SHA guard + env prefix; git anyway.
doc-publish: private SHELL := /bin/bash
doc-publish: private .SHELLFLAGS := -o pipefail -c
doc-publish: .PLEDGE := $(pledge_build) inet dns
doc-publish: .UNVEIL := $(unveil_run) rwc:.git rwc:. r:/home r:/root
doc-publish: $(all_docs) $(docs_publish) | $(bootstrap_cosmic)
	@test -n "$(SOURCE_SHA)" || { echo "SOURCE_SHA required"; exit 1; }
	@LUA_PATH="$(tree_lua_path)" $(bootstrap_cosmic) -- $(docs_publish) $(SOURCE_SHA) $(o)/docs $(or $(DOCS_BRANCH),docs)
