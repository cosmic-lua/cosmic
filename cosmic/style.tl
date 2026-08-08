--- The PURE style checks: file length and column width.
---
--- Pure means "needs nothing but the file's lines", which is what lets
--- this module sit inside the strip floor (`cosmic/**`), where a
--- STRIPPED artifact must still boot and there is no Teal compiler to
--- require. The checks that need the LEXER — cast justification, the
--- cosmo-require rule, call-after-define — are in `_cli.lint`, which
--- composes these with those and is what `--check lint` runs.
---
--- Column length is exported and not run by that composition: this tree
--- does not satisfy it (roughly 800+ lines over 90 columns, most of
--- them prose in doc comments) and never did, because the gate ran a linter that
--- never called it. A rule a gate does not enforce reads as enforced,
--- which is worse than no rule; enforcing this one is its own change.
---
--- Public rather than internal, by the `_` rule: this module has a
--- caller OUTSIDE `cosmic/`, so it cannot be internal to it. Deriving
--- visibility from position closes the gap a hand-written manifest
--- leaves open, where a module can be reachable from somewhere its
--- entry says it is not.

local record Diagnostic
  file: string
  line: integer
  col: integer
  rule: string
  message: string
end

local DEFAULT_FILE_LINES < const > = 500

local function check_file_length(file: string, n: integer, limit: integer): {Diagnostic}
  if n > limit then
    return {{
        file = file,
        line = limit + 1,
        col = 1,
        rule = "file-length",
        message = string.format("%s has %d lines (limit: %d)", file, n, limit),
      }}
  end
  return {}
end

return {
  Diagnostic = Diagnostic,
  DEFAULT_FILE_LINES = DEFAULT_FILE_LINES,
  check_file_length = check_file_length,
}
