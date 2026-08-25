The mechanism the decoded-data shaping class is missing: a validator
that takes an already-decoded value and hands it back as a declared
record, with the fields checked.

`json.decode_object` and `json.decode_array` (`cosmic/json.tl:135`,
`:155`) type the outermost table and stop; nothing in the tree turns a
decoded table into a declared record. Measured 2026-08-25 against
`5cd43b78`: the parent's 61 sites carry 44 that are field reads
underneath a decoded value, and only 3 that a `decode_object` call
change alone would close (`_eval/stage_test.tl:77`, `:95`, and the
already-redundant cast at `_eval/score_test.tl:39`) — so the missing
API, not the existing calls, is what closes this class.

**The API cannot be a decode function.** 17 of the 61 sites never call
`json.decode`: the value arrives from `literal.parse`
(`cosmic/literal_test.tl` 7, `_make/pin_test.tl` 2), a loaded chunk
(`cosmic/teal_config_test.tl:15` via `loadfile`,
`_tool/coverage/report.tl:227` via `pcall(chunk)`), or
`Response:json()` (`_perf/baseline.tl:154`,
`cosmic/fetch/verbs_test.tl:205`). Command:

```text
git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"
```

So the mechanism validates an `any` that is already decoded, and the
decoders keep their current signatures. Teal has no runtime reflection
over record fields, so the target shape must be described at runtime by
a value the caller passes — which is the design question this item
exists to settle: what that description looks like, how it composes
(nested tables, arrays, optional fields, unions with nil), what it
returns on failure (a `string`, or a structured `Failure` per D24), and
where it lives (`cosmic.json`, `cosmic.literal`, or a new module both
can point at).

That is a public-API tradeoff with alternatives worth recording, so
refinement should decide whether this earns a `docs/decisions/` record
(the `decide` skill) and, if so, whether the record lands as its own
slice ahead of the implementation.

Non-goals to carry forward: no change to `json.decode`,
`json.decode_object`, `json.decode_array` or `literal.parse` return
contracts, and no call-site conversions in this item — the parent's two
sibling items do that, and a validator that lands inside the PR that
also consumes it proves nothing.
