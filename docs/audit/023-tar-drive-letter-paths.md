# 023 — tar path guard misses drive-letter names embed's guard rejects

severity: low
type: security hardening (windows), consistency
area: `cosmic/tar.tl`, `cosmic/embed/extract.tl`

## issue

`tar.unsafe_path` rejects empty, absolute, backslash-containing, and
`..`-containing names — but not `^%a:` drive-letter prefixes, which
`embed/extract.tl:42` (`unsafe_entry`) explicitly rejects for the same class
of input. verified: an archive entry named `C:/evil.txt` extracts — on POSIX
as a literal subdirectory named `C:`, harmless; on Windows a colon component
invites drive-relative and NTFS alternate-data-stream path semantics. the
backslash rejection does already catch `..\evil` shapes.

everything else about tar's security posture checked out empirically during
review: pax `path=../evil` rejected, absolute symlink targets rejected,
hardlinks rejected loudly, `..` and absolute names rejected, symlink targets
constrained to relative-no-`..` (no transitive escape found), checksums
verified, decompression capped at 512 MiB.

## where

- `cosmic/tar.tl:109` — `unsafe_path`, missing the drive-letter case.
- `cosmic/embed/extract.tl:42` — the sibling guard that has it.

## suggested fix

add the `^%a:` rejection to `unsafe_path`, matching `unsafe_entry`. the two
guards protect the same operation (writing archive-controlled names under a
dest); consider extracting one shared predicate so they cannot drift again.

## test to add

a tar test with an entry named `C:/evil.txt` asserting refusal.
