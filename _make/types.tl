--- Shared type definitions for the `cosmic --make` project model.
---
--- A project is a directory tree; filenames and directory positions
--- declare intent. These records are what the walk produces and what
--- every verb consumes, so they are the contract between the model
--- (project.tl), the validator (validate.tl), and the verbs.

local record make_types

  --- What a discovered file declares, derived from its name and
  --- position. One file has exactly one kind.
  ---
  ---   module    a package source (.tl/.lua) — compiled and embedded
  ---   entry     main.tl at the root, or cmd/<name>/main.tl — a binary
  ---   test      *_test.tl
  ---   example   *_example.tl
  ---   types     *.d.tl — type-only; on the include path, never embedded
  ---   pin       *.pin.tl — a pinned external asset, data not code
  ---   gen       *.gen.tl — a generation unit
  ---   testdata  anything under a testdata/ directory — never embedded
  ---   payload   anything under embed/ — embedded at its path INSIDE
  ---             embed/, which is how a project puts a file somewhere
  ---             the one layout rule would not
  ---   asset     everything else — embedded at its relative path
  enum Kind
    "module"
    "entry"
    "test"
    "example"
    "types"
    "pin"
    "gen"
    "testdata"
    "payload"
    "asset"
  end

  --- One discovered file.
  record File
    --- Path relative to the project root, with `/` separators.
    path: string
    --- What this file declares.
    kind: Kind
    --- Import path (`pkg/db.tl` -> `pkg.db`, `pkg/init.tl` -> `pkg`),
    --- or nil for kinds that are never required (asset, testdata, pin,
    --- gen).
    import: string
    --- For an entry: the artifact name it builds (`o/bin/<name>`).
    binary: string
  end

  --- One artifact the project builds.
  record Binary
    --- Artifact name; `o/bin/<name>`.
    name: string
    --- Directory the entry lives in, relative to the root ("" for the
    --- root binary, `cmd/<name>` otherwise).
    dir: string
    --- Path to the entry source, relative to the root.
    entry: string
  end

  --- A scanned project.
  record Project
    --- Absolute path to the project root.
    root: string
    --- Every discovered file, sorted by path.
    files: {File}
    --- Every artifact, sorted by name.
    binaries: {Binary}
  end

  --- One validator complaint. `path` is relative to the root and names
  --- the file (or directory) the complaint is about.
  record Issue
    path: string
    message: string
  end

  --- Kinds a `.tl` file must be to reach the format gate.
  ---
  --- Two consumers ask this question -- the facts writer, which emits
  --- `fmt_sources` for the whole project, and the `fmt` verb's
  --- selection table -- and they used to answer it differently: one by
  --- kind, the other by suffix. A full `fmt` then gated `testdata/`
  --- fixtures and `embed/` payload that a selected `fmt` skipped,
  --- which are exactly the two kinds whose job is to stay out of the
  --- model. One definition, both readers.
  fmt_kinds: {string: boolean}
end

make_types.fmt_kinds = {
  module = true,
  entry = true,
  test = true,
  example = true,
  gen = true,
  pin = true,
  types = true,
}

return make_types
