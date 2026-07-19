#!/usr/bin/env lua

-- The shared checks (file-length, column-length, call-after-define,
-- lint_file) live in cosmic.cli.style — ONE implementation for both
-- `bin/make lint` and `cosmic --check-style`. The build invokes this
-- linter under the pinned bootstrap binary with LUA_PATH pointing at
-- this tree's freshly compiled modules (the doc/index.tl pattern), so
-- the delegation always runs THIS tree's style code, not the
-- bootstrap's embedded copy. This file adds only the build-side
-- checks: the cast ratchet and the cosmo-require rule.
local proc = require("cosmic.proc")
local style = require("cosmic.cli.style")
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

-- Cast ratchet: per-file `as` cast counts, pinned by lib/build/casts.txt
-- (count<TAB>path, sorted; files absent from the list are pinned at 0).
-- Counting is token-exact via the Teal lexer, so casts inside strings and
-- comments never count. The pin is two-sided: growth fails (prefer `is`
-- narrowing, or raise the entry deliberately), and improvement fails until
-- the baseline is lowered (`bin/make casts-baseline`) so headroom cannot
-- accumulate for later regressions.
local CASTS_BASELINE < const > = "lib/build/casts.txt"

local function load_casts_baseline(): {string: integer}
  local base: {string: integer} = {}
  local f = io.open(CASTS_BASELINE, "r")
  if not f then
    return base
  end
  for line in f:lines() do
    local n, path = line:match("^(%d+)\t(.+)$")
    local count = n and tonumber(n)
    if count then
      base[path] = math.tointeger(count)
    end
  end
  f:close()
  return base
end

local function count_casts(content: string, file: string): integer
  local tokens = tl.lex(content, file)
  if not tokens then
    return 0
  end
  local n = 0
  for _, t in ipairs(tokens) do
    if t.tk == "as" then
      n = n + 1
    end
  end
  return n
end

local function check_cast_ratchet(file: string, content: string, base: {string: integer}): {Diagnostic}
  local count = count_casts(content, file)
  local pinned = base[file] or 0
  if count > pinned then
    return {{
        file = file,
        line = 1,
        col = 1,
        rule = "cast-ratchet",
        message = string.format(
          "%s has %d `as` casts (pinned at %d): prefer `x is Rec` narrowing"
          .. " (see CLAUDE.md), or raise lib/build/casts.txt deliberately",
          file, count, pinned),
      }}
  elseif count < pinned then
    return {{
        file = file,
        line = 1,
        col = 1,
        rule = "cast-ratchet",
        message = string.format(
          "%s improved to %d `as` casts (pinned at %d): run"
          .. " 'bin/make casts-baseline' to lock it in",
          file, count, pinned),
      }}
  end
  return {}
end

--- Tests and examples must use cosmic.* wrappers, never raw cosmo.* bindings
--- (AGENTS.md "cosmo vs cosmic"). These files are the enumerated exceptions
--- from the July audit's §1.7 — each needs the raw layer for a reason the
--- wrappers cannot provide. Additions here require the same justification.
local COSMO_REQUIRE_ALLOWLIST < const >: {string: boolean} = {
  -- fault injection: monkey-patches unix.fork, so it must share the exact
  -- cosmo.unix module table that child.tl uses
  ["lib/cosmic/child/init_test.tl"] = true,
  -- fault injection via the shared cosmo.unix table, plus a heredoc child
  -- payload that raises SIGKILL on itself
  ["lib/cosmic/child/io_test.tl"] = true,
  -- exercises the require machinery itself, including raw cosmo modules
  ["lib/cosmic/require_test.tl"] = true,
  -- raw-fd fixtures: sets up open file descriptors without going through
  -- the fs module under test
  ["lib/cosmic/fs/init_test.tl"] = true,
  ["lib/cosmic/fs/dir_test.tl"] = true,
  -- heredoc payload run inside a namespaced child process
  ["lib/cosmic/quicksand/proc_test.tl"] = true,
  -- heredoc payloads exercising the script runner / compiler on sources
  -- that themselves use cosmo
  ["lib/cosmic/script_test.tl"] = true,
  ["lib/cosmic/compile_test.tl"] = true,
  -- fixture strings in this file quote the forbidden pattern itself
  ["lib/build/lint_test.tl"] = true,
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
          col = col as integer,
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

local function write_casts_baseline(files: {string}): integer
  local entries: {string} = {}
  for _, file in ipairs(files) do
    if file:match("%.tl$") and not is_exempt(file) then
      local f = io.open(file, "r")
      if f then
        local content = f:read("*a")
        f:close()
        local count = count_casts(content or "", file)
        if count > 0 then
          table.insert(entries, string.format("%d\t%s", count, file))
        end
      end
    end
  end
  table.sort(entries, function(a: string, b: string): boolean
      return a:match("\t(.+)$") < b:match("\t(.+)$")
    end)
  local f = io.open(CASTS_BASELINE, "w")
  if not f then
    io.stderr:write("cannot write " .. CASTS_BASELINE .. "\n")
    return 1
  end
  f:write(table.concat(entries, "\n"), "\n")
  f:close()
  print(string.format("wrote %s (%d files with casts)", CASTS_BASELINE, #entries))
  return 0
end

local function main(...: string): integer
  local files: {string} = {...}
  if files[1] == "--write-casts-baseline" then
    table.remove(files, 1)
    return write_casts_baseline(files)
  end
  if #files == 0 then
    io.stderr:write("usage: lint.lua [--write-casts-baseline] FILE...\n")
    return 1
  end

  local casts_base = load_casts_baseline()
  local all_diagnostics: {Diagnostic} = {}
  for _, file in ipairs(files) do
    -- The standalone lint binary enforces file-length (run on all tracked
    -- files), the cast ratchet (.tl files), and cosmo-require
    -- (tests/examples). Column-length and assert-order are enforced via
    -- --check-style on .tl files (same cosmic.cli.style implementation).
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
          for _, d in ipairs(check_cast_ratchet(file, content or "", casts_base)) do
            table.insert(all_diagnostics, d)
          end
          if file:match("_test%.tl$") or file:match("_example%.tl$") then
            local lines: {string} = {}
            for line in ((content or "") .. "\n"):gmatch("([^\n]*)\n") do
              lines[#lines + 1] = line
            end
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
  count_casts = count_casts,
  check_cast_ratchet = check_cast_ratchet,
  main = main,
}
