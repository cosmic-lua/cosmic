--- @public
--- Replacements of exact text in a file's body, as [`Edit.file`] and cosmic agent's edit tool make them: each old text must be in
--- the body once, as it was before any replacement, and no two may overlap. The body is matched with LF line ends, as a model writes them, and a body of CRLF line ends keeps them.
---
---     local body = assert(Edit.apply("one teh two\n", { { old = "teh", new = "the" } }, "notes.txt", "old"))

local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")

local record Edit
  --- One replacement: `old`, which the body holds once, becomes `new`.
  record Replacement
    --- The text to replace.
    old: string
    --- What takes its place.
    new: string
  end
end

--- `text` with LF line ends.
local function lf(text: string): string
  local out = text:gsub("\r\n", "\n")
  return out
end

--- `raw` with each of `edits` made, and how many were; or nil and why not, naming `path` and the replacements'
--- field `field` (as `oldText` for the tool), and each replacement by its index from `first` (0 where nil, as a JSON
--- list counts; 1 for a snippet's list).
function Edit.apply(raw: string, edits: {Edit.Replacement}, path: string, field: string, first?: integer):
    (string, integer) | (nil, string)
  if #edits == 0 then return nil, "edits must hold at least one replacement" end
  local crlf = raw:find("\r\n", 1, true) ~= nil
  local body = lf(raw)
  local order: mut {integer} = {}
  local starts: mut {integer: integer} = {}
  for i, e in ipairs(edits) do
    local name = string.format("edits[%d]", i - 1 + (first or 0))
    local old = lf(e.old)
    if old == "" then return nil, name .. "." .. field .. " must not be empty" end
    local at = body:find(old, 1, true)
    if at == nil then
      return nil, "Could not find " .. name .. " in " .. path .. ". The " .. field ..
        " must match exactly, including all whitespace and newlines."
    end
    if body:find(old, at + 1, true) ~= nil then
      return nil, "Found more than one occurrence of " .. name .. " in " .. path .. ". Each " .. field ..
        " must be unique: give more context to make it so."
    end
    starts[i] = at
    order[#order + 1] = i
  end
  table.sort(order, function(a: integer, b: integer): boolean
    return (starts[a] or 0) < (starts[b] or 0)
  end)
  local out: mut {string} = {}
  local from = 1
  for _, i in ipairs(order) do
    local e = assert(edits[i])
    local at = starts[i] or 0
    if at < from then return nil, "Two edits overlap in " .. path .. ": merge them into one." end
    out[#out + 1] = body:sub(from, at - 1)
    out[#out + 1] = lf(e.new)
    from = at + #lf(e.old)
  end
  out[#out + 1] = body:sub(from)
  local edited = table.concat(out)
  if crlf then edited = edited:gsub("\n", "\r\n") end
  return edited, #order
end

--- Makes each of `edits` in the file `path`, in place of writing it whole: each `old` is exact text that the file
--- holds once, as it was before any edit ([`Edit.apply`] says the rest), no two overlap, and a file of CRLF line ends
--- keeps them. A link's file is changed and the link kept. Returns how many edits it made, or nil and a [`Failure`]
--- that names the edit by its index in `edits` (from 1) and how to fix it; it changes nothing then.
---
---     local made = Edit.file("notes.md", { { old = "teh", new = "the" } })!
function Edit.file(path: string, edits: {Edit.Replacement}): (integer) | (nil, Failure)
  local file = path
  for _ = 1, 40 do
    local target, _ = Fs.readlink(file)
    if target == nil then break end
    file = if target:sub(1, 1) == "/" then target else Fs.dirname(file) .. "/" .. target end
  end
  local raw, why = Fs.read(file)
  if raw == nil then return nil, why end
  local edited, made = Edit.apply(raw, edits, path, "old", 1)
  if edited == nil then return nil, Failure.new(made) end
  local ok, write_why = Fs.write(file, edited)
  if not ok then return nil, write_why end
  return made
end

return Edit
