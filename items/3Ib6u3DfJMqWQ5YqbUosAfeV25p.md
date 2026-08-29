## Change

Board ids gain a legible derived display: the raw id8 renders chunked,
and every item carries a hash-derived alias in an unambiguous
alphabet, accepted as input — all derived by pure function, never
stored.

Evidence, 2026-08-29: same-week KSUIDs share their leading display
characters (live board: 3IVLEO8M / 3IVUGuv6 / 3IVRNCFB side by side),
and base62's l/1/I and O/0 lookalikes make the distinguishing tail
hard to read and to retype. Measured: `wc -l < _work/store.tl` → 500
(AT the cap — resolution changes must not land there), `wc -l <
_work/gitboard.tl` → 296, `wc -l < _work/gitview.tl` and
`_work/gitshow.tl` have room.

The change, one new module plus render/dispatch touches:

1. `_work/alias.tl` (new, pure): `of(id: string): string` — Crockford
   base32 (alphabet 0123456789ABCDEFGHJKMNPQRSTVWXYZ) over the first
   40 bits of `cosmic.hash.sha256_hex(id)`'s bytes, rendered as two
   4-char chunks `XXXX-XXXX`; and
   `resolve(all: {item.Item}, input: string): string | nil, string` —
   case-insensitive match with Crockford input folding (i/l→1, o→0,
   hyphens ignored) over every item's alias, refusing on zero or
   (astronomically unlikely, still checked) multiple matches with the
   colliding ids named. Unit-tested pure: determinism, chunk shape,
   folding, the refusal arms.
2. Renders: `_work/gitview.tl` (status doing/todo lines, next's
   target line) and `_work/gitshow.tl` (the header) print the id8
   chunked `3Ib4-KH0q` and the alias after the title, e.g.
   `3Ib4-KH0q the slice [Q4TX-9GMD]` — exact placement decided by the
   existing line shapes; update the render tests in place.
3. Input: in `_work/gitboard.tl`'s id-resolution path, when
   `store.resolve` refuses AND the input matches alias shape
   (8 Crockford chars, optional hyphen), fall back to
   `alias.resolve` over `store.list`. `store.tl` is untouched (it is
   at the 500-line cap).

## Non-goals

Ids themselves, item filenames, commit subjects, and every verdict-
line and log grammar are UNCHANGED — the alias appears only in
`show`/`next`/status renders and as accepted input; it never enters
committed text (the log's fixed grammars are a parsing contract:
flowstats ships against them). No color rendering (considered and
rejected: not needed). No petname word list (considered and set
aside: same mechanics, worse density).
