local Xml = require("cosmic.xml")

--- Events as text, to compare: one per `|`, each its kind, then its name
--- and its attributes (sorted, `name=value`) or its text, quoted.
local function show(events: {Xml.Event}): string
  local out: mut {string} = {}
  for _, e in ipairs(events) do
    local parts: mut {string} = { e.kind }
    local element = e.name
    if element ~= nil then parts[#parts + 1] = element end
    local attributes = e.attributes
    if attributes ~= nil then
      local names: mut {string} = {}
      for name in pairs(attributes) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        parts[#parts + 1] = name .. "=" .. assert(attributes[name])
      end
    end
    local text = e.text
    if text ~= nil then parts[#parts + 1] = string.format("%q", text) end
    out[#out + 1] = table.concat(parts, " ")
  end
  return table.concat(out, "|")
end

local function read(text: string, opts?: Xml.Options): string
  local events, why = Xml.events(text, opts)
  assert(events ~= nil, why)
  return show(events)
end

local function refused(text: string, opts?: Xml.Options): string
  local events, why = Xml.events(text, opts)
  assert(events == nil, "read as " .. show(events or {}))
  return why
end

local function test_events_in_document_order()
  local got = read('<?xml version="1.0"?><a href="x" id="1">hi<!-- note --><b/><?go now?></a>')
  assert(got == 'start a href=x id=1|text "hi"|comment " note "|start b|end b|instruction go "now"|end a', got)
end

local function test_text_reads_references_cdata_and_entities()
  local got = read('<!DOCTYPE a [<!ENTITY who "world">]><a>&lt;&#x41;<![CDATA[<x>]]>&who;</a>')
  assert(got == 'start a|text "<A<x>world"|end a', got)
end

--- However the chunks split it, a document answers the same events, and a
--- run of character data stays one event.
local function test_chunks_split_anywhere()
  local text = '<r k="v">one &amp; two<c>three</c>\n four</r>'
  local whole = read(text)
  for size = 1, #text do
    local p <close> = assert(Xml.parser())
    local all: mut {Xml.Event} = {}
    for at = 1, #text, size do
      for _, e in ipairs((assert(p:feed(text:sub(at, at + size - 1))))) do all[#all + 1] = e end
    end
    for _, e in ipairs((assert(p:finish()))) do all[#all + 1] = e end
    assert(show(all) == whole, "split by " .. tostring(size) .. ": " .. show(all))
  end
end

local function test_namespaces_answer_clark_notation()
  local text = '<x:a xmlns:x="urn:x" x:k="1" plain="2"><b xmlns="urn:d"/></x:a>'
  local got = read(text, { namespaces = true })
  assert(got == 'start {urn:x}a plain=2 {urn:x}k=1|start {urn:d}b|end {urn:d}b|end {urn:x}a', got)
  assert(read(text) == 'start x:a plain=2 x:k=1 xmlns:x=urn:x|start b xmlns=urn:d|end b|end x:a')
  local why = refused("<y:a/>", { namespaces = true })
  assert(why == "xml: line 1, column 1: unbound prefix", why)
end

local function test_refusals_name_where()
  local why = refused("<a>\n  <b></a>")
  assert(why == "xml: line 2, column 8: mismatched tag", why)
  why = refused("<a>")
  assert(why:match("^xml: line 1, column 4: ") ~= nil, why)
  why = refused('<a x="1" x="2"/>')
  assert(why == "xml: line 1, column 10: duplicate attribute", why)
end

--- The billion laughs: expat's amplification limit refuses the expansion
--- before it is built.
local function test_entity_expansion_is_bounded()
  local lines: mut {string} = { '<!DOCTYPE l [<!ENTITY l0 "lol">' }
  for i = 1, 9 do
    lines[#lines + 1] = string.format('<!ENTITY l%d "%s">', i, string.rep("&l" .. tostring(i - 1) .. ";", 10))
  end
  lines[#lines + 1] = "]><l>&l9;</l>"
  local why = refused(table.concat(lines))
  assert(why:match("amplification") ~= nil, why)
end

--- An external entity is never fetched: a reference to one is skipped.
local function test_external_entities_are_not_read()
  local got = read('<!DOCTYPE a [<!ENTITY e SYSTEM "file:///etc/passwd">]><a>[&e;]</a>')
  assert(got == 'start a|text "[]"|end a', got)
end

local function test_a_finished_parser_raises()
  local p = assert(Xml.parser())
  assert(p:feed("<a/>"))
  assert(p:finish())
  local ok, why = pcall(p.feed, p, "<b/>")
  assert(not ok and tostring(why):match("the parser is finished") ~= nil, tostring(why))
  local failed = assert(Xml.parser())
  assert(failed:feed("<a></b>") == nil)
  local finished, _ = pcall(failed.finish, failed)
  assert(not finished)
  local closed = assert(Xml.parser())
  do
    local _ <close> = closed
  end
  local fed, _ = pcall(closed.feed, closed, "<a/>")
  assert(not fed)
end
