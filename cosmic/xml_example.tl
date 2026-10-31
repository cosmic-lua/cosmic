--- Worked examples for [`cosmic.xml`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Xml = require("cosmic.xml")

local record Example end

--- A parser takes the text in chunks, split anywhere, and answers each
--- with the events it completes: here the item names of a feed, read as
--- it arrives.
function Example.parser()
  local p <close> = assert(Xml.parser())
  local titles: mut {string} = {}
  local inside = false
  local function take(events: {Xml.Event})
    for _, e in ipairs(events) do
      if e.kind == "start" and e.name == "title" then
        inside = true
      elseif e.kind == "end" and e.name == "title" then
        inside = false
      elseif e.kind == "text" and inside then
        local text = assert(e.text)
        titles[#titles + 1] = text
      end
    end
  end
  for _, chunk in ipairs({ "<feed><item><ti", "tle>One &amp; two</title></item>",
      "<item><title>Three</title></item></feed>" }) do
    take((assert(p:feed(chunk))))
  end
  take((assert(p:finish())))
  assert(table.concat(titles, "; ") == "One & two; Three")
end

--- `events` reads a document whole; with `namespaces`, a name in one is
--- `{uri}local`. A document that is not well-formed is refused, naming
--- where.
function Example.events()
  local events = assert(Xml.events('<a xmlns="urn:x" id="7">hi</a>', { namespaces = true }))
  local first = assert(events[1])
  assert(first.kind == "start" and first.name == "{urn:x}a")
  assert(assert(first.attributes)["id"] == "7")
  local none, why = Xml.events("<a><b></a>")
  assert(none == nil)
  print(why) -- xml: line 1, column 9: mismatched tag
end

--- `write` turns events back into a document, here one built by hand;
--- a parser reads it back to the same events. It refuses events that are
--- no document, naming the event.
function Example.write()
  local text = assert(Xml.write({
    { kind = "start", name = "note", attributes = { to = "Ann & Bob" } },
    { kind = "text", text = "1 < 2" },
    { kind = "end", name = "note" },
  }))
  assert(text == '<note to="Ann &amp; Bob">1 &lt; 2</note>')
  local none, why = Xml.write({ { kind = "start", name = "a" } })
  assert(none == nil)
  print(why) -- xml: <a> is not closed
end

--- `tree` reads a small document whole; `child`, `children` and `text`
--- find what it holds. With `local_names`, a name loses its namespace,
--- so `r:id` reads as `id`.
function Example.tree()
  local root = assert(Xml.tree([[
<sheets xmlns="urn:main" xmlns:r="urn:rel">
  <sheet name="Sales" r:id="rId1"/>
  <sheet name="Costs" r:id="rId2"/>
  <note>Kept <b>whole</b></note>
</sheets>]], { local_names = true }))
  for _, sheet in ipairs(Xml.children(root, "sheet")) do
    print(sheet.attributes["name"], sheet.attributes["id"]) -- Sales  rId1, then Costs  rId2
  end
  local note = assert(Xml.child(root, "note"))
  assert(Xml.text(note) == "Kept whole")
end

--- `subtrees` reads one element at a time from a document fed in
--- chunks, here each `row`, so a document of any size is held a row at
--- a time.
function Example.subtrees()
  local p <close> = assert(Xml.parser())
  local rows = Xml.subtrees("table/row")
  local total = 0
  for _, chunk in ipairs({ "<table><row><n>2</n></ro", "w><row><n>3</n></row></table>" }) do
    for _, row in ipairs(rows:take((assert(p:feed(chunk))))) do
      total = total + assert(math.tointeger(Xml.text(assert(Xml.child(row, "n")))))
    end
  end
  for _, row in ipairs(rows:take((assert(p:finish())))) do
    total = total + assert(math.tointeger(Xml.text(assert(Xml.child(row, "n")))))
  end
  assert(total == 5, tostring(total))
end

return Example
