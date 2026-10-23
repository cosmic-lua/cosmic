--- The command line of the writer of the translated tree: `bin/cosmic build/tree_writer_main.tl write <dir>
--- [--again] [--root <tree>] [path...]`, run from the root of the tree ([`build/tree_writer.tl`]).

local TreeWriter = require("build.tree_writer")

return function(argv: {string}): integer
  return TreeWriter.main(argv)
end
