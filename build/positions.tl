--- Position is the manifest: whether a file can be reached from outside
--- its own directory is a question of where it sits, not of its name.
---
--- A directory that holds its own `init.tl` is a module in its own
--- right, the ordinary way Lua already resolves `require("a.b")` to
--- `a/b/init.tl`, and every other file directly inside that directory
--- is a sibling, reachable only from a file that itself sits inside it.
--- A flat file with no such directory around it has no sibling to
--- protect and is public by construction. This generalizes the
--- reservation `build.importer` makes for the whole `cosmic` directory
--- to every directory in the tree.
---
--- The `Module` shape lives here, not in `build.importer`, so this
--- check can be a plain function of a module list without the two
--- files requiring one another.

local record positions
  record Module
    path: string
    file: string
    kind: string
    source: string
    source_hash: string
    requires: {string}
    key: string
    lua: string
    bytecode: string
  end
end

--- The file's own name, with no directory in front of it.
local function basename(file: string): string
  return file:match("([^/]+)$") or file
end

--- The directory a file sits in, or "" when it sits at the tree's root.
local function dirname(file: string): string
  return file:match("^(.*)/[^/]+$") or ""
end

--- Whether every require in `modules` respects sibling privacy, and if
--- not, which one and why.
--- @param modules every module the tree holds, with its requires
function positions.check(modules: {positions.Module}): boolean, string
  local by_path: {string:positions.Module} = {}
  local private_dirs: {string:boolean} = {}
  for _, m in ipairs(modules) do
    by_path[m.path] = m
    if basename(m.file) == "init.tl" then
      local dir = dirname(m.file)
      if dir ~= "" then
        private_dirs[dir] = true
      end
    end
  end
  for _, m in ipairs(modules) do
    for _, name in ipairs(m.requires) do
      local other = by_path[name]
      if other ~= nil then
        local dir = dirname(other.file)
        if private_dirs[dir] and other.file ~= dir .. "/init.tl" then
          local inside = m.file:sub(1, #dir + 1) == dir .. "/"
          if not inside then
            return false, m.file .. ": " .. name .. " is private to " ..
              dir .. "/; only a file inside it may import it"
          end
        end
      end
    end
  end
  return true, ""
end

return positions
