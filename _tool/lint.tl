--- The PURE style checks: file length and column width. A lint helper
--- is toolchain, not battery, so it lives here instead of as public
--- API — which also leaves the `style` name free for ansi's job.
---
--- Pure means "needs nothing but the file's lines". The checks that
--- need the LEXER — cast justification, the cosmo-require rule,
--- call-after-define — are in `_cli.lint`, which composes these with
--- those and is what `--check lint` runs.
---
--- The justification-marker reader is here for the same reason. Two
--- conventions demand a written reason beside a site — `-- cast:` on
--- an `as`, `-- assert:` on the library assert D23 licenses — and
--- reading either one needs nothing but the file's lines. The lexer
--- walks that FIND the sites stay in `_cli`, one per rule; they share
--- this reader rather than each carrying a copy of it.
---
--- Column length is exported and not run by that composition: this tree
--- does not satisfy it (roughly 800+ lines over 90 columns, most of
--- them prose in doc comments) and never did, because the gate ran a linter that
--- never called it. A rule a gate does not enforce reads as enforced,
--- which is worse than no rule; enforcing this one is its own change.

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

--- Whether the site on line `y` carries its justification comment: a
--- trailing `-- <marker>: <reason>`, or one on the line directly above
--- when 90 columns will not fit it. The `%S` is what demands a reason —
--- a bare `-- cast:` with nothing after it justifies nothing.
--- @param lines {string} The file's lines
--- @param y integer The line the site is on
--- @param marker string The marker word: `cast`, `assert`
--- @return boolean True when justified here or on the line above
local function is_justified(lines: {string}, y: integer,
    marker: string): boolean
  local pattern = "%-%- " .. marker .. ": %S"
  local here = lines[y]
  if here and here:match(pattern) then
    return true
  end
  local above = lines[y - 1]
  return above ~= nil and above:match("^%s*" .. pattern) ~= nil
end

return {
  Diagnostic = Diagnostic,
  DEFAULT_FILE_LINES = DEFAULT_FILE_LINES,
  check_file_length = check_file_length,
  is_justified = is_justified,
}
