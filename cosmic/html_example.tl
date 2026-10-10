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

--- A piece of a URL is escaped whole: a name that holds a `/` or `?` stays
--- one path segment, and `..` cannot climb. A query built by code goes
--- through `url_query`.
function Example.url_part()
  local segment = Html.raw_url_part(Html.url_part("a b/c?"))
  print("/users/" .. segment) -- /users/a%20b%2Fc%3F
  assert(segment == "a%20b%2Fc%3F")
  assert(Html.raw_url_part(Html.url_part("..")) == "%252E%252E")
  local query = (assert(Html.url_query({ { "q", "fish & chips" }, { "page", "2" } })))
  assert(Html.raw_url_part(query) == "q=fish%20%26%20chips&page=2")
end

--- [`local_href`] keeps a link on this site: a scheme, or a host, makes it
--- `about:invalid`.
function Example.local_href()
  assert(Html.raw_url(Html.local_href("/inbox?unread=1")) == "/inbox?unread=1")
  assert(Html.raw_url(Html.local_href("https://example.com/")) == "about:invalid")
  assert(Html.raw_url(Html.local_href("//example.com/")) == "about:invalid")
end

--- A selector built from data is escaped as CSS identifier text, so a
--- value cannot end the identifier and select another element.
function Example.escape_css_attr()
  local target = Html.escape_css_attr("x, body")
  print(Html.raw_attr(target)) -- x&#92;2c&#32;&#92;20&#32;body
  assert(Html.raw_attr(target) == "x&#92;2c&#32;&#92;20&#32;body")
end

--- JSON for an attribute such as `hx-vals` is encoded by `json`, and a
--- value that cannot be JSON is refused. Its text is escaped for an
--- attribute where the page puts it in one.
function Example.json()
  local vals = (assert(Html.json({ id = 7 })))
  print(Html.raw_json(vals)) -- {"id":7}
  assert(Html.raw_json(vals) == '{"id":7}')
  local missing, why = Html.json({ run = print })
  assert(missing == nil and why:find("function", 1, true))
  assert(Html.raw_json((assert(Html.json_text('[1, 2]')))) == "[1, 2]")
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
