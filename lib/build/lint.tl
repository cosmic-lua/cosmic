#!/usr/bin/env lua

local proc = require("cosmic.proc")

local record Diagnostic
  file: string
  line: integer
  col: integer
  rule: string
  message: string
end

local DEFAULT_FILE_LINES < const > = 500
local DEFAULT_COLUMN_WIDTH < const > = 90

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

local function check_column_length(file: string, lines: {string}, limit: integer): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  for i, line in ipairs(lines) do
    if #line > limit then
      table.insert(diagnostics, {
          file = file,
          line = i,
          col = limit + 1,
          rule = "column-length",
          message = string.format("%s:%d has %d columns (limit: %d)", file, i, #line, limit),
        })
    end
  end
  return diagnostics
end

--- Check that top-level `local function NAME(` is immediately called as `NAME()` on
--- the next non-blank line after its closing `end`. Heuristic: track depth of
--- `function`/`end` keywords; when depth returns to 0, check the next line.
local function check_call_after_define(file: string, lines: {string}): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  local i = 1
  while i <= #lines do
    local line = lines[i]
    -- Match top-level local function definition
    local fname = line:match("^local function%s+([%w_]+)%s*%(")
    if fname then
      local def_line = i
      -- Track end depth to find the closing end
      local depth = 1
      i = i + 1
      while i <= #lines and depth > 0 do
        local l = lines[i]
        -- Count keywords that open a new block scope
        for _ in l:gmatch("%f[%w_]function%f[^%w_]") do
          depth = depth + 1
        end
        for _ in l:gmatch("%f[%w_]if%f[^%w_]") do
          depth = depth + 1
        end
        for _ in l:gmatch("%f[%w_]for%f[^%w_]") do
          depth = depth + 1
        end
        for _ in l:gmatch("%f[%w_]while%f[^%w_]") do
          depth = depth + 1
        end
        for _ in l:gmatch("%f[%w_]repeat%f[^%w_]") do
          depth = depth + 1
        end
        -- Count standalone `do` (not the `do` terminating a for/while header,
        -- which is already counted above via for/while). A `do` is standalone
        -- when the same line contains no `for` or `while` keyword.
        if l:match("%f[%w_]do%f[^%w_]") and
        not l:match("%f[%w_]for%f[^%w_]") and
        not l:match("%f[%w_]while%f[^%w_]") then
          depth = depth + 1
        end
        -- `until` closes a repeat block without an `end`
        for _ in l:gmatch("%f[%w_]until%f[^%w_]") do
          depth = depth - 1
        end
        -- Count end keywords
        for _ in l:gmatch("%f[%w_]end%f[^%w_]") do
          depth = depth - 1
        end
        i = i + 1
      end
      -- i is now one past the closing end line; skip blank lines
      while i <= #lines and lines[i]:match("^%s*$") do
        i = i + 1
      end
      if i <= #lines then
        local call_line = lines[i]
        -- Accept NAME() or NAME(...) as a valid call
        if not call_line:match("^" .. fname .. "%s*%(") then
          table.insert(diagnostics, {
              file = file,
              line = def_line,
              col = 1,
              rule = "call-after-define",
              message = string.format(
                "function '%s' must be called immediately after its definition "
                  .. "(test/example files call each test_* function right after defining it)",
                fname
              ),
            })
        end
      end
    else
      i = i + 1
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

local function lint_file(path: string): {Diagnostic}
  if is_exempt(path) then
    return {}
  end

  local diagnostics: {Diagnostic} = {}

  local f = io.open(path, "r")
  if not f then
    return diagnostics
  end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then
    return diagnostics
  end

  local lines: {string} = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end

  local n = #lines
  -- A trailing newline produces an empty last element; adjust count
  if n > 0 and lines[n] == "" then
    n = n - 1
  end

  local file_diags = check_file_length(path, n, DEFAULT_FILE_LINES)
  for _, d in ipairs(file_diags) do
    table.insert(diagnostics, d)
  end

  -- Column-length and assert-order checks apply to Teal source files only
  if path:match("%.tl$") then
    local col_diags = check_column_length(path, lines, DEFAULT_COLUMN_WIDTH)
    for _, d in ipairs(col_diags) do
      table.insert(diagnostics, d)
    end

    local order_diags = check_call_after_define(path, lines)
    for _, d in ipairs(order_diags) do
      table.insert(diagnostics, d)
    end
  end

  return diagnostics
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
    -- files) and cosmo-require (tests/examples). Column-length and
    -- assert-order are enforced via --check-style on .tl files.
    if not is_exempt(file) then
      local n = count_lines(file)
      local diags = check_file_length(file, n, DEFAULT_FILE_LINES)
      for _, d in ipairs(diags) do
        table.insert(all_diagnostics, d)
      end
      if file:match("_test%.tl$") or file:match("_example%.tl$") then
        local f = io.open(file, "r")
        if f then
          local content = f:read("*a")
          f:close()
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
  Diagnostic = Diagnostic,
  DEFAULT_FILE_LINES = DEFAULT_FILE_LINES,
  DEFAULT_COLUMN_WIDTH = DEFAULT_COLUMN_WIDTH,
  count_lines = count_lines,
  check_file_length = check_file_length,
  check_column_length = check_column_length,
  check_call_after_define = check_call_after_define,
  check_cosmo_require = check_cosmo_require,
  lint_file = lint_file,
  main = main,
}
