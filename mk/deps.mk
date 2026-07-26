# One rule family per mk/*.mk; the Makefile keeps aggregation and the
# shared path variables. Include order is load-bearing: pattern-specific
# variables and their nesting depend on where this is included.
#
# the versioned-dependency pipeline: .versioned -> .fetched -> .staged.

# versions get fetched: o/module/.fetched -> o/fetched/module/<ver>-<sha>/<archive>
.PHONY: fetched
all_fetched := $(patsubst %/.versioned,%/.fetched,$(call filter-only,$(all_versioned)))
## Fetch all dependencies only
fetched: $(all_fetched)
# Downloads are integrity-checked against the sha256 pinned in each
# module's *_pin.tl — TLS is transport, not the trust root — via the
# host CA store (bootstrap CAs are too narrow for github.com; an
# operator SSL_CERT_FILE bundle is unveiled). The scripts run under the
# pinned bootstrap against THIS tree's cosmic.* APIs — the compiled
# stdlib is a prerequisite (a cold parallel build once fell back to the
# bootstrap's embedded stdlib; only= must not shrink it). Extraction is
# in-process and each recipe is a direct bootstrap exec under
# the global no-shell default — no $(unveil_hostx): ONLY the pinned
# bootstrap executes under these grants, with .ENV/.SANDBOXED/LUA_PATH
# for the family living in cook.mk.
stdlib_lua := $(patsubst %.tl,$(o)/%.lua,$(filter cosmic/%,$(all_tl)))
# The fetch/stage trees must EXIST before their sandboxed rules launch
# (unveil silently skips missing paths — the same trap the target-dir
# derivation closed upstream, one level up); the driver's list mode mints
# them as a stamp.
$(FETCH_O)/.exists $(STAGE_O)/.exists: | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) --build list $@
$(o)/%/.fetched: export SSL_USE_SYSTEM_CERTS = 1
$(o)/%/.fetched: .PLEDGE := $(pledge_build) inet dns
$(o)/%/.fetched: .UNVEIL := $(unveil_fetch) $(unveil_dev) r:/etc/resolv.conf r:/etc/hosts r:/etc/ssl $(if $(SSL_CERT_FILE),r:$(SSL_CERT_FILE))
$(o)/%/.fetched: $(o)/%/.versioned $(build_fetch_files) $(stdlib_lua) | $(bootstrap_cosmic) $(FETCH_O)/.exists
	@$(bootstrap_cosmic) -- $(build_fetch) $< $(platform) $@

# versions get staged: o/module/.staged -> o/staged/module/<ver>-<sha>
.PHONY: staged
all_staged := $(patsubst %/.fetched,%/.staged,$(all_fetched))
## Fetch and extract all dependencies
staged: $(all_staged)
$(o)/%/.staged: .PLEDGE := $(pledge_build)
$(o)/%/.staged: .UNVEIL := $(unveil_stage) $(unveil_dev)
$(o)/%/.staged: $(o)/%/.fetched $(build_stage_files) $(stdlib_lua) | $(STAGE_O)/.exists
	@$(bootstrap_cosmic) -- $(build_stage) $(o)/$*/.versioned $(platform) $< $@
