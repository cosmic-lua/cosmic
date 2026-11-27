--- Run-time microbenchmarks of text work: `bin/cosmic bench/text.tl [name...]`.
--- HTML and SVG writing, XML parsing and writing, URL parsing and escaping, string helpers, and CSV writing. Each
--- case is one line on [`bench.harness`], which takes `--json`, `--rounds` and `--against <old-binary>`. It
--- measures; it gates nothing, and no test reads its numbers.
local Bench = require("bench.harness")
local Csv = require("cosmic.csv")
local Html = require("cosmic.html")
local String = require("cosmic.string")
local Svg = require("cosmic.svg")
local Url = require("cosmic.url")
local Xml = require("cosmic.xml")

local bench = Bench.new("text")
local case = bench.case

-- HTML: escape text that needs it, and an attribute.
local plain = string.rep("The quick brown fox jumps over the lazy dog. ", 1000)
local tagged = string.rep("<a href=\"x?a=1&b=2\">Tom & 'Jerry'</a> ", 1000)
case("html.escape plain 45 KB", function(n: integer)
  for _ = 1, n do local _ = Html.escape(plain) end
end, { bytes = #plain })
case("html.escape markup 40 KB", function(n: integer)
  for _ = 1, n do local _ = Html.escape(tagged) end
end, { bytes = #tagged })
case("html.escape_attr markup 40 KB", function(n: integer)
  for _ = 1, n do local _ = Html.escape_attr(tagged) end
end, { bytes = #tagged })

-- SVG: a chart of 500 bars, written to text.
case("svg build 500 rects", function(n: integer)
  for _ = 1, n do
    local bars: mut {Svg.Node} = {}
    for i = 1, 500 do bars[i] = Svg.rect(i * 2, 0, 1, i % 50, { fill = "#369" }) end
    local _ = Svg.svg(1000, 100, {}, Svg.all(bars))
  end
end)

-- XML: 1000 records, parsed to a tree, to events, and written back.
local rows: mut {string} = {}
for i = 1, 1000 do
  rows[i] = ('<item id="%d" kind="a"><name>user%d</name><note>fish &amp; chips</note></item>'):format(i, i)
end
local xml_text = '<?xml version="1.0"?><items>' .. table.concat(rows, "") .. "</items>"
local events: {Xml.Event} = {}
do
  local got, why = Xml.events(xml_text)
  if got == nil then error(tostring(why)) end
  events = got
end
case("xml.tree 1000 items", function(n: integer)
  for _ = 1, n do local _ = Xml.tree(xml_text)! end
end, { bytes = #xml_text })
case("xml.events 1000 items", function(n: integer)
  for _ = 1, n do local _ = Xml.events(xml_text)! end
end, { bytes = #xml_text })
case("xml.write 1000 items", function(n: integer)
  for _ = 1, n do local _ = Xml.write(events)! end
end, { bytes = #xml_text })

-- URLs: 1000 addresses parsed, resolved, and a query string decoded, encoded and escaped.
local addresses: mut {string} = {}
for i = 1, 1000 do
  local address = ("https://user@example.com:8443/a/b/c%d/index.html?x=%d&y=a%%20b&z=%%e2%%82%%ac#frag"):format(i, i)
  addresses[#addresses + 1] = address
end
case("url.parse 1000 urls", function(n: integer)
  for _ = 1, n do
    for _, a in ipairs(addresses) do local _ = Url.parse(a)! end
  end
end)
case("url.resolve 1000 urls", function(n: integer)
  for _ = 1, n do
    for _, a in ipairs(addresses) do
      local _ = Url.resolve("https://example.com/a/b/", "../c/d.html?q=" .. tostring(#a))
    end
  end
end)
local query = "a=1&b=two%20words&c=%e2%82%ac&" .. string.rep("k=v&", 200) .. "last=1"
case("url.decode_query 200 pairs", function(n: integer)
  for _ = 1, n do local _ = Url.decode_query(query)! end
end, { bytes = #query })
local pairs_list: mut {Url.Pair} = {}
for i = 1, 200 do
  local pair: Url.Pair = { name = "key" .. tostring(i), value = "a value & more " .. tostring(i) }
  pairs_list[#pairs_list + 1] = pair
end
case("url.encode_query 200 pairs", function(n: integer)
  for _ = 1, n do local _ = Url.encode_query(pairs_list) end
end)
case("url.escape 45 KB", function(n: integer)
  for _ = 1, n do local _ = Url.escape(plain) end
end, { bytes = #plain })

-- Strings: split, lines, trim and the predicates over 1 MiB of lines.
local line_text = string.rep("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu\n", 16384)
case("string.split lines 1 MiB", function(n: integer)
  for _ = 1, n do local _ = String.split(line_text, "\n") end
end, { bytes = #line_text })
case("string.lines iterate 1 MiB", function(n: integer)
  for _ = 1, n do
    local count = 0
    for _ in String.lines(line_text) do count = count + 1 end
  end
end, { bytes = #line_text })
case("string.trim 1 MiB", function(n: integer)
  local padded = "   " .. line_text .. "   "
  for _ = 1, n do local _ = String.trim(padded) end
end, { bytes = #line_text })
case("string.contains miss 1 MiB", function(n: integer)
  for _ = 1, n do local _ = String.contains(line_text, "needle") end
end, { bytes = #line_text })

-- CSV writing: 1000 rows of five fields, one quoted.
local csv_rows: mut {{string}} = {}
for i = 1, 1000 do
  local row = { tostring(i), "user" .. tostring(i), "u@example.com", "a, \"quoted\" field", tostring(i / 7) }
  csv_rows[#csv_rows + 1] = row
end
case("csv.encode 1000 rows", function(n: integer)
  for _ = 1, n do local _ = Csv.encode(csv_rows) end
end)

return function(argv: {string}): integer return bench.main(argv) end
