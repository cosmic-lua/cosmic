--- Worked examples for [`cosmic.svg`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other test.

local Html = require("cosmic.html")
local Svg = require("cosmic.svg")

local record Example
end

--- A bar chart drawn from data, put in a page.
function Example.html()
  local counts = { 3, 5, 2 }
  local bars = Svg.map(counts, function(n: integer, i: integer): Svg.Node
    return Svg.rect((i - 1) * 30, 60 - n * 10, 20, n * 10, { fill = "#4a7" })
  end)
  local chart = Svg.svg(90, 60, { role = "img", ["aria-label"] = "counts" }, bars)
  local page = Html.concat({ Html.trust("<figure>"), Svg.html(chart), Html.trust("</figure>") })
  assert(Html.raw(page):find('<rect fill="#4a7" height="30" width="20" x="0" y="30"></rect>', 1, true) ~= nil)
end

--- A picture's own shapes, moved and grouped, with path data made from
--- numbers; [`Svg.render`] gives the text of any node.
function Example.render()
  local wheel = Svg.g({ class = "wheel" },
    Svg.circle(0, 0, 10, { fill = "none", stroke = "#333" }),
    Svg.ellipse(0, 0, 3, 2, { fill = "#333" }),
    Svg.line(-10, 0, 10, 0, { stroke = "#333" }))
  local road = Svg.path(Svg.f("M{} {} H{}", 0, 30.5, Svg.num(200)), { stroke = "#999" })
  local label = Svg.text(100, 50, "two wheels", { ["text-anchor"] = "middle" })
  local bike = Svg.all({ Svg.translate(20, 20, wheel), Svg.translate(60, 20, wheel), road, label, Svg.none() })
  local text = Svg.render(Svg.svg(200, 60, nil, bike))
  assert(text:find('<path d="M0 30.5 H200" stroke="#999"></path>', 1, true) ~= nil)
end

--- An element the shapes here do not name is made by [`Svg.el`].
function Example.el()
  local shape = Svg.el("polygon", { points = "0,0 10,0 5,8", fill = "#c33" })
  print(Svg.render(shape))
  assert(Svg.render(shape) == '<polygon fill="#c33" points="0,0 10,0 5,8"></polygon>')
end

return Example
