--- @public
--- Replacements of exact text in a file's body, as cosmic agent's edit tool makes them and a snippet's
--- [`Host.edit`] does: each old text must be in the body once, as it was before any replacement, and no two may
--- overlap. The body is matched with LF line ends, as a model writes them, and a body of CRLF line ends keeps them.
---
---     local body = assert(Edit.apply("one teh two\n", { { old = "teh", new = "the" } }, "notes.txt", "old"))

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
--- field `field` (as `oldText` for the tool, `old` for [`Host.edit`]).
function Edit.apply(raw: string, edits: {Edit.Replacement}, path: string, field: string): (string, integer) | (nil, string)
  if #edits == 0 then return nil, "edits must hold at least one replacement" end
  local crlf = raw:find("\r\n", 1, true) ~= nil
  local body = lf(raw)
  local order: mut {integer} = {}
  local starts: mut {integer: integer} = {}
  for i, e in ipairs(edits) do
    local name = string.format("edits[%d]", i - 1)
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

return Edit
