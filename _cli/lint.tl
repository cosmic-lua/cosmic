--- The style gate behind `--check lint`, and so behind `--make lint`.
---
--- Two layers, split by what they may require. `_tool.lint` holds the
--- pure checks — file length, column width — because it is inside the
--- strip floor, where a STRIPPED artifact must still boot and there is
--- no Teal compiler to require. The checks that need the LEXER live
--- here, in the dispatcher, which a stripped artifact does not carry
--- anyway.
---
--- That split is the whole reason this file exists rather than the
--- checks living beside the ones they belong with. It also fixes what
--- the heuristic versions got wrong: counting `function`/`end` by
--- matching source lines counts the ones inside strings and comments
--- too, which produced 170 false positives on a tree that follows the
--- convention exactly.

local assert_lint = require("_cli.assert_lint")
local citations = require("_cli.citations")
local discover = require("_tool.discover")
local fs = require("cosmic.fs")
local pattern_args = require("_cli.pattern_args")
local reads_lint = require("_cli.reads_lint")
local returns = require("_cli.returns")
local style = require("_tool.lint")
local tl = require("tl")
local visibility = require("_cli.visibility")

local check_find_needle = pattern_args.check_find_needle
local check_gsub_replacement = pattern_args.check_gsub_replacement

local type Diagnostic = style.Diagnostic

