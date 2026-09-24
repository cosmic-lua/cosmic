--- Rewrites `vendor/<name>/` trees from the upstream archives their
--- PINs name, keeping only the files the build reads.
---
---     cosmic --standalone build/vendor.tl [name...]
---     cosmic --standalone build/vendor.tl vendor/<name> <archive>
---
--- Like `build/zig.tl`, this runs standalone -- against the running
--- binary's own standard library, never the tree it sits in -- so it
--- requires `cosmic.*` modules only and holds everything it needs.
---
--- With no archive argument it fetches for itself: every `name` (every
--- `vendor/*/PIN` by default) is downloaded from its PIN's `url` into
--- `$XDG_CACHE_HOME/cosmic/vendor` (default `$HOME/.cache/cosmic/vendor`;
--- see `Fs.cache_dir`) -- reusing a cached file only when its sha256
--- still matches the PIN's -- verified with `Http.download`'s own `sha256` check, and
--- then rewritten exactly as the two-argument form does. This is what
--- `bin/vendor` runs; the repository is found from this script's own
--- path, so it works from any working directory.
---
--- The two-argument form rewrites one tree directly from an archive
--- already on disk, without fetching or verifying it. The archive is
--- read with `cosmic.archive`, whatever format it turns out to be, and
--- unpacked with `Archive.extract` -- which refuses absolute and `..`
--- entry paths and keeps permission bits -- into a scratch directory
--- beside the tree, so a refused or broken archive never leaves the
--- tree half rewritten. Paths lose a leading `./` and then PIN's
--- `strip` prefix, and a file is kept when a `keep` glob matches it and
--- no `drop` glob does: `*` matches within one path segment, `**`
--- across them. Every `keep` must match something, so an upstream
--- rename fails here rather than in the build.
---
--- A PIN with a `file <name>` line vendors a single file that is not an
--- archive at all (a `.pem`, say): its bytes become `<name>`, and every
--- `keep` must match that name. Without a `file` line, an archive
--- `cosmic.archive` cannot read is an error, never a single file.
---
--- Everything else in the tree but PIN is removed.
local Archive = require("cosmic.archive")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local sys = require("cosmic.sys")

local record Vendor
  record Pin
    url: string
    sha256: string
    strip: string
    --- The name a single-file PIN vendors its download as; empty for
    --- an archive.
    file: string
    keep: {string}
    drop: {string}
  end
end

local function complain(line: string)
  local _, _ = Fs.put(Fs.stderr, "vendor: " .. line .. "\n")
end

