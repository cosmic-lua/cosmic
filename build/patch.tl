--- The patch applier: each vendored tree with its patch records applied,
--- written whole to a directory of its own.
---
---     cosmic --standalone build/patch.tl <root> <cache>
---     cosmic --standalone build/patch.tl --zig-lib <root> <lib> <out>
---
--- The second writes zig's library directory with `patch/zig-lib/`'s records
--- applied ([`Patch.zig_lib`]).
---
--- For every `vendor/<name>/PIN` under `root` it prints `<name>`, a tab,
--- and the directory holding `vendor/<name>` with every record under
--- `patch/<name>/` applied, in name order. The directory is
--- `<cache>/<name>-<key>`, `<key>` a hash of the patched tree itself --
--- its directories, and each file's path, permission bits and bytes as
--- written -- so it is named by its contents alone: the same from every
--- checkout, and from every version of this file that writes the same
--- bytes, which is what lets zig's cache, keyed by a source's path,
--- compile a vendored file once for all of them. One
--- already there is used as it is; one is written beside it first and
--- renamed into place, so a directory at that name is always whole.
---
--- A record is a text file:
---
---     file: src/luaconf.h
---     note: why this edit exists
---     --- find
---     the exact bytes to replace
---     --- replace
---     the bytes to put there
---     --- end
---
--- The `---` prefix is the default fence. A record whose own bytes hold
--- a fence line declares another with a `fence: <token>` line first.
--- Both blocks are exact bytes, each running to the line break before
--- its closing fence, and the find must match exactly once: none or
--- more than one is an error naming the record. Only a `.txt` in
--- `patch/<name>/` is a record.
---
--- The copy replaces the vendored tree whole rather than sitting beside
--- it, because a quoted `#include` finds its neighbour first, and a
--- half-applied patch would build green. It holds the tree's regular
--- files and directories, with their permission bits; a link or anything
--- else is not upstream source and is left out.
---
--- This file's own source is in no key: an edit to it that writes the
--- same trees (a comment, a refactor) names every tree as before, and
--- zig compiles none of vendor/ again; one that changes a tree's bytes
--- names that tree anew. Every byte written under a tree's name is
--- decided by the [`Tree`] its key hashes, so a change to how a tree is
--- written must go through that record to reach the disk. Since the file
--- is in the image fingerprint (build/work.tl), an edit still boots the
--- tool.
---
--- Like [`build/zig.tl`], which runs it before every `zig build`, this runs
--- standalone -- against the running binary's own standard library,
--- never the tree it sits in -- so it requires `cosmic.*` modules only.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Log = require("cosmic.log")
local sys = require("cosmic.sys")
local String = require("cosmic.string")

