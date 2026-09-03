## Change

`cosmic/codec_test.tl`, `test_latin1_roundtrip` (line 204 on origin/main): a
`check.must` rewrite kept the slot-1 narrowing and silently dropped the test's
slot-2 assertion. `check.must` (cosmic/check.tl:187) tests only `value == nil`;
it says nothing about slot 2, so `encode_latin1` returning `"…", "spurious"`
now passes a test that used to refuse it. Restore the slot-2 claim while
keeping the narrowing:

```teal
local function test_latin1_roundtrip()
  local original = "café résumé naïve"
  local encoded, err = codec.encode_latin1(original)
  assert(err == nil, "encode failed: " .. (err or ""))
  local decoded = codec.decode_latin1(check.must(encoded))
  assert(decoded == original, "roundtrip mismatch: got '" .. decoded .. "'")
end
```

`encode_latin1`'s contract is explicit about slot 2 (`return result, nil`,
cosmic/codec.tl:186) and D20 rule 11 / docs/decisions/d24-structured-failures.md
make "nothing in slot 2 on success" part of the fallible-return shape; the
file's own sibling tests still pin it (lines 26, 32, 38, 60), so this brings
line 204 back to the file's convention. No other file changes; the file is at
301 lines (`git show origin/main:cosmic/codec_test.tl | wc -l`).

The class, not the instance: the same sweep shape (a two-value binding plus
`assert(err == nil, …)` collapsed to `check.must(...)`) could recur in any
future nil-flow PR. The reviewer's check for it is one command over the PR:

```
git show --format='' -U0 <sha> | grep -n '^-' | grep -v '^[0-9]*:---' | grep -E 'err == nil'
```

Run it over the seven check.must sweep merges for this item's evidence (below);
it names exactly one site, this one. Record that command in the PR body so the
next sweep's reviewer runs it too.

## Evidence

Removed lines mentioning `err` or `assert` across the seven sweep merges
(`for c in 6677f0d1 c6359a85 52678da6 5031b0ff c60dcf19 e414a290 f2d7627d; do
git show --format='' -U0 $c | grep -n '^-' | grep -v '^[0-9]*:---' | grep -E
'err|assert'; done`):

```
27:-  local encoded, err = codec.encode_latin1(original)
28:-  assert(err == nil, "encode failed: " .. (err or ""))
47:-  data = assert(f:read(100))
48:-  assert(data == "01ABC56789", "write with offset result: got '" .. data .. "'")
27:-  local cerr: string = nil
62:-        local _ok, _err = fs.visit(tmpdir, function(e: fs.Entry, _ctx: any)
71:-            local st, serr = fs.stat(fs.join(tmpdir, "dir-" .. d, "file-" .. f .. ".txt"))
```

Only the first pair (5031b0ff, #1633, codec_test) asserted slot 2. The
fd_test pair (`data = assert(f:read(100))`) asserted slot 1 only, which
`check.must` preserves. The three remaining hits are declarations, not
assertions. The same grep widened to `err == nil|err\)|, err` over cf416d85,
63cc3a60 and 9fcfff3f finds one line, string_test's `str.to_integer(...)`
binding, which was not an assertion.

The pattern the test is being returned to is the file's own:
`git grep -n 'assert(.*err == nil' origin/main -- 'cosmic/codec_test.tl'`
lists lines 26, 32, 38, 60; tree-wide the same grep over `cosmic/*_test.tl`
counts 54 sites still holding a slot-2 assertion, so the sweep dropped one of
55, not a convention.

The contract being pinned: `git show origin/main:cosmic/codec.tl | sed -n
179,187p`

```
local function encode_latin1(str: string): string | nil, string
  ...
  return result, nil
end
```

What `check.must` checks: `git show origin/main:cosmic/check.tl | sed -n 187,198p`
shows `if value == nil then … error(...) end; return value` — slot 2 is read
only to build the error message.

## Non-goals

No change to `cosmic/codec.tl` or to `check.must`'s shape: a `must` that also
asserted slot 2 would refuse the bindings whose success tuples carry extra
data by design (`unix.wait`, `unix.accept`, `cosmo.Fetch`).
