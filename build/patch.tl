--- The patch applier: each vendored tree with its patch records applied,
--- written whole to a directory of its own.
---
---     cosmic --standalone build/patch.tl <root> <cache>
---
--- For every `vendor/<name>/PIN` under `root` it prints `<name>`, a tab,
--- and the directory holding `vendor/<name>` with every record under
--- `patch/<name>/` applied, in name order. The directory is
--- `<cache>/<name>-<key>`, `<key>` a hash of this file, every file of the
--- vendored tree and every record, so it is named by its contents alone:
--- the same from every checkout, which is what lets zig's cache, keyed by
--- a source's path, compile a vendored file once for all of them. One
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
--- The applier's own source is part of every key, so an edit to this file
--- -- a comment's included -- names every tree anew: zig compiles all of
--- vendor/ again, and, since the file is in the image fingerprint
--- (build/work.tl), the tool boots.
---
--- Like `build/zig.tl`, which runs it before every `zig build`, this runs
--- standalone -- against the running binary's own standard library,
--- never the tree it sits in -- so it requires `cosmic.*` modules only.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Log = require("cosmic.log")
local sys = require("cosmic.sys")

local record Patch
  --- One record, parsed.
  record Record
    file: string
    note: string
    find: string
    replace: string
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
  if line:sub(1, #prefix) ~= prefix then
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

--- Parses the record `text`, named `name` in what it says of it.
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
           replace = replaced }, ""
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
--- name the tree is given (`key_of`) and what is written under it
--- (`write_tree`) are of the same bytes whatever changes meanwhile: the
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

--- Writes `inputs` into `out`, which must not exist, with the records
--- applied, and syncs every file and directory it wrote. Modes are set
--- outright, whatever the umask.
local function write_tree(inputs: Inputs, out: string): boolean, string
  local dirs: {string} = { out }
  for _, dir in ipairs(inputs.dirs) do
    dirs[#dirs + 1] = out .. "/" .. dir
  end
  for _, dir in ipairs(dirs) do
    local made, trouble = Fs.mkdirs(dir)
    if not made then
      return false, trouble
    end
    local moded, mode_trouble = Fs.chmod(dir, 0x1ed)
    if not moded then
      return false, mode_trouble
    end
  end
  local contents: {string:string} = {}
  local modes: {string:integer} = {}
  for _, file in ipairs(inputs.files) do
    contents[file.path] = file.data
    modes[file.path] = file.mode
  end
  for _, input in ipairs(inputs.records) do
    local parsed, parse_trouble = Patch.parse(input.data, input.path)
    if parsed == nil then
      return false, parse_trouble
    end
    local source = contents[parsed.file]
    if source == nil then
      return false, input.path .. ": no file " .. parsed.file .. " to patch"
    end
    local patched, apply_trouble = Patch.apply(source, parsed, input.path)
    if patched == nil then
      return false, apply_trouble
    end
    contents[parsed.file] = patched
  end
  for _, file in ipairs(inputs.files) do
    local path = out .. "/" .. file.path
    local written, write_trouble = write_synced(path, contents[file.path],
      modes[file.path])
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
  return write_tree(inputs, out)
end

--- The hash that names a patched tree: `applier`, the source doing the
--- patching, then every directory and file of the vendored tree, each
--- file with its permission bits, and every record, each by its path and
--- contents.
local function key_of(inputs: Inputs, applier: string): string
  local lines: {string} = { "applier " .. Hash.hex_sha256(applier) .. "\n" }
  for _, dir in ipairs(inputs.dirs) do
    lines[#lines + 1] = "dir " .. dir .. "\n"
  end
  for _, file in ipairs(inputs.files) do
    lines[#lines + 1] = "file " .. file.path .. " " .. tostring(file.mode) ..
      " " .. Hash.hex_sha256(file.data) .. "\n"
  end
  for _, input in ipairs(inputs.records) do
    lines[#lines + 1] = "record " .. input.path .. " " ..
      Hash.hex_sha256(input.data) .. "\n"
  end
  return Hash.hex_sha256(table.concat(lines))
end

--- Removes every `<tree>.work.<pid>` under `cache` whose process is gone:
--- what a build killed partway left behind. A live process's own is left
--- alone.
local function sweep(cache: string)
  local names, _ = Fs.list(cache)
  if names == nil then
    return
  end
  for _, entry in ipairs(names) do
    local pid = math.tointeger(tonumber(entry:match("%.work%.(%d+)$")))
    if pid ~= nil and pid ~= sys.getpid() then
      local _, _, number = sys.kill(pid, 0)
      if number == sys.ESRCH then
        local _, _ = Fs.remove_tree(cache .. "/" .. entry)
      end
    end
  end
end

--- The directory under `cache` holding `name`'s patched tree, written
--- there first when it is not yet. The tree is synced whole before it
--- takes its name, so after a crash of the machine a tree at its name
--- is never one with empty or missing files.
-- TODO: nothing removes a tree no build names any more, and each edit to
-- a vendored tree, a record or this file leaves one behind (tens of MB
-- for every tree at once); remove the ones older than the newest of each
-- name, or those no manifest (o/patched.tsv) names, as zig leaves its
-- own cache to be deleted whole.
function Patch.prepare(root: string, name: string, cache: string,
                       applier: string): string | nil, string
  local inputs, trouble = read_inputs(root, name)
  if inputs == nil then
    return nil, trouble
  end
  local dir = cache .. "/" .. name .. "-" .. key_of(inputs, applier)
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
  sweep(cache)
  local scratch = dir .. ".work." .. tostring(sys.getpid())
  local _, _ = Fs.remove_tree(scratch)
  local written, write_trouble = write_tree(inputs, scratch)
  if not written then
    local _, _ = Fs.remove_tree(scratch)
    return nil, write_trouble
  end
  local moved, move_trouble = Fs.rename(scratch, dir)
  if not moved then
    local _, _ = Fs.remove_tree(scratch)
    -- Another build may have won the race; its tree is the same bytes.
    local raced, _ = Fs.exists(dir)
    if raced then
      return dir, ""
    end
    return nil, move_trouble
  end
  -- The rename itself, so the next build finds the tree rather than
  -- writing it again; the tree at its name is whole whether it did.
  local synced, sync_trouble = sync_dir(cache)
  if not synced then
    return nil, sync_trouble
  end
  return dir, ""
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
  local root, cache = argv[1], argv[2]
  if root == nil or cache == nil or argv[3] ~= nil then
    log:complain("usage: cosmic --standalone build/patch.tl <root> <cache>")
    return 2
  end
  local applier, applier_trouble = Fs.read(argv[0])
  if applier == nil then
    log:complain(applier_trouble)
    return 1
  end
  local names, trouble = Patch.names(root)
  if names == nil then
    log:complain(trouble)
    return 1
  end
  local lines: {string} = {}
  for _, name in ipairs(names) do
    local dir, prepare_trouble = Patch.prepare(root, name, cache, applier)
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