local record Patch
  --- One record, parsed: `note` is its `note:` line's value, and
  --- `find_at` and `replace_at` are where in the record's text the find
  --- and replace blocks start (the byte after each fence's line).
  record Record
    file: string
    note: string
    find: string
    replace: string
    find_at: integer
    replace_at: integer
  end
end

local log = Log.new("patch")

--- A line found in a record: what it holds (a header's value), where it
--- starts, and where the line after it does.
local record Line
  value: string
  start: integer
  after: integer
end

--- The `key: value` line at `at` in `text`, or nil when it is not one.
local function header(text: string, at: integer, key: string): Line | nil
  local eol = text:find("\n", at, true)
  if eol == nil then
    return nil
  end
  local line = text:sub(at, eol - 1)
  local prefix = key .. ": "
  if not String.starts_with(line, prefix) then
    return nil
  end
  return { value = line:sub(#prefix + 1), start = at, after = eol + 1 }
end

--- The first line from `at` on that is exactly `fence` and `word`, or nil.
local function fence_line(text: string, at: integer, fence: string,
                          word: string): Line | nil
  local wanted = fence .. " " .. word
  local from = at
  while from <= #text do
    local eol = text:find("\n", from, true)
    local last = eol == nil and #text or eol - 1
    if text:sub(from, last) == wanted then
      return { value = wanted, start = from, after = last + 2 }
    end
    if eol == nil then
      break
    end
    from = eol + 1
  end
  return nil
end

--- Parses the record `text`, named `name` in what it says of it. What
--- it takes as a record decides the TODOs build.todo_scan keeps of one,
--- so a change to that bumps build/work.tl's `version`.
function Patch.parse(text: string, name: string): Patch.Record | nil, string
  local at = 1
  local fence = "---"
  if text:sub(1, 7) == "fence: " then
    local given = header(text, at, "fence")
    if given == nil then
      return nil, name .. ": expected a 'fence: ' line"
    end
    fence, at = given.value, given.after
  end
  local file = header(text, at, "file")
  if file == nil then
    return nil, name .. ": expected a 'file: ' line"
  end
  local note = header(text, file.after, "note")
  if note == nil then
    return nil, name .. ": expected a 'note: ' line"
  end
  if note.value == "" then
    return nil, name .. ": the note says nothing"
  end
  local find = fence_line(text, note.after, fence, "find")
  if find == nil then
    return nil, name .. ": no '" .. fence .. " find' line"
  end
  local replace = fence_line(text, find.after, fence, "replace")
  if replace == nil then
    return nil, name .. ": no '" .. fence .. " replace' line"
  end
  local finish = fence_line(text, replace.after, fence, "end")
  if finish == nil then
    return nil, name .. ": no '" .. fence .. " end' line"
  end
  -- Each block runs to the line break before its closing fence: that
  -- break belongs to the fence, not to the bytes.
  if replace.start == find.after then
    return nil, name .. ": the find block is empty"
  end
  local replaced = ""
  if finish.start > replace.after then
    replaced = text:sub(replace.after, finish.start - 2)
  end
  return { file = file.value, note = note.value,
    find = text:sub(find.after, replace.start - 2),
    replace = replaced, find_at = find.after, replace_at = replace.after }, ""
end

--- `source` with the record's one match replaced, or nil and why when it
--- matches other than once. `name` names the record.
function Patch.apply(source: string, record: Patch.Record,
                     name: string): string | nil, string
  local first = source:find(record.find, 1, true)
  local matches = 0
  local at = first
  while at ~= nil do
    matches = matches + 1
    at = source:find(record.find, at + 1, true)
  end
  if first == nil or matches ~= 1 then
    return nil, name .. ": found " .. tostring(matches) .. " matches in " ..
      record.file .. ", wanted exactly 1"
  end
  return source:sub(1, first - 1) .. record.replace ..
    source:sub(first + #record.find), ""
end

--- One file a patched tree is made of, as it was read: its path (under
--- the vendored tree, or under the root for a record), its permission
--- bits, and its bytes.
local record Input
  path: string
  mode: integer
  data: string
end

--- Everything a patched tree is made of, each byte read once, so the
--- name the tree is given ([`key_of`]) and what is written under it
--- ([`write_tree`]) are of the same bytes whatever changes meanwhile: the
--- vendored tree's directories and regular files, in path order, and its
--- records, in name order.
local record Inputs
  dirs: {string}
  files: {Input}
  records: {Input}
end

--- Appends to `inputs` everything under `dir`, which is `relative` under
--- the vendored tree: directories and regular files, never following a
--- link, and nothing else -- a link, a device -- which is not upstream
--- source.
local function read_dir(dir: string, relative: string, inputs: Inputs): boolean, string
  local names, trouble = Fs.list(dir)
  if names == nil then
    return false, trouble
  end
  for _, entry in ipairs(names) do
    local path = dir .. "/" .. entry
    local under = relative == "" and entry or relative .. "/" .. entry
    local st, st_trouble = sys.lstat(path)
    if st == nil then
      return false, path .. ": " .. st_trouble
    end
    if st.kind == "dir" then
      inputs.dirs[#inputs.dirs + 1] = under
      local read, read_trouble = read_dir(path, under, inputs)
      if not read then
        return false, read_trouble
      end
    elseif st.kind == "file" then
      local data, read_trouble = Fs.read(path)
      if data == nil then
        return false, read_trouble
      end
      inputs.files[#inputs.files + 1] = { path = under, mode = st.mode & 0x1ff, data = data }
    end
  end
  return true, ""
end

--- Reads what `name`'s patched tree under `root` is made of: the records
--- are every `.txt` in `patch/<name>/`, none when there is no such
--- directory.
local function read_inputs(root: string, name: string): Inputs | nil, string
  local inputs: Inputs = { dirs = {}, files = {}, records = {} }
  local read, trouble = read_dir(root .. "/vendor/" .. name, "", inputs)
  if not read then
    return nil, trouble
  end
  local dir = root .. "/patch/" .. name
  local present, present_trouble = Fs.exists(dir)
  if present == nil then
    return nil, present_trouble
  end
  if not present then
    return inputs, ""
  end
  local names, list_trouble = Fs.list(dir)
  if names == nil then
    return nil, list_trouble
  end
  for _, entry in ipairs(names) do
    if #entry > 4 and entry:sub(-4) == ".txt" then
      local data, data_trouble = Fs.read(dir .. "/" .. entry)
      if data == nil then
        return nil, data_trouble
      end
      inputs.records[#inputs.records + 1] = {
        path = "patch/" .. name .. "/" .. entry, mode = 0, data = data }
    end
  end
  return inputs, ""
end

--- Writes `data` to a new file at `path` with exactly `mode`, and syncs
--- it, its mode included, before closing it.
-- TODO: measure filesystem-wide sync on disk-backed cold misses before
-- replacing per-file fsync. Activate only once ci/cosmic-driver.pin names
-- a release carrying sys.syncfs, and measurements justify the change;
-- preserve this path without both proofs.
local function write_synced(path: string, data: string,
                            mode: integer): boolean, string
  local fd, trouble = Fs.open_write(path, mode)
  if fd == nil then
    return false, trouble
  end
  local ok, failure = Fs.put(fd, data)
  if ok then
    -- Its failure names the path already; the rest are prefixed below.
    local moded, mode_trouble = Fs.chmod(path, mode)
    if not moded then
      local _, _ = Fs.close(fd)
      return false, mode_trouble
    end
    ok, failure = Fs.fsync(fd)
  end
  local closed, close_trouble = Fs.close(fd)
  if ok and not closed then
    ok, failure = false, close_trouble
  end
  if not ok then
    return false, path .. ": " .. failure
  end
  return true, ""
end

--- Syncs the directory at `path`: its entries and its mode.
local function sync_dir(path: string): boolean, string
  local fd, trouble = Fs.open_read(path)
  if fd == nil then
    return false, trouble
  end
  local ok, failure = Fs.fsync(fd)
  local closed, close_trouble = Fs.close(fd)
  if ok and not closed then
    ok, failure = false, close_trouble
  end
  if not ok then
    return false, path .. ": " .. failure
  end
  return true, ""
end

--- A patched tree as it is to be written, every byte of it decided:
--- each directory, by its path under the tree and its permission bits,
--- and each file, by its path, permission bits and bytes, the records
--- applied. Its key ([`key_of`]) hashes all of it and [`write_tree`]
--- writes all of it and nothing else, so two trees of one key are the
--- same bytes, whatever version of this file wrote them.
local record Tree
  dir_mode: integer
  dirs: {string}
  files: {Input}
end

--- What every directory of a tree is given, whatever the umask.
local dir_mode <const> = 0x1ed

--- `inputs` with its records applied, or nil and why, naming the record
--- that failed.
local function patched(inputs: Inputs): Tree | nil, string
  local contents: {string:string} = {}
  for _, file in ipairs(inputs.files) do
    contents[file.path] = file.data
  end
  for _, input in ipairs(inputs.records) do
    local parsed, parse_trouble = Patch.parse(input.data, input.path)
    if parsed == nil then
      return nil, parse_trouble
    end
    local source = contents[parsed.file]
    if source == nil then
      return nil, input.path .. ": no file " .. parsed.file .. " to patch"
    end
    local applied, apply_trouble = Patch.apply(source, parsed, input.path)
    if applied == nil then
      return nil, apply_trouble
    end
    contents[parsed.file] = applied
  end
  local files: {Input} = {}
  for _, file in ipairs(inputs.files) do
    files[#files + 1] = { path = file.path, mode = file.mode, data = contents[file.path] }
  end
  return { dir_mode = dir_mode, dirs = inputs.dirs, files = files }, ""
end

--- Writes `tree` into `out`, which must not exist, and syncs every file
--- and directory it wrote. Modes are set outright, whatever the umask.
local function write_tree(tree: Tree, out: string): boolean, string
  local dirs: {string} = { out }
  for _, dir in ipairs(tree.dirs) do
    dirs[#dirs + 1] = out .. "/" .. dir
  end
  for _, dir in ipairs(dirs) do
    local made, trouble = Fs.mkdirs(dir)
    if not made then
      return false, trouble
    end
    local moded, mode_trouble = Fs.chmod(dir, tree.dir_mode)
    if not moded then
      return false, mode_trouble
    end
  end
  for _, file in ipairs(tree.files) do
    local path = out .. "/" .. file.path
    local written, write_trouble = write_synced(path, file.data, file.mode)
    if not written then
      return false, write_trouble
    end
  end
  for _, dir in ipairs(dirs) do
    local synced, sync_trouble = sync_dir(dir)
    if not synced then
      return false, sync_trouble
    end
  end
  return true, ""
end

--- Writes `vendor/<name>` under `root` into `out`, which must not exist,
--- with its records applied.
function Patch.tree(root: string, name: string, out: string): boolean, string
  local inputs, trouble = read_inputs(root, name)
  if inputs == nil then
    return false, trouble
  end
  local tree, patch_trouble = patched(inputs)
  if tree == nil then
    return false, patch_trouble
  end
  return write_tree(tree, out)
end

--- The hash that names a patched tree: all of `tree`, as it is to be
--- written -- the directories' permission bits, then every directory,
--- and every file with its permission bits and the hash of its patched
--- bytes, in path order. Neither the records nor the source doing the
--- patching is in it but through what they write, so an edit to either
--- that writes the same bytes names the same tree.
local function key_of(tree: Tree): string
  local lines: {string} = { "dirs " .. tostring(tree.dir_mode) .. "\n" }
  for _, dir in ipairs(tree.dirs) do
    lines[#lines + 1] = "dir " .. dir .. "\n"
  end
  for _, file in ipairs(tree.files) do
    lines[#lines + 1] = "file " .. file.path .. " " .. tostring(file.mode) ..
      " " .. Hash.hex_sha256(file.data) .. "\n"
  end
  return Hash.hex_sha256(table.concat(lines))
end

--- The gate is never unlinked: every creator and sweeper must lock the
--- same inode. It covers creation through ownership, so no sweep sees a
--- new wrapper before its owner is locked. Expensive work runs outside it.
--- Kept here because this standalone script can load only the pinned
--- release's cosmic.* modules, not another module from the checkout.
local record Descriptor
  fd: integer
  metamethod __close: function(Descriptor)
end
local descriptor_mt: metatable<Descriptor> = {
  __close = function(self: Descriptor) local _, _ = sys.close(self.fd) end,
}

local record Scratch
  path: string
  owner: integer
  metamethod __close: function(Scratch)
end
local scratch_mt: metatable<Scratch> = {
  __close = function(self: Scratch)
    local _, _ = Fs.remove_tree(self.path)
    local _, _ = sys.close(self.owner)
  end,
}

-- build/zig_fetch.tl holds an identical copy, and the TODO to take both
-- from Fs.scratch once ci/cosmic-driver.pin names a release whose
-- cosmic.fs carries it.
local function scratch(cache: string): Scratch | nil, string
  local fd, trouble = sys.open(cache .. "/.scratch-gate", sys.O_RDWR | sys.O_CREAT | sys.O_NOFOLLOW, 0x180)
  if fd == nil then return nil, trouble end
  local opened: Descriptor = { fd = fd }
  local gate <close> = setmetatable(opened, descriptor_mt)
  local locked, lock_trouble = sys.flock(gate.fd, "exclusive", -1)
  if not locked then return nil, lock_trouble end
  local names, list_trouble = Fs.list(cache)
  if names == nil then return nil, list_trouble end
  for _, name in ipairs(names) do
    -- PID-only names belong to old tools and say nothing about ownership
    -- across namespaces. Missing owner files are also left alone.
    if name:match("^%.scratch%.[%w]+$") then
      local path = cache .. "/" .. name
      local owner, _ = sys.open(path .. "/owner", sys.O_RDWR | sys.O_NOFOLLOW)
      if owner ~= nil then
        local descriptor: Descriptor = { fd = owner }
        local probe <close> = setmetatable(descriptor, descriptor_mt)
        local dead, _ = sys.flock(probe.fd, "exclusive", 0)
        if dead then local _, _ = Fs.remove_tree(path) end
      end
    end
  end
  local path, create_trouble = sys.mkdtemp(cache .. "/.scratch.XXXXXX")
  if path == nil then return nil, create_trouble end
  local owner, owner_trouble = sys.open(path .. "/owner", sys.O_RDWR | sys.O_CREAT | sys.O_EXCL, 0x180)
  if owner == nil then
    local _, _ = Fs.remove_tree(path)
    return nil, owner_trouble
  end
  local owned: Scratch = { path = path, owner = owner }
  local holding = setmetatable(owned, scratch_mt)
  local held, hold_trouble = sys.flock(owner, "exclusive", 0)
  if not held then
    local _cleanup <close> = holding
    return nil, hold_trouble
  end
  return holding, ""
end

--- The directory under `cache` holding `name`'s patched tree, written
--- there first when it is not yet. Every file and directory of the tree
--- is fsynced before it takes its name. On Darwin, a full device-cache
--- flush is requested too; the device still decides what reaches stable
--- storage.
-- TODO: nothing removes a tree no build names any more, and each edit
-- that changes a tree's bytes leaves the one before behind (tens of MB
-- when every tree changes at once); remove the ones older than the newest of each
-- name, or those no manifest (o/patched.tsv) names, as zig leaves its
-- own cache to be deleted whole.
function Patch.prepare(root: string, name: string, cache: string): string | nil, string
  local inputs, trouble = read_inputs(root, name)
  if inputs == nil then
    return nil, trouble
  end
  local tree, patch_trouble = patched(inputs)
  if tree == nil then
    return nil, patch_trouble
  end
  local dir = cache .. "/" .. name .. "-" .. key_of(tree)
  local present, present_trouble = Fs.exists(dir)
  if present == nil then
    return nil, present_trouble
  end
  if present then
    return dir, ""
  end
  local made, made_trouble = Fs.mkdirs(cache)
  if not made then
    return nil, made_trouble
  end
  local owned, own_trouble = scratch(cache)
  if owned == nil then return nil, own_trouble end
  local holding <close> = owned
  local payload = holding.path .. "/payload"
  local written, write_trouble = write_tree(tree, payload)
  if not written then
    return nil, write_trouble
  end
  local host, host_trouble = sys.uname()
  if host == nil then return nil, host_trouble end
  if host.sysname == "Darwin" then
    -- F_FULLFSYNC needs a regular file. The held owner is on the
    -- payload's filesystem, even when the payload has no files.
    local flushed, flush_trouble = sys.full_fsync(holding.owner)
    if not flushed then return nil, holding.path .. "/owner: " .. flush_trouble end
  end
  local moved, move_trouble = Fs.rename(payload, dir)
  if not moved then
    -- Another build may have won the race; its tree is the same bytes.
    local raced, _ = Fs.exists(dir)
    if raced then
      return dir, ""
    end
    return nil, move_trouble
  end
  -- The rename itself, so the next build finds the tree rather than
  -- writing it again. Best effort: the tree at its name is whole
  -- whether or not the rename lasts.
  local _, _ = sync_dir(cache)
  return dir, ""
end

--- Writes zig's library directory `lib` into `out`, which must not
--- exist, with every record under `root/patch/zig-lib/` applied in name
--- order, each `file:` a path under `lib`: what bin/zig points zig at
--- (build/zig.tl's `patched_lib`). The copy is `cp -Rp`'s
--- ([`Fs.copy_tree`]), made under a scratch directory beside `out` and
--- renamed into place whole, so a directory at that name is always a
--- whole patched library. One another build put there first is kept.
function Patch.zig_lib(root: string, lib: string, out: string): boolean, string
  local dir = root .. "/patch/zig-lib"
  local names, list_trouble = Fs.list(dir)
  if names == nil then
    return false, list_trouble
  end
  local cache = Fs.dirname(out)
  local owned, own_trouble = scratch(cache)
  if owned == nil then return false, own_trouble end
  local holding <close> = owned
  local payload = holding.path .. "/payload"
  local copied, copy_trouble = Fs.copy_tree(lib, payload)
  if not copied then
    return false, copy_trouble
  end
  for _, entry in ipairs(names) do
    if #entry > 4 and entry:sub(-4) == ".txt" then
      local name = "patch/zig-lib/" .. entry
      local text, text_trouble = Fs.read(dir .. "/" .. entry)
      if text == nil then
        return false, text_trouble
      end
      local parsed, parse_trouble = Patch.parse(text, name)
      if parsed == nil then
        return false, parse_trouble
      end
      local path = payload .. "/" .. parsed.file
      local st, _ = sys.lstat(path)
      if st == nil or st.kind ~= "file" then
        return false, name .. ": no file " .. parsed.file .. " to patch"
      end
      local source, read_trouble = Fs.read(path)
      if source == nil then
        return false, read_trouble
      end
      local applied, apply_trouble = Patch.apply(source, parsed, name)
      if applied == nil then
        return false, apply_trouble
      end
      -- A fresh file, for one the copy keeps read-only.
      local removed, remove_trouble = Fs.remove(path)
      if not removed then
        return false, remove_trouble
      end
      local written, write_trouble = write_synced(path, applied, st.mode & 0x1ff)
      if not written then
        return false, write_trouble
      end
    end
  end
  local moved, move_trouble = Fs.rename(payload, out)
  if not moved then
    -- Another build may have won the race; its library is the same bytes.
    local raced, _ = Fs.exists(out)
    if raced then
      return true, ""
    end
    return false, move_trouble
  end
  return true, ""
end

--- Every vendored tree's name under `root`: each `vendor/<name>` with a
--- PIN, in name order.
function Patch.names(root: string): {string} | nil, string
  local entries, trouble = Fs.list(root .. "/vendor")
  if entries == nil then
    return nil, trouble
  end
  local names: {string} = {}
  for _, name in ipairs(entries) do
    local pinned, _ = Fs.exists(root .. "/vendor/" .. name .. "/PIN")
    if pinned then
      names[#names + 1] = name
    end
  end
  return names, ""
end

--- The whole entry point, over `argv` as the entry-point contract
--- hands it: `argv[0]` is this script's own path.
function Patch.main(argv: {integer:string}): integer
  if argv[1] == "--zig-lib" then
    local root, lib, out = argv[2], argv[3], argv[4]
    if root == nil or lib == nil or out == nil or argv[5] ~= nil then
      log:complain("usage: cosmic --standalone build/patch.tl --zig-lib <root> <lib> <out>")
      return 2
    end
    local written, trouble = Patch.zig_lib(root, lib, out)
    if not written then
      log:complain(trouble)
      return 1
    end
    return 0
  end
  local root, cache = argv[1], argv[2]
  if root == nil or cache == nil or argv[3] ~= nil then
    log:complain("usage: cosmic --standalone build/patch.tl <root> <cache>")
    return 2
  end
  local names, trouble = Patch.names(root)
  if names == nil then
    log:complain(trouble)
    return 1
  end
  local lines: {string} = {}
  for _, name in ipairs(names) do
    local dir, prepare_trouble = Patch.prepare(root, name, cache)
    if dir == nil then
      log:complain(prepare_trouble)
      return 1
    end
    lines[#lines + 1] = name .. "\t" .. dir .. "\n"
  end
  local put, put_trouble = Fs.put(Fs.stdout, table.concat(lines))
  if not put then
    log:complain(put_trouble)
    return 1
  end
  return 0
end

return Patch
