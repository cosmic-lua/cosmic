# 024 — tar failure semantics: partial extraction, missing terminator accepted

severity: low
type: bug (contract/documentation), robustness
area: `cosmic/tar.tl`

## issue

two related contract gaps, both verified empirically:

1. **partial extraction on failure.** an archive whose third entry is
   refused (e.g. a hardlink) has already written its first entries into
   dest before `extract` returns `false, err`. callers must treat dest as
   scratch on failure; the pin/stage pipeline happens to, but the public
   API docs do not say so, and a downstream caller extracting into a live
   directory gets a half-written tree plus an error.
2. **missing end-of-archive terminator accepted.** the parser deliberately
   accepts an archive that ends without the two zero blocks
   (`cosmic/tar.tl:219`, commented). combined with a truncation that lands
   on a 512-byte block boundary *after* gzip decompression, that is a
   silent partial success. reachable only for crafted archives today (gzip
   integrity plus upstream sha pins cover accidental truncation), but it is
   a correctness hole in a public module.

## where

- `cosmic/tar.tl` — extraction loop writes entries as it goes; no cleanup
  or staging on failure.
- `cosmic/tar.tl:219` — terminator acceptance.

## suggested fix

1. document the partial-extraction contract in the module doc ("on failure,
   dest may contain a partial tree; extract into a fresh directory") — or
   extract into a temp sibling and rename on success, which upgrades the
   contract to atomic and matches the write-if-changed spirit elsewhere.
2. for the terminator: track whether the archive ended at a proper
   terminator and return an error (or at minimum a warning field) when it
   did not. an explicit opt-out flag could preserve compatibility with
   known terminator-less producers if any exist.

## test to add

(1) an archive failing mid-way, asserting the documented/atomic behavior;
(2) a block-aligned truncated archive asserting refusal once the
terminator check exists.
