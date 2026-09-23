--- Rewrites one `vendor/<name>/` tree from the upstream archive its PIN
--- names, keeping only the files the build reads.
---
---     cosmic vendor.tl vendor/<name> <archive>
---
--- `bin/vendor` fetches the archive and runs this. The archive must
--- hash to PIN's `sha256`. Its entries lose PIN's `strip` prefix, and
--- an entry is kept when a `keep` glob matches it and no `drop` glob
--- does; `*` matches within one path segment. Every `keep` must match
--- something, so an upstream rename fails here rather than in the
--- build. Everything else in the tree but PIN is removed.
local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")

local record Pin
  sha256: string
  strip: string
  keep: {string}
  drop: {string}
end

local record Entry
  path: string
  data: string
end

local function complain(line: string)
  Fs.put(Fs.stderr, "vendor: " .. line .. "\n")
end

local function read_pin(path: string): Pin | nil, string
  local text, trouble = Fs.read(path)
  if text == nil then
    return nil, trouble
  end
  local pin: Pin = { sha256 = "", strip = "", keep = {}, drop = {} }
  for key, value in text:gmatch("([%w_]+)[ \t]+([^\n]+)") do
    if key == "sha256" then
      pin.sha256 = value
    elseif key == "strip" then
      pin.strip = value
    elseif key == "keep" then
      pin.keep[#pin.keep + 1] = value
    elseif key == "drop" then
      pin.drop[#pin.drop + 1] = value
    end
  end
  if pin.sha256 == "" or #pin.keep == 0 then
    return nil, path .. " needs a sha256 and at least one keep"
  end
  return pin
end

--- A glob as an anchored Lua pattern: `*` is any run within a segment,
--- and everything else is itself.
local function pattern_of(glob: string): string
  local escaped = glob:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
  return "^" .. escaped:gsub("%*", "[^/]*") .. "$"
end

--- A zip's entries, read through its central directory.
local function unzip(bytes: string): {Entry} | nil, string
  local at: integer = nil
  for i = #bytes - 21, 1, -1 do
    if bytes:sub(i, i + 3) == "PK\5\6" then
      at = i
      break
    end
  end
  if at == nil then
    return nil, "no end of central directory"
  end
  local count, _, offset = string.unpack("<I2I4I4", bytes, at + 10)
  local entries: {Entry} = {}
  local here = offset + 1
  for _ = 1, count do
    if bytes:sub(here, here + 3) ~= "PK\1\2" then
      return nil, "a broken central directory"
    end
    local method = string.unpack("<I2", bytes, here + 10)
    local packed, size, name_len, extra_len, comment_len =
      string.unpack("<I4I4I2I2I2", bytes, here + 20)
    local header = string.unpack("<I4", bytes, here + 42) + 1
    local name = bytes:sub(here + 46, here + 45 + name_len)
    here = here + 46 + name_len + extra_len + comment_len

    local local_name, local_extra = string.unpack("<I2I2", bytes, header + 26)
    local from = header + 30 + local_name + local_extra
    local raw = bytes:sub(from, from + packed - 1)
    local data: string
    if method == 0 then
      data = raw
    elseif method == 8 then
      local out, trouble = Compress.inflate_raw(raw, size)
      if out == nil then
        return nil, name .. ": " .. trouble
      end
      data = out
    else
      return nil, name .. ": compression method " .. method
    end
    if #data ~= size then
      return nil, name .. ": expanded to the wrong size"
    end
    if name:sub(-1) ~= "/" then
      entries[#entries + 1] = { path = name, data = data }
    end
  end
  return entries
end

--- A gzip member's contents.
local function gunzip(bytes: string): string | nil, string
  local flags = bytes:byte(4)
  local at = 11
  if flags & 4 ~= 0 then
    at = at + 2 + string.unpack("<I2", bytes, at)
  end
  if flags & 8 ~= 0 then
    at = bytes:find("\0", at, true) + 1
  end
  if flags & 16 ~= 0 then
    at = bytes:find("\0", at, true) + 1
  end
  if flags & 2 ~= 0 then
    at = at + 2
  end
  local size = string.unpack("<I4", bytes, #bytes - 3)
  return Compress.inflate_raw(bytes:sub(at, #bytes - 8), size)
end

--- A tar's regular files, with pax `path` records honored.
local function untar(bytes: string): {Entry} | nil, string
  local entries: {Entry} = {}
  local at = 1
  local long_name: string = nil
  while at + 511 <= #bytes do
    local header = bytes:sub(at, at + 511)
    if header == string.rep("\0", 512) then
      break
    end
    local name = header:sub(1, 100):match("^[^%z]*")
    local size = tonumber(header:sub(125, 136):match("[0-7]+") or "0", 8)
    local kind = header:sub(157, 157)
    if header:sub(258, 262) == "ustar" then
      local prefix = header:sub(346, 500):match("^[^%z]*")
      if prefix ~= "" then
        name = prefix .. "/" .. name
      end
    end
    local data = bytes:sub(at + 512, at + 511 + size)
    at = at + 512 + ((size + 511) // 512) * 512
    if kind == "x" then
      long_name = data:match("%d+ path=([^\n]*)\n")
    elseif kind == "0" or kind == "\0" then
      entries[#entries + 1] = { path = long_name or name, data = data }
      long_name = nil
    elseif kind == "5" or kind == "g" then
      long_name = nil
    else
      return nil, name .. ": tar entry type " .. kind
    end
  end
  return entries
end

local function entries_of(bytes: string): {Entry} | nil, string
  if bytes:sub(1, 4) == "PK\3\4" then
    return unzip(bytes)
  end
  if bytes:sub(1, 2) == "\31\139" then
    local tar, trouble = gunzip(bytes)
    if tar == nil then
      return nil, trouble
    end
    return untar(tar)
  end
  return nil, "neither a zip nor a gzipped tar"
end

--- The entries PIN keeps, by their path under the tree.
local function kept(pin: Pin, entries: {Entry}): {string: string} | nil, string
  local out: {string: string} = {}
  local used: {string: boolean} = {}
  for _, e in ipairs(entries) do
    if e.path:sub(1, #pin.strip) == pin.strip then
      local path = e.path:sub(#pin.strip + 1)
      local keep = false
      for _, glob in ipairs(pin.keep) do
        if path:match(pattern_of(glob)) then
          keep = true
          used[glob] = true
        end
      end
      for _, glob in ipairs(pin.drop) do
        if path:match(pattern_of(glob)) then
          keep = false
        end
      end
      if keep then
        out[path] = e.data
      end
    end
  end
  for _, glob in ipairs(pin.keep) do
    if not used[glob] then
      return nil, "keep " .. glob .. " matches nothing in the archive"
    end
  end
  return out
end

--- Removes every file under `tree` but PIN and those `files` names,
--- then every directory left empty.
local function prune(tree: string, files: {string: string}): boolean, string
  local present, trouble = Fs.walk(tree)
  if present == nil then
    return false, trouble
  end
  for _, path in ipairs(present) do
    if path ~= "PIN" and files[path] == nil then
      local gone, why = Fs.remove(tree .. "/" .. path)
      if not gone then
        return false, why
      end
      local dir = path:match("^(.*)/[^/]+$")
      while dir ~= nil do
        local names = Fs.list(tree .. "/" .. dir)
        if names == nil or #names > 0 then
          break
        end
        sys.rmdir(tree .. "/" .. dir)
        dir = dir:match("^(.*)/[^/]+$")
      end
    end
  end
  return true, ""
end

return function(argv: {integer:string}): integer
  local tree, archive = argv[2], argv[3]
  if tree == nil or archive == nil then
    complain("usage: cosmic vendor.tl vendor/<name> <archive>")
    return 2
  end
  tree = tree:gsub("/+$", "")

  local pin, pin_trouble = read_pin(tree .. "/PIN")
  if pin == nil then
    complain(pin_trouble)
    return 1
  end
  local bytes, read_trouble = Fs.read(archive)
  if bytes == nil then
    complain(read_trouble)
    return 1
  end
  local got = Hash.hex_sha256(bytes)
  if got ~= pin.sha256 then
    complain(archive .. " has sha256 " .. got .. "; the pin says " .. pin.sha256)
    return 1
  end

  local entries, entries_trouble = entries_of(bytes)
  if entries == nil then
    complain(archive .. ": " .. entries_trouble)
    return 1
  end
  local files, keep_trouble = kept(pin, entries)
  if files == nil then
    complain(tree .. ": " .. keep_trouble)
    return 1
  end

  local pruned, prune_trouble = prune(tree, files)
  if not pruned then
    complain(prune_trouble)
    return 1
  end
  local count = 0
  for path, data in pairs(files) do
    local dir = path:match("^(.*)/[^/]+$")
    if dir ~= nil then
      local made, mkdir_trouble = Fs.mkdirs(tree .. "/" .. dir)
      if not made then
        complain(mkdir_trouble)
        return 1
      end
    end
    local written, write_trouble = Fs.write(tree .. "/" .. path, data)
    if not written then
      complain(write_trouble)
      return 1
    end
    count = count + 1
  end
  Fs.put(Fs.stdout, "vendor: " .. tree .. " (" .. count .. " files)\n")
  return 0
end
