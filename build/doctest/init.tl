--- Turns a markdown doc's fenced code-block examples into one compiled
--- Teal source string, per doc/meta.md's grammar. The result is an
--- ordinary `kind = "test"` module's own source: `build.importer`'s
--- `collect` treats it exactly like a hand-written `_test.tl`, discovers
--- its tests through the same `build.positions.analyze`, and runs them
--- through the same `build.test`. Nothing here runs a test, discovers
--- one, or records a verdict -- that would be the doctest machinery of
--- its own doc/meta.md says a doc never needs.
local markdown = require("build.doctest.markdown")
local generate = require("build.doctest.generate")

local record doctest
end

--- @param source string the doc's own markdown text
--- @param file string the doc's path, named inside a generated
---   example's own failure message; never prefixed onto this
---   function's OWN error below, which the caller (`collect`) already
---   prefixes with `file` the same way it does for every other module
--- @return string | nil generated Teal source, or nil on a grammar
---   error -- an unterminated fence, an unknown tag, an `sh` block, or
---   a block ordering the grammar in doc/meta.md does not allow
--- @return string why, naming the source line the trouble sits at
function doctest.extract(source: string, file: string): string | nil, string
  local blocks, block_trouble = markdown.parse_blocks(source)
  if blocks == nil then
    return nil, block_trouble
  end
  return generate.from_blocks(blocks, file)
end

return doctest
