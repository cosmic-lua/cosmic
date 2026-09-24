--- Paths from a verb's command line, which narrow what it does to the
--- files under them, as doc/design.md's command line promises: each is
--- read the way the tree's own paths are written, relative to the root.

local Fs = require("cosmic.fs")

local record narrow
end

--- Each word as a path relative to `root`: "." for the root itself, the
--- rest after it for a path within it, and a path outside it or not
--- there at all as written, less a leading "./" and a trailing "/".
function narrow.paths(root: string, words: {string}): {string}
  local out: {string} = {}
  for _, word in ipairs(words) do
    local path = word:gsub("/+$", "")
    while path:sub(1, 2) == "./" do path = path:sub(3) end
    local absolute, _ = Fs.absolute(word)
    if absolute ~= nil then
      local rest, _ = Fs.relative(absolute, root)
      path = rest or absolute
    end
    out[#out + 1] = path
  end
  return out
end

--- Whether `file`, relative to the root, is one of `paths` or under one;
--- every file is when there are none.
function narrow.holds(paths: {string}, file: string): boolean
  if #paths == 0 then
    return true
  end
  for _, path in ipairs(paths) do
    if path == "." or Fs.within(file, path) then
      return true
    end
  end
  return false
end

return narrow
