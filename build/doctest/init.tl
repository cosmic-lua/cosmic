--- Turns a markdown doc's fenced code-block examples into one Teal
--- source string, per doc/meta.md's grammar. The result is the source of
--- an ordinary `kind = "test"` module: [`build.compilation.collect`]
--- treats it like a hand-written `_test.tl`. [`build.analyzer.analyze`]
--- discovers its tests and [`build.test`] runs them. Nothing
--- here runs a test, discovers one, or records a verdict: doc/meta.md
--- says a doc needs no doctest machinery of its own.
local markdown = require("build.doctest.markdown")
local generate = require("build.doctest.generate")

local record doctest
  type Entry = generate.Entry
end

--- @param source string the doc's own markdown text
--- @param file string the doc's path, named inside a generated
---   example's own failure message; never prefixed onto this
---   function's own error below, which [`build.derivation`] already
---   prefixes with `file` the same way it does for every other input
--- @return string | nil generated Teal source, or nil on a grammar
---   error -- an unterminated fence, an unknown tag, or
---   a block ordering the grammar in doc/meta.md does not allow
--- @return string why, naming the source line the trouble sits at
function doctest.extract(source: string, file: string): string | nil, string
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
function doctest.entries(source: string): {generate.Entry} | nil, string
  local blocks, block_trouble = markdown.parse_blocks(source)
  if blocks == nil then
    return nil, block_trouble
  end
  return generate.entries(blocks)
end

return doctest
