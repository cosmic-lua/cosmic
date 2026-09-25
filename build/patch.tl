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

--- The records for `name` under `root`, as paths in name order: every
--- `.txt` in `patch/<name>/`, none when there is no such directory.
local function records(root: string, name: string): {string} | nil, string
  local dir = root .. "/patch/" .. name
  local present, trouble = Fs.exists(dir)
  if present == nil then
    return nil, trouble
  end
  if not present then
    return {}, ""
  end
  local names, list_trouble = Fs.list(dir)
  if names == nil then
    return nil, list_trouble
  end
  local found: {string} = {}
  for _, entry in ipairs(names) do
    if #entry > 4 and entry:sub(-4) == ".txt" then
      found[#found + 1] = dir .. "/" .. entry
    end
  end
  return found, ""
end

--- Writes `vendor/<name>` under `root` into `out`, which must not exist,
--- with its records applied.
function Patch.tree(root: string, name: string, out: string): boolean, string
  local vendor = root .. "/vendor/" .. name
  local files, trouble = Fs.walk(vendor)
  if files == nil then
    return false, trouble
  end
  local made, made_trouble = Fs.mkdirs(out)
  if not made then
    return false, made_trouble
  end
  for _, file in ipairs(files) do
    local from = vendor .. "/" .. file
    local st, st_trouble = Fs.stat(from)
    if st == nil then
      return false, st_trouble
    end
    local data, read_trouble = Fs.read(from)
    if data == nil then
      return false, read_trouble
    end
    local dir = file:match("^(.*)/[^/]+$")
    if dir ~= nil then
      local dirs, dirs_trouble = Fs.mkdirs(out .. "/" .. dir)
      if not dirs then
        return false, dirs_trouble
      end
    end
    local written, write_trouble = Fs.write(out .. "/" .. file, data, st.mode & 0x1ff)
    if not written then
      return false, write_trouble
    end
  end
  local paths, records_trouble = records(root, name)
  if paths == nil then
    return false, records_trouble
  end
  for _, path in ipairs(paths) do
    local text, text_trouble = Fs.read(path)
    if text == nil then
      return false, text_trouble
    end
    local parsed, parse_trouble = Patch.parse(text, path)
    if parsed == nil then
      return false, parse_trouble
    end
    local target = out .. "/" .. parsed.file
    local st, st_trouble = Fs.stat(target)
    if st == nil then
      return false, path .. ": " .. st_trouble
    end
    local source, read_trouble = Fs.read(target)
    if source == nil then
      return false, path .. ": " .. read_trouble
    end
    local patched, apply_trouble = Patch.apply(source, parsed, path)
    if patched == nil then
      return false, apply_trouble
    end
    local written, write_trouble = Fs.write(target, patched, st.mode & 0x1ff)
    if not written then
      return false, write_trouble
    end
  end
  return true, ""
end

--- The hash that names `name`'s patched tree: `applier`, the source doing
--- the patching, then every file of the vendored tree, with its
--- permission bits, and every record, each by its path and contents.
local function key_of(root: string, name: string, applier: string): string | nil, string
  local lines: {string} = {}
  local function add(label: string, data: string)
    lines[#lines + 1] = label .. " " .. Hash.hex_sha256(data) .. "\n"
  end
  add("applier", applier)
  local vendor = root .. "/vendor/" .. name
  local files, walk_trouble = Fs.walk(vendor)
  if files == nil then
    return nil, walk_trouble
  end
  for _, file in ipairs(files) do
    local data, read_trouble = Fs.read(vendor .. "/" .. file)
    if data == nil then
      return nil, read_trouble
    end
    local st, st_trouble = Fs.stat(vendor .. "/" .. file)
    if st == nil then
      return nil, st_trouble
    end
    add("vendor/" .. file .. " " .. tostring(st.mode & 0x1ff), data)
  end
  local paths, records_trouble = records(root, name)
  if paths == nil then
    return nil, records_trouble
  end
  for _, path in ipairs(paths) do
    local data, read_trouble = Fs.read(path)
    if data == nil then
      return nil, read_trouble
    end
    add(path:sub(#root + 2), data)
  end
  return Hash.hex_sha256(table.concat(lines)), ""
end

--- The directory under `cache` holding `name`'s patched tree, written
--- there first when it is not yet.
function Patch.prepare(root: string, name: string, cache: string,
                       applier: string): string | nil, string
  local key, trouble = key_of(root, name, applier)
  if key == nil then
    return nil, trouble
  end
  local dir = cache .. "/" .. name .. "-" .. key
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
  local scratch = dir .. ".work." .. tostring(sys.getpid())
  local _, _ = Fs.remove_tree(scratch)
  local written, write_trouble = Patch.tree(root, name, scratch)
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
