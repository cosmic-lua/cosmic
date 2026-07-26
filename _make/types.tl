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
  ---   gen       *.gen.tl — a generation unit, scoped to its own
  ---             directory's subtree, run by `regen`
  ---   payload-gen  embed.gen.tl — a BINARY's payload generator: scoped
  ---             to the binary, run by `build`, writes `o/<unit>/`
  ---   testdata  anything under a testdata/ directory — never embedded
  ---   payload   anything under embed/ — embedded at its path INSIDE
  ---             embed/, which is how a project puts a file somewhere
  ---             the one layout rule would not
  ---   asset     everything else — part of the project, NOT of its
  ---             artifacts. Shipping is opt-in: `embed/**` is where a
  ---             non-module file says it belongs in the binary
  enum Kind
    "module"
    "entry"
    "test"
    "example"
    "types"
    "pin"
    "gen"
    "payload-gen"
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

  --- Which files a graph verb acts on, and the make variable a
  --- selection overrides. A command-line assignment beats the one in
  --- `o/project.mk`, so selection needs no rules of its own:
  --- everything downstream is derived from these lists.
  record Selection
    kinds: {Kind}
    --- Suffix a candidate's path must end with, or nil for no filter.
    ---
    --- nil rather than "": the empty string spelled "unfiltered" only
    --- by convention, and the natural comparison for it --
    --- `path:sub(-#"")` -- is `sub(-0)`, which is `sub(0)`, which is
    --- the WHOLE string. So the obvious code silently matched nothing
    --- and the guard against it lived in a comment. The type says it
    --- now.
    suffix: string | nil
    variable: string
  end

  --- One verb: everything the dispatcher, the usage text and the
  --- planned-verb stub need to know about it, in one row.
  ---
  --- Adding a verb used to mean editing two lists, up to two maps and
  --- an if-chain in `run`, with which mechanism a verb belonged to
  --- discoverable only by reading the dispatch. Most of the remaining
  --- verbs are POLICY verbs (orchestration, not graph targets), so on
  --- that shape each would have become another branch. The registry is
  --- also the data structure `ci` needs: a fixed order of stages is a
  --- list of verb names only if verbs are values.
  record Verb
    --- The name typed on the command line.
    name: string
    --- Defined by the design, not shipped yet.
    planned: boolean
    --- The make target this verb lowers onto, when it is a graph verb.
    target: string | nil
    --- What paths select, for a graph verb.
    select: Selection | nil
    --- The in-process implementation. A verb with no `target` is
    --- entirely this; a verb with both lowers onto the graph *and* has
    --- work of its own around it (`build` assembles after, `test`
    --- assembles before), and its runner is what orders the two.
    run: function(proj: Project, paths: {string}, cosmic: string): integer
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
  fmt_kinds: {Kind: boolean}
end

make_types.fmt_kinds = {
  module = true,
  entry = true,
  test = true,
  example = true,
  gen = true,
  ["payload-gen"] = true,
  pin = true,
  types = true,
}

return make_types
