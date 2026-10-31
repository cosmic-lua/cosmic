--- XML text as a stream of events: a reader over expat.
---
---     local p <close> = assert(Xml.parser())
---     for _, e in ipairs(assert(p:feed('<a href="x">hi'))) do
---       -- { kind = "start", name = "a", attributes = { href = "x" } }
---     end
---     local rest = assert(p:feed("</a>"))
---     -- { { kind = "text", text = "hi" }, { kind = "end", name = "a" } }
---     assert(p:finish())
---
--- A parser takes the text a chunk at a time, split anywhere, and answers
--- each chunk with the events it completes, in document order. A run of
--- character data is one `text` event however the chunks split it: it
--- is held back until markup follows it or the input ends. CDATA
--- sections, character references and the predefined and declared
--- entities are read into the text they stand for, and the text is
--- UTF-8, whatever encoding the document declares (UTF-8, UTF-16,
--- ISO-8859-1 or US-ASCII). A name is answered as written: `p:x` stays
--- `p:x` unless the parser was asked for namespaces, when an element's
--- or attribute's name in one is `{uri}local`, Clark's notation, and a
--- prefix with no declaration is refused.
---
--- What is refused, naming `line N, column M` (both from 1; a column
--- counts bytes): text that is not well-formed XML, and an entity whose
--- expansion grows past expat's amplification limits. No external
--- entity or DTD is ever read: a reference to an external entity is
--- skipped, and so is one to an entity a document with an external DTD
--- leaves undeclared, as XML allows a parser that reads no DTD.
---
--- A failure finishes the parser, as does `finish`, a raise inside a
--- call (out of memory), or closing it: `feed` and `finish` raise on a
--- finished parser.

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

  --- `feed(chunk)` answers the events `chunk` completes, possibly none;
  --- `finish()` says the input has ended, and answers the events that
  --- completes. Each answers `events, ""`, or nil and why, and finishes
  --- the parser on a failure; `finish` finishes it either way. A parser
  --- is closeable: `local p <close> = assert(Xml.parser())` frees it at
  --- the end of the scope.
  type Parser = raw_xml.Parser

  record Options
    --- Answer names in a namespace as `{uri}local`.
    namespaces: boolean
  end
end

--- A parser, as [`Xml.Parser`] describes it; nil and why when memory runs
--- out.
function Xml.parser(opts?: Xml.Options): Xml.Parser?, string
  return raw.parser(opts ~= nil and opts.namespaces)
end

--- Every event in `text`, read whole, as one parser's `feed` and `finish`
--- answer them together; nil and why when it does not read.
function Xml.events(text: string, opts?: Xml.Options): {Xml.Event}?, string
  local p <close>, trouble = raw.parser(opts ~= nil and opts.namespaces)
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

return Xml
