--- Rewrites one `vendor/<name>/` tree from an upstream archive,
--- keeping only the files the build reads.
---
---     cosmic build/vendor.tl [name...]
---     cosmic build/vendor.tl vendor/<name> <archive>
---
--- With no archive argument, this fetches for itself: every `name`
--- (every `vendor/*/PIN` by default) is downloaded from its PIN's
--- `url` into `$XDG_CACHE_HOME/cosmic/vendor` (default
--- `$HOME/.cache/cosmic/vendor`) -- reusing a cached file only when
--- its sha256 still matches the PIN's -- verified with
--- `Http.download`'s own `sha256` check, and then rewritten exactly
--- as the two-argument form below. This is what `bin/vendor` runs.
---
--- The two-argument form rewrites one tree directly from an archive
--- already on disk, without fetching or verifying it: `<archive>` is
--- walked with `cosmic.archive`, whatever format it turns out to be.
--- Paths lose PIN's `strip` prefix, and a file is kept when a `keep`
--- glob matches it and no `drop` glob does: `*` matches within one
--- path segment, `**` across them. Every `keep` must match something,
--- so an upstream rename fails here rather than in the build.
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
local Fetch = require("build.fetch")
local VendorLib = require("build.vendor_lib")

local type Pin = VendorLib.Pin
local read_pin = VendorLib.read_pin

local function complain(line: string)
  Fs.put(Fs.stderr, "vendor: " .. line .. "\n")
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

--- Fetches `name`'s PIN's archive into `cache` (reusing it when its
--- sha256 still matches) and rewrites `vendor/<name>` from it.
local function fetch_and_rewrite(root: string, cache: string, name: string): integer | nil, string
  local tree = root .. "/vendor/" .. name
  local text, pin_trouble = Fs.read(tree .. "/PIN")
  if text == nil then
    return nil, pin_trouble
  end
  local pin, trouble = read_pin(text)
  if pin == nil then
    return nil, tree .. "/PIN: " .. trouble
  end
  if pin.url == "" then
    return nil, tree .. "/PIN names no url"
  end
  if pin.sha256 == "" then
    return nil, tree .. "/PIN names no sha256"
  end
  local base = pin.url:match("([^/]+)$") or name
  local archive_path = cache .. "/" .. base
  local fetched, ftrouble = Fetch.file(pin.url, archive_path, pin.sha256)
  if fetched == nil then
    return nil, ftrouble
  end
  return rewrite(tree, fetched)
end

return function(argv: {integer:string}): integer
  if VendorLib.is_direct_rewrite(argv) then
    local tree = (argv[1]):gsub("/+$", "")
    local count, trouble = rewrite(tree, argv[2])
    if count == nil then
      complain(trouble)
      return 1
    end
    Fs.put(Fs.stdout, "vendor: " .. tree .. " (" .. count .. " files)\n")
    return 0
  end

  local root, root_trouble = VendorLib.repo_root(argv[0])
  if root == nil then
    complain(root_trouble)
    return 2
  end

  local names: {string} = {}
  local at = 1
  while argv[at] ~= nil do
    names[#names + 1] = argv[at]
    at = at + 1
  end
  if #names == 0 then
    local found, trouble = VendorLib.all_names(root)
    if found == nil then
      complain(trouble)
      return 1
    end
    names = found
  end

  local cache = Fetch.cache_dir("vendor")
  local made, mtrouble = Fs.mkdirs(cache)
  if not made then
    complain(mtrouble)
    return 1
  end

  local failed = false
  for _, name in ipairs(names) do
    local count, trouble = fetch_and_rewrite(root, cache, name)
    if count == nil then
      complain(name .. ": " .. trouble)
      failed = true
    else
      Fs.put(Fs.stdout, "vendor: vendor/" .. name .. " (" .. count .. " files)\n")
    end
  end
  return failed and 1 or 0
end
