#!/usr/bin/env lua

-- The shared checks (file-length, column-length, call-after-define,
-- lint_file) live in cosmic.style — ONE implementation for both
-- `bin/make lint` and `cosmic --check-style`. The build invokes this
-- linter under the pinned bootstrap binary with LUA_PATH pointing at
-- this tree's freshly compiled modules (the doc/index.tl pattern), so
-- the delegation always runs THIS tree's style code, not the
-- bootstrap's embedded copy. This file adds only the build-side
-- checks: cast justification and the cosmo-require rule.
local proc = require("cosmic.proc")
local style = require("cosmic.style")
local tl = require("tl")

local type Diagnostic = style.Diagnostic

local function count_lines(path: string): integer
  local f = io.open(path, "r")
  if not f then
    return 0
  end
  local n = 0
  local ok = pcall(function()
      for _ in f:lines() do
        n = n + 1
      end
    end)
  f:close()
  if not ok then
    return 0
  end
  return n
end

-- Cast justification: every `as` cast is an unchecked hole in the type
-- system, so each one must be deliberate and say why. A line containing a
-- cast needs `-- cast: <reason>` either trailing on that line or as a
-- comment on the line directly above (for lines the 90-column width cannot
-- fit a trailing comment on). Detection is token-exact via the Teal lexer,
-- so casts inside strings and comments never count. This replaced the
-- count-ratchet (_build/casts.txt): a count pins how MANY holes exist,
-- a justification records WHY each one does, with no baseline bookkeeping.
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
      table.insert(lines, t.y)
    end
  end
  return lines
end

local function is_justified(lines: {string}, y: integer): boolean
  local here = lines[y]
  if here and here:match("%-%- cast: %S") then
    return true
  end
  local above = lines[y - 1]
  return above ~= nil and above:match("^%s*%-%- cast: %S") ~= nil
end

local function check_cast_justification(file: string, content: string,
    lines: {string}): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  for _, y in ipairs(cast_lines(content, file)) do
    if not is_justified(lines, y) then
      table.insert(diagnostics, {
          file = file,
          line = y,
          col = 1,
          rule = "cast-justify",
          message = string.format(
            "%s:%d: `as` cast without justification: prefer `is` narrowing"
            .. " or check.must (see CLAUDE.md); a deliberate cast takes a"
            .. " trailing `-- cast: <reason>` (or on the line above)",
            file, y),
        })
    end
  end
  return diagnostics
end

--- Tests and examples must use cosmic.* wrappers, never raw cosmo.* bindings
--- (AGENTS.md "cosmo vs cosmic"). These files are the enumerated exceptions
--- from the July audit's §1.7 — each needs the raw layer for a reason the
--- wrappers cannot provide. Additions here require the same justification.
local COSMO_REQUIRE_ALLOWLIST < const >: {string: boolean} = {
  -- fault injection: monkey-patches unix.fork, so it must share the exact
  -- cosmo.unix module table that child.tl uses
  ["cosmic/child/init_test.tl"] = true,
  -- fault injection via the shared cosmo.unix table, plus a heredoc child
  -- payload that raises SIGKILL on itself
  ["cosmic/child/io_test.tl"] = true,
  -- exercises the require machinery itself, including raw cosmo modules
  ["cosmic/require_test.tl"] = true,
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
  ["_build/lint_test.tl"] = true,
  -- third-party Teal compiler test scaffold
  ["3p/tl/tl_test.tl"] = true,
}

--- Flag require("cosmo") / require("cosmo.<mod>") in test and example files.
--- Only `cosmo` exactly or a `cosmo.` prefix counts — `cosmos`, `cosmic`,
--- etc. are unrelated modules.
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
      table.insert(diagnostics, {
          file = file,
          line = i,
          col = col,
          rule = "cosmo-require",
          message = string.format(
            "%s:%d: require(\"cosmo...\") forbidden in tests/examples; "
            .. "use cosmic.* wrappers",
            file, i
          ),
        })
    end
  end
  return diagnostics
end

--- Files exempt from lint: .d.tl type declaration files (they describe C
--- binding interfaces and cannot be split due to Teal's record system).
local function is_exempt(path: string): boolean
  return path:match("%.d%.tl$") ~= nil
end

local function main(...: string): integer
  local files: {string} = {...}
  if #files == 0 then
    io.stderr:write("usage: lint.lua FILE...\n")
    return 1
  end

  local all_diagnostics: {Diagnostic} = {}
  for _, file in ipairs(files) do
    -- The standalone lint binary enforces file-length (run on all tracked
    -- files), cast justification (.tl files), and cosmo-require
    -- (tests/examples). Column-length and assert-order are enforced via
    -- --check-style on .tl files (same cosmic.style implementation).
    if not is_exempt(file) then
      local n = count_lines(file)
      local diags = style.check_file_length(file, n, style.DEFAULT_FILE_LINES)
      for _, d in ipairs(diags) do
        table.insert(all_diagnostics, d)
      end
      if file:match("%.tl$") then
        local f = io.open(file, "r")
        if f then
          local content = f:read("*a")
          f:close()
          local lines: {string} = {}
          for line in ((content or "") .. "\n"):gmatch("([^\n]*)\n") do
            lines[#lines + 1] = line
          end
          for _, d in ipairs(check_cast_justification(file, content or "", lines)) do
            table.insert(all_diagnostics, d)
          end
          if file:match("_test%.tl$") or file:match("_example%.tl$") then
            for _, d in ipairs(check_cosmo_require(file, lines)) do
              table.insert(all_diagnostics, d)
            end
          end
        end
      end
    end
  end

  if #all_diagnostics == 0 then
    print("pass:")
    return 0
  end

  print(string.format("fail: %d issues", #all_diagnostics))
  print("")
  for _, d in ipairs(all_diagnostics) do
    print(string.format("%s:%d:%d: %s: %s", d.file, d.line, d.col, d.rule, d.message))
  end
  return 1
end

if proc.is_main() then
  os.exit(main(...))
end

return {
  Diagnostic = style.Diagnostic,
  DEFAULT_FILE_LINES = style.DEFAULT_FILE_LINES,
  DEFAULT_COLUMN_WIDTH = style.DEFAULT_COLUMN_WIDTH,
  count_lines = count_lines,
  -- shared checks: the same function objects cosmic --check-style uses
  check_file_length = style.check_file_length,
  check_column_length = style.check_column_length,
  check_call_after_define = style.check_call_after_define,
  lint_file = style.lint_file,
  -- build-side checks
  check_cosmo_require = check_cosmo_require,
  check_cast_justification = check_cast_justification,
  main = main,
}
