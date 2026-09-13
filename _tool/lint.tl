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

--- Whether a site spanning lines `y` through `yend` carries its
--- justification comment: a trailing `-- <marker>: <reason>` on ANY
--- line the site occupies, or one on the line directly above it when
--- 90 columns will not fit it. The `%S` is what demands a reason — a
--- bare `-- cast:` with nothing after it justifies nothing.
---
--- The span is what a multi-line site needs. The convention names the
--- token the rule is about — the `as`, the `assert` — and an author
--- writes the reason beside THAT, which on a cast whose expression
--- wraps is below the line the diagnostic anchors at. Searching the
--- site's whole extent finds it there without moving the anchor.
--- @param lines {string} The file's lines
--- @param y integer The site's first line
--- @param yend integer The site's last line; `y` for a single-line site
--- @param marker string The marker word: `cast`, `assert`, `throws`, `exits`
--- @return boolean True when justified anywhere in the span or on the line above
local function is_justified_span(lines: {string}, y: integer, yend: integer,
    marker: string): boolean
  local pattern = "%-%- " .. marker .. ": %S"
  local above = lines[y - 1]
  if above ~= nil and above:match("^%s*" .. pattern) ~= nil then
    return true
  end
  for i = y, yend do
    local here = lines[i]
    if here and here:match(pattern) then
      return true
    end
  end
  return false
end

--- Whether the single-line site on line `y` carries its justification
--- comment: `is_justified_span` over the one line `y`.
--- @param lines {string} The file's lines
--- @param y integer The line the site is on
--- @param marker string The marker word: `cast`, `assert`, `throws`, `exits`
--- @return boolean True when justified here or on the line above
local function is_justified(lines: {string}, y: integer,
    marker: string): boolean
  return is_justified_span(lines, y, y, marker)
end

--- Whether `file` is a `cosmic.*` library module — the only source the
--- library-doctrine rules (D23's assert licence, D30's throw/exit
--- boundary) govern. The paths the gate walks are repo-relative;
--- `/cosmic/` is deliberately NOT matched as well, because the
--- repository root directory is itself named `cosmic` and that pattern
--- would sweep the whole tree whenever a caller passes an absolute
--- path.
--- @param file string The path being linted
--- @return boolean True for library source, false for tests and examples
local function is_library_source(file: string): boolean
  if not file:match("^cosmic/") then
    return false
  end
  return not (file:match("_test%.tl$") or file:match("_example%.tl$"))
end

return {
  Diagnostic = Diagnostic,
  DEFAULT_FILE_LINES = DEFAULT_FILE_LINES,
  check_file_length = check_file_length,
  is_justified = is_justified,
  is_justified_span = is_justified_span,
  is_library_source = is_library_source,
}
