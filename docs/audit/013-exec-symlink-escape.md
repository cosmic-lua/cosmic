# 013 — `exec` root check is lexical; a symlink under `o/` escapes it

severity: low/medium
type: security (guarantee weaker than stated)
area: `_cli/build/steps.tl`

## issue

`do_exec` computes `fs.abspath(program)` and prefix-checks it against
`fs.abspath(COSMIC_EXEC_ROOT)`. `fs.abspath` normalizes `..` and correctly
rejects absolute paths outside the root (both are tested), but it does
**not** resolve symlinks (documented at `cosmic/fs/path.tl:195-201`). a
symlink `o/tool -> /bin/sh` has an abspath under the root, passes the check,
and the kernel follows it at spawn — so the design's guarantee ("`exec`
resolves only to pinned bytes under `o/`, never PATH", make.md) is stronger
than the check enforces.

## where

- `_cli/build/steps.tl:376-386` — the prefix check on `fs.abspath`.
- mitigations that keep in-repo exploitability low: `o/` symlinks are
  build-controlled (the `link` verb; `bin/make`'s `ln -sf cosmic
  o/bootstrap/lua`), and fetched trees carry no symlinks at all —
  `_make/extract.tl:37-39` copies only regular files out of staging.

## failure scenario

anything that can create a symlink under `o/` (a hostile recipe using the
`link` verb, a compromised generator, or a pin format that later preserves
symlinks — see 021, which proposes exactly that) can point `exec` at any
host binary, defeating the pinned-bytes-only property that is one of the
design's two load-bearing security claims.

## suggested fix

resolve the program with realpath (follow symlinks) before the prefix check,
and check the *resolved* path against the resolved root. cosmopolitan
exposes realpath; if a wrapper is missing in `cosmic.fs`, add one. note the
interaction with 021: if `strip_into` starts preserving symlinks, this fix
becomes a prerequisite, not an option.

## test to add

in `_cli/build/init_test.tl` beside the existing `..`/absolute cases: create
`o/evil -> /bin/sh` (or a test-local outside binary) and assert `exec evil`
is refused.
