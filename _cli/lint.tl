--- The style gate behind `--check lint`, and so behind `--make lint`.
---
--- Two layers, split by what they may require. `cosmic.style` holds the
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

local fs = require("cosmic.fs")
local style = require("cosmic.style")
local tl = require("tl")
local visibility = require("_cli.visibility")

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

--- Whether a cast on line `y` carries its reason.
--- @param lines {string} The file's lines
--- @param y integer The line the cast is on
--- @return boolean True when justified here or on the line above
local function is_justified(lines: {string}, y: integer): boolean
  local here = lines[y]
  if here and here:match("%-%- cast: %S") then
    return true
  end
  local above = lines[y - 1]
  return above ~= nil and above:match("^%s*%-%- cast: %S") ~= nil
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
    if not is_justified(lines, y) then
      diagnostics[#diagnostics + 1] = {
        file = file,
        line = y,
        col = 1,
        rule = "cast-justify",
        message = string.format(
          "%s:%d: `as` cast without justification: prefer `is` narrowing"
          .. " or check.must (see AGENTS.md); a deliberate cast takes a"
          .. " trailing `-- cast: <reason>` (or on the line above)",
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

--- Where a top-level `local function NAME(...)` ends, by TOKEN depth.
---
--- The heuristic this replaces counted `function`/`if`/`for`/`do`/`end`
--- by matching source text, so every one inside a string literal or a
--- comment moved the depth. A test whose body quotes `end` in a fixture
--- — which is most of the ones that build fixtures — got a wrong end
--- line and a false positive.
--- @param tokens {tl.Token} The file's tokens
--- @param from integer Index of the `function` keyword
--- @return integer|nil Line of the matching `end`
local function end_line_of(tokens: {tl.Token}, from: integer): integer | nil
  local depth = 0
  -- `for`/`while` open a block AND write a `do` to end their header, so
  -- that `do` must not count a second time. A flag, not a look-behind at
  -- the previous token: `for _ in pairs(t) do` and a bare `do` block
  -- inside a function both follow a `)`, and the look-behind version
  -- read the second as a header and lost a level.
  local pending_do = false
  for i = from, #tokens do
    local tk = tokens[i].tk
    if tk == "for" or tk == "while" then
      depth = depth + 1
      pending_do = true
    elseif tk == "do" then
      if pending_do then
        pending_do = false
      else
        depth = depth + 1
      end
    elseif tk == "function" or tk == "if" then
      depth = depth + 1
    elseif tk == "repeat" then
      depth = depth + 1
    elseif tk == "until" then
      depth = depth - 1
    elseif tk == "end" then
      depth = depth - 1
      if depth == 0 then
        return tokens[i].y
      end
    end
  end
  return nil
end

--- A test file calls each `test_*` function immediately after defining
--- it, so a failing run names the function that failed rather than the
--- file.
---
--- `test_*` only, and in `_test.tl` only. A test file's HELPERS are
--- defined once and called from several tests, and an `Example_*`
--- function is called by the example RUNNER rather than by its own
--- file — flagging either made the rule unsatisfiable rather than
--- enforced.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @param lines {string} The file's lines
--- @return {Diagnostic} One per definition not immediately called
local function check_call_after_define(file: string, content: string,
    lines: {string}): {Diagnostic}
  if not file:match("_test%.tl$") then
    return {}
  end
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  for i = 1, #tokens - 2 do
    local t = tokens[i]
    if t.tk == "local" and t.x == 1 and tokens[i + 1].tk == "function" then
      local name = tokens[i + 2].tk
      if name:match("^test_") then
        local ends = end_line_of(tokens, i + 1)
        if ends then
          local next_line: string = nil
          for y = ends + 1, #lines do
            if lines[y]:match("%S") then
              next_line = lines[y]
              break
            end
          end
          if not next_line or not next_line:match("^" .. name .. "%s*%(") then
            diagnostics[#diagnostics + 1] = {
              file = file,
              line = t.y,
              col = 1,
              rule = "call-after-define",
              message = string.format(
                "%s:%d: '%s' must be called immediately after its "
                .. "definition, so a failing run names the function",
                file, t.y, name),
            }
          end
        end
      end
    end
  end
  return diagnostics
end

--- Calls of `find` whose needle is a VARIABLE and which never say
--- whether they meant a pattern.
---
--- `s:find(x)` treats x as a Lua pattern, so a `-`, `.`, `(` or `%` in
--- it silently changes what matches. When x is a path, a name, or a
--- filter the author almost always meant a substring, and the failure is
--- invisible: the assertion still runs, it just compares the wrong
--- thing. A test that plants a file under `/tmp/a-b/` and greps for it
--- passes everywhere except where the path has a dash.
---
--- Literal needles are exempt — `s:find("%d+")` is a pattern on purpose
--- and reads as one. The rule is only for needles the reader cannot see.
--- @param content string The file's bytes
--- @param file string Path, for the lexer's error messages
--- @return {integer} 1-based line numbers, each at most once
local function unguarded_find_lines(content: string, file: string): {integer}
  local tokens = tl.lex(content, file)
  if not tokens then
    return {}
  end
  local seen: {integer: boolean} = {}
  local out: {integer} = {}
  for i, t in ipairs(tokens) do
    local prev = i > 1 and tokens[i - 1] or nil
    local open = tokens[i + 1]
    -- Method form takes the subject as the receiver, so its needle is
    -- first and plain is third; `string.find(s, needle, init, plain)`
    -- passes the subject too, shifting both by one. A `.` on anything
    -- but `string` is some other function that happens to be named
    -- find, and is none of this rule's business.
    local needle_at = 0
    local plain_at = 0
    if t.tk == "find" and open and open.tk == "(" and prev then
      if prev.tk == ":" then
        needle_at = 1
        plain_at = 3
      elseif prev.tk == "." and i > 2 and tokens[i - 2].tk == "string" then
        needle_at = 2
        plain_at = 4
      end
    end
    if plain_at > 0 and not seen[t.y] then
      local depth = 1
      local argno = 1
      local literal_needle = true
      local empty = true
      local j = i + 2
      while j <= #tokens and depth > 0 do
        local tk = tokens[j].tk
        local separator = tk == "," and depth == 1
        if tk == "(" or tk == "[" or tk == "{" then
          depth = depth + 1
        elseif tk == ")" or tk == "]" or tk == "}" then
          depth = depth - 1
        elseif separator then
          argno = argno + 1
        end
        -- The separator belongs to no argument: counting it as one made
        -- every `string.find(s, "literal")` look non-literal, because
        -- the comma before the needle is not a string token.
        if depth > 0 and not separator then
          empty = false
          if argno == needle_at and tokens[j].kind ~= "string" and tk ~= ".." then
            literal_needle = false
          end
        end
        j = j + 1
      end
      if not empty and not literal_needle and argno < plain_at then
        seen[t.y] = true
        out[#out + 1] = t.y
      end
    end
  end
  return out
end

--- Report each `find` that leaves pattern-vs-substring unsaid.
--- @param file string Path, for the diagnostic
--- @param content string The file's bytes
--- @return {Diagnostic} One per unguarded call
local function check_find_needle(file: string, content: string): {Diagnostic}
  local diagnostics: {Diagnostic} = {}
  for _, y in ipairs(unguarded_find_lines(content, file)) do
    diagnostics[#diagnostics + 1] = {
      file = file,
      line = y,
      col = 1,
      rule = "find-needle",
      message = string.format(
        "%s:%d: `find` with a non-literal needle is a PATTERN, so a `-`,"
        .. " `.` or `%%` in it silently changes the match: pass `, 1, true`"
        .. " for a substring, or `, 1, false` to mean the pattern",
        file, y),
    }
  end
  return diagnostics
end

--- Report each `check.needs` guard that returns instead of exiting.
---
--- `check.needs` says an environment cannot run a test; the exit code is
--- the only part of that the runner reads. A `return` ends the function
--- and lets the file run on to a clean exit, and a clean exit is graded
--- `pass` -- so the guard reports the test as run and green when it did
--- neither. `os.exit(check.EXIT_SKIP)` is what `records.status_of`
--- grades as a skip, and it is the form `check.needs` documents.
---
--- Line-based rather than token-based: the shape is two adjacent lines,
--- and the lexer's own guards (comments, strings) do not apply to a
--- `return` that has to be at statement position to parse at all.
--- @param file string Path, for the diagnostic
--- @param lines {string} The file's lines
--- @return {Diagnostic} One per guard that returns rather than exits
local function check_needs_exit(file: string, lines: {string}): {Diagnostic}
  if not file:match("_test%.tl$") then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  for i, line in ipairs(lines) do
    if line:find("check.needs(", 1, true) then
      -- The call wraps when its arguments are long, so the `then` that
      -- opens the guard may be a line or two below the call. Beyond
      -- that it is some other use of `needs` and not this shape.
      for j = i, math.min(i + 2, #lines) do
        if lines[j]:match("then%s*$") then
          if (lines[j + 1] or ""):match("^%s*return%s*$") then
            diagnostics[#diagnostics + 1] = {
              file = file,
              line = j + 1,
              col = 1,
              rule = "needs-exit",
              message = string.format(
                "%s:%d: a `check.needs` guard that returns exits 0, which"
                .. " the runner grades as a PASS for a test that never"
                .. " ran: `os.exit(check.EXIT_SKIP)` reports the skip",
                file, j + 1),
            }
          end
          break
        end
      end
    end
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
  if not fs.isfile(path) then
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
    for _, d in ipairs(check_needs_exit(path, lines)) do
      diagnostics[#diagnostics + 1] = d
    end
    for _, d in ipairs(visibility.check_shard_require(path, lines)) do
      diagnostics[#diagnostics + 1] = d
    end
  end
  return diagnostics
end

local record LintModule
  check_cast_justification: function(file: string, content: string, lines: {string}): {Diagnostic}
  check_cosmo_require: function(file: string, lines: {string}): {Diagnostic}
  check_call_after_define: function(file: string, content: string, lines: {string}): {Diagnostic}
  check_find_needle: function(file: string, content: string): {Diagnostic}
  check_needs_exit: function(file: string, lines: {string}): {Diagnostic}
  lint_file: function(path: string): {Diagnostic} | nil, string
end

local M: LintModule = {
  check_cast_justification = check_cast_justification,
  check_cosmo_require = check_cosmo_require,
  check_call_after_define = check_call_after_define,
  check_find_needle = check_find_needle,
  check_needs_exit = check_needs_exit,
  lint_file = lint_file,
}

return M
