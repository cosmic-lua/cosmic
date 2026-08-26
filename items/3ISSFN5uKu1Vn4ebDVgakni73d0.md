## Goal
G3 — an honest type layer, no escape hatches. The parent container
(3ISJI4Lg) enumerates four checker gaps that left casts behind; this
slice retires gap (2)'s three casts, which the carried
`narrow-or-fallback` patch already made unnecessary.

## Change
Delete the three `-- cast: or fallback does not narrow` casts in
`_cli/build/init_test.tl` and their comment lines, then regenerate the
casts floor.

Measured 2026-08-26 against `main` `ec794d44`, with `o/bin/cosmic`
built from that tree:

- `grep -rn "or fallback does not narrow" --include=*.tl . | grep -v "^./o/"`
  returns exactly 3 lines, all in `_cli/build/init_test.tl`, at lines
  72, 144 and 169 (the comment; the cast is on the line below each).
- `wc -l < _cli/build/init_test.tl` is 260 — 240 lines of headroom
  under the 500-line cap; this change only removes lines.
- `grep -n '_cli/build/init_test.tl' _build/casts_baseline.tl` is
  `3:  ["_cli/build/init_test.tl"] = 3,` — one row, count 3.

The three sites are two spellings of the same shape:

```teal
  -- cast: or fallback does not narrow
  local lua = (fs.read(out) or "") as string      -- line 72-73
  -- cast: or fallback does not narrow
  local written = (fs.read(out) or "") as string  -- lines 144-145, 169-170
```

Replace each two-line pair with the single cast-free line, keeping the
same local name and indentation:

```teal
  local lua = fs.read(out) or ""
  local written = fs.read(out) or ""
```

Then rewrite the committed floor with the command the ratchet's failure
message prints — `bin/cosmic --make run _build/casts.tl --baseline` —
and commit the result. `_build/casts.tl`'s `main` writes only files that
still hold casts, so the `_cli/build/init_test.tl` row is REMOVED from
`_build/casts_baseline.tl` rather than set to 0; that is the expected
diff, and no other row should move.

Probed 2026-08-26 on this tree: with all three casts and their comments
deleted, `o/bin/cosmic --check types _cli/build/init_test.tl` prints
`Type check passed: _cli/build/init_test.tl`. The file was restored
afterwards, so the tree at `ec794d44` still carries all three.

## Non-goals
- Do NOT touch `3p/tl/tl_patch.tl` or `_make/patch.tl`: no new patch
  entry is involved. The narrowing that admits the cast-free spelling
  is already carried, so the cold-build rule does not bind.
- Do NOT retire the parent's other three gaps (`pack.n`, closure
  carry-through, `metatable<any>`) — they are separate items under
  3ISJI4Lg.
- Do NOT add or change tests in `cosmic/teal_narrowing_test.tl`; the
  boundary this slice relies on is already pinned by the carried patch.
- Do NOT edit any other row of `_build/casts_baseline.tl` by hand, and
  do NOT weaken the casts ratchet in `_build/casts.tl` or
  `_build/casts_test.tl`.
- Do NOT change the assertions, test names, or behaviour of
  `_cli/build/init_test.tl`; only the two-line cast pairs move.

## Acceptance
- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _cli/build/init_test.tl` passes.
- `grep -c "cast:" _cli/build/init_test.tl` prints `0` (today: `3`).
- `grep -c "_cli/build/init_test.tl" _build/casts_baseline.tl` prints
  `0` (today: `1`).
- `git diff --stat origin/main` touches exactly two files:
  `_cli/build/init_test.tl` and `_build/casts_baseline.tl`.

## Enablement
none needed. The wrong turns a literal-minded session could take here
are already closed by gates and by this spec: the casts ratchet
(`_build/casts_test.tl`) fails loudly on a stale floor and prints the
exact regen command, `--check types` catches a mis-edited line, and
`--make ci` covers fmt and lint. The one non-mechanizable point — that
the baseline row DISAPPEARS rather than going to 0 — is stated in
`Change` and checked by the `grep -c` acceptance command.
