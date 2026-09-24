--- Whether a directory is cosmic's own source tree, structurally.
--- Nothing else in `build` needs to answer this: it is a small
--- filesystem check, kept in its own module so answering it never
--- costs loading the rest of the compiler.

local Fs = require("cosmic.fs")

local record tree
end

--- Whether `root` is cosmic's own tree, structurally: `core/` and
--- `build/` both exist, and `build/` holds the importer itself rather
--- than just a directory of that name. `cosmic.*` is reserved to this
--- one tree; nothing else may claim it, by directory or by import path.
function tree.is_own(root: string): boolean | nil, string
  local core, trouble = Fs.is_dir(root .. "/core")
  if core == nil then return nil, trouble end
  if not core then return false, "" end
  local build, build_trouble = Fs.is_dir(root .. "/build")
  if build == nil then return nil, build_trouble end
  if not build then return false, "" end
  local importer, importer_trouble = Fs.exists(root .. "/build/importer.tl")
  if importer == nil then return nil, importer_trouble end
  if not importer then return false, "" end
  local importer_dir, directory_trouble = Fs.is_dir(root .. "/build/importer.tl")
  if importer_dir == nil then return nil, directory_trouble end
  return not importer_dir, ""
end

return tree
