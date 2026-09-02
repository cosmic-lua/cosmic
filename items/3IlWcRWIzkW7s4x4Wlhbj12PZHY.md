## Goal

G3 — an honest type layer. Three library iterator declarations put
the terminating nil in the iterator's first return type, so every
`for … in` body over them types its variable as `string | nil` and
seven census rows exist with no producing call to wrap.

## Evidence

Census Method (`docs/design/nil-flow.md`, `## Method`) re-run
2026-09-02 at `5a36e7c9` under a strict binary that reproduced the
Method's proof-of-life. Probe: `for x in it()` with `it(): function():
string | nil` flags `take(x)` at a `string` sink; the same with
`function(): string` does not — tl's own stdlib declares
`string.gmatch`'s iterator without the nil for this reason. The three
declarations and the rows they cause:

```text
cosmic/fs/find.tl:108   FileIter.__call: function(self: FileIter): string | nil, {string}
  -> cosmic/fs/path_test.tl:210, fs/traps_test.tl:159, fs/walk_example.tl:87,
     fs/walk_test.tl:89, fs/walk_test.tl:430
cosmic/stream.tl:56     type LineIter = function(): string | nil, string
  -> cosmic/net/io_test.tl:103
cosmic/fetch/body.tl:19,137   Body.lines(): function(): string | nil, string
  -> cosmic/fetch/stream_test.tl:69
```

The sweep children under 3IQfJ1tn close those rows on the test side
with `check.must(<var>)` at the use; that is the workaround, not the
fix. Re-measure at pull time with the Method's recipe recorded in
3IQfJ1tn's `## Enablement`.

## Change

Retype the three iterator declarations so the first return is the
plain element type (`string`), matching tl's stdlib convention for
`for … in` iterators; the terminating nil is the protocol, not a
value the body can see. `cosmic/fs/find.tl`, `cosmic/stream.tl`,
`cosmic/fetch/body.tl`, plus any `.d.tl` or doc line that spells the
old type. Then drop the corresponding `check.must(<var>)` wraps in
whichever sweep children have landed (or leave them; they are
harmless). A public-API type change: name it in the PR and in the
module docs.

## Non-goals

- No behaviour change to the iterators.
- No test-side edits beyond removing wraps made unnecessary.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- The Method's scan no longer reports the seven rows above (or their
  `check.must(<var>)` successors are removable without a new row).
