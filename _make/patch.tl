--- Carried patches: `*_patch.tl` is Teal **data**, like the pin it
--- rides beside.
---
--- A pin names bytes; sometimes those bytes need a small, deliberate
--- change this project cannot yet have upstream — a compiler fix in
--- flight, a backport. The change is declared, never computed: a patch
--- file is one `return { … }` of named edits, each an exact `find`
--- string replaced by an exact `replace` string in one unpacked file.
--- No diff format, no external tool — and the exactness is the safety:
---
--- - `find` must occur EXACTLY ONCE in the target, or the patch fails
---   loudly. A pin bump that moves the anchor is supposed to fail —
---   that failure is the "re-audit the patch" signal, never a silent
---   drift.
--- - Application is idempotent: a target already containing `replace`
---   is already patched, and re-fetching skips it.
--- - `fetch` re-verifies application the same way it re-verifies the
---   digest, so adding or changing a patch repairs on the next fetch
---   (the archive's bytes are still pristine; unpack restores them
---   before edits re-apply).
---
--- **Probing an entry.** A modified copy of a pinned file placed on
--- `package.path` is ignored. `require` resolves a module the binary
--- embeds from its own `/zip` before `package.path` is consulted, so
--- such a probe measures the shipped copy and reports a confident
--- wrong answer with nothing logged. `patch.reverse` is the probe: it
--- reverses named entries into a temporary copy and installs it in
--- `package.loaded`, which `require` reads before any searcher.
---
--- The patch sits beside its pin — `3p/tl/tl_pin.tl` carries
--- `3p/tl/tl_patch.tl`, or, when the entry set outgrows the 500-line
--- file cap, a `3p/tl/tl_patch/` directory whose `*.tl` files each
--- hold entries in the same format (capacity comes from splitting,
--- never from a cap exemption). Edits name files relative to the
--- pin's unpack directory under `o/`. The literal grammar has no
--- array part, so edits are named entries — one namespace across the
--- whole set, applied in sorted-name order:
---
---     return {
---       ["narrow-truthiness"] = {
---         file = "tl.lua",
---         find = [=====[exact anchor text]=====],
---         replace = [=====[exact replacement text]=====],
---         note = "why: an issue, an upstream PR",
---       },
---     }

local fs = require("cosmic.fs")
local literal = require("cosmic.literal")
local str = require("cosmic.string")

--- One declared edit.
local record Edit
  --- The entry's key in the patch file, for messages.
  name: string
  --- The file to edit, relative to the pin's unpack directory.
  file: string
  --- Exact text to replace; must occur exactly once.
  find: string
  --- Exact replacement text.
  replace: string
  --- Why this edit exists (an issue, an upstream PR).
  note: string
end

