--- A test that reaches the filesystem for its inputs must say so.
---
--- `_make/imports.tl`'s `reads_scan` finds a test's dependencies by a
--- STATIC scan of its `--- reads:` header; it cannot see what a call
--- like `fs.glob()` enumerates at runtime. A `*_test.tl` that globs the
--- tree without declaring what it globbed gets a cached PASS that never
--- re-runs when those files change — the coverage stage's ratchet then
--- reports a clean floor over a tree it did not actually re-check. This
--- rule catches the gap: an undeclared `fs.glob()` call in a test file.

local fs = require("cosmic.fs")
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

--- Whether a `--- reads:` token names a path under `o/` at all (`o`
--- itself, or anything starting `o/`) — the shape a build output has.
--- A path that merely CONTAINS `/o/` (a directory named `o` nested
--- somewhere else) is not this: only the leading segment matters.
--- @param token string One whitespace-separated token from a `reads:` line
--- @return boolean
local function is_o_path(token: string): boolean
  return token == "o" or token:match("^o/") ~= nil
end

--- Whether `prefix` (an `o/`-relative path with no trailing ".tl") is a
--- binary's payload generator: `cmd/<name>/embed_gen`. It packs what
--- the graph produced (AGENTS.md: "the other way round: it packs what
--- the graph produced, so it runs last"), so its output directory is
--- exactly the build-output case this rule exists to catch, not a
--- pre-graph input, even though `<name>/embed_gen.tl` exists.
--- @param prefix string Path relative to the project root
--- @return boolean
local function is_embed_gen(prefix: string): boolean
  return prefix:match("^cmd/[^/]+/embed_gen$") ~= nil
end

--- The prefix of `rest` (an `o/`-relative path, `reads:`'s token with
--- its leading `o/` stripped) that is a generator's own output
--- directory, or nil when no segment of `rest` is one.
---
--- A `*_gen.tl` at `<dir>/<stem>_gen.tl` runs before the graph and
--- writes its output to `o/<dir>/<stem>_gen/` (AGENTS.md: "generators
--- run before the graph"), so that directory always exists by the time
--- a graph-touching verb checks a `reads:` declaration, cold tree
--- included — unlike an ordinary build output, which the SAME graph
--- run produces after checking declarations. Scanning left to right and
--- stopping at the first segment ending `_gen` whose own `.tl` file
--- exists finds that directory regardless of how much of `rest` names
--- a path beneath it.
--- @param rest string An `o/`-relative path, without the leading `o/`
--- @return string|nil The matched prefix, relative to the project root
local function generator_output_prefix(rest: string): string | nil
  local segments: {string} = {}
  for segment in rest:gmatch("[^/]+") do
    segments[#segments + 1] = segment
  end
  for i, segment in ipairs(segments) do
    if segment:match("_gen$") then
      local prefix = table.concat(segments, "/", 1, i)
      if fs.is_file(prefix .. ".tl") then
        return prefix
      end
    end
  end
  return nil
end

--- Whether an `o/`-shaped `--- reads:` token names a genuine build
--- OUTPUT rather than one of the two pre-graph inputs AGENTS.md
--- documents: the trust-root bootstrap (`o/bootstrap/**`, "no verb
--- reproduces it") and a generator's own output directory (above) —
--- everything else under `o/` is produced by the SAME graph run that
--- would need to check the declaration, so it can never exist on a
--- cold tree. `_make/imports.tl` (`reads_of_file`) already refuses such
--- an entry, but only when the graph is built, so it passes a warm `o/`
--- and fails only CI's cold-tree `build` lane (the cold-build rule).
--- @param token string An `is_o_path` token, its leading `o/` still on
--- @return boolean
local function names_build_output(token: string): boolean
  if token == "o/bootstrap" or token:match("^o/bootstrap/") then
    return false
  end
  local rest = token:match("^o/(.+)$")
  if not rest then
    return true -- bare "o" names no pre-graph input
  end
  local prefix = generator_output_prefix(rest)
  return not (prefix and not is_embed_gen(prefix))
end

--- Flag a `reads:` header entry that names a build output, at the
--- header line it appears on.
--- @param file string Path, for the diagnostic message
--- @param lines {string} The file's lines
--- @return {Diagnostic}
local function check_reads_output_path(file: string,
    lines: {string}): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  for i, line in ipairs(lines) do
    local rest = line:match("^%-%-%- reads: (.+)$")
    if rest then
      for token in rest:gmatch("%S+") do
        if is_o_path(token) and names_build_output(token) then
          diagnostics[#diagnostics + 1] = {
            file = file,
            line = i,
            col = line:find(token, 1, true) or 1,
            rule = "reads-declaration",
            message = string.format(
              "`reads: %s` names a build output, which does not exist"
              .. " on a cold tree; derive it in-process from the tree"
              .. " (the generator's own module) or declare the SOURCES"
              .. " it is built from", token),
          }
        end
      end
    end
  end
  return diagnostics
end

--- Flag an undeclared `fs.glob()` call, and a `reads:` header entry
--- naming a build output, in a `*_test.tl` file.
---
--- Scope for `fs.glob` is that call only (see the item's Non-goals):
--- `fs.find`, `fs.find_iter`, `fs.find_info`, `fs.visit` and computed
--- `require` targets are each a wider, unaudited trigger and are
--- follow-up work.
--- @param file string Path, for the diagnostic message
--- @param content string The file's bytes
--- @param lines {string} The file's lines
--- @return {Diagnostic}
local function check_reads_declaration(file: string, content: string,
    lines: {string}): {Diagnostic}
  if not file:match("_test%.tl$") then
    return {}
  end
  local diagnostics: {Diagnostic} = check_reads_output_path(file, lines)
  if ALLOWLIST[file] then
    return diagnostics
  end
  if #imports.reads_scan(content) > 0 then
    return diagnostics
  end
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
