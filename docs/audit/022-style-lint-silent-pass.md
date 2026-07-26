# 022 — `style.lint_file` silently passes files it cannot read

severity: low
type: bug (error handling)
area: `cosmic/style.tl`

## issue

`lint_file` returns an empty findings table when `io.open` fails or the read
returns nothing — indistinguishable from "file is clean". a lint sweep over
a path with a permission error, or a file deleted mid-run, reports success.
this violates the repo's "never silently discard errors" rule, and the
module is now public API (promoted in 3c), so downstream callers inherit
the trap. the CLI handler happens to pre-check openability, but the library
contract itself does not.

## where

- `cosmic/style.tl:141-149` — `io.open`/read failure path returns `{}`.

## failure scenario

`bin/make lint` (or any downstream tool using `cosmic.style`) sweeps a tree
containing an unreadable file. the sweep passes; the file was never
checked. in a gate whose job is "every file obeys the caps", an unreadable
file is a fail-open.

## suggested fix

give `lint_file` an honest failure channel: return `nil, err` on open/read
failure (`{Finding}|nil, string`), and update callers to treat nil as a
gate failure naming the file. an empty findings table then always means
"read and clean".

## test to add

a style test on a nonexistent path (and, where the host permits, an
unreadable one) asserting `nil, err` rather than `{}`.
