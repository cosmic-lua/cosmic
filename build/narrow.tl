--- Paths from a verb's command line, which narrow what it does to the
--- files under them, as doc/design.md's command line promises: each is
--- read the way the tree's own paths are written, relative to the root.

local Fs = require("cosmic.fs")

local record narrow
end

--- `path` with each "." and empty component dropped and each ".."
--- taking the one before it away, lexically: a ".." with nothing before
--- it to take stays, but none climbs above "/".
local function lexical(path: string): string
  local parts: {string} = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        parts[#parts] = nil
      elseif path:sub(1, 1) ~= "/" then
        parts[#parts + 1] = part
      end
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  local joined = table.concat(parts, "/")
  if path:sub(1, 1) == "/" then
    return "/" .. joined
  end
  return joined == "" and "." or joined
end

--- Each word as a path relative to `root`: "." for the root itself, the
--- rest after it for a path within it, and a path outside it or not
--- there at all as written, with its "." and ".." resolved lexically.
function narrow.paths(root: string, words: {string}): {string}
  local out: {string} = {}
  for _, word in ipairs(words) do
    local path = lexical(word)
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
