The three `-- cast: or fallback does not narrow` casts in
`_cli/build/init_test.tl` (lines 72-73, 144-145, 169-170 at main
`8f34339e`) are stale: the carried `narrow-or-fallback` patch already
narrows their exact shape. Probed 2026-08-26 (research 3ISKgwfn):
`local lua = (fs.read("x") or "")` followed by `lua:match(...)` and
`local lua: string = fs.read("x") or ""` both pass
`o/bin/cosmic --check types`; deleting all three casts and their
comments from the file itself passes `--check types` unchanged. The
slice: remove the three casts, regenerate `_build/casts_baseline.tl`
with the command the ratchet prints (the file's row drops 3), ci. The
cold-build rule does not bind — no new patch entry is involved; the
narrowing that admits the cast-free spelling is already in the pin's
successor and in the tree's own checker.
