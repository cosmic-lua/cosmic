--- Worked examples for [`cosmic.html`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Html = require("cosmic.html")

local Example = {}

--- Text from a user is escaped, so markup in it is shown, not run.
function Example.escape()
  local shown = Html.escape("<script>alert('x') & more</script>")
  print(Html.raw(shown)) -- &lt;script&gt;alert(&#39;x&#39;) &amp; more&lt;/script&gt;
  assert(Html.raw(shown) == "&lt;script&gt;alert(&#39;x&#39;) &amp; more&lt;/script&gt;")
end

--- An attribute value is made by a function of its own, for a quoted
--- attribute: the types keep it from being put in element content, and
--- a string from being put in either. `trust_attr` is the door for a
--- value the program wrote.
function Example.escape_attr()
  local title: Html.SafeAttr = Html.escape_attr('say "hi" & leave')
  print(Html.raw_attr(title)) -- say&#32;&#34;hi&#34;&#32;&#38;&#32;leave
  assert(Html.raw_attr(title) == "say&#32;&#34;hi&#34;&#32;&#38;&#32;leave")
  assert(Html.raw_attr(Html.trust_attr("fixed")) == "fixed")
end

--- `concat` joins pieces in one pass; `trust` is the one door that
--- does not escape, for markup the program wrote.
function Example.concat()
  local items: {Html.SafeHtml} = {}
  for _, name in ipairs({ "Fish & Chips", "Bread <3" }) do
    items[#items + 1] = Html.concat({ Html.trust("<li>"), Html.escape(name), Html.trust("</li>") })
  end
  local list = Html.concat({ Html.trust("<ul>"), Html.concat(items), Html.trust("</ul>") })
  print(Html.raw(list)) -- <ul><li>Fish &amp; Chips</li><li>Bread &lt;3</li></ul>
  assert(Html.raw(list) == "<ul><li>Fish &amp; Chips</li><li>Bread &lt;3</li></ul>")
end

return Example
