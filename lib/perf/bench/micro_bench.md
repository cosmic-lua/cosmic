# micro_bench

 CPU-bound scenarios: hashing, encoding, compression, string handling.
 Exercises the cosmo crypto/codec C bindings and pure-Lua cosmic.string
 code. Checks use known-answer vectors and round-trip properties, so a
 faster-but-wrong implementation fails instead of winning.
