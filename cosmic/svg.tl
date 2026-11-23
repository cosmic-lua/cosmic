--- SVG made as a tree of nodes in code and written out as text: for a
--- picture, a chart or an icon that a server draws from data and puts in
--- a page.
---
---     local Svg = require("cosmic.svg")
---     local picture = Svg.svg(120, 80, nil,
---       Svg.rect(0, 0, 120, 80, { fill = "#f4efe6" }),
---       Svg.translate(60, 40, Svg.circle(0, 0, 20, { fill = "#e8907f" })))
---     local html = Svg.html(picture)
---
--- A node is an element, its name, attributes and what it holds, or a
--- group of nodes written one after another ([`Svg.all`]), which an
--- element takes in place of one child: a list made by a loop, or
--- [`Svg.none`] where there is nothing to draw. An attribute's value is a
--- string or a number, a number written as [`Svg.num`] writes it.
--- Attributes are written in name order, so the same tree is the same
--- text, and an element with nothing in it is written with an end tag
--- (`<circle ...></circle>`), which both HTML and XML read.
---
--- Text and attribute values are escaped as they are written, and a
--- byte that is no UTF-8, or a control character XML cannot hold, is
--- written as U+FFFD. A name (of an element or an attribute) that is no
--- XML name raises, as does a number that is not finite: both are the
--- program's mistake, and neither can be written.
---
--- Names and what they mean are the program's: an attribute such as
--- `href` or `onload`, or an element such as `<script>`, acts as it
--- would in any page, so a value from outside goes only where it is
--- shown, never where it is run or followed unchecked.
--- @public

local Html = require("cosmic.html")

