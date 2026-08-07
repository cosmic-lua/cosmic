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
--- The patch file sits beside its pin — `3p/tl/tl_pin.tl` carries
--- `3p/tl/tl_patch.tl` — and edits name files relative to the pin's
--- unpack directory under `o/`. The literal grammar has no array part,
--- so edits are named entries, applied in sorted-name order:
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

--- The patch file beside a pin, or nil when the pin carries none.
--- @param pin_source string The pin's path (`.../<stem>_pin.tl`)
--- @return string|nil The `<stem>_patch.tl` path when it exists
local function of_pin(pin_source: string): string | nil
  if not str.ends_with(pin_source, "_pin.tl") then
    return nil
  end
  local p = string.sub(pin_source, 1, #pin_source - #"_pin.tl") .. "_patch.tl"
  if fs.is_file(p) then
    return p
  end
  return nil
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

local record PatchModule
  type Edit = Edit
  of_pin: function(pin_source: string): string | nil
  read: function(path: string): {Edit} | nil, string
  applied: function(dir: string, edits: {Edit}): boolean
  apply: function(dir: string, edits: {Edit}): boolean, string
end

local M: PatchModule = {
  of_pin = of_pin,
  read = read,
  applied = applied,
  apply = apply,
}

return M
