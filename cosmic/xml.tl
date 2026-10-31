--- XML text as a stream of events: a reader over expat.
---
---     local p <close> = assert(Xml.parser())
---     local first = assert(p:feed('<a href="x">hi'))
---     -- { { kind = "start", name = "a", attributes = { href = "x" } } }
---     local rest = assert(p:feed("</a>"))
---     -- { { kind = "text", text = "hi" }, { kind = "end", name = "a" } }
---     assert(p:finish())
---
--- A parser takes the text a chunk at a time, split anywhere, and answers
--- each chunk with events in document order: those it completes, or
--- fewer. An event may come with a later chunk than the one that
--- completes it, and every one has come once `finish` answers: expat
--- puts off reading again a token a chunk left open until the text it
--- holds has doubled, so a large token fed in small chunks costs linear
--- time, not quadratic. A parser made `eager` reads it again at every
--- chunk instead, so each chunk answers every event it completes, which
--- a protocol that waits for a reply element before it sends more
--- needs. A run of character data is one `text` event however the
--- chunks split it: it is held back, whole, until markup follows it or
--- the input ends, and a run longer than `max_text` bytes is refused.
--- CDATA
--- sections, character references and the predefined and declared
--- entities are read into the text they stand for, and the text is
--- UTF-8, whatever encoding the document declares (UTF-8, UTF-16,
--- ISO-8859-1 or US-ASCII). A name is answered as written: `p:x` stays
--- `p:x` unless the parser was asked for namespaces, when an element's
--- or attribute's name in one is `{uri}local`, Clark's notation, and a
--- prefix with no declaration is refused.
---
--- What is refused, naming `line N, column M` (both from 1; a column
--- counts characters): text that is not well-formed XML, a run of text
--- past `max_text`, an encoding
--- other than the four above, and an entity whose expansion grows past
--- expat's amplification limits. No external entity or DTD is ever read:
--- a reference to an external entity in content is skipped, and so is
--- one to an entity a document with an external DTD leaves undeclared,
--- as XML allows a parser that reads no DTD; one in an attribute value
--- is refused. With namespaces, a namespace name holding `}` is refused
--- too, since Clark's notation could not be read back.
---
--- A failure finishes the parser, as does `finish`, a raise inside a
--- call (out of memory), or closing it: `feed` and `finish` raise on a
--- finished parser, and on one in a call already (from a finalizer
--- that runs during it).

-- The raw module behind the parser lives under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why this
-- indirection exists.
local type raw_xml = require("cosmic.internal.xml")

local Shape = require("cosmic.shape")

-- The table the store hands this module's loader. [`Shape.any`] checks
-- nothing: what the store hands a wrapper of its own is the core's.
local handed, _: raw_xml?, string = Shape.into(select(2, ...), Shape.any)
local raw <const>: raw_xml = handed or require("cosmic.internal.xml")

local record Xml
  --- What an event is:
  ---
  --- - `start`: an element opens. `name` is its name and `attributes`
  ---   maps each attribute's name to its value, normalized as XML says.
  ---   An empty element (`<br/>`) is a `start` and then an `end`.
  --- - `end`: an element closes; `name` is its name.
  --- - `text`: character data, in `text`, whitespace included.
  --- - `comment`: a comment's content, between `<!--` and `-->`, in
  ---   `text`.
  --- - `instruction`: a processing instruction: `name` is its target and
  ---   `text` the rest. The XML declaration is not one.
  type Kind = raw_xml.Kind

  --- One event. A field the kind does not name is nil.
  type Event = raw_xml.Event

  --- `feed(chunk)` answers events `chunk` completes, possibly none, and
  --- possibly ones an earlier chunk completed; `finish()` says the input
  --- has ended, and answers every event not yet answered. Each answers `events, ""`, or nil and why, and finishes
  --- the parser on a failure; `finish` finishes it either way. A parser
  --- is closeable: `local p <close> = assert(Xml.parser())` frees it at
  --- the end of the scope.
  type Parser = raw_xml.Parser

  record Options
    --- Answer names in a namespace as `{uri}local`.
    namespaces?: boolean
    --- Read a token a chunk left open again at every chunk, so a chunk
    --- answers every event it completes.
    eager?: boolean
    --- The longest run of text a parser holds, in bytes: 64 MiB when
    --- absent. A longer one is refused. Under 1 raises.
    max_text?: integer
  end
end

--- A parser, as [`Xml.Parser`] describes it; nil and why when memory runs
--- out. Raises where [`Xml.Options`] says.
function Xml.parser(opts?: Xml.Options): Xml.Parser?, string
  if opts == nil then return raw.parser() end
  return raw.parser(opts.namespaces, opts.eager, opts.max_text)
end

