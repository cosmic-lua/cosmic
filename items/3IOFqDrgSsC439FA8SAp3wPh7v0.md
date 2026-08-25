The 2026-08-25 literal-vs-json audit (main a0c4ebd, built binary)
established two properties worth keeping, and today nothing in the
tree pins them: every in-domain value round-trips
`parse(format(v))` exactly in BOTH layouts — byte-exact strings
including binary bytes and invalid UTF-8 (`string.char(0, 1, 27,
127, 128, 255)` comes back identical, where json silently mutates
it), integer/float subtype preserved (`1.0` stays a float, `42`
stays an integer), and the extremes hold (math.maxinteger,
math.mininteger, 1e308, -0.0, reserved-word keys, empty tables).
The audit ran these by hand; a property nobody committed is a win
the next change can silently lose. The capture: pin the round-trip
contract as a committed property — a generator over the literal
domain (string-keyed tables of strings with arbitrary bytes, finite
numbers of both subtypes, booleans, nesting to the cap) asserting
deep-equality and string byte-identity through `parse(format(v))`
under both `pin` and `compact` layouts, alongside or extending
`_fuzz/literal_fuzz_test.tl` (which today fuzzes the parse side
differentially, C vs Teal, not the format half); and state the
fidelity guarantee in cosmic/literal.tl's doc comment as verified
behavior — the byte-exactness and subtype preservation are the
module's selling points over json for config data and are currently
undocumented. The known depth-boundary defect is its own item; the
property test lands with the boundary excluded until that fix, then
tightens to the shared cap.
