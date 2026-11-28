--- Turns a markdown doc's fenced code-block examples into one Teal
--- source string, per doc/writing.md's grammar. The result is the source of
--- an ordinary `kind = "test"` module: [`build.plans`]'s `collect`
--- treats it like a hand-written `_test.tl`. [`build.syntax_analyzer`]'s `analysis_of`
--- discovers its tests and [`build.test`] runs them. Nothing
--- here runs a test, discovers one, or records a verdict: doc/writing.md
--- says a doc needs no doctest machinery of its own.
local markdown = require("build.doctest.markdown")
local generate = require("build.doctest.generate")

local record doctest
  type Entry = generate.Entry
  type Block = markdown.Block
end

--- @param source string the doc's own markdown text
--- @param file string the doc's path, named inside a generated
---   example's own failure message; never prefixed onto this
---   function's own error below, which [`build.derivation`] already
---   prefixes with `file` the same way it does for every other input
--- @return string | nil generated Teal source, or nil on a grammar
---   error -- an unterminated fence, an unknown tag, or
---   a block ordering the grammar in doc/writing.md does not allow
--- @return string why, naming the source line the trouble sits at
function doctest.extract(source: string, file: string): string?, string
  local blocks, block_trouble = markdown.parse_blocks(source)
  if blocks == nil then
    return nil, block_trouble
  end
  return generate.from_blocks(blocks, file, generate.prose(source))
end

--- The examples of a doc, each as its reader copies it (skips left
--- out): what `extract` makes into functions, before the wrapping.
--- @param source string the doc's own markdown text
--- @return {generate.Entry} | nil nil on a grammar error, as `extract`
--- @return string why
function doctest.entries(source: string): {generate.Entry}?, string
  local blocks, block_trouble = markdown.parse_blocks(source)
  if blocks == nil then
    return nil, block_trouble
  end
  return generate.entries(blocks)
end

--- The fenced blocks of a doc, in document order, each with the line of its opening fence: what a tool that rewrites a
--- block in place needs, and what `extract` and `entries` read.
--- @param source string the doc's own markdown text
--- @return {markdown.Block} | nil nil on a grammar error, as `extract`
--- @return string why
function doctest.blocks(source: string): {markdown.Block}?, string
  return markdown.parse_blocks(source)
end

--- Where an error at line `at` of the source `extract` made stands in the doc: the doc's own line where the
--- line is one of an example's statements, the line the example opens at where it is some other line of its
--- function (a `sh` command, the output check), nil where it is one of the helpers every doc's source starts with.
--- @param source the generated source
--- @param at 1-based line of that source
--- @return integer | nil the doc line
function doctest.relocate(source: string, at: integer): integer?
  local lines: mut {string} = {}
  for each in (source .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = each end
  local opened: mut {string:integer} = {}
  for _, each in ipairs(lines) do
    local name, line = each:match("^%-%- line ([%w_]+) (%d+)$")
    if name ~= nil then opened[name] = math.tointeger(tonumber(line)) or 0 end
  end
  local current: string? = nil
  local marker: integer? = nil
  local first = 0
  local count = 0
  for i = 1, math.min(at, #lines) do
    local each = lines[i] or ""
    local name = each:match("^local function ([%w_]+)%(tmp: string%)$")
    if name ~= nil then
      current = name
      marker = nil
    elseif each == "end" then
      current = nil
      marker = nil
    else
      local doc, many = each:match("^  %-%- doc (%d+) (%d+)$")
      if doc ~= nil and many ~= nil then
        marker = i
        first = math.tointeger(tonumber(doc)) or 0
        count = math.tointeger(tonumber(many)) or 0
      end
    end
  end
  if marker ~= nil and at > marker and at <= marker + count then
    return first + (at - marker - 1)
  end
  if current ~= nil then
    return opened[current]
  end
  return nil
end

return doctest
