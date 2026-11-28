--- What `cosmic fix --check` keeps of a run over the whole of cosmic's own tree that found nothing: the key of all it
--- read, so that a run that would read the same finds the same and is not made again.
---
--- A run's result is a function of what it reads, and the key holds each of those, so no change can hide behind it:
---
--- - every entry under the root but `.git`: its path, its kind, and a file's mode and bytes or a link's target;
--- - every byte of the running tool, its core and its own database of modules;
--- - the command line and the environment, but for the variables a shell sets for itself ([`NOISE`]);
--- - what git answers about the tree: the paths it ignores ([`build.fix.ignored`]) and the base the markers are held to
---   ([`build.ceilings_base`]), whose files that base's commit names.
---
--- What the run reads beyond those is made from them: the build directory's databases, the memoed verdicts of single
--- files, and the tools the pins of the tree name ([`bin/zig.pin`], [`ci/cosmic-driver.pin`]). A key is kept only where a run exited 0 having
--- changed nothing, and only where the key read after the run is the one read before it, so a file changed while it ran
--- is never held passed. [`OFF`] set to `0` makes a run in full.
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")

local record verdict
  --- What the key of a run is read from: the root it runs at, its command line, its environment, the path of the
  --- running tool and what git answers about the tree ([`build.fix.ignored`]'s `answer` and
  --- [`build.ceilings_base`]'s `inputs`), each given so a test can say its own.
  record Inputs
    root: string
    argv: {string}
    environment: {string: string}
    tool: string
    git: string
  end

  --- The key of a run that reads `inputs`, as hexadecimal SHA-256; nil and why where any of it cannot be read.
  key: function(inputs: Inputs): string?, string
  --- Whether the file at `path` holds `key` as a run that passed: a file of this user's that no one else may write.
  held: function(path: string, key: string): boolean
  --- Keeps `key` in the file at `path` as a run that passed, with the [`KEPT`] keys kept last before it: a few, so a
  --- switch between branches finds each. Returns whether it was written, and why not.
  keep: function(path: string, key: string): boolean, string
  --- Whether `environment` turns the reuse off ([`OFF`]).
  off: function(environment: {string: string}): boolean
end

--- Changes when what a key holds would mean something else.
local VERSION <const> = "fix verdict 1"

--- The variable that, set to `0`, makes every run in full.
local OFF <const> = "COSMIC_FIX_VERDICT"

--- How many keys the file keeps.
local KEPT <const> = 8

--- The variables a shell sets for itself, which no check reads: the root stands for `PWD`. [`OFF`] is one too: it
--- turns the reuse off and changes nothing a check finds.
local NOISE <const>: {string: boolean} = { PWD = true, OLDPWD = true, SHLVL = true, _ = true, [OFF] = true }

--- What a file of the tree at `root` adds to the key: its path, its mode and the digest of its bytes.
local function file_part(root: string, path: string): string?, string
  local st, why = sys.lstat(root .. "/" .. path)
  if st == nil then return nil, path .. ": " .. why end
  local digest, trouble = Hash.file("sha256", root .. "/" .. path)
  if digest == nil then return nil, path .. ": " .. tostring(trouble) end
  return "f\0" .. path .. "\0" .. tostring(st.mode) .. "\0" .. Codec.hex(digest), ""
end

--- What the entries of the tree at `root` add to the key, sorted: each file as [`file_part`] says, each directory by its
--- path, each link by its target and anything else by its kind. `.git` at the root is left out.
local function tree_parts(root: string): {string}?, string
  local others: mut {string} = {}
  local files, trouble = Fs.walk(root, { skip = function(entry: string, _: string, kind: string): boolean
    if entry == ".git" then return true end
    if kind == "dir" then
      others[#others + 1] = "d\0" .. entry
    elseif kind == "link" then
      local target, _ = Fs.readlink(root .. "/" .. entry)
      others[#others + 1] = "l\0" .. entry .. "\0" .. (target or "?")
    elseif kind ~= "file" then
      others[#others + 1] = "o\0" .. entry .. "\0" .. kind
    end
    return false
  end })
  if files == nil then return nil, tostring(trouble) end
  local parts: mut {string} = {}
  for _, path in ipairs(files) do
    local part, why = file_part(root, path)
    if part == nil then return nil, why end
    parts[#parts + 1] = part
  end
  for _, part in ipairs(others) do parts[#parts + 1] = part end
  table.sort(parts)
  return parts, ""
end

function verdict.key(inputs: verdict.Inputs): string?, string
  local tool, tool_trouble = Hash.file("sha256", inputs.tool)
  if tool == nil then return nil, inputs.tool .. ": " .. tostring(tool_trouble) end
  local tree, tree_trouble = tree_parts(inputs.root)
  if tree == nil then return nil, tree_trouble end
  local names: mut {string} = {}
  for name in pairs(inputs.environment) do
    if NOISE[name] == nil then names[#names + 1] = name end
  end
  table.sort(names)
  local hasher <close> = assert(Hash.hasher("sha256"))
  -- Each part is closed by its length, so no two lists of parts hash alike.
  local function add(part: string)
    hasher:update(tostring(#part) .. ":" .. part)
  end
  add(VERSION)
  add("root\0" .. inputs.root)
  add("tool\0" .. Codec.hex(tool))
  add("argv " .. tostring(#inputs.argv))
  for _, word in ipairs(inputs.argv) do add(word) end
  add("environment " .. tostring(#names))
  for _, name in ipairs(names) do add(name .. "=" .. assert(inputs.environment[name])) end
  add("git\0" .. inputs.git)
  add("tree " .. tostring(#tree))
  for _, part in ipairs(tree) do add(part) end
  local digest, why = hasher:digest()
  if digest == nil then return nil, why end
  return Codec.hex(digest), ""
end

--- The keys the file at `path` holds, oldest first; none where it cannot be read.
local function keys_of(path: string): {string}
  local text, _ = Fs.read(path)
  local out: mut {string} = {}
  for line in (text or ""):gmatch("[^\n]+") do
    if line:match("^%x+$") ~= nil and #line == 64 then out[#out + 1] = line end
  end
  return out
end

--- Whether the file at `path` is this user's, taken as it is and never through a link, and no one else may write it:
--- a key planted by another would pass a run unchecked.
local function private(path: string): boolean
  local st, _ = sys.lstat(path)
  if st == nil or st.kind ~= "file" then return false end
  return st.uid == sys.getuid() and st.mode & 0x12 == 0
end

function verdict.held(path: string, key: string): boolean
  if not private(path) then return false end
  for _, kept in ipairs(keys_of(path)) do
    if kept == key then return true end
  end
  return false
end

function verdict.keep(path: string, key: string): boolean, string
  local kept: mut {string} = {}
  for _, old in ipairs(keys_of(path)) do
    if old ~= key then kept[#kept + 1] = old end
  end
  kept[#kept + 1] = key
  while #kept > KEPT do table.remove(kept, 1) end
  local wrote, trouble = Fs.write(path, table.concat(kept, "\n") .. "\n", 0x180)
  if wrote == nil then return false, tostring(trouble) end
  return true, ""
end

function verdict.off(environment: {string: string}): boolean
  return environment[OFF] == "0"
end

return verdict
