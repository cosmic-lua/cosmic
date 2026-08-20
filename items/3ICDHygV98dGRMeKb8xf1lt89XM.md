## Evidence

2026-08-20 audit at main 0b2907b9, by reading. `_fuzz/url_fuzz_test.tl:122-135`
`encode_params` iterates `pairs(params)`; Lua 5.4's string hash seed
varies per process, so the same draw sequence encodes params in
different orders in different processes. In-process replay and shrink
are unaffected and the reported base64 input is self-contained, but
crash-BISECTION probes and the parent's input reconstruction
(driver.tl:267-270) regenerate the input in other processes, and the
module-doc promise "rerunning with FUZZ_SEED=<seed> reaches the same
input" (driver.tl:6-8) does not hold for this generator. Fix shape:
sort keys before encoding in the gen (the property tests round-trip,
not order).
