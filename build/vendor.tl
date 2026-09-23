--- Rewrites one `vendor/<name>/` tree from an upstream archive already
--- unpacked into a directory, keeping only the files the build reads.
---
---     cosmic build/vendor.tl vendor/<name> <unpacked>
---
--- `bin/vendor` fetches and verifies the archive, unpacks it, and runs
--- this. Paths lose PIN's `strip` prefix, and a file is kept when a
--- `keep` glob matches it and no `drop` glob does: `*` matches within
--- one path segment, `**` across them. Every `keep` must match
--- something, so an upstream rename fails here rather than in the
--- build. Everything else in the tree but PIN is removed.
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local record Pin
  strip: string
  keep: {string}
  drop: {string}
end

local function complain(line: string)
  Fs.put(Fs.stderr, "vendor: " .. line .. "\n")
end

local function read_pin(text: string): Pin | nil, string
  local pin: Pin = { strip = "", keep = {}, drop = {} }
  for key, value in text:gmatch("([%w_]+)[ \t]+([^\n]+)") do
    if key == "strip" then
      pin.strip = value
    elseif key == "keep" then
      pin.keep[#pin.keep + 1] = value
    elseif key == "drop" then
      pin.drop[#pin.drop + 1] = value
    end
  end
  if #pin.keep == 0 then
    return nil, "a PIN needs at least one keep"
  end
  return pin, ""
end

--- A glob as an anchored Lua pattern.
local function pattern_of(glob: string): string
  local escaped = glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
  local wild = escaped:gsub("%*%*", "\0"):gsub("%*", "[^/]*"):gsub("\0", ".*")
  return "^" .. wild .. "$"
end

local function matches(globs: {string}, path: string, used?: {string:boolean}): boolean
  local any = false
  for _, glob in ipairs(globs) do
    if path:match(pattern_of(glob)) then
      any = true
      if used ~= nil then
        used[glob] = true
      end
    end
  end
  return any
end

--- The unpacked paths PIN keeps, by their path under the tree.
local function kept(pin: Pin, paths: {string}): {string:string} | nil, string
  local out: {string:string} = {}
  local used: {string:boolean} = {}
  for _, path in ipairs(paths) do
    if path:sub(1, #pin.strip) == pin.strip then
      local under = path:sub(#pin.strip + 1)
      if matches(pin.keep, under, used) and not matches(pin.drop, under) then
        out[under] = path
      end
    end
  end
  for _, glob in ipairs(pin.keep) do
    if not used[glob] then
      return nil, "keep " .. glob .. " matches nothing in the archive"
    end
  end
  return out, ""
end

--- Removes every entry under `tree` -- links included, which `Fs.walk`
--- does not list -- but PIN and those `files` names, then every
--- directory that leaves empty.
local function prune(tree: string, files: {string:string}, under?: string): boolean, string
  local directory = under == nil and tree or (tree .. "/" .. under)
  local entries, trouble = sys.readdir(directory)
  if entries == nil then
    return false, directory .. ": " .. trouble
  end
  for name, kind in pairs(entries) do
    local path = under == nil and name or (under .. "/" .. name)
    -- A link to a directory is listed as one; it is removed, not followed.
    local st = sys.lstat(tree .. "/" .. path)
    if kind == "dir" and st ~= nil and st.kind == "dir" then
      local pruned, why = prune(tree, files, path)
      if not pruned then
        return false, why
      end
      local left = Fs.list(tree .. "/" .. path)
      if left ~= nil and #left == 0 then
        sys.rmdir(tree .. "/" .. path)
      end
    elseif path ~= "PIN" and files[path] == nil then
      local gone, why = Fs.remove(tree .. "/" .. path)
      if not gone then
        return false, why
      end
    end
  end
  return true, ""
end

--- Rewrites `tree` to exactly what its PIN keeps of `unpacked`.
local function rewrite(tree: string, unpacked: string): integer | nil, string
  local text, pin_trouble = Fs.read(tree .. "/PIN")
  if text == nil then
    return nil, pin_trouble
  end
  local pin, trouble = read_pin(text)
  if pin == nil then
    return nil, tree .. "/PIN: " .. trouble
  end
  local paths, walk_trouble = Fs.walk(unpacked)
  if paths == nil then
    return nil, walk_trouble
  end
  local files, keep_trouble = kept(pin, paths)
  if files == nil then
    return nil, tree .. ": " .. keep_trouble
  end
  local pruned, prune_trouble = prune(tree, files)
  if not pruned then
    return nil, prune_trouble
  end
  local count = 0
  for under, path in pairs(files) do
    local data, read_trouble = Fs.read(unpacked .. "/" .. path)
    if data == nil then
      return nil, read_trouble
    end
    local dir = under:match("^(.*)/[^/]+$")
    if dir ~= nil then
      local made, mkdir_trouble = Fs.mkdirs(tree .. "/" .. dir)
      if not made then
        return nil, mkdir_trouble
      end
    end
    local written, write_trouble = Fs.write(tree .. "/" .. under, data)
    if not written then
      return nil, write_trouble
    end
    count = count + 1
  end
  return count, ""
end

return function(argv: {integer:string}): integer
  local tree, unpacked = argv[1], argv[2]
  if tree == nil or unpacked == nil then
    complain("usage: cosmic build/vendor.tl vendor/<name> <unpacked>")
    return 2
  end
  tree = tree:gsub("/+$", "")
  local count, trouble = rewrite(tree, unpacked)
  if count == nil then
    complain(trouble)
    return 1
  end
  Fs.put(Fs.stdout, "vendor: " .. tree .. " (" .. count .. " files)\n")
  return 0
end