local record Svg
  --- An attribute's value.
  type Value = string | number

  --- An element, or, where `name` is "", the nodes of `kids` written one
  --- after another.
  record Node
    --- The element's name, "" for a group.
    name: string
    --- Its attributes by name.
    attrs: mut {string: Value}
    --- What it holds, in order.
    kids: mut {Node}
    --- Its text (a `<text>`'s words), written before `kids`. A group
    --- holds neither text nor attributes.
    mut text?: string
  end

end

local NAME <const> = "^[%a_][%w_.:-]*$"

--- `x` as text: an integer below 1e15 with no point, else the fewest
--- digits (of 15 to 17, as C's `%g` writes them) that read back as `x`.
--- Raises for a number that is not finite.
--- @param x number The number
--- @return string The text
function Svg.num(x: number): string
  if x ~= x or x == math.huge or x == -math.huge then
    error("svg: " .. tostring(x) .. " is no number an attribute can hold", 2)
  end
  if x == math.floor(x) and math.abs(x) < 1e15 then
    return ("%d"):format(math.floor(x))
  end
  for digits = 15, 17 do
    local s = ("%." .. tostring(digits) .. "g"):format(x)
    if tonumber(s) == x then return s end
  end
  return ("%.17g"):format(x)
end

--- `pattern` with each `{}` in it the next of `...`: a number as
--- [`Svg.num`] writes it, a string as it is. For path data and
--- transforms: `Svg.f("M{} {} L{} {}", x, y, x + 10, y)`. Raises when
--- the count of values is not the count of `{}`.
--- @param pattern string The text, with a `{}` for each value
--- @param ... Svg.Value The values
--- @return string The text
function Svg.f(pattern: string, ...: Svg.Value): string
  local args = table.pack(...)
  local _, holes = pattern:gsub("{}", "")
  if holes ~= args.n then
    error("svg: " .. string.format("%q", pattern) .. " has " .. tostring(holes) .. " {} for " ..
        tostring(args.n) .. " given", 2)
  end
  local i = 0
  return (pattern:gsub("{}", function(): string
    i = i + 1
    local v = args[i]
    if v is number then return Svg.num(v) end
    return tostring(v)
  end))
end

--- The element `name` with `attrs` and the nodes of `...` in it. Raises
--- for a name that is no XML name.
--- @param name string The element's name
--- @param attrs {string: Svg.Value} | nil Its attributes
--- @param ... Svg.Node What it holds
--- @return Svg.Node The element
function Svg.el(name: string, attrs?: {string: Svg.Value}, ...: Svg.Node): Svg.Node
  if name:find(NAME) == nil then
    error("svg: " .. string.format("%q", name) .. " is no element name", 2)
  end
  local own: mut {string: Svg.Value} = {}
  for k, v in pairs(attrs or {}) do own[k] = v end
  local kids: mut {Svg.Node} = {}
  for _, kid in ipairs({ ... }) do kids[#kids + 1] = kid end
  return { name = name, attrs = own, kids = kids }
end

--- The nodes of `list` as one node, written one after another.
--- @param list {Svg.Node} The nodes
--- @return Svg.Node The group
function Svg.all(list: {Svg.Node}): Svg.Node
  local kids: mut {Svg.Node} = {}
  for _, kid in ipairs(list) do kids[#kids + 1] = kid end
  return { name = "", attrs = {}, kids = kids }
end

--- A group of nothing: what an element is given where there is nothing
--- to draw.
--- @return Svg.Node The group
function Svg.none(): Svg.Node
  return Svg.all({})
end

--- `f` of each of `list` and its place in it (from 1), as [`Svg.all`].
--- @param list {T} The values
--- @param f function(T, integer): Svg.Node What each is drawn as
--- @return Svg.Node The group
function Svg.map<T>(list: {T}, f: function(T, integer): Svg.Node): Svg.Node
  local out: mut {Svg.Node} = {}
  for i, v in ipairs(list) do
    local node = f(v, i)
    out[#out + 1] = node
  end
  return Svg.all(out)
end

--- A `<g>` with `attrs` around `...`.
--- @param attrs {string: Svg.Value} | nil Its attributes
--- @param ... Svg.Node What it holds
--- @return Svg.Node The group element
function Svg.g(attrs?: {string: Svg.Value}, ...: Svg.Node): Svg.Node
  return Svg.el("g", attrs, ...)
end

--- `...` moved by (x, y): a `<g transform="translate(x y)">`.
--- @param x number Right
--- @param y number Down
--- @param ... Svg.Node What it moves
--- @return Svg.Node The group element
function Svg.translate(x: number, y: number, ...: Svg.Node): Svg.Node
  return Svg.el("g", { transform = Svg.f("translate({} {})", x, y) }, ...)
end

--- `attrs` and `more` in one table, `more` over `attrs`.
local function merged(attrs: {string: Svg.Value}, more: {string: Svg.Value}?): {string: Svg.Value}
  local out: mut {string: Svg.Value} = {}
  for k, v in pairs(attrs) do out[k] = v end
  for k, v in pairs(more or {}) do out[k] = v end
  return out
end

--- A `<rect>` at (x, y), `w` by `h`, with `more` attributes (`fill`,
--- `rx`, ...).
--- @param x number Left
--- @param y number Top
--- @param w number Width
--- @param h number Height
--- @param more {string: Svg.Value} | nil More attributes
--- @return Svg.Node The element
function Svg.rect(x: number, y: number, w: number, h: number, more?: {string: Svg.Value}): Svg.Node
  return Svg.el("rect", merged({ x = x, y = y, width = w, height = h }, more))
end

--- A `<circle>` about (cx, cy) of radius `r`, with `more` attributes.
--- @param cx number Centre, across
--- @param cy number Centre, down
--- @param r number Radius
--- @param more {string: Svg.Value} | nil More attributes
--- @return Svg.Node The element
function Svg.circle(cx: number, cy: number, r: number, more?: {string: Svg.Value}): Svg.Node
  return Svg.el("circle", merged({ cx = cx, cy = cy, r = r }, more))
end

--- An `<ellipse>`: a circle stretched, `rx` across and `ry` down from
--- its middle (cx, cy), with `more` attributes.
--- @param cx number Middle, left to right
--- @param cy number Middle, top to bottom
--- @param rx number Half its width
--- @param ry number Half its height
--- @param more {string: Svg.Value} | nil More attributes
--- @return Svg.Node The element
function Svg.ellipse(cx: number, cy: number, rx: number, ry: number, more?: {string: Svg.Value}): Svg.Node
  return Svg.el("ellipse", merged({ cx = cx, cy = cy, rx = rx, ry = ry }, more))
end

--- A `<line>` from (x1, y1) to (x2, y2), with `more` attributes
--- (`stroke`, ...).
--- @param x1 number Start, across
--- @param y1 number Start, down
--- @param x2 number End, across
--- @param y2 number End, down
--- @param more {string: Svg.Value} | nil More attributes
--- @return Svg.Node The element
function Svg.line(x1: number, y1: number, x2: number, y2: number, more?: {string: Svg.Value}): Svg.Node
  return Svg.el("line", merged({ x1 = x1, y1 = y1, x2 = x2, y2 = y2 }, more))
end

--- A `<path>` along `d` (path data, as [`Svg.f`] makes it), with `more`
--- attributes.
--- @param d string The path data
--- @param more {string: Svg.Value} | nil More attributes
--- @return Svg.Node The element
function Svg.path(d: string, more?: {string: Svg.Value}): Svg.Node
  return Svg.el("path", merged({ d = d }, more))
end

--- A `<text>` at (x, y) saying `words`, with `more` attributes.
--- @param x number Across
--- @param y number Down, to the baseline
--- @param words string What it says
--- @param more {string: Svg.Value} | nil More attributes
--- @return Svg.Node The element
function Svg.text(x: number, y: number, words: string, more?: {string: Svg.Value}): Svg.Node
  local node = Svg.el("text", merged({ x = x, y = y }, more))
  node.text = words
  return node
end

--- The `<svg>` element of a picture `width` by `height`, its `viewBox`
--- the same, with `attrs` (over these, a `viewBox` of its own say) and
--- `...` in it.
--- @param width number Its width
--- @param height number Its height
--- @param attrs {string: Svg.Value} | nil More attributes
--- @param ... Svg.Node What it holds
--- @return Svg.Node The element
function Svg.svg(width: number, height: number, attrs?: {string: Svg.Value}, ...: Svg.Node): Svg.Node
  local base: {string: Svg.Value} = { xmlns = "http://www.w3.org/2000/svg", width = width, height = height,
    viewBox = Svg.f("0 0 {} {}", width, height) }
  return Svg.el("svg", merged(base, attrs), ...)
end

local ESCAPES <const>: {string: string} = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;",
  ["\t"] = "&#9;", ["\n"] = "&#10;", ["\r"] = "&#13;" }
local CONTROL <const> = "[\0-\8\11\12\14-\31]"

--- `s` with each byte that is no UTF-8, and each control character XML
--- cannot hold, as U+FFFD.
local function clean(s: string): string
  local out: mut {string} = {}
  local i = 1
  while i <= #s do
    local _, bad = utf8.len(s, i)
    if bad == nil then
      out[#out + 1] = s:sub(i)
      break
    end
    out[#out + 1] = s:sub(i, bad - 1)
    out[#out + 1] = "\u{FFFD}"
    i = bad + 1
  end
  return (table.concat(out):gsub(CONTROL, "\u{FFFD}"))
end

--- `s` escaped as text, or, where `value`, as an attribute's value, whose
--- tab, newline and carriage return a reader would make spaces.
local function escape(s: string, value: boolean): string
  local pattern = if value then '[&<>"\t\n\r]' else '[&<>"\r]' end
  return (clean(s):gsub(pattern, ESCAPES))
end

local function write(node: Svg.Node, o: mut {string})
  if node.name == "" then
    if node.text ~= nil or next(node.attrs) ~= nil then
      error("svg: a group holds neither text nor attributes", 0)
    end
    for _, kid in ipairs(node.kids) do write(kid, o) end
    return
  end
  if node.name:find(NAME) == nil then
    error("svg: " .. string.format("%q", node.name) .. " is no element name", 0)
  end
  o[#o + 1] = "<" .. node.name
  local names: mut {string} = {}
  for name in pairs(node.attrs) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if name:find(NAME) == nil then
      error("svg: " .. string.format("%q", name) .. " is no attribute name", 0)
    end
    local v = assert(node.attrs[name])
    local s = if v is number then Svg.num(v) else v end
    local attr = (' %s="%s"'):format(name, escape(s, true))
    o[#o + 1] = attr
  end
  o[#o + 1] = ">"
  local text = node.text
  if text ~= nil then
    local said = escape(text, false)
    o[#o + 1] = said
  end
  for _, kid in ipairs(node.kids) do write(kid, o) end
  o[#o + 1] = "</" .. node.name .. ">"
end

--- `node` written as text. Raises for a name that is no XML name, a
--- number that is not finite, or a group given text or attributes.
--- @param node Svg.Node The node
--- @return string The text
function Svg.render(node: Svg.Node): string
  local out: mut {string} = {}
  write(node, out)
  return table.concat(out)
end

--- `node` written as text, as HTML a page can hold: an `<svg>` element in
--- HTML is SVG, and every text and value in it was escaped (what names
--- do is the program's, as the module says).
--- @param node Svg.Node The node
--- @return Html.SafeHtml The markup
function Svg.html(node: Svg.Node): Html.SafeHtml
  return Html.trust(Svg.render(node))
end

return Svg
