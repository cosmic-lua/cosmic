--- A test that reaches the filesystem for its inputs must say so.
---
--- `_make/imports.tl`'s `reads_scan` finds a test's dependencies by a
--- STATIC scan of its `--- reads:` header; it cannot see what a call
--- like `fs.glob()` enumerates at runtime. A `*_test.tl` that globs the
--- tree without declaring what it globbed gets a cached PASS that never
--- re-runs when those files change — the coverage stage's ratchet then
--- reports a clean floor over a tree it did not actually re-check. This
--- rule catches the gap: an undeclared `fs.glob()` call in a test file.

local imports = require("_make.imports")
local style = require("_tool.lint")

local type Diagnostic = style.Diagnostic

--- Files this rule does not apply to: each entry's `fs.glob()` calls are
--- audited to depend on nothing but a fixture the test itself builds
--- under `TEST_TMPDIR`, never the project tree.
local ALLOWLIST < const >: {string: boolean} = {
  -- exercises fs.glob() itself against a TEST_TMPDIR fixture; nothing
  -- in it depends on the project tree
  ["cosmic/fs/glob_test.tl"] = true,
  -- exercises this very rule: its fixture sources quote the literal
  -- `fs.glob(` the rule scans for, same as require_hints_test.tl
  -- quoting `require("cosmo...")` for check_cosmo_require
  ["_cli/reads_lint_test.tl"] = true,
}

--- Flag an undeclared `fs.glob()` call in a `*_test.tl` file.
---
--- Scope is `fs.glob` only (see the item's Non-goals): `fs.find`,
--- `fs.find_iter`, `fs.find_info`, `fs.visit` and computed `require`
--- targets are each a wider, unaudited trigger and are follow-up work.
--- @param file string Path, for the diagnostic message
--- @param content string The file's bytes
--- @param lines {string} The file's lines
--- @return {Diagnostic}
local function check_reads_declaration(file: string, content: string,
    lines: {string}): {Diagnostic}
  if not file:match("_test%.tl$") then
    return {}
  end
  if ALLOWLIST[file] then
    return {}
  end
  if #imports.reads_scan(content) > 0 then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  for i, line in ipairs(lines) do
    local col = line:find("fs%.glob%s*%(")
    if col then
      diagnostics[#diagnostics + 1] = {
        file = file,
        line = i,
        col = col,
        rule = "reads-declaration",
        message = string.format(
          "%s:%d: fs.glob() enumerates files with no '--- reads:'"
          .. " declaration; a static import scan can't see what it"
          .. " finds at runtime, so this test's cached PASS never"
          .. " re-runs when those files change — add '--- reads:"
          .. " <dir>' naming what the glob covers (see"
          .. " _make/imports.tl)", file, i),
      }
    end
  end
  return diagnostics
end

local record ReadsLintModule
  check_reads_declaration: function(file: string, content: string,
  lines: {string}): {Diagnostic}
end

local M: ReadsLintModule = {
  check_reads_declaration = check_reads_declaration,
}

return M