--- Lines holding an `as` cast, token-exact so casts inside strings and
--- comments never count.
--- @param content string The file's bytes
--- @param file string Path, for the lexer's error messages
--- @return {integer} 1-based line numbers, each at most once
local function cast_lines(content: string, file: string): {integer}
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local seen: {integer: boolean} = {}
  local lines: {integer} = {}
  for _, t in ipairs(tokens) do
    if t.tk == "as" and not seen[t.y] then
      seen[t.y] = true
      lines[#lines + 1] = t.y
    end
  end
  return lines
end

--- Every `as` cast is an unchecked hole in the type system, so each one
--- must be deliberate and say why: a trailing `-- cast: <reason>`, or
--- one on the line directly above when 90 columns will not fit it.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @param lines {string} The file's lines
--- @return {Diagnostic} One per unjustified cast
local function check_cast_justification(file: string, content: string,
    lines: {string}): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  for _, y in ipairs(cast_lines(content, file)) do
    if not style.is_justified(lines, y, "cast") then
      diagnostics[#diagnostics + 1] = {
        file = file,
        line = y,
        col = 1,
        rule = "cast-justify",
        message = string.format(
          "%s:%d: `as` cast without justification: prefer `is` narrowing"
          .. " or check.must (see `cosmic --docs guide.checking`); a"
          .. " deliberate cast takes a trailing `-- cast: <reason>` (or on"
          .. " the line above)",
          file, y),
      }
    end
  end
  return diagnostics
end

--- Tests and examples must use cosmic.* wrappers, never raw cosmo.*
--- bindings (AGENTS.md "cosmo vs cosmic"). Each entry here needs the raw
--- layer for a reason the wrappers cannot provide; additions require the
--- same justification.
local COSMO_REQUIRE_ALLOWLIST < const >: {string: boolean} = {
  -- fault injection: monkey-patches unix.fork, so it must share the exact
  -- cosmo.unix module table that child.tl uses
  ["cosmic/child/init_test.tl"] = true,
  -- fault injection via the shared cosmo.unix table, plus a heredoc child
  -- payload that raises SIGKILL on itself
  ["cosmic/child/io_test.tl"] = true,
  -- exercises the require machinery itself, including raw cosmo modules
  ["_cli/require_hints_test.tl"] = true,
  -- raw-fd fixtures: sets up open file descriptors without going through
  -- the fs module under test
  ["cosmic/fs/init_test.tl"] = true,
  ["cosmic/fs/dir_test.tl"] = true,
  -- heredoc payload run inside a namespaced child process
  ["cosmic/quicksand/proc_test.tl"] = true,
  -- heredoc payloads exercising the script runner / compiler on sources
  -- that themselves use cosmo
  ["cosmic/script_test.tl"] = true,
  ["cosmic/compile_test.tl"] = true,
  -- fixture strings in this file quote the forbidden pattern itself
  ["_cli/lint_test.tl"] = true,
  -- third-party Teal compiler test scaffold
  ["3p/tl/tl_test.tl"] = true,
}

--- Flag require("cosmo") / require("cosmo.<mod>") in test and example
--- files. Only `cosmo` exactly or a `cosmo.` prefix counts — `cosmos`,
--- `cosmic` and the rest are unrelated modules.
--- @param file string Path, for the diagnostic
--- @param lines {string} The file's lines
--- @return {Diagnostic} One per offending require
local function check_cosmo_require(file: string, lines: {string}): {Diagnostic}
  if not (file:match("_test%.tl$") or file:match("_example%.tl$")) then
    return {}
  end
  if COSMO_REQUIRE_ALLOWLIST[file] then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  for i, line in ipairs(lines) do
    local col = line:find("require%s*%(%s*[\"']cosmo[\"'%.]")
    if col then
      diagnostics[#diagnostics + 1] = {
        file = file,
        line = i,
        col = col,
        rule = "cosmo-require",
        message = string.format(
          "%s:%d: require(\"cosmo...\") forbidden in tests/examples; "
          .. "use cosmic.* wrappers", file, i),
      }
    end
  end
  return diagnostics
end

--- A test file is all-or-nothing about self-calls (D29): every
--- `test_*` called on the line after its `end` is legacy mode, none
--- called is runner mode (the toolchain runs what discovery finds),
--- and a MIX is the one shape that must never pass — its uncalled
--- half would silently not run under legacy semantics. The walk
--- itself lives in `_tool.discover`, shared with the runner seam.
---
--- `test_*` only, and in `_test.tl` only. A test file's HELPERS are
--- defined once and called from several tests, and an `Example_*`
--- function is called by the example RUNNER rather than by its own
--- file — flagging either made the rule unsatisfiable rather than
--- enforced.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @param lines {string} The file's lines
--- @return {Diagnostic} One per uncalled definition in a mixed file
local function check_call_after_define(file: string, content: string,
    lines: {string}): {Diagnostic}
  if not file:match("_test%.tl$") then
    return {}
  end
  local found = discover.discover(file, content, lines)
  if found.mode ~= "mixed" then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  for _, case in ipairs(found.cases) do
    if not case.called then
      diagnostics[#diagnostics + 1] = {
        file = file,
        line = case.line,
        col = 1,
        rule = "call-after-define",
        message = string.format(
          "%s:%d: '%s' is not called immediately after its"
          .. " definition, and the file is not runner mode either."
          .. " A file picks ONE mode (D29): call every test on the"
          .. " line after its `end`, or call none of them anywhere",
          file, case.line, case.name),
      }
    end
  end
  return diagnostics
end

--- Declarations of the form `local x = nil` with no type annotation.
---
--- Teal infers such a local as the type `nil` — not "unknown yet", not
--- `T | nil` — so every later assignment and comparison fails, no
--- guard helps, and neither downstream error names the declaration as
--- the cause (gotcha 13). Flagging the declaration itself turns a
--- confusing far-away error into a one-line fix at the actual defect.
---
--- Scope: an unannotated declaration whose whole right-hand side is
--- `nil` (single or multi). A `:` anywhere before the `=` is an
--- annotation and passes; a mixed RHS (`local a, b = nil, 1`) is left
--- to the checker's error-site hint. Token-exact, so fixtures quoting
--- the trap inside strings never count.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @return {Diagnostic} One per nil-typed declaration
local function check_nil_declaration(file: string, content: string): {Diagnostic}
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  local i = 1
  while i <= #tokens do
    local t = tokens[i]
    if t.tk == "local" then
      -- Walk the declaration head: names, commas, and <attribute>
      -- groups. A `:` is an annotation (pass); anything else that is
      -- not a plain name list (local function, local record, ...) is
      -- some other statement (pass).
      local j = i + 1
      local head_ok = true
      while j <= #tokens do
        local tk = tokens[j].tk
        if tk == "=" then
          break
        elseif tk == ":" then
          head_ok = false
          break
        elseif tokens[j].kind == "identifier" or tk == ","
        or tk == "<" or tk == ">" or tk == "const" or tk == "close" then
          j = j + 1
        else
          head_ok = false
          break
        end
      end
      if head_ok and j <= #tokens and tokens[j].tk == "=" then
        -- The RHS, on the declaration's own line: all-nil means the
        -- inferred type is nil forever.
        local line = tokens[j].y
        local k = j + 1
        local saw_nil = false
        local all_nil = true
        while k <= #tokens and tokens[k].y == line do
          local tk = tokens[k].tk
          if tk == "nil" then
            saw_nil = true
          elseif tk ~= "," then
            all_nil = false
            break
          end
          k = k + 1
        end
        if saw_nil and all_nil then
          diagnostics[#diagnostics + 1] = {
            file = file,
            line = t.y,
            col = 1,
            rule = "nil-declaration",
            message = string.format(
              "%s:%d: a local initialized to nil with no type annotation"
              .. " has type nil FOREVER — every later assignment fails;"
              .. " annotate the optional: `local x: T | nil = nil`",
              file, t.y),
          }
        end
      end
    end
    i = i + 1
  end
  return diagnostics
end

--- Every style check, for one file.
---
--- `.d.tl` declarations are exempt: they describe C binding interfaces
--- and cannot be split under Teal's record system.
--- @param path string The file to check
--- @return {Diagnostic}|nil The findings, or nil when unreadable
--- @return string The error message
local function lint_file(path: string): {Diagnostic} | nil, string
  if path:match("%.d%.tl$") then
    return {}
  end
  -- A path that is not a regular file has nothing to lint: `.claude/skills`
  -- here is a symlink to a directory, and `git ls-files` lists it. Not the
  -- same as unreadable, which stays a failure below — the linter it
  -- replaced counted a directory as zero lines and reported it clean,
  -- which is the fail-open shape this distinction exists to avoid.
  if not fs.is_file(path) then
    return {}
  end
  local f, oerr = io.open(path, "r")
  if not f then
    return nil, oerr or ("cannot open " .. path)
  end
  local content = f:read("*a")
  f:close()
  if not content then
    return nil, "cannot read " .. path
  end
  if content == "" then
    return {}
  end

  local lines: {string} = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local n = #lines
  if n > 0 and lines[n] == "" then
    n = n - 1
  end

  local diagnostics = style.check_file_length(path, n, style.DEFAULT_FILE_LINES)
  -- A length failure on something that is not Teal/Lua source is almost
  -- never fixed by splitting the file: it is a binary or a data file the
  -- project walk swept in (lint reads bytes, deliberately), and the fix
  -- the model already provides is `.cosmicignore`. Say so in the
  -- diagnostic, where the reader is — the rule alone reads as "split
  -- your 90,000-line file" when the file is an ELF binary.
  if not (path:match("%.tl$") or path:match("%.lua$")) then
    local nature = content:find("\0", 1, true)
    and "a binary file, not text" or "not Teal/Lua source"
    for _, d in ipairs(diagnostics) do
      if d.rule == "file-length" then
        d.message = d.message .. " — " .. nature .. "; lint gates every"
        .. " file the project walk sees, so if this one should not be"
        .. " judged, list it in .cosmicignore"
      end
    end
  end
  if path:match("%.tl$") then
    for _, d in ipairs(check_cast_justification(path, content, lines)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(check_cosmo_require(path, lines)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(check_call_after_define(path, content, lines)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(check_find_needle(path, content)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(check_gsub_replacement(path, content, lines)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(check_nil_declaration(path, content)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(returns.check_fallible_returns(path, content)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(assert_lint.check_return_assert(path, content)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(assert_lint.check_assert_justification(path, content,
        lines)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(reads_lint.check_reads_declaration(path, content, lines)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(visibility.check_shard_require(path, lines)) do
      diagnostics[#diagnostics + 1] = d
    end
  end
  -- Prose is gated too: a document citing the tree by `file:line` is
  -- evidence a reader cannot re-derive, so the citation is checked the
  -- way a cast's justification is.
  if path:match("%.md$") then
    for _, d in ipairs(citations.check_citations(path, lines)) do
      diagnostics[#diagnostics + 1] = d
    end
  end
  return diagnostics
end

local record LintModule
  cast_lines: function(content: string, file: string): {integer}
  check_cast_justification: function(file: string, content: string, lines: {string}): {Diagnostic}
  check_cosmo_require: function(file: string, lines: {string}): {Diagnostic}
  check_call_after_define: function(file: string, content: string, lines: {string}): {Diagnostic}
  check_find_needle: function(file: string, content: string): {Diagnostic}
  check_gsub_replacement: function(file: string, content: string, lines: {string}): {Diagnostic}
  check_nil_declaration: function(file: string, content: string): {Diagnostic}
  check_fallible_returns: function(file: string, content: string,
  lines: {string}): {Diagnostic}
  check_reads_declaration: function(file: string, content: string,
  lines: {string}): {Diagnostic}
  check_return_assert: function(file: string, content: string): {Diagnostic}
  check_assert_justification: function(file: string, content: string,
  lines: {string}): {Diagnostic}
  lint_file: function(path: string): {Diagnostic} | nil, string
end

local M: LintModule = {
  cast_lines = cast_lines,
  check_cast_justification = check_cast_justification,
  check_cosmo_require = check_cosmo_require,
  check_call_after_define = check_call_after_define,
  check_find_needle = check_find_needle,
  check_gsub_replacement = check_gsub_replacement,
  check_nil_declaration = check_nil_declaration,
  check_fallible_returns = returns.check_fallible_returns,
  check_reads_declaration = reads_lint.check_reads_declaration,
  check_return_assert = assert_lint.check_return_assert,
  check_assert_justification = assert_lint.check_assert_justification,
  lint_file = lint_file,
}

return M
