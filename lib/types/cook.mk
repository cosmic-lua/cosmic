modules += types
# gentype_test.tl reads /zip/.lua/definitions.lua (embedded in the built cosmic
# binary via cosmos) and the committed lib/types/cosmo/*.d.tl, so it runs as a
# normal test under $(cosmic_bin). It guards the generator against drift, e.g.
# the errno-return contract in unix.d.tl (see test_errno_drift_unix).
types_tests := lib/types/gentype_test.tl lib/types/gentype_alias_test.tl lib/types/gentl_test.tl lib/types/tl_conformance_test.tl
# types_deps is intentionally not set - types_files are source files (.d.tl),
# not built outputs. The regen-types target uses bootstrap_cosmic directly.

# gentl_test reads the staged tl source through the o/tl/.staged symlink
# (tl_staged is defined after includes, hence the secondary expansion).
$(o)/lib/types/gentl_test.tl.test.got $(o)/coverage/lib/types/gentl_test.tl.test.got: $$(tl_staged)

.PHONY: regen-tl-types
## Regenerate lib/types/tl.d.tl from the staged tl source
regen-tl-types: .PLEDGE = stdio rpath wpath cpath proc exec
regen-tl-types: .UNVEIL = rx:$(o)/bootstrap r:lib r:3p rwcx:$(o) rwc:lib/types
regen-tl-types: $(o)/lib/types/gentl.lua $$(tl_staged) | $(bootstrap_cosmic)
	@$(bootstrap_cosmic) $(o)/lib/types/gentl.lua $(o)/tl/.staged/tl.tl > lib/types/tl.d.tl.tmp
	@mv lib/types/tl.d.tl.tmp lib/types/tl.d.tl
	@echo "wrote lib/types/tl.d.tl"
