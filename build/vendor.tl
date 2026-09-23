--- Rewrites one `vendor/<name>/` tree from an upstream archive,
--- keeping only the files the build reads.
---
---     cosmic build/vendor.tl vendor/<name> <archive>
---
--- `bin/vendor` fetches and verifies the archive and runs this over
--- it directly, without unpacking it first: `<archive>` is walked with
--- `cosmic.archive`, whatever format it turns out to be. Paths lose
--- PIN's `strip` prefix, and a file is kept when a `keep` glob matches
--- it and no `drop` glob does: `*` matches within one path segment,
--- `**` across them. Every `keep` must match something, so an
--- upstream rename fails here rather than in the build.
---
--- When `<archive>` is not a format `cosmic.archive` recognizes (a
--- single file such as a `.pem`, say) and PIN names no `strip`, it is
--- vendored as one file instead: named by a `file <name>` PIN line,
--- or by the basename of PIN's `url` when there is no `file` line.
---
--- Everything else in the tree but PIN is removed.
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Stream = require("cosmic.stream")
local Archive = require("cosmic.archive")

local record Pin
  url: string
  strip: string
  --- The name a single-file PIN (one with no `keep`) vendors its
  --- archive as, when it is not itself a recognized archive format.
  --- Defaults to the basename of `url` when empty.
  file: string
  keep: {string}
  drop: {string}
end

local function complain(line: string)
  Fs.put(Fs.stderr, "vendor: " .. line .. "\n")
end

local function read_pin(text: string): Pin | nil, string
  local pin: Pin = { url = "", strip = "", file = "", keep = {}, drop = {} }
  for key, value in text:gmatch("([%w_]+)[ \t]+([^\n]+)") do
    if key == "url" then
      pin.url = value
    elseif key == "strip" then
      pin.strip = value
    elseif key == "file" then
      pin.file = value
    elseif key == "keep" then
      pin.keep[#pin.keep + 1] = value
    elseif key == "drop" then
      pin.drop[#pin.drop + 1] = value
    end
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

--- The archive paths PIN keeps, by the path they land at under the
--- tree (with `strip` removed).
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

--- Writes `data` to `tree/under`, making its parent directories first.
local function write_under(tree: string, under: string, data: string): boolean, string
  local dir = under:match("^(.*)/[^/]+$")
  if dir ~= nil then
    local made, mkdir_trouble = Fs.mkdirs(tree .. "/" .. dir)
    if not made then return false, mkdir_trouble end
  end
  return Fs.write(tree .. "/" .. under, data)
end

--- Every regular file `reader` holds, by its archive path.
local function file_paths(reader: Archive.ArchiveReader): {string} | nil, string
  local paths: {string} = {}
  while true do
    local entry, etrouble = reader:next()
    if entry == nil then
      reader:close()
      if etrouble ~= "" then return nil, etrouble end
      return paths, ""
    end
    if entry.kind == "file" then
      paths[#paths + 1] = entry.path
    end
  end
end

--- Rewrites `tree` to exactly what `pin` keeps of the archive at
--- `archive_path`, walked in two passes: `cosmic.archive`'s readers
--- run forward only, so which paths are kept (needed before `prune`
--- can run, since a keep that matches nothing is refused) has to be
--- settled in a pass of its own, ahead of one that reads bodies.
local function from_archive(tree: string, pin: Pin, archive_path: string): integer | nil, string
  if #pin.keep == 0 then
    return nil, tree .. "/PIN: a PIN needs at least one keep"
  end
  local reader, otrouble = Archive.open(archive_path)
  if reader == nil then return nil, archive_path .. ": " .. otrouble end
  local paths, walk_trouble = file_paths(reader)
  if paths == nil then return nil, archive_path .. ": " .. walk_trouble end
  local files, keep_trouble = kept(pin, paths)
  if files == nil then return nil, tree .. ": " .. keep_trouble end
  local pruned, prune_trouble = prune(tree, files)
  if not pruned then return nil, prune_trouble end

  local wanted: {string:string} = {} -- archive path -> path under tree
  for under, path in pairs(files) do wanted[path] = under end

  local reader2, otrouble2 = Archive.open(archive_path)
  if reader2 == nil then return nil, archive_path .. ": " .. otrouble2 end
  local count = 0
  while true do
    local entry, etrouble = reader2:next()
    if entry == nil then
      reader2:close()
      if etrouble ~= "" then return nil, etrouble end
      return count, ""
    end
    if entry.kind == "file" then
      local under = wanted[entry.path]
      if under ~= nil then
        local body, btrouble = entry:open()
        if body == nil then return nil, btrouble end
        local data, rtrouble = Stream.read_all(body)
        if data == nil then return nil, rtrouble end
        local written, write_trouble = write_under(tree, under, data)
        if not written then return nil, write_trouble end
        count = count + 1
      end
    end
  end
end

--- `pin.file`, or the basename of `pin.url` when that is empty.
local function single_file_name(pin: Pin): string | nil
  if pin.file ~= "" then return pin.file end
  if pin.url == "" then return nil end
  return pin.url:match("([^/]+)$")
end

--- Rewrites `tree` to hold just `archive_path`'s own bytes, named by
--- `single_file_name`, for a PIN whose archive turned out not to be
--- one `cosmic.archive` recognizes.
local function as_single_file(tree: string, pin: Pin, archive_path: string): integer | nil, string
  local name = single_file_name(pin)
  if name == nil then
    return nil, tree .. "/PIN: cannot name the vendored file -- add a 'file <name>' line"
  end
  local data, read_trouble = Fs.read(archive_path)
  if data == nil then return nil, read_trouble end
  local pruned, prune_trouble = prune(tree, { [name] = archive_path })
  if not pruned then return nil, prune_trouble end
  local written, write_trouble = write_under(tree, name, data)
  if not written then return nil, write_trouble end
  return 1, ""
end

local function rewrite(tree: string, archive_path: string): integer | nil, string
  local text, pin_trouble = Fs.read(tree .. "/PIN")
  if text == nil then
    return nil, pin_trouble
  end
  local pin, trouble = read_pin(text)
  if pin == nil then
    return nil, tree .. "/PIN: " .. trouble
  end
  local probe, otrouble = Archive.open(archive_path)
  if probe == nil then
    if pin.strip == "" then
      return as_single_file(tree, pin, archive_path)
    end
    return nil, archive_path .. ": " .. otrouble
  end
  probe:close()
  return from_archive(tree, pin, archive_path)
end

return function(argv: {integer:string}): integer
  local tree, archive_path = argv[1], argv[2]
  if tree == nil or archive_path == nil then
    complain("usage: cosmic build/vendor.tl vendor/<name> <archive>")
    return 2
  end
  tree = tree:gsub("/+$", "")
  local count, trouble = rewrite(tree, archive_path)
  if count == nil then
    complain(trouble)
    return 1
  end
  Fs.put(Fs.stdout, "vendor: " .. tree .. " (" .. count .. " files)\n")
  return 0
end
