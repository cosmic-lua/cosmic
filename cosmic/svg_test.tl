local Html = require("cosmic.html")
local Svg = require("cosmic.svg")
local Test = require("cosmic.test")
local Xml = require("cosmic.xml")
local Bench = require("cosmic.bench")

local function test_a_number_is_written_in_the_fewest_digits_that_read_back()
  assert(Svg.num(3) == "3" and Svg.num(-0.5) == "-0.5" and Svg.num(1200.0) == "1200")
  assert(Svg.num(0.1 + 0.2) == "0.30000000000000004" and Svg.num(1 / 3) == "0.3333333333333333")
  assert(Svg.num(2.5e15) == "2.5e+15")
  Test.raises(function() Svg.num(0 / 0) end, "no number")
  Test.raises(function() Svg.num(math.huge) end, "no number")
  assert(Svg.num(-0.0) == "0" and Svg.num(1e-7) == "1e-07" and Svg.num(2 ^ 53) == "9007199254740992")
  assert(Svg.f("M{} {} L{} {}", 1, 2.5, "a", -3) == "M1 2.5 La -3")
  Test.raises(function() Svg.f("{} {}", 1) end, "has 2 {} for 1 given")
  Test.raises(function() Svg.f("{}", 1, 2) end, "has 1 {} for 2 given")
end

local function test_attributes_are_sorted_and_an_empty_element_has_an_end_tag()
  local dot = Svg.circle(10, 20, 5, { fill = "#fff", class = "dot" })
  assert(Svg.render(dot) == '<circle class="dot" cx="10" cy="20" fill="#fff" r="5"></circle>', Svg.render(dot))
  local moved = Svg.translate(1.5, 2, Svg.rect(0, 0, 4, 3))
  assert(Svg.render(moved) == '<g transform="translate(1.5 2)"><rect height="3" width="4" x="0" y="0"></rect></g>')
end

local function test_a_group_and_none_are_written_in_place()
  local none = Svg.none()
  none.kids[1] = Svg.rect(0, 0, 1, 1)
  assert(Svg.render(Svg.none()) == "")
  local row = Svg.map({ "a", "b" }, function(label: string, i: integer): Svg.Node
    return Svg.text(i * 10, 0, label)
  end)
  local out = Svg.render(Svg.g({ id = "row" }, row, Svg.none(), Svg.all({ Svg.none() })))
  assert(out == '<g id="row"><text x="10" y="0">a</text><text x="20" y="0">b</text></g>', out)
  assert(Svg.render(Svg.all({})) == "")
end

local function test_text_and_values_are_escaped()
  local said = Svg.text(0, 0, '<script>&"', { ["data-note"] = '"><script>' })
  local out = Svg.render(said)
  assert(out == '<text data-note="&quot;&gt;&lt;script&gt;" x="0" y="0">&lt;script&gt;&amp;&quot;</text>', out)
  assert(Html.raw(Svg.html(said)) == out)
  local odd = Svg.text(0, 0, "a\0b\1c\xffd\re'", { title = "a\nb\tc'" })
  local written = Svg.render(odd)
  assert(written == '<text title="a&#10;b&#9;c\'" x="0" y="0">a\u{FFFD}b\u{FFFD}c\u{FFFD}d&#13;e\'</text>', written)
  local tree = assert(Xml.tree(written))
  assert(tree.attributes["title"] == "a\nb\tc'" and Xml.text(tree) == "a\u{FFFD}b\u{FFFD}c\u{FFFD}d\re'")
end

local function test_a_name_that_is_no_xml_name_raises()
  Test.raises(function() Svg.el("a b") end, "no element name")
  Test.raises(function() Svg.el("") end, "no element name")
  Test.raises(function() Svg.render(Svg.el("g", { ['x" onload="y'] = 1 })) end, "no attribute name")
  Test.raises(function() Svg.render(Svg.rect(0, 0, 0 / 0, 1)) end, "no number")
  local forged: Svg.Node = { name = "g><script>", attrs = {}, kids = {} }
  Test.raises(function() Svg.render(forged) end, "no element name")
  local group = Svg.all({})
  group.text = "lost"
  Test.raises(function() Svg.render(group) end, "neither text nor attributes")
end

local function test_a_picture_is_a_document_an_xml_parser_reads_back()
  local picture = Svg.svg(120, 80, { role = "img" },
    Svg.rect(0, 0, 120, 80, { fill = "#f4efe6" }),
    Svg.line(0, 0, 120, 80, { stroke = "#000" }),
    Svg.ellipse(60, 40, 30, 10),
    Svg.path(Svg.f("M{} {}h{}", 0, 0, 10)),
    Svg.text(5, 70, "a & b"))
  local tree = assert(Xml.tree(Svg.render(picture)))
  assert(tree.name == "svg" and tree.attributes["viewBox"] == "0 0 120 80" and tree.attributes["role"] == "img")
  assert(tree.attributes["xmlns"] == "http://www.w3.org/2000/svg")
  local said = assert(Xml.child(tree, "text"))
  assert(Xml.text(said) == "a & b")
  local own = Svg.svg(10, 10, { viewBox = "0 0 1 1" })
  assert(Svg.render(own):find('viewBox="0 0 1 1"', 1, true) ~= nil)
end

--- Bench: a chart of 500 bars, built.
local function bench_build_500_rects(b: Bench.B)
  for _ = 1, b.n do
    local bars: mut {Svg.Node} = {}
    for i = 1, 500 do bars[i] = Svg.rect(i * 2, 0, 1, i % 50, { fill = "#369" }) end
    local _ = Svg.svg(1000, 100, {}, Svg.all(bars))
  end
end
