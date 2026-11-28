--- What the checks of the tree keep of a file's parse: what it requires and, for a test file, its early returns.
--- `cosmic fix` keeps them as it parses each file, so the checks do not parse it again ([`build.fix.read`]).
---
--- @public
local tree_common = require("build.tree_checks.common")
local type Ast = require("lang.ast")

local record known
  --- What a parse of a file told the checks.
  record Parse
    requires: {string}
    returns?: {{string}}
  end

  --- Keeps what `chunk`, a parse of `source` as the text of `file`, tells the checks of the tree.
  parse: function(source: string, file: string, chunk: Ast.Chunk)

  --- Keeps `known`, as a parse of the text `source` of `file` found it, or a memo of that parse.
  keep: function(source: string, file: string, known: Parse)

  --- What [`parse`] or [`keep`] kept of the text `source` of `file`, nil where they kept none.
  of: function(source: string, file: string): Parse?
end

function known.parse(source: string, file: string, chunk: Ast.Chunk)
  tree_common.knows_parse(source, file, chunk)
end

function known.keep(source: string, file: string, kept: known.Parse)
  tree_common.knows(source, file, kept.requires, kept.returns)
end

function known.of(source: string, file: string): known.Parse?
  local requires, returns = tree_common.known_of(source, file)
  if requires == nil then return nil end
  return { requires = requires, returns = returns }
end

return known
