`_build/nil_returns_baseline.tl` records 136 `return nil` sites across 58 files
whose declared slot 1 cannot be nil. The gate that counts them stops the class
growing; nothing drives it down, and the floor only moves by hand.

Three kinds are present and they take different fixes, so this is a decomposed
sweep rather than one pass:

1. **A `boolean, string` effect returning `nil, err`** where the house rule is
   `false, msg` (`_docs/publish.tl:190,193`, `_make/extract.tl:56,62,89`). The
   fix is `return false, ...` and it changes no caller: nil and false are both
   falsy.
2. **A signature whose doc comment already states the honest type**
   (`_eval/journal.tl:168` declares `: boolean` under `@return boolean|nil`).
   The fix is to widen the signature to what the comment says, and each one
   may make the checker demand narrowing at existing call sites — which is the
   point, and the work.
3. **A function whose `nil` means success**, returning an error string
   (`_perf/bench/embed_bench.tl:72`, `cosmic/quicksand/proxy/rules.tl`). The
   honest declaration is `string | nil`, and callers already treat the result
   as optional.

The largest single files are `_docs/publish.tl` 12, `_perf/bench/embed_bench.tl`
8, `cosmic/flags/parse.tl` 7. `cosmic/**` carries roughly a quarter of the
total, and those matter most: they are the published API, and the honest-nil
doctrine is theirs to keep.

Cut this by kind or by tree, not all at once — each slice lowers the floor with
`bin/cosmic --make run _build/nil_returns.tl --baseline`, and the ratchet
refuses a floor that no longer matches, so a partial sweep cannot silently
stall.
