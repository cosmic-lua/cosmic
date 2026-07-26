# 021 — `strip_into` silently drops symlinks tar deliberately preserved

severity: low
type: bug (silent data loss)
area: `_make/extract.tl`, `cosmic/tar.tl`

## issue

`cosmic.tar` validates and writes archive-internal symlinks (relative,
no-`..` targets are allowed by design — `cosmic/tar.tl:149-154`). but the
pin pipeline's `strip_into` walks the unpacked staging tree with
`AT_SYMLINK_NOFOLLOW` and copies only `is_file()` entries, so every symlink
tar preserved is silently missing from the pin's final tree. no warning, no
error.

## where

- `_make/extract.tl:34-81` — the walk-and-copy; only regular files copied.
- `cosmic/tar.tl:149-154` — the symlink support that becomes dead weight.

## failure scenario

a pinned tarball uses the common `lib/libfoo.so -> libfoo.so.1` shape, or a
versioned-file-plus-alias layout. the unpack succeeds, the pin reports
satisfied, and the tree under `o/` is missing the links — failures surface
later, far from fetch, as missing files.

## interaction

deliberate symlink-freedom of fetched trees is currently a *mitigation* for
013 (`exec`'s lexical root check). if this issue is fixed by preserving
symlinks, fix 013 (realpath check) first. if it is fixed by refusing
symlinks loudly, note that in tar's docs instead.

## suggested fix

pick a contract and enforce it loudly: either (a) `strip_into` re-creates
relative symlinks (after 013's realpath fix lands), or (b) it returns an
error naming the first symlink it will not carry, so the pin fails at fetch
time with a message rather than later with an absence. today's silent drop
is the only wrong option.

## test to add

an extract test whose staging tree contains a relative symlink, asserting
whichever contract is chosen (link present, or loud refusal).
