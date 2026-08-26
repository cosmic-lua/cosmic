--- Test discovery: one token-exact lexer walk classifies a test file
--- and yields its ordered cases. D29 settled that a test runs because
--- the toolchain found it — a top-level `local function test_*` IS the
--- enrolment — and this module is the finding half, extracted from the
--- `call-after-define` lint so the lint, and later the compile seam,
--- read the same walk instead of each carrying one.
---
--- A file is all-or-nothing (D29): every case self-called is `legacy`
--- and compiles unchanged; none called is `runner` and gets the
--- toolchain tail at the compile seam; a mix is the one shape that
--- must never pass, because its uncalled half would silently not run
--- under legacy semantics. A file with no `test_*` definitions at all
--- is `empty` — helpers-only and `Example_*` files are not test files
--- in the runner sense.
---
--- `runner` demands more than "no immediate self-call": a case name
--- referenced ANYWHERE outside its definition and its immediate call
--- line (a bottom-of-file call block, a `pcall(test_x)`) keeps the
--- file out of runner mode. Such a file would run its tests once by
--- its own calls AND once by the seam's tail, so it classifies mixed
--- and the lint refuses it, exactly as the old rule did.
---
--- Token-exact via the lexer, so a `local function test_x` quoted in a
--- string or a long-bracket fixture never counts, and source order is
--- the run order.

local tl = require("tl")

local type Token = tl.Token

--- What a test file's shape means for the toolchain.
local enum Mode
  "legacy"
  "runner"
  "mixed"
  "empty"
end

--- One discovered test case, in source order.
local record Case
  --- The function's name, `test_*`.
  name: string
  --- The line its definition starts on.
  line: integer
  --- True when the next non-blank line after its `end` calls it —
  --- today's call-after-define shape.
  called: boolean
end

--- A test file's classification and its ordered case list.
local record Discovery
  mode: Mode
  cases: {Case}
end

--- Line of the `end` that closes the function starting at `from`.
--- @param tokens {tl.Token} The file's tokens
--- @param from integer Index of the `function` keyword
--- @return integer|nil Line of the matching `end`
local function end_line_of(tokens: {Token}, from: integer): integer | nil
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

--- Walk one file's source and classify it.
--- @param file string Path, handed to the lexer for its messages
--- @param content string The file's bytes
--- @param lines {string} The file's lines
--- @return Discovery The mode and the ordered case list
local function discover(file: string, content: string,
    lines: {string}): Discovery
  local cases: {Case} = {}
  local tokens = tl.lex(content, file)
  if not tokens then
    return {mode = "empty", cases = cases}
  end
  local call_line: {string: integer} = {}
  for i = 1, #tokens - 2 do
    local t = tokens[i]
    if t.tk == "local" and t.x == 1 and tokens[i + 1].tk == "function" then
      local name = tokens[i + 2].tk
      if name:match("^test_") then
        -- A nil end line means the depth walk lost the closer (a
        -- `function` token in TYPE position has no `end` — the
        -- 3IP9ijhv class); the old lint skipped such definitions
        -- rather than judging them, and this walk keeps that
        -- behavior verbatim until that item fixes the counter.
        local ends = end_line_of(tokens, i + 1)
        if ends then
          local called = false
          for y = ends + 1, #lines do
            if lines[y]:match("%S") then
              if lines[y]:match("^" .. name .. "%s*%(") then
                called = true
                call_line[name] = y
              end
              break
            end
          end
          cases[#cases + 1] = {name = name, line = t.y, called = called}
        end
      end
    end
  end
  if #cases == 0 then
    return {mode = "empty", cases = cases}
  end
  -- A case name referenced anywhere else — not its definition, not its
  -- immediate call — is a late call block or an indirect use, and it
  -- keeps the file out of runner mode.
  local by_name: {string: Case} = {}
  for _, c in ipairs(cases) do
    by_name[c.name] = c
  end
  local referenced_elsewhere = false
  for i, t in ipairs(tokens) do
    local c = t.kind == "identifier" and by_name[t.tk] or nil
    if c and t.y ~= c.line and t.y ~= call_line[t.tk]
    and (i == 1 or tokens[i - 1].tk ~= "function") then
      referenced_elsewhere = true
      break
    end
  end
  local called_n = 0
  for _, c in ipairs(cases) do
    if c.called then
      called_n = called_n + 1
    end
  end
  local mode: Mode = "mixed"
  if called_n == #cases then
    mode = "legacy"
  elseif called_n == 0 and not referenced_elsewhere then
    mode = "runner"
  end
  return {mode = mode, cases = cases}
end

local record DiscoverModule
  type Mode = Mode
  type Case = Case
  type Discovery = Discovery
  discover: function(file: string, content: string,
  lines: {string}): Discovery
end

local M: DiscoverModule = {
  discover = discover,
}

return M
