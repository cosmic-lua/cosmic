modules += types
# Note: gentype_test.tl requires /zip/.lua/definitions.lua from cosmopolitan
# and is not included in regular tests. Run manually with: cosmic lib/types/gentype_test.tl
# types_deps is intentionally not set - types_files are source files (.d.tl),
# not built outputs. The regen-types target uses bootstrap_cosmic directly.
