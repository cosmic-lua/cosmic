local Fuzz = require("build.fuzz")
local Xml = require("cosmic.xml")

--- Pieces of XML, well-formed and not, that a document is strung from:
--- markup that opens and closes, references, sections, and bytes no
--- document may hold.
local PIECES <const>: {string} = {
  "<a>", "</a>", "<b x='1'>", "</b>", "<c/>", "<p:d xmlns:p='urn:p'>", "</p:d>", "text", " ", "\n",
  "&amp;", "&#x41;", "&e;", "&bogus;", "<![CDATA[<x>]]>", "<!-- note -->", "<?pi data?>", "\u{E9}",
  "<", ">", "&", "]]>", "\0", "\xff", "'", '"',
}

--- A document: an optional prolog, a root, and pieces inside it.
local function gen_document(src: Fuzz.Source): string
  local parts: mut {string} = {}
  if src:int(0, 2) == 0 then parts[#parts + 1] = '<!DOCTYPE r [<!ENTITY e "entity">]>' end
  parts[#parts + 1] = "<r>"
  while Fuzz.more(src, #parts, 40) do
    local piece = if src:int(0, 9) == 0 then Fuzz.bytes(src, 4) else Fuzz.pick(src, PIECES) end
    parts[#parts + 1] = piece
  end
  if src:int(0, 3) ~= 0 then parts[#parts + 1] = "</r>" end
  return table.concat(parts)
end

--- The events of `text` fed in pieces of `size` bytes, each as a line, or
--- the reason it was refused.
local function read(text: string, size: integer): string
  local p <close> = assert(Xml.parser({ namespaces = true }))
  local out: mut {string} = {}
  local function take(events: {Xml.Event})
    for _, e in ipairs(events) do
      local line = e.kind .. " " .. (e.name or "") .. " " .. (e.text or "")
      out[#out + 1] = line
    end
  end
  for at = 1, #text, size do
    local events, why = p:feed(text:sub(at, at + size - 1))
    if events == nil then return why end
    take(events)
  end
  local last, why = p:finish()
  if last == nil then return why end
  take(last)
  return table.concat(out, "\n")
end

--- However a document is split into chunks, the parser answers the same
--- events, or refuses it with the same message.
local function test_chunks_never_change_what_a_document_reads(tmp: string)
  Fuzz.run({
    name = "xml chunking",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return gen_document(src)
    end,
    requires = { "read", "refused" },
    shares = { read = 0.05, refused = 0.2 },
    check = function(text: string): boolean, string
      local whole = read(text, math.max(#text, 1))
      for _, size in ipairs({ 1, 2, 7 }) do
        local split = read(text, size)
        if split ~= whole then
          return false, "split by " .. tostring(size) .. ":\n" .. split .. "\nwhole:\n" .. whole
        end
      end
      Fuzz.label(if whole:match("^xml: ") ~= nil then "refused" else "read" end)
      return true, ""
    end,
  })
end

--- Every document a parser reads, written back, reads to the same events.
local function test_what_reads_writes_back_to_the_same_events(tmp: string)
  Fuzz.run({
    name = "xml write round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return gen_document(src)
    end,
    requires = { "written" },
    shares = { written = 0.05 },
    check = function(text: string): boolean, string
      local events = Xml.events(text)
      if events == nil then return true, "" end
      local written, why = Xml.write(events)
      if written == nil then return false, "read but not written: " .. why end
      local again, trouble = Xml.events(written)
      if again == nil then return false, "written but not read: " .. trouble .. "\n" .. written end
      local before = read(text, #text)
      local after = read(written, #written)
      if before ~= after then return false, "read back otherwise:\n" .. written end
      Fuzz.label("written")
      return true, ""
    end,
  })
end
