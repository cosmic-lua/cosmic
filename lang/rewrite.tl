--- Puts the checker's errors right where each has one rewrite that keeps what the program means ([`Codes.Rewrite`]):
--- `n` in `"n=" .. n` becomes `tostring(n)`, and a `boolean?` condition `x` becomes `x == true`. `cosmic fix` writes
--- them into a file, and cosmic agent's run into a refused snippet before it runs it, telling the model what it changed.
local Codes = require("lang.check_codes")

local record Rewrite
  --- A rewrite at a place of a text: the error's code and where it is, and what to write before and after the place.
  record Edit
    code: string
    y: integer
    x: integer
    --- The byte the place begins at, from 1, and how many bytes it spans.
    offset: integer
    length: integer
    before: string
    after: string
    --- What replaces the text of the place, between `before` and `after`; nil where the text of the place stays.
    text?: string
  end

  --- A rewrite made: where, under which code, and the text of the place before and after it.
  record Made
    code: string
    y: integer
    x: integer
    was: string
    now: string
  end

  --- A text with edits made to it, and what each made, in the order of the text.
  record Applied
    text: string
    made: {Made}
  end
end

--- The edit that makes the rewrite `r` of an error `code` at the place `y`, `x`, `offset`, `length`: at the place the
--- rewrite names where it names one.
function Rewrite.edit(code: string, y: integer, x: integer, offset: integer, length: integer, r: Codes.Rewrite): Rewrite.Edit
  local place = r.place
  if place ~= nil then
    y, x, offset, length = place.y, place.x, place.offset, place.length
  end
  return { code = code, y = y, x = x, offset = offset, length = length, before = r.before, after = r.after, text = r.text }
end

--- `text` with `edits` made to it. Of two edits whose places overlap,
--- the first made is kept and the other left: the text it was about is gone. The same edit twice (two stages that tell
--- one error) is made once.
function Rewrite.apply(text: string, edits: {Rewrite.Edit}): Rewrite.Applied
  local sorted: mut {Rewrite.Edit} = {}
  for _, e in ipairs(edits) do sorted[#sorted + 1] = e end
  table.sort(sorted, function(a: Rewrite.Edit, b: Rewrite.Edit): boolean
    if a.offset ~= b.offset then return a.offset < b.offset end
    return a.length > b.length
  end)
  local kept: mut {Rewrite.Edit} = {}
  -- The first byte no edit kept has taken.
  local free = 1
  for _, e in ipairs(sorted) do
    if e.offset >= free and e.offset + e.length <= #text + 1 then
      kept[#kept + 1] = e
      free = e.offset + math.max(e.length, 1)
    end
  end
  local made: mut {Rewrite.Made} = {}
  local parts: mut {string} = {}
  local at = 1
  for _, e in ipairs(kept) do
    local was = text:sub(e.offset, e.offset + e.length - 1)
    local now = e.before .. (e.text or was) .. e.after
    parts[#parts + 1] = text:sub(at, e.offset - 1)
    parts[#parts + 1] = now
    at = e.offset + e.length
    made[#made + 1] = { code = e.code, y = e.y, x = e.x, was = was, now = now }
  end
  parts[#parts + 1] = text:sub(at)
  return { text = table.concat(parts), made = made }
end

--- `text` with the rewrites `edits_of` finds in it made, round after round, until it finds none or `most` rounds are
--- made: a checker tells one error of an expression at a time (the right operand of `a > b` once the left is put
--- right), so the text a round makes is checked again. What each round made is in the order of the rounds.
function Rewrite.rounds(text: string, edits_of: function(text: string): {Rewrite.Edit}, most: integer): Rewrite.Applied
  local made: mut {Rewrite.Made} = {}
  local now = text
  for _ = 1, most do
    local edits = edits_of(now)
    if #edits == 0 then break end
    local applied = Rewrite.apply(now, edits)
    if applied.text == now then break end
    for _, m in ipairs(applied.made) do made[#made + 1] = m end
    now = applied.text
  end
  return { text = now, made = made }
end

--- What `made` changed in the file `file`, a line for each: `file:y:x: code: `was` -> `now``.
function Rewrite.told(file: string, made: {Rewrite.Made}): {string}
  local out: mut {string} = {}
  for _, m in ipairs(made) do
    out[#out + 1] = file .. ":" .. tostring(m.y) .. ":" .. tostring(m.x) .. ": " .. m.code .. ": `" .. m.was .. "` -> `" ..
      m.now .. "`"
  end
  return out
end

return Rewrite
