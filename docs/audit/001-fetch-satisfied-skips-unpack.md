# 001 — a verified archive permanently skips unpacking after a failed unpack

severity: high
type: bug
area: `_make/fetch.tl`

## issue

`satisfied()` decides whether a pin needs work by hashing only the *archive*
bytes at `landing(p)`. But for a pin that declares a `format`, the pin's real
output is the unpacked tree, and the archive is written to disk *before*
`unpacked()` runs. If unpacking fails once — ENOSPC, a kill mid-run, corrupt
zip contents — or the unpacked files are later deleted while the archive
survives, every subsequent `--make fetch` finds a correctly-hashing archive,
reports `fetch: PASS`, and never unpacks again.

## where

- `_make/fetch.tl:59-65` — `satisfied()` reads `landing(p)` and compares the
  sha256; it never looks at unpack products.
- `_make/fetch.tl:71-73` — `one()` early-returns `true` when `satisfied(p)`.
- `_make/fetch.tl:100-105` — the archive is written (`fs.write(out, ...)`)
  and only then `unpacked(p, out)` runs; a failure between the two leaves the
  poisoned state on disk.

## failure scenario

1. `cosmic --make fetch` downloads `o/3p/tl/v0.24.8.tar.gz`, digest matches,
   archive is written.
2. `unpacked()` fails (disk full, process killed, bad archive member).
3. every later `cosmic --make fetch` hashes the archive, says PASS, and
   `o/3p/tl/tl.lua` never exists — `build` then fails (or worse, uses a stale
   copy) with nothing pointing at fetch.

recovery today requires manually deleting the archive under `o/`.

## suggested fix

make `satisfied()` format-aware: for a pin with `format`, also require the
unpack products to exist (e.g. probe the first entry recorded at unpack time,
or a `<archive>.unpacked` stamp written only after `unpacked()` succeeds).
alternatively, run `unpacked()` unconditionally in the satisfied path — it
must then be idempotent and cheap when the tree already matches.

the docstring's claim ("an output that hashes correctly is the output") is
only true for format-less pins; keep the fast path for those.

## test to add

in `_make/fetch` tests: fetch a format pin, delete the unpacked tree but keep
the archive, run fetch again, assert the tree is restored. also: simulate a
failed unpack (unwritable dest) and assert the next fetch retries it.
