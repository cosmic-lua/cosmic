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

--- An attribute value is made by a function of its own: the types keep
--- it from being put in element content, and a string from being put
--- in either.
function Example.escape_attr()
  local title: Html.SafeAttr = Html.escape_attr('say "hi" & leave')
  local tag = Html.concat({
    Html.trust('<a title="'),
    Html.trust(Html.raw_attr(title)),
    Html.trust('">link</a>'),
  })
  print(Html.raw(tag)) -- <a title="say&#32;&#34;hi&#34;&#32;&#38;&#32;leave">link</a>
  assert(Html.raw(tag) == '<a title="say&#32;&#34;hi&#34;&#32;&#38;&#32;leave">link</a>')
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

--- A safe value is opaque: it is no string, and only `raw` and
--- `raw_attr` give the string back. A table literal, a string, or a
--- value of the other type in its place is refused when the program is
--- type-checked.
function Example.opaque()
  local vouched = Html.trust_attr("x")
  assert(type(vouched) == "userdata")
  assert(Html.raw_attr(vouched) == "x")
end

return Example
