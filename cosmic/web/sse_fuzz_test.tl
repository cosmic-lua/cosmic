--- Fuzz property for [`Sse.format_event`], whose input is data a program
--- takes from users: whatever the fields hold, the output is one event at
--- most, carrying the fields given and none that were not.

local Fuzz = require("build.fuzz")
local Sse = require("cosmic.web.sse")

--- Pieces that make a line ending, a field name or a blank line out of a field.
local PIECES <const>: {string} = {
  "a", "b", " ", ":", "\n", "\r", "\r\n", "\0", "data: x", "event: y", "id: z", "retry: 5", "\n\n",
  "\r\r", "\n\r", ": c", "é", "\xff",
}

--- A field value: pieces, and at times a stray byte.
local function gen_text(src: Fuzz.Source): string
  local parts: mut {string} = {}
  while Fuzz.more(src, #parts, 8) do
    if src:int(0, 9) == 0 then
      parts[#parts + 1] = Fuzz.bytes(src, 3)
    else
      parts[#parts + 1] = Fuzz.pick(src, PIECES)
    end
  end
  return table.concat(parts)
end

--- Five fields, each present or not, and a retry.
local function gen_event(src: Fuzz.Source): string
  local present = ""
  local texts: mut {string} = {}
  for i = 1, 4 do
    local has = src:int(0, 2) ~= 0
    present = present .. (if has then "1" else "0" end)
    local text = has and gen_text(src) or ""
    -- The event and the id are mostly drawn to be valid, so most inputs reach the formatter.
    if (i == 2 or i == 3) and src:int(0, 4) ~= 0 then text = text:gsub("[%c]", "") end
    texts[#texts + 1] = text
  end
  local fields: mut {string} = { present }
  for _, text in ipairs(texts) do fields[#fields + 1] = text end
  fields[#fields + 1] = tostring(Fuzz.pick(src, { 0, 1, 3000, 7, 7, 0, 5000, -1 }))
  return Fuzz.pack(fields)
end

--- `text` with every line ending as LF.
local function unified(text: string): string
  local lf = text:gsub("\r\n", "\n")
  lf = lf:gsub("\r", "\n")
  return lf
end

--- Whether the field can carry the text: no line ending and no NUL.
local function carried(value: string): boolean
  return not value:find("[\r\n%z]")
end

local function test_format_event_makes_one_event_with_the_fields_given_and_no_other(tmp: string)
  Fuzz.run({
    name = "sse format_event",
    dir = tmp,
    gen = gen_event,
    requires = { "formatted", "refused", "injection attempt" },
    shares = { formatted = 0.3, refused = 0.05 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local present = assert(fields[1], "the generator packs which fields are present")
      local retry = math.tointeger(tonumber(fields[6]))
      local ev: Sse.Event = { retry = retry }
      if present:sub(1, 1) == "1" then ev.data = fields[2] end
      if present:sub(2, 2) == "1" then ev.event = fields[3] end
      if present:sub(3, 3) == "1" then ev.id = fields[4] end
      if present:sub(4, 4) == "1" then ev.comment = fields[5] end
      local ev_event, ev_id = ev.event, ev.id
      local expect_refusal = (retry ~= nil and retry < 0) or
        (ev_event ~= nil and not carried(ev_event)) or (ev_id ~= nil and not carried(ev_id))
      local ok, out = pcall(Sse.format_event, ev)
      if not ok then
        if not expect_refusal then return false, "refused a valid event: " .. tostring(out) end
        Fuzz.label("refused")
        return true, ""
      end
      if expect_refusal then
        return false, "formatted an event a field of which cannot be carried"
      end
      if out:find("\r", 1, true) then return false, "a CR in the output" end
      if out == "" then return true, "" end
      Fuzz.label("formatted")
      if out:sub(-2) ~= "\n\n" or out:find("\n\n", 1, true) ~= #out - 1 then
        return false, "a blank line before the end of the event"
      end
      local seen: mut {string: integer} = {}
      local data: mut {string} = {}
      local comment: mut {string} = {}
      local id: string? = nil
      local event: string? = nil
      for line in out:sub(1, -3):gmatch("[^\n]*") do
        local name, value = line:match("^(%a+): (.*)$")
        if line:sub(1, 2) == ": " then
          comment[#comment + 1] = line:sub(3)
        elseif name == "data" then
          data[#data + 1] = value
        elseif name == "event" or name == "id" or name == "retry" then
          seen[name] = (seen[name] or 0) + 1
          if name == "id" then id = value elseif name == "event" then event = value end
        else
          return false, ("a line that is no field this event holds: %q"):format(line)
        end
      end
      for name, n in pairs(seen) do
        if n > 1 then return false, name .. " appears " .. tostring(n) .. " times" end
      end
      local ev_data = ev.data
      if ev_data ~= nil and table.concat(data, "\n") ~= unified(ev_data) then
        return false, "the data does not rejoin"
      end
      if ev.data == nil and #data > 0 then return false, "data from nowhere" end
      local ev_comment = ev.comment
      if ev_comment ~= nil and table.concat(comment, "\n") ~= unified(ev_comment) then
        return false, "the comment does not rejoin"
      end
      if ev.comment == nil and #comment > 0 then return false, "a comment from nowhere" end
      if id ~= ev.id then return false, "id differs" end
      if (ev.event or "") ~= (event or "") then return false, "event differs" end
      if (retry or 0) == 0 and seen.retry ~= nil then return false, "retry from nowhere" end
      if (retry or 0) > 0 and seen.retry ~= 1 then return false, "retry is lost" end
      if (ev.data or ""):find("[\r\n]") or (ev.comment or ""):find("[\r\n]") then
        Fuzz.label("injection attempt")
      end
      return true, ""
    end,
  })
end
