The goals name zip in the fuzzed-parser list ("fuzzing the parsers
(json, re, url, zip, sse)"), and `cosmic/zip.tl` plus
`cosmic/zip_extract_test.tl` face untrusted archives — but `_fuzz/`
has no zip property (measured 2026-08-25: `ls _fuzz/` shows json,
re, url, sse, compress, tar, literal fuzz tests; no zip). A
malformed central directory, a truncated local header, a
path-traversal name, or a lying uncompressed-size field are exactly
the adversarial inputs the promise covers. Add `_fuzz/zip_fuzz_test.tl`
on the existing driver: generate/mutate archives (the tar fuzzer is
the structural precedent), assert no crash, no hang past the budget,
no write outside the extraction root, and decode/extract error
returns rather than throws.
