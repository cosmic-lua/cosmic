--- Test discovery: one lex-and-parse pass classifies a test file and
--- yields its ordered cases. D29 settled that a test runs because the
--- toolchain found it — a top-level `local function test_*` IS the
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
--- Definitions and their extents come from the PARSER, not a token
--- depth count: `tl.parse_program` sets each function node's `yend`
--- from its own closing `end`, so a nested `record`/`enum`/`interface`
--- body cannot pull the extent early and a `function` token in type
--- position cannot lose it (the 3IP9ijhv pair). A `local function
--- test_x` quoted in a string or a long-bracket fixture still never
--- counts — the parser reads code, not strings. Source order is the
--- run order.

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

--- One parsed `test_*` definition, before the call check.
local record Definition
  name: string
  line: integer
  ends: integer
end

--- The top-level `local function test_*` definitions, in source order.
---
--- Read from the parsed program, whose array part is the top-level
--- statement list: a `local_function` node's `y` is its `local`
--- token's line and its `yend` is set from the closing `end` token by
--- the parser itself. The parse is error-tolerant, so a file with a
--- syntax error yields whatever definitions did parse — such a file
--- fails the type gate on its own, and there is nothing sounder this
--- walk could report about it.
--- @param tokens {tl.Token} The file's tokens
--- @param file string Path, handed to the parser for its messages
--- @return {Definition} The definitions, with their `end` lines
local function definitions_of(tokens: {Token}, file: string): {Definition}
  local defs: {Definition} = {}
  local errs: {tl.Error} = {}
  local program = tl.parse_program(tokens, errs, file)
  -- the program node's array part is its top-level statement list;
  -- cast: the narrowed tl API types the parsed program as `any`
  for _, stmt in ipairs(program as {any}) do
    local node = stmt as {string: any} -- cast: tl AST node fields
    if node["kind"] == "local_function" then
      -- cast: tl AST identifier node, whose `tk` is the name
      local name_node = node["name"] as {string: any}
      local name = name_node["tk"]
      local y = node["y"]
      local ends = node["yend"]
      if name is string and name:match("^test_")
      and y is integer and ends is integer then
        defs[#defs + 1] = {name = name, line = y, ends = ends}
      end
    end
  end
  return defs
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
  for _, def in ipairs(definitions_of(tokens, file)) do
    local called = false
    for y = def.ends + 1, #lines do
      if lines[y]:match("%S") then
        if lines[y]:match("^" .. def.name .. "%s*%(") then
          called = true
          call_line[def.name] = y
        end
        break
      end
    end
    cases[#cases + 1] = {name = def.name, line = def.line, called = called}
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
