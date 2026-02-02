--- Generic directory tree walking.
--- Provides a Walker interface that can be implemented for different
--- filesystems (real, in-memory, zip, etc.).

--- Walker interface for traversing directory trees.
--- Implement this record to walk different kinds of filesystems.
local record Walker
  --- List entries in a directory.
  --- Returns an iterator that yields entry names (not full paths).
  --- @param path string Directory path to list
  --- @return function Iterator yielding entry names
  readdir: function(path: string): function(): string

  --- Check if a path is a directory.
  --- @param path string Path to check
  --- @return boolean True if path is a directory
  isdir: function(path: string): boolean

  --- Join path components.
  --- @param ... string Path components
  --- @return string Joined path
  join: function(...: string): string
end

--- Visitor function called for each entry during walk.
--- @param path string Full path to the entry
--- @param name string Basename of the entry
--- @param isdir boolean True if entry is a directory
--- @param ctx any User context
--- @return boolean Return false to skip recursing into this directory
local type Visitor = function(path: string, name: string, isdir: boolean, ctx: any): boolean

--- Walk a directory tree using the provided walker.
--- Calls visitor for each entry, recursing into directories unless visitor returns false.
--- @param root string Starting directory
--- @param w Walker Walker implementation
--- @param visitor Visitor Function called for each entry
--- @param ctx T Optional context passed to visitor
--- @return T The context, potentially modified
local function walk<T>(root: string, w: Walker, visitor: Visitor, ctx?: T): T
  ctx = ctx or {} as T

  local iter = w.readdir(root)
  if not iter then return ctx end

  for name in iter do
    if name ~= "." and name ~= ".." then
      local full_path = w.join(root, name)
      local is_dir = w.isdir(full_path)
      local continue = visitor(full_path, name, is_dir, ctx)
      if continue ~= false and is_dir then
        walk(full_path, w, visitor, ctx)
      end
    end
  end

  return ctx
end

--- Collect paths matching a pattern.
--- @param root string Starting directory
--- @param w Walker Walker implementation
--- @param pattern string Lua pattern to match against basenames
--- @return {string} List of matching full paths
local function collect(root: string, w: Walker, pattern: string): {string}
  local results: {string} = {}
  walk(root, w, function(path: string, name: string, isdir: boolean, ctx: {string}): boolean
    if not isdir and name:match(pattern) then
      table.insert(ctx, path)
    end
    return true
  end, results)
  return results
end

--- File info returned by collect_all.
local record FileInfo
  isdir: boolean
end

--- Collect all entries with metadata.
--- @param root string Starting directory
--- @param w Walker Walker implementation
--- @return {string:FileInfo} Map of relative paths to file info
local function collect_all(root: string, w: Walker): {string:FileInfo}
  local files: {string:FileInfo} = {}

  local function do_walk(dir: string, base: string)
    local iter = w.readdir(dir)
    if not iter then return end

    for name in iter do
      if name ~= "." and name ~= ".." then
        local full_path = w.join(dir, name)
        local rel_path = base == "" and name or w.join(base, name)
        local is_dir = w.isdir(full_path)

        if is_dir then
          do_walk(full_path, rel_path)
        else
          files[rel_path] = { isdir = false }
        end
      end
    end
  end

  do_walk(root, "")
  return files
end

return {
  walk = walk,
  collect = collect,
  collect_all = collect_all,
}
