local Stream = require("cosmic.stream")
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
  return tostring(why)
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
  assert(why == "xml: unbound prefix at line 1, column 1", why)
end

local function test_refusals_name_where()
  local why = refused("<a>\n  <b></a>")
  assert(why == "xml: mismatched tag at line 2, column 8", why)
  why = refused("<a>")
  assert(why:match("^xml: .* at line 1, column 4$") ~= nil, why)
  why = refused('<a x="1" x="2"/>')
  assert(why == "xml: duplicate attribute at line 1, column 10", why)
end

--- The billion laughs: nine entities, each ten references to the one
--- before, the last 3 GB of "lol" once expanded.
local function laughs(): string
  local lines: mut {string} = { '<!DOCTYPE l [<!ENTITY l0 "lol">' }
  for i = 1, 9 do
    lines[#lines + 1] = string.format('<!ENTITY l%d "%s">', i, string.rep("&l" .. tostring(i - 1) .. ";", 10))
  end
  lines[#lines + 1] = "]><l>&l9;</l>"
  return table.concat(lines)
end

--- The billion laughs: expat's amplification limit refuses the expansion
--- before it is built.
local function test_entity_expansion_is_bounded()
  local why = refused(laughs())
  assert(why:match("amplification") ~= nil, why)
end

--- The amplification limit refuses an entity from its size before
--- expanding it: none of the text reaches the parser, so a text limit
--- below the limit's 8 MiB threshold is never met. Expat before 2.10.0
--- expanded until the limit tripped, and met this one first.
local function test_entity_expansion_is_refused_before_any_text()
  local why = refused(laughs(), { max_text = 1 << 20 })
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
  local finished, after_failure = pcall(failed.finish, failed)
  assert(not finished and tostring(after_failure):match("the parser is finished") ~= nil, tostring(after_failure))
  local closed = assert(Xml.parser())
  do
    local _ <close> = closed
  end
  local fed, after_close = pcall(closed.feed, closed, "<a/>")
  assert(not fed and tostring(after_close):match("the parser is finished") ~= nil, tostring(after_close))
end

--- A name and a value far past the blocks expat starts its string pools
--- with are read whole: the pools grow in place.
local function test_long_names_and_values_read_whole()
  local name = "n" .. string.rep("x", 70000)
  local value = string.rep("v", 100000)
  local events = assert(Xml.events("<" .. name .. ' k="' .. value .. '"/>'))
  local start = assert(events[1])
  assert(start.name == name and assert(start.attributes)["k"] == value)
end

--- A finalizer runs only at a call Lua code makes, never at a C function's own
--- `lua_pcall` (patch/lua/31-finalizers-at-c-calls-run-call.txt), so none runs while a call
--- appends an event, however much the call allocates: the ones it leaves
--- pending run after it, with the parser free. Teal declares a finalizer as
--- a class's `__gc`, but this one is Lua's, from a chunk, to reach the
--- parser's own `__close`: it keeps one armed, and each time it runs it feeds
--- the parser and, the first time, closes it.
local function test_no_finalizer_runs_inside_a_parser_call()
  local p = assert(Xml.parser())
  local chunk = assert(load([[
    local p, seen = ...
    local closed = false
    local function arm()
      setmetatable({}, { __gc = function()
        if #seen >= 3 then return end
        local ok, why = pcall(p.feed, p, "<x/>")
        seen[#seen + 1] = ok and "fed" or tostring(why)
        if not closed then
          closed = true
          getmetatable(p).__close(p)
        end
        arm()
      end })
    end
    arm()
  ]], "finalizer", "t"))
  local seen: mut {string} = {}
  -- The input is built before the finalizer is armed: building it after
  -- could run a collection, and the finalizer, before the call.
  local input = "<r>" .. string.rep("<i>t</i>", 20000)
  chunk(p, seen)
  local events = assert(p:feed(input))
  assert(#seen == 0, "a finalizer ran during the call")
  assert(#events > 0)
  collectgarbage()
  collectgarbage()
  -- The first ran with the parser free, fed it and closed it; a later one finds it finished.
  local first = assert(seen[1], "no finalizer ran after the call")
  assert(first == "fed", first)
  for i = 2, #seen do
    local why = assert(seen[i])
    assert(why:match("the parser is finished") ~= nil, why)
  end
  local fed, why = pcall(p.feed, p, "</r>")
  assert(not fed and tostring(why):match("the parser is finished") ~= nil, tostring(why))
end

--- A column counts characters, not bytes: `é` is two bytes, one column.
local function test_a_column_counts_characters()
  local why = refused("<a>\u{E9}\u{E9}</b>")
  assert(why == "xml: mismatched tag at line 1, column 8", why)
end

--- A run of text past `max_text` is refused where it passes it, however
--- the chunks split it; one at the limit reads.
local function test_a_run_of_text_past_max_text_is_refused()
  local why = refused("<a>" .. string.rep("x", 11) .. "</a>", { max_text = 10 })
  assert(why == "xml: a run of text is longer than 10 bytes at line 1, column 4", why)
  assert(read("<a>" .. string.rep("x", 10) .. "</a>", { max_text = 10 }) == 'start a|text "xxxxxxxxxx"|end a')
  local ok, raised = pcall(function() local _, _ = Xml.parser({ max_text = 0 }) end)
  assert(not ok and tostring(raised):match("max_text must be at least 1") ~= nil, tostring(raised))
end

--- Fed a byte at a time past a long attribute, an eager parser answers
--- each element in the chunk that completes it; a deferring one may hold
--- it back.
local function test_an_eager_parser_answers_each_chunk_what_it_completes()
  local text = '<r><i k="' .. string.rep("v", 10000) .. '"/><b/>'
  local p <close> = assert(Xml.parser({ eager = true }))
  local seen: mut {string} = {}
  for at = 1, #text do
    local events = assert(p:feed(text:sub(at, at)))
    for _, e in ipairs(events) do
      local line = tostring(at) .. " " .. e.kind .. " " .. (e.name or "")
      seen[#seen + 1] = line
    end
  end
  local closes = #text - #"<b/>"
  local want = { "3 start r", tostring(closes) .. " start i", tostring(closes) .. " end i",
    tostring(#text) .. " start b", tostring(#text) .. " end b" }
  assert(table.concat(seen, "|") == table.concat(want, "|"), table.concat(seen, "|"))
end

--- What the writer writes, a parser reads back to the same events.
local function test_write_reads_back_to_the_same_events()
  local text = '<?go now?><r b="2" a="tab&#9;here&amp;&quot;">x &lt; y\r\n<e/><!-- c --><![CDATA[]]]]><![CDATA[>]]></r>'
  local events = assert(Xml.events(text))
  local written = assert(Xml.write(events))
  assert(written == '<?go now?><r a="tab&#9;here&amp;&quot;" b="2">x &lt; y\n<e/><!-- c -->]]&gt;</r>', written)
  assert(show((assert(Xml.events(written)))) == show(events))
end

local function test_write_refuses_what_is_no_document()
  local function why(events: {Xml.Event}): string
    local written, trouble = Xml.write(events)
    assert(written == nil, written)
    return tostring(trouble)
  end
  assert(why({ { kind = "start", name = "a" } }) == "xml: <a> is not closed")
  assert(why({}) == "xml: no root element")
  assert(why({ { kind = "start", name = "a" }, { kind = "end", name = "b" } }) == "xml: event 2: </b> closes <a>")
  assert(why({ { kind = "text", text = "x" } }) == "xml: event 1: text outside the root element")
  assert(why({ { kind = "start", name = "a" }, { kind = "end", name = "a" }, { kind = "start", name = "b" } }) ==
      "xml: event 3: a second root element")
  assert(why({ { kind = "comment", text = "a--b" } }) == "xml: event 1: a comment cannot hold this text")
  assert(why({ { kind = "instruction", name = "XmL", text = "" } }):match("not an instruction's target") ~= nil)
  assert(why({ { kind = "start", name = "a" }, { kind = "text", text = "\1" } }) ==
      "xml: event 2: text holds what XML cannot")
  assert(why({ { kind = "start", name = "a", attributes = { k = "\xff" } } }) ==
      "xml: event 1: the value of k holds what XML cannot")
end

--- Local names drop the namespace from element and attribute names, and
--- still refuse an undeclared prefix.
local function test_local_names_drop_the_namespace()
  local text = '<x:a xmlns:x="urn:x" xmlns:r="urn:r" r:id="7"><b xmlns="urn:d"/></x:a>'
  assert(read(text, { local_names = true }) == "start a id=7|start b|end b|end a")
  local why = refused("<y:a/>", { local_names = true })
  assert(why == "xml: unbound prefix at line 1, column 1", why)
end

--- A tree keeps text and children in document order; `text` joins all
--- of it, `children` and `child` pick elements by name.
local function test_a_tree_keeps_content_in_order()
  local root = assert(Xml.tree('<r k="v">a<b>x<i>y</i></b>c<b/><!-- no --></r>'))
  assert(root.name == "r" and root.attributes["k"] == "v")
  assert(#root.content == 4, tostring(#root.content))
  assert(root.content[1] == "a" and root.content[3] == "c")
  assert(Xml.text(root) == "axyc", Xml.text(root))
  assert(#Xml.children(root, "b") == 2 and #Xml.children(root) == 2)
  local b = assert(Xml.child(root, "b"))
  assert(Xml.text(b) == "xy")
  assert(Xml.child(root, "missing") == nil)
  local _, why = Xml.tree("<r>")
  assert(tostring(why):match("^xml: ") ~= nil, why)
end

--- `text` walks a tree as deep as a parse builds without running out of
--- the Lua stack.
local function test_text_reads_a_deeply_nested_tree()
  local levels = 200000
  local root = assert(Xml.tree(string.rep("<a>", levels) .. "deep" .. string.rep("</a>", levels)))
  assert(Xml.text(root) == "deep")
end

--- Subtrees at a path come whole, one as each closes, however the
--- chunks split the document; `*` stands for any name, and an element
--- at the path inside another is part of it, not answered apart.
local function test_subtrees_come_whole_at_their_path()
  local text = '<doc><rows><row n="1"><c>a</c></row><row n="2"><c>b</c><c>c</c></row></rows><other><row/></other></doc>'
  for size = 1, #text do
    local p <close> = assert(Xml.parser())
    local rows = Xml.subtrees("doc/rows/row")
    local got: mut {string} = {}
    local function take(events: {Xml.Event})
      for _, row in ipairs(rows:take(events)) do
        local line = assert(row.attributes["n"]) .. ":" .. Xml.text(row)
        got[#got + 1] = line
      end
    end
    for at = 1, #text, size do take((assert(p:feed(text:sub(at, at + size - 1))))) end
    take((assert(p:finish())))
    assert(table.concat(got, " ") == "1:a 2:bc", table.concat(got, " "))
  end
  local any = Xml.subtrees("doc/*/row"):take((assert(Xml.events(text))))
  assert(#any == 3, tostring(#any))
end

--- Two attributes that share a local name: the later in the document
--- stands.
local function test_local_names_keep_the_later_of_two_attributes()
  local got = read('<a xmlns:x="urn:x" xmlns:y="urn:y" x:id="1" y:id="2"/>', { local_names = true })
  assert(got == "start a id=2|end a", got)
end

--- Names in Clark's notation are written under prefixes the writer binds,
--- each declared on the first element that needs it and used inside it;
--- XML's own namespace is `xml`. A parser asked for namespaces reads the
--- document back to the same events.
local function test_write_binds_prefixes_for_namespaced_names()
  local events = assert(Xml.events('<a xmlns="urn:d" xmlns:x="urn:x" x:k="1" xml:lang="en"><b/><x:c/></a>',
    { namespaces = true }))
  local written = assert(Xml.write(events))
  assert(written == '<ns1:a ns2:k="1" xml:lang="en" xmlns:ns1="urn:d" xmlns:ns2="urn:x"><ns1:b/><ns2:c/></ns1:a>',
    written)
  assert(show((assert(Xml.events(written, { namespaces = true })))) == show(events))
end

--- A prefix the events declare for themselves is never chosen, and a name
--- in no namespace, in `xmlns`'s own, or with a prefixed local part is
--- refused.
local function test_write_keeps_clear_of_declared_prefixes()
  local written = assert(Xml.write({
    { kind = "start", name = "{urn:a}r", attributes = { ["xmlns:ns1"] = "urn:other" } },
    { kind = "end", name = "{urn:a}r" },
  }))
  assert(written == '<ns2:r xmlns:ns1="urn:other" xmlns:ns2="urn:a"/>', written)
  local function why(name: string): string
    local none, trouble = Xml.write({ { kind = "start", name = name }, { kind = "end", name = name } })
    assert(none == nil, none)
    return tostring(trouble)
  end
  assert(why("{}a") == 'xml: event 1: no namespace a name may be in: ""', why("{}a"))
  assert(why("{http://www.w3.org/2000/xmlns/}a"):match("no namespace a name may be in") ~= nil)
  assert(why("{urn:a}p:b") == 'xml: event 1: not an XML name: "{urn:a}p:b"', why("{urn:a}p:b"))
end

--- A prefix bound on an element is in scope only inside it: a sibling binds
--- its own. An attribute in its element's namespace takes the same prefix,
--- declared once, and a prefix a plain name uses is never bound.
local function test_write_scopes_each_binding_to_its_element()
  local written = assert(Xml.write({
    { kind = "start", name = "r" },
    { kind = "start", name = "{urn:a}x", attributes = { ["{urn:a}k"] = "1" } },
    { kind = "end", name = "{urn:a}x" },
    { kind = "start", name = "{urn:a}y" },
    { kind = "end", name = "{urn:a}y" },
    { kind = "start", name = "ns1:z", attributes = { ["xmlns:ns1"] = "urn:z" } },
    { kind = "end", name = "ns1:z" },
    { kind = "end", name = "r" },
  }))
  assert(written == '<r><ns2:x ns2:k="1" xmlns:ns2="urn:a"/><ns3:y xmlns:ns3="urn:a"/><ns1:z xmlns:ns1="urn:z"/></r>',
    written)
  local plain = assert(Xml.write({
    { kind = "start", name = "ns1:r" },
    { kind = "start", name = "{urn:a}x" },
    { kind = "end", name = "{urn:a}x" },
    { kind = "end", name = "ns1:r" },
  }))
  assert(plain == '<ns1:r><ns2:x xmlns:ns2="urn:a"/></ns1:r>', plain)
end

--- Written a batch at a time, split anywhere, a document comes out as
--- `write` writes it whole: a start tag left at a batch's end waits for
--- the next to say whether it closes at once.
local function test_a_writer_writes_batches_as_write_writes_the_whole()
  local events = assert(Xml.events('<r xmlns:x="urn:x"><a k="1"/><x:b>t</x:b><!-- c --><e/></r>',
    { namespaces = true }))
  local whole = assert(Xml.write(events))
  for cut = 0, #events do
    local out = Stream.collect()
    local w = Xml.writer(out)
    local first: mut {Xml.Event} = {}
    local rest: mut {Xml.Event} = {}
    for i, e in ipairs(events) do
      if i <= cut then first[#first + 1] = e else rest[#rest + 1] = e end
    end
    assert(w:write(first))
    assert(w:write(rest))
    assert(w:close())
    assert(out:result() == whole, "cut at " .. tostring(cut) .. ": " .. out:result())
  end
end

--- A writer refused once stays refused; one closed on an unfinished
--- document aborts its target; and a later batch may not name a prefix
--- the writer bound already.
local function test_a_writer_refuses_and_stays_refused()
  local w = Xml.writer(Stream.collect())
  local ok, why = w:write({ { kind = "text", text = "x" } })
  assert(not ok and tostring(why) == "xml: event 1: text outside the root element", tostring(why))
  local again, still = w:write({ { kind = "start", name = "r" } })
  assert(not again and still == why, still)
  local unfinished = Stream.collect()
  local open = Xml.writer(unfinished)
  assert(open:write({ { kind = "start", name = "r" }, { kind = "text", text = "t" } }))
  assert(unfinished:result() == "<r>t", unfinished:result())
  local closed, unclosed = open:close()
  assert(not closed and tostring(unclosed) == "xml: <r> is not closed", tostring(unclosed))
  assert(unfinished:result() == "", "the target was not aborted: " .. unfinished:result())
  local named = Xml.writer(Stream.collect())
  assert(named:write({ { kind = "start", name = "r" }, { kind = "start", name = "{urn:a}x" } }))
  local bound, clash = named:write({ { kind = "start", name = "ns1:y" } })
  assert(not bound and tostring(clash) == "xml: event 3: the prefix ns1 is bound by the writer already", tostring(clash))
  -- Once the binding's element is closed, a later batch may name the prefix, as a
  -- whole document's events may.
  local later_out = Stream.collect()
  local later = Xml.writer(later_out)
  assert(later:write({ { kind = "start", name = "r" }, { kind = "start", name = "{urn:a}x" },
    { kind = "end", name = "{urn:a}x" } }))
  assert(later:write({ { kind = "start", name = "ns1:y", attributes = { ["xmlns:ns1"] = "urn:y" } },
    { kind = "end", name = "ns1:y" }, { kind = "end", name = "r" } }))
  assert(later:close())
  assert(later_out:result() == '<r><ns1:x xmlns:ns1="urn:a"/><ns1:y xmlns:ns1="urn:y"/></r>', later_out:result())
end

--- A writer closed once stays closed and keeps what it wrote: a second
--- `close` answers true, and `abort` after it leaves the document as it is.
local function test_a_closed_writer_keeps_its_document()
  local out = Stream.collect()
  local w = Xml.writer(out)
  assert(w:write({}))
  assert(w:write({ { kind = "start", name = "r" }, { kind = "end", name = "r" } }))
  assert(w:close())
  assert(w:close())
  assert(w:abort())
  assert(out:result() == "<r/>", out:result())
end
