modules += types
# gentype_test.tl reads /zip/.lua/definitions.lua (embedded in the built cosmic
# binary via cosmos) and the committed _types/cosmo/*.d.tl, so it runs as a
# normal test under $(cosmic_bin). It guards the generator against drift, e.g.
# the errno-return contract in unix.d.tl (see test_errno_drift_unix).
# The generators are checked; the generated .d.tl declarations are not.
# gentype_test asserts those byte-for-byte against generator output, so
# formatting them would fight the generator rather than the source.
# Same _srcs-not-_tl reasoning as the other build-tool modules.
types_srcs := $(filter-out %.d.tl,$(wildcard _types/*.tl))

types_tests := _types/gentype_test.tl _types/gentype_alias_test.tl _types/gentype_return_test.tl _types/gentl_test.tl _types/tl_conformance_test.tl
# types_deps is intentionally not set - types_files are source files (.d.tl),
# not built outputs. The regen-types target uses bootstrap_cosmic directly.

# gentl_test reads the staged tl source through the o/tl/.staged symlink
# (tl_staged is defined after includes, hence the secondary expansion).
$(call test_got,_types/gentl_test.tl): $$(tl_staged)

.PHONY: regen-tl-types
## Regenerate _types/tl.d.tl from the staged tl source
# De-shelled: the driver's capture mode owns the output —
# write-if-changed, nothing written when the generator fails.
regen-tl-types: .PLEDGE := $(pledge_build)
regen-tl-types: .UNVEIL := $(unveil_base) rwcx:$(o) rwc:_types
regen-tl-types: $(o)/_types/gentl.lua $$(tl_staged) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) --build capture $(bootstrap_cosmic) _types/tl.d.tl $(o)/_types/gentl.lua $(o)/tl/.staged/tl.tl
	@echo wrote _types/tl.d.tl