--- The patch beside a pin: the single `<stem>_patch.tl`, or the
--- sorted `*.tl` files of a `<stem>_patch/` directory. Nil (with no
--- error) when the pin carries neither; nil plus the reason when the
--- layout is ambiguous (both forms) or the directory is empty.
--- @param pin_source string The pin's path (`.../<stem>_pin.tl`)
--- @return {string}|nil The patch file paths, sorted
--- @return string The error when the layout cannot be used
local function paths_of_pin(pin_source: string): {string} | nil, string
  if not str.ends_with(pin_source, "_pin.tl") then
    return nil
  end
  local stem = string.sub(pin_source, 1, #pin_source - #"_pin.tl")
  local file = stem .. "_patch.tl"
  local dir = stem .. "_patch"
  local has_file = fs.is_file(file)
  local has_dir = fs.is_dir(dir)
  if has_file and has_dir then
    return nil, "make: " .. file .. " and " .. dir ..
    "/ both exist; keep exactly one"
  end
  if has_file then
    return {file}
  end
  if not has_dir then
    return nil
  end
  local found, gerr = fs.glob(dir, "*.tl")
  if not found then
    return nil, "make: " .. dir .. ": " .. (gerr or "cannot list")
  end
  local paths: {string} = {}
  for _, p in ipairs(found) do
    paths[#paths + 1] = p
  end
  table.sort(paths)
  if #paths == 0 then
    return nil, "make: " .. dir ..
    ": a patch directory with no *.tl entries is one to delete"
  end
  return paths
end

--- Read a patch file into its edits, in sorted-name order.
--- @param path string The `*_patch.tl` path
--- @return {Edit}|nil The edits
--- @return string The error naming the file
local function read(path: string): {Edit} | nil, string
  local data, err = literal.parse_file(path, {noun = "patch"})
  if not (data is {string: any}) then
    return nil, (err or (path .. ": not literal data"))
  end
  local names: {string} = {}
  for name in pairs(data) do
    names[#names + 1] = name
  end
  table.sort(names)
  local edits: {Edit} = {}
  for _, name in ipairs(names) do
    local raw = data[name]
    local where = path .. ": edit '" .. name .. "'"
    if not (raw is {string: any}) then
      return nil, where .. ": not a table of fields"
    end
    local e = raw
    local file = e["file"]
    local find = e["find"]
    local replace = e["replace"]
    local note = e["note"]
    if not (file is string) or not (find is string)
    or not (replace is string) or not (note is string) then
      return nil, where .. ": needs file, find, replace, note (all strings)"
    end
    edits[#edits + 1] = {
      name = name,
      file = file,
      find = find,
      replace = replace,
      note = note,
    }
  end
  if #edits == 0 then
    return nil, path .. ": a patch with no edits is a patch to delete"
  end
  return edits
end

--- Read a whole patch set: every file's edits merged into one
--- sorted-name list. One entry namespace whatever the layout, so a
--- name declared in two files is a conflict to refuse, never a
--- shadow — apply order stays the same as a single file's.
--- @param paths {string} The patch file paths
--- @return {Edit}|nil The merged edits
--- @return string The error naming the file (both, on a duplicate)
local function read_all(paths: {string}): {Edit} | nil, string
  local by_name: {string: string} = {}
  local all: {Edit} = {}
  for _, p in ipairs(paths) do
    local edits, err = read(p)
    if not edits then
      return nil, err
    end
    for _, e in ipairs(edits) do
      local prev = by_name[e.name]
      if prev then
        return nil, "make: patch edit '" .. e.name .. "' declared in both "
        .. prev .. " and " .. p .. "; entry names share one namespace"
      end
      by_name[e.name] = p
      all[#all + 1] = e
    end
  end
  table.sort(all, function(a: Edit, b: Edit): boolean
      return a.name < b.name
    end)
  return all
end

--- Occurrences of an exact substring.
local function count(haystack: string, needle: string): integer
  local n = 0
  local at = 1
  while true do
    local found = string.find(haystack, needle, at, true)
    if not found then
      return n
    end
    n = n + 1
    at = found + 1
  end
end

--- Are all edits already present in the unpacked tree?
--- @param dir string The pin's unpack directory
--- @param edits {Edit} The declared edits
--- @return boolean True when every target contains its replacement
local function applied(dir: string, edits: {Edit}): boolean
  for _, e in ipairs(edits) do
    local text = fs.read(fs.join(dir, e.file))
    if not (text is string) then
      return false
    end
    if not string.find(text, e.replace, 1, true) then
      return false
    end
  end
  return true
end

--- Apply every edit, exact-once, idempotently.
--- @param dir string The pin's unpack directory
--- @param edits {Edit} The declared edits
--- @return boolean, string Success, or false plus the reason
local function apply(dir: string, edits: {Edit}): boolean, string
  for _, e in ipairs(edits) do
    local target = fs.join(dir, e.file)
    local text = fs.read(target)
    if not (text is string) then
      return false, "make: patch edit '" .. e.name .. "': cannot read " .. target
    end
    local body = text
    if string.find(body, e.replace, 1, true) then
      -- Already applied: the idempotent re-fetch path.
    else
      local n = count(body, e.find)
      if n ~= 1 then
        return false, "make: patch edit '" .. e.name .. "' (" .. e.note ..
        "): anchor occurs " .. tostring(n) .. " time(s) in " .. target ..
        ", need exactly 1 — the pin moved; re-audit the patch"
      end
      local patched = str.replace(body, e.find, e.replace, 1)
      local wok, werr = fs.write(target, patched)
      if not wok then
        return false, "make: patch edit '" .. e.name .. "': cannot write " ..
        target .. ": " .. (werr or "unknown error")
      end
    end
  end
  return true
end

--- Which entries to reverse, in which unpacked file, loaded as what.
local record Options
  --- The pin's source path, e.g. "3p/tl/tl_pin.tl".
  pin: string
  --- The pin's unpack directory, e.g. "o/3p/tl".
  dir: string
  --- Entry names to reverse. Must be non-empty.
  entries: {string}
  --- The file under `dir` to load, e.g. "tl.lua". Every named entry
  --- must target it.
  file: string
  --- Module name to install the loaded copy as, e.g. "tl".
  module_name: string
end

--- Reverse named entries out of the unpacked file and install the
--- result as `opts.module_name`, so the next `require` of that name
--- observes the pin WITHOUT those edits.
---
--- The copy is installed in `package.loaded` because `require` reads
--- that table before it runs any searcher. The unpack directory is
--- never written: the reversed text lands in a fresh temporary
--- directory, under `TEST_TMPDIR` when that is set.
---
--- A caller whose process outlives the probe saves
--- `package.loaded[opts.module_name]` beforehand and puts it back
--- itself — `reverse` does not restore.
--- @param opts Options The entries to reverse and the name to load as
--- @return any|nil The loaded module
--- @return string The error
local function reverse(opts: Options): any, string
  local paths, perr = paths_of_pin(opts.pin)
  if not paths then
    return nil, perr or
    ("make: " .. opts.pin .. ": carries no patch to reverse")
  end
  local edits, rerr = read_all(paths)
  if not edits then
    return nil, rerr
  end
  if #opts.entries == 0 then
    return nil, "make: reverse needs at least one entry name"
  end
  local by_name: {string: Edit} = {}
  for _, e in ipairs(edits) do
    by_name[e.name] = e
  end
  local chosen: {Edit} = {}
  for _, name in ipairs(opts.entries) do
    local e = by_name[name]
    if not e then
      return nil, "make: patch edit '" .. name .. "': not declared by " ..
      opts.pin
    end
    if e.file ~= opts.file then
      return nil, "make: patch edit '" .. name .. "': targets " .. e.file ..
      ", not " .. opts.file
    end
    chosen[#chosen + 1] = e
  end
  local target = fs.join(opts.dir, opts.file)
  local text, terr = fs.read(target)
  if not (text is string) then
    return nil, "make: reverse: cannot read " .. target .. ": " ..
    (terr or "unknown error")
  end
  local body = text
  for _, e in ipairs(chosen) do
    local n = count(body, e.replace)
    if n ~= 1 then
      return nil, "make: patch edit '" .. e.name .. "': replacement occurs " ..
      tostring(n) .. " time(s) in " .. target .. ", need exactly 1 — " ..
      "the unpack directory is not patched; run `--make fetch`"
    end
    body = str.replace(body, e.replace, e.find, 1)
  end
  local root = os.getenv("TEST_TMPDIR") or "/tmp"
  local scratch, derr = fs.temp_dir(fs.join(root, "patch-reverse-XXXXXX"))
  if not scratch then
    return nil, "make: reverse: cannot make a temporary directory: " ..
    (derr or "unknown error")
  end
  local copy = fs.join(scratch, fs.basename(opts.file))
  local wok, werr = fs.write(copy, body)
  if not wok then
    return nil, "make: reverse: cannot write " .. copy .. ": " ..
    (werr or "unknown error")
  end
  local loaded = dofile(copy)
  package.loaded[opts.module_name] = loaded
  return loaded
end

local record PatchModule
  type Edit = Edit
  type Options = Options
  paths_of_pin: function(pin_source: string): {string} | nil, string
  read: function(path: string): {Edit} | nil, string
  read_all: function(paths: {string}): {Edit} | nil, string
  applied: function(dir: string, edits: {Edit}): boolean
  apply: function(dir: string, edits: {Edit}): boolean, string
  reverse: function(opts: Options): any, string
end

local M: PatchModule = {
  paths_of_pin = paths_of_pin,
  read = read,
  read_all = read_all,
  applied = applied,
  apply = apply,
  reverse = reverse,
}

return M