--- Every event in `text`, read whole, as one parser's `feed` and `finish`
--- answer them together; nil and why when it does not read.
function Xml.events(text: string, opts?: Xml.Options): {Xml.Event}?, string
  local p <close>, trouble = Xml.parser(opts)
  if p == nil then return nil, trouble end
  local events, feed_trouble = p:feed(text)
  if events == nil then return nil, feed_trouble end
  local last, finish_trouble = p:finish()
  if last == nil then return nil, finish_trouble end
  local all: mut {Xml.Event} = {}
  for _, e in ipairs(events) do all[#all + 1] = e end
  for _, e in ipairs(last) do all[#all + 1] = e end
  return all, ""
end

--- Whether `s` is UTF-8 that XML 1.0 can carry: no C0 control but tab,
--- line feed and carriage return, and neither U+FFFE nor U+FFFF.
local function carried(s: string): boolean
  return utf8.len(s) ~= nil and s:find("[\0-\8\11\12\14-\31]") == nil and
    s:find("\xEF\xBF[\xBE\xBF]") == nil
end

--- Whether `name` is an XML name: a letter, `_`, `:` or any character
--- past ASCII, then those, digits, `.` and `-`.
local function is_name(name: string): boolean
  return carried(name) and name:find("^[%a_:\128-\255][%w_:%.%-\128-\255]*$") ~= nil
end

--- `s` as character data: `&`, `<` and `>` escaped, which keeps a `]]>`
--- out, and a carriage return written as a reference, which a reader
--- would otherwise fold into a line feed.
local function escape_text(s: string): string
  return (s:gsub("[&<>\r]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ["\r"] = "&#13;" }))
end

--- `s` as an attribute value in double quotes: as text, with `"` escaped,
--- and tab and line feed written as references, which a reader would
--- otherwise read as spaces.
local function escape_attribute(s: string): string
  return (s:gsub('[&<>"\t\n\r]', { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;",
    ["\t"] = "&#9;", ["\n"] = "&#10;", ["\r"] = "&#13;" }))
end

--- `events`, such as a parser answers, written as an XML document in
--- UTF-8, which a parser reads back to the same events: an element with
--- nothing in it as `<name/>`, its attributes sorted by name. nil and
--- why, naming the event, when they are no document: an element that is
--- not closed, or closed by another name; no root element, or a second;
--- text outside the root; a name that is no XML name, or one in Clark's
--- notation (write a prefix and its `xmlns` attribute); a comment holding
--- `--` or ending in `-`; an instruction whose target is `xml` in any
--- case or whose text holds `?>`; or a string that is not UTF-8 or holds
--- a character XML cannot carry, even as a reference.
function Xml.write(events: {Xml.Event}): string?, string
  local out: mut {string} = {}
  local open: mut {string} = {}
  local roots = 0
  for index, e in ipairs(events) do
    local function refuse(why: string): nil, string
      return nil, "xml: event " .. tostring(index) .. ": " .. why
    end
    local name = e.name or ""
    local text = e.text or ""
    if e.kind == "start" then
      if not is_name(name) then return refuse("not an XML name: " .. string.format("%q", name)) end
      if #open == 0 then
        roots = roots + 1
        if roots > 1 then return refuse("a second root element") end
      end
      local piece: mut {string} = { "<", name }
      local attributes = e.attributes or {}
      local names: mut {string} = {}
      for attribute in pairs(attributes) do names[#names + 1] = attribute end
      table.sort(names)
      for _, attribute in ipairs(names) do
        local value = assert(attributes[attribute])
        if not is_name(attribute) then
          return refuse("not an XML name: " .. string.format("%q", attribute))
        end
        if not carried(value) then
          return refuse("the value of " .. attribute .. " holds what XML cannot")
        end
        piece[#piece + 1] = " " .. attribute .. '="' .. escape_attribute(value) .. '"'
      end
      local following = events[index + 1]
      if following ~= nil and following.kind == "end" and following.name == name then
        piece[#piece + 1] = "/>"
      else
        piece[#piece + 1] = ">"
      end
      out[#out + 1] = table.concat(piece)
      open[#open + 1] = name
    elseif e.kind == "end" then
      local innermost = open[#open]
      if innermost == nil then return refuse("an end with no element open") end
      if innermost ~= name then
        return refuse("</" .. name .. "> closes <" .. innermost .. ">")
      end
      open[#open] = nil
      local before = events[index - 1]
      if before == nil or before.kind ~= "start" or before.name ~= name then
        out[#out + 1] = "</" .. name .. ">"
      end
    elseif e.kind == "text" then
      if #open == 0 then return refuse("text outside the root element") end
      if not carried(text) then return refuse("text holds what XML cannot") end
      out[#out + 1] = escape_text(text)
    elseif e.kind == "comment" then
      if not carried(text) or text:find("--", 1, true) ~= nil or text:sub(-1) == "-" then
        return refuse("a comment cannot hold this text")
      end
      out[#out + 1] = "<!--" .. text .. "-->"
    else
      if not is_name(name) or name:lower() == "xml" then
        return refuse("not an instruction's target: " .. string.format("%q", name))
      end
      if not carried(text) or text:find("?>", 1, true) ~= nil then
        return refuse("an instruction cannot hold this text")
      end
      out[#out + 1] = "<?" .. name .. (if text == "" then "" else " " .. text end) .. "?>"
    end
  end
  local unclosed = open[#open]
  if unclosed ~= nil then return nil, "xml: <" .. unclosed .. "> is not closed" end
  if roots == 0 then return nil, "xml: no root element" end
  return table.concat(out), ""
end

return Xml
