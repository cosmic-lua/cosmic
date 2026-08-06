--- Render lint diagnostics with the offending source line beneath each
--- finding — the way fmt shows its have/want pair, so a file with nine
--- flagged casts is fixable from the terminal without opening it to
--- cross-reference line numbers.
---
--- Its own module rather than a new key on `_cli.lint`, deliberately: a
--- cold build's first generation runs under the PINNED release, whose
--- own `_cli.lint` is already loaded — a new key on that record fails
--- the strict compile of every caller until the pin catches up. A new
--- module name resolves from the tree everywhere, first generation
--- included.
local style = require("cosmic.style")

local type Diagnostic = style.Diagnostic

--- Render diagnostics for one file. file-length is the one rule about
--- the whole file rather than a line — and its target may not even be
--- text — so it gets no snippet; over-long lines truncate so one bad
--- line cannot flood the terminal.
--- @param path string The linted file, for reading the snippets
--- @param diagnostics {Diagnostic} What lint_file found
--- @return string The rendered text, newline-terminated ("" for none)
local function render_diagnostics(path: string,
    diagnostics: {Diagnostic}): string
  local lines: {string} = {}
  local f = io.open(path, "r")
  if f then
    for line in f:lines() do
      lines[#lines + 1] = line
    end
    f:close()
  end
  local out: {string} = {}
  for _, d in ipairs(diagnostics) do
    out[#out + 1] = string.format("%s:%d:%d: %s: %s",
      d.file, d.line, d.col, d.rule, d.message)
    if d.rule ~= "file-length" then
      local snippet = lines[d.line]
      if snippet then
        if #snippet > 120 then
          snippet = snippet:sub(1, 117) .. "..."
        end
        out[#out + 1] = "    | " .. snippet
      end
    end
  end
  if #out == 0 then
    return ""
  end
  return table.concat(out, "\n") .. "\n"
end

local record LintRenderModule
  render_diagnostics: function(path: string, diagnostics: {Diagnostic}): string
end

local M: LintRenderModule = {
  render_diagnostics = render_diagnostics,
}

return M
