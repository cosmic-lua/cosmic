modules += types
# gentype_test.tl reads /zip/.lua/definitions.lua (embedded in the built cosmic
# binary via cosmos) and the committed lib/types/cosmo/*.d.tl, so it runs as a
# normal test under $(cosmic_bin). It guards the generator against drift, e.g.
# the errno-return contract in unix.d.tl (see test_errno_drift_unix).
types_tests := lib/types/gentype_test.tl
# types_deps is intentionally not set - types_files are source files (.d.tl),
# not built outputs. The regen-types target uses bootstrap_cosmic directly.
