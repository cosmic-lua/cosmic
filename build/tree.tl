--- Whether a directory is cosmic's own source tree, structurally.
--- Nothing else in `build` needs to answer this: it is a four-line
--- filesystem check, kept in its own module so answering it never
--- costs loading the rest of the compiler.

local Fs = require("cosmic.fs")

local record tree
end

--- Whether `root` is cosmic's own tree, structurally: `core/` and
--- `build/` both exist, and `build/` holds the importer itself rather
--- than just a directory of that name. `cosmic.*` is reserved to this
--- one tree; nothing else may claim it, by directory or by import path.
function tree.is_own(root: string): boolean
  return Fs.is_dir(root .. "/core") and Fs.is_dir(root .. "/build") and
    Fs.exists(root .. "/build/importer.tl") and
    not Fs.is_dir(root .. "/build/importer.tl")
end

return tree