--- `vendor/<name>/PIN`'s text, as `key value` lines. A value is the
--- line's second word, so trailing blanks or a `\r` never become part
--- of it; `keep` and `drop` accumulate, and for every other key the
--- first line naming it wins.
function Vendor.read_pin(text: string): Vendor.Pin
  local pin: Vendor.Pin = { url = "", sha256 = "", strip = "", file = "", keep = {}, drop = {} }
  local seen: {string:boolean} = {}
  for line in text:gmatch("[^\n]+") do
    local key, value = line:match("^([%w_]+)%s+(%S+)")
    if key == "keep" then
      pin.keep[#pin.keep + 1] = value
    elseif key == "drop" then
      pin.drop[#pin.drop + 1] = value
    elseif key ~= nil and not seen[key] then
      seen[key] = true
      if key == "url" then
        pin.url = value
      elseif key == "sha256" then
        pin.sha256 = value
      elseif key == "strip" then
        pin.strip = value
      elseif key == "file" then
        pin.file = value
      end
    end
  end
  return pin
end

--- `vendor/<name> <archive>`: argv[1] names a tree directly (it holds
--- a "/"), so it and argv[2] are read as the two-argument form.
function Vendor.is_direct_rewrite(argv: {integer:string}): boolean
  return argv[1] ~= nil and argv[2] ~= nil and argv[1]:find("/", 1, true) ~= nil
end

--- The repository root, from this script's own path, `argv[0]`.
function Vendor.repo_root(script_path: string): string | nil, string
  if script_path == nil then
    return nil, "expected to run as .../build/vendor.tl"
  end
  local abs, trouble = Fs.absolute(script_path)
  if abs == nil then
    return nil, trouble
  end
  local root = abs:match("^(.*)/build/[^/]+%.tl$")
  if root == nil then
    return nil, script_path .. ": expected to run as .../build/vendor.tl"
  end
  return root, ""
end

--- Every name `vendor/*/PIN` names under `root`, sorted.
function Vendor.all_names(root: string): {string} | nil, string
  local entries, trouble = Fs.list(root .. "/vendor")
  if entries == nil then
    return nil, trouble
  end
  local names: {string} = {}
  for _, name in ipairs(entries) do
    local pinned, pin_trouble = Fs.exists(root .. "/vendor/" .. name .. "/PIN")
    if pinned == nil then
      return nil, pin_trouble
    end
    if pinned then
      names[#names + 1] = name
    end
  end
  return names, ""
end

--- True when `path` exists and its sha256 is `sha256`.
function Vendor.matches(path: string, sha256: string): boolean
  local data, _ = Fs.read(path)
  if data == nil then
    return false
  end
  return Hash.hex_sha256(data) == sha256:lower()
end

--- `path`, downloading `url` into it first unless it is already there
--- with the right sha256: a stale or corrupt cached file is refetched,
--- never reused.
function Vendor.fetch(url: string, path: string, sha256: string): string | nil, string
  if Vendor.matches(path, sha256) then
    return path, ""
  end
  local _, _ = Fs.remove(path)
  local ok, trouble = Http.download(url, path, { sha256 = sha256 })
  if not ok then
    return nil, trouble
  end
  return path, ""
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

--- `path` without any leading `./` segments.
local function plain(path: string): string
  local out = path
  while out:sub(1, 2) == "./" do
    out = out:sub(3):gsub("^/+", "")
  end
  return out
end

--- The archive's files PIN keeps: by archive path, the path each lands
--- at under the tree.
local function kept(pin: Vendor.Pin, entries: {Archive.Entry}): {string:string} | nil, string
  local out: {string:string} = {}
  local used: {string:boolean} = {}
  local strip = plain(pin.strip)
  for _, entry in ipairs(entries) do
    local path = plain(entry.path)
    if entry.kind == "file" and path:sub(1, #strip) == strip then
      local under = path:sub(#strip + 1)
      if under ~= "" and matches(pin.keep, under, used) and not matches(pin.drop, under) then
        out[entry.path] = under
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

--- Removes every entry under `tree` -- links included -- but PIN and
--- the `files` names, then every directory that leaves empty.
local function prune(tree: string, files: {string:boolean}, under?: string): boolean, string
  local directory = under == nil and tree or (tree .. "/" .. under)
  local entries, trouble = sys.readdir(directory)
  if entries == nil then
    return false, directory .. ": " .. trouble
  end
  for name, kind in pairs(entries) do
    local path = under == nil and name or (under .. "/" .. name)
    -- A link to a directory is listed as one; it is removed, not followed.
    local st, _ = sys.lstat(tree .. "/" .. path)
    if kind == "dir" and st ~= nil and st.kind == "dir" then
      local pruned, why = prune(tree, files, path)
      if not pruned then
        return false, why
      end
      local left, _ = Fs.list(tree .. "/" .. path)
      if left ~= nil and #left == 0 then
        local _, _ = sys.rmdir(tree .. "/" .. path)
      end
    elseif path ~= "PIN" and not files[path] then
      local gone, why = Fs.remove(tree .. "/" .. path)
      if not gone then
        return false, why
      end
    end
  end
  return true, ""
end

--- Moves each `scratch/<archive path>` to `tree/<under>`, once `tree`
--- holds nothing else but PIN.
local function install(tree: string, scratch: string, files: {string:string}): integer | nil, string
  local names: {string:boolean} = {}
  for _, under in pairs(files) do
    names[under] = true
  end
  local pruned, prune_trouble = prune(tree, names)
  if not pruned then
    return nil, prune_trouble
  end
  local count = 0
  for path, under in pairs(files) do
    local dir = under:match("^(.*)/[^/]+$")
    if dir ~= nil then
      local made, trouble = Fs.mkdirs(tree .. "/" .. dir)
      if not made then
        return nil, trouble
      end
    end
    local moved, trouble = Fs.rename(scratch .. "/" .. path, tree .. "/" .. under)
    if not moved then
      return nil, trouble
    end
    count = count + 1
  end
  return count, ""
end

--- A scratch directory beside `tree`, on the same filesystem, so what
--- is unpacked into it can be renamed into place.
local function scratch_beside(tree: string): string | nil, string
  local parent, name = tree:match("^(.*)/([^/]+)$")
  if parent == nil then
    parent, name = ".", tree
  end
  local template = parent .. "/." .. name .. ".vendor.XXXXXX"
  local made, trouble = sys.mkdtemp(template)
  if made == nil then
    return nil, template .. ": " .. trouble
  end
  return made, ""
end

--- Rewrites `tree` to exactly what `pin` keeps of the archive at
--- `archive_path`.
local function from_archive(tree: string, pin: Vendor.Pin, archive_path: string): integer | nil, string
  if #pin.keep == 0 then
    return nil, tree .. "/PIN: a PIN needs at least one keep"
  end
  local entries, list_trouble = Archive.list(archive_path)
  if entries == nil then
    return nil, archive_path .. ": " .. list_trouble
  end
  local files, keep_trouble = kept(pin, entries)
  if files == nil then
    return nil, tree .. ": " .. keep_trouble
  end
  local scratch, scratch_trouble = scratch_beside(tree)
  if scratch == nil then
    return nil, scratch_trouble
  end
  local written, extract_trouble = Archive.extract(archive_path, scratch, {
    filter = function(path: string): boolean
      return files[path] ~= nil
    end,
  })
  local count: integer
  local trouble = ""
  if written == nil then
    trouble = archive_path .. ": " .. extract_trouble
  else
    count, trouble = install(tree, scratch, files)
  end
  -- What is left in the scratch directory is only litter; the
  -- extraction's or the install's own answer is the one reported.
  local _, _ = Fs.remove_tree(scratch)
  if count == nil then
    return nil, trouble
  end
  return count, ""
end

--- Rewrites `tree` to hold just `download`'s own bytes, as `pin.file`.
local function as_single_file(tree: string, pin: Vendor.Pin, download: string): integer | nil, string
  if #pin.keep == 0 then
    return nil, tree .. "/PIN: a PIN needs at least one keep"
  end
  for _, glob in ipairs(pin.keep) do
    if not pin.file:match(pattern_of(glob)) then
      return nil, tree .. "/PIN: keep " .. glob .. " does not match file " .. pin.file
    end
  end
  local data, read_trouble = Fs.read(download)
  if data == nil then
    return nil, read_trouble
  end
  local pruned, prune_trouble = prune(tree, { [pin.file] = true })
  if not pruned then
    return nil, prune_trouble
  end
  local written, write_trouble = Fs.write(tree .. "/" .. pin.file, data)
  if not written then
    return nil, write_trouble
  end
  return 1, ""
end

--- Rewrites `tree` from the download at `path`, as its PIN says.
function Vendor.rewrite(tree: string, path: string): integer | nil, string
  local text, pin_trouble = Fs.read(tree .. "/PIN")
  if text == nil then
    return nil, pin_trouble
  end
  local pin = Vendor.read_pin(text)
  if pin.file ~= "" then
    if pin.file:find("/", 1, true) ~= nil or pin.file == "PIN" or pin.file:sub(1, 1) == "." then
      return nil, tree .. "/PIN: file " .. pin.file .. " is not a plain name"
    end
    return as_single_file(tree, pin, path)
  end
  return from_archive(tree, pin, path)
end

--- Fetches `name`'s PIN's download into `cache` (reusing it when its
--- sha256 still matches) and rewrites `vendor/<name>` from it.
local function fetch_and_rewrite(root: string, cache: string, name: string): integer | nil, string
  local tree = root .. "/vendor/" .. name
  local text, pin_trouble = Fs.read(tree .. "/PIN")
  if text == nil then
    return nil, pin_trouble
  end
  local pin = Vendor.read_pin(text)
  if pin.url == "" then
    return nil, tree .. "/PIN names no url"
  end
  if pin.sha256 == "" then
    return nil, tree .. "/PIN names no sha256"
  end
  local base = pin.url:match("([^/]+)$") or name
  local fetched, ftrouble = Vendor.fetch(pin.url, cache .. "/" .. base, pin.sha256)
  if fetched == nil then
    return nil, ftrouble
  end
  return Vendor.rewrite(tree, fetched)
end

function Vendor.main(argv: {integer:string}): integer
  if Vendor.is_direct_rewrite(argv) then
    local tree = (argv[1]):gsub("/+$", "")
    local count, trouble = Vendor.rewrite(tree, argv[2])
    if count == nil then
      complain(trouble)
      return 1
    end
    local _, _ = Fs.put(Fs.stdout, "vendor: " .. tree .. " (" .. count .. " files)\n")
    return 0
  end

  local root, root_trouble = Vendor.repo_root(argv[0])
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
    local found, trouble = Vendor.all_names(root)
    if found == nil then
      complain(trouble)
      return 1
    end
    names = found
  end

  local cache, ctrouble = Fs.cache_dir("vendor")
  if cache == nil then
    complain(ctrouble)
    return 1
  end

  local failed = false
  for _, name in ipairs(names) do
    local count, trouble = fetch_and_rewrite(root, cache, name)
    if count == nil then
      complain(name .. ": " .. trouble)
      failed = true
    else
      local _, _ = Fs.put(Fs.stdout, "vendor: vendor/" .. name .. " (" .. count .. " files)\n")
    end
  end
  return failed and 1 or 0
end

return Vendor
