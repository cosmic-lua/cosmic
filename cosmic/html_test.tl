--- [`cosmic.html`]'s safe values: what each escaper makes of the bytes
--- that matter, that a safe value is opaque at run time and refused by
--- the type checker in another's place, and that `raw` and `concat`
--- hold to their types.
local Fs = require("cosmic.fs")
local Html = require("cosmic.html")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

-- A fixture reads the `cosmic.*` modules it requires out of the store,
-- which holds a test to its import closure.
local type _html = require("cosmic.html")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

local type Call = function(...: any): any...

--- `value` with its type forgotten, as the checker would not let it be.
local function untyped(value: any): any
  return value
end

--- Calls `f` with `...` as the checker would not allow: whatever it is
--- declared to take.
local function attempt(f: any, ...: any): boolean, any
  return pcall(f as Call, ...) -- cast: a function of the core's, called past its declaration
end

--- Runs the Lua `body` on `...`, for an operator the checker refuses.
local function lua(body: string, ...: any): boolean, any
  local chunk = assert(load(body))
  return pcall(chunk as Call, ...) -- cast: the chunk is untyped Lua
end

local function test_escape_replaces_the_five_characters()
  assert(Html.raw(Html.escape("<a href=\"x\" title='y'>&</a>")) ==
      "&lt;a href=&quot;x&quot; title=&#39;y&#39;&gt;&amp;&lt;/a&gt;")
  assert(Html.raw(Html.escape("")) == "")
  assert(Html.raw(Html.escape("plain text, 1 < 2")) == "plain text, 1 &lt; 2")
end

local function test_escape_keeps_every_other_byte()
  local kept = "plain \0\1\127 \xc3\xa9\xe2\x82\xac \xff` =/\n"
  assert(Html.raw(Html.escape(kept)) == kept)
  -- An entity already there is escaped like any text: `&` is not special
  -- by what follows it.
  assert(Html.raw(Html.escape("&amp;")) == "&amp;amp;")
end

local function test_escape_attr_encodes_every_ascii_byte_but_letters_and_digits()
  for byte = 0, 127 do
    local c = string.char(byte)
    local out = Html.raw_attr(Html.escape_attr(c))
    if c:find("^%w$") then
      assert(out == c, "a letter or digit changed: " .. byte)
    else
      assert(out == "&#" .. byte .. ";", byte .. " became " .. out)
    end
  end
  assert(Html.raw_attr(Html.escape_attr("a b\"c'd=e<f>g`h&i")) ==
      "a&#32;b&#34;c&#39;d&#61;e&#60;f&#62;g&#96;h&#38;i")
end

--- A byte of 0x80 or more passes, so a UTF-8 character is not made into
--- the characters its bytes would be as code points.
local function test_escape_attr_keeps_utf8_whole()
  local text = "caf\xc3\xa9 \xe2\x82\xac"
  assert(Html.raw_attr(Html.escape_attr(text)) == "caf\xc3\xa9&#32;\xe2\x82\xac")
  assert(Html.raw_attr(Html.escape_attr("\xff\xfe")) == "\xff\xfe")
end

local function test_trust_keeps_the_string_as_it_is()
  assert(Html.raw(Html.trust("<b>x</b>")) == "<b>x</b>")
  assert(Html.raw_attr(Html.trust_attr("a b\"")) == "a b\"")
  assert(Html.raw(Html.trust("")) == "")
end

local function test_concat_joins_in_order()
  local parts = { Html.trust("<p>"), Html.escape("a < b"), Html.trust("</p>") }
  assert(Html.raw(Html.concat(parts)) == "<p>a &lt; b</p>")
  assert(Html.raw(Html.concat({})) == "")
  local many: {Html.SafeHtml} = {}
  for i = 1, 500 do many[i] = Html.trust(tostring(i) .. ",") end
  assert(Html.raw(Html.concat(many)):sub(1, 8) == "1,2,3,4,")
  assert(#Html.raw(Html.concat(many)) == 1892)
end

--- Nothing but `raw` reaches the string: a safe value has no operator.
--- A table of the values given, as a sequence, with its type forgotten.
local function table_of(...: any): {any: any}
  local out: {any: any} = {}
  for index, value in ipairs({ ... }) do out[index] = value end
  return out
end

--- A table that is no sequence is refused, not read as far as `#` happens
--- to reach: a hole would drop the parts after it.
local function test_concat_refuses_a_table_that_is_no_sequence()
  local a, b = Html.trust("a"), Html.trust("b")
  local holes = table_of(a)
  holes[3] = b
  local extra = table_of(a, b)
  extra["note"] = a
  local sparse = table_of(a)
  sparse[5] = b
  local negative = table_of(a)
  negative[-1] = b
  local float = table_of(a)
  float[1.5] = b
  for name, parts in pairs({ holes = holes, extra = extra, sparse = sparse,
      negative = negative, float = float }) do
    local ok, why = attempt(Html.concat, parts)
    assert(not ok and tostring(why):find("parts is not a sequence", 1, true), name .. ": " .. tostring(why))
  end
  assert(Html.raw(Html.concat({ a, b })) == "ab")
end

local function test_a_safe_value_has_no_string_behavior()
  local html = untyped(Html.escape("x"))
  local attr = untyped(Html.escape_attr("x"))
  local url = untyped(Html.trust_url("x"))
  for _, value in ipairs({ html, attr, url }) do
    assert(type(value) == "userdata")
    assert(not lua("return ... .. 'y'", value))
    assert(not lua("return 'y' .. ...", value))
    assert(not lua("return #...", value))
    assert(not lua("return (...).x", value))
    assert(not lua("return (...).raw", value))
    assert(not lua("return (...) < (...)", value))
    assert(lua("return (...) == 'x'", value) and not select(2, lua("return (...) == 'x'", value)))
    assert(tostring(value):find("^cosmic%.html%.Safe%w+: ") ~= nil, tostring(value))
  end
  -- The metatable is hidden, so no program adds an operator to every value.
  local function metatable_of(value: any): any
    return getmetatable(value)
  end
  assert(metatable_of(html) == false and metatable_of(attr) == false and metatable_of(url) == false)
  assert(not attempt(setmetatable, html, {}))
end

--- The raw functions and `concat` refuse a value of a type they were not
--- made for, whatever the checker saw.
local function test_the_functions_refuse_what_is_not_theirs()
  local attr = untyped(Html.escape_attr("x"))
  local html = untyped(Html.escape("x"))
  local ok, why = attempt(Html.raw, attr)
  assert(not ok and tostring(why):find("SafeHtml expected", 1, true), tostring(why))
  ok, why = attempt(Html.raw_attr, html)
  assert(not ok and tostring(why):find("SafeAttr expected", 1, true), tostring(why))
  local plains: {any} = { "x", {}, 1 }
  for _, plain in ipairs(plains) do
    assert(not attempt(Html.raw, plain))
    assert(not attempt(Html.raw_attr, plain))
  end
  local mixed: {any} = { Html.trust("a"), attr }
  ok, why = attempt(Html.concat, mixed)
  assert(not ok and tostring(why):find("element 2 is not a SafeHtml", 1, true), tostring(why))
  local strings: {any} = { "a" }
  ok, why = attempt(Html.concat, strings)
  assert(not ok and tostring(why):find("element 1 is not a SafeHtml", 1, true), tostring(why))
  assert(not attempt(Html.concat, "a"))
  assert(not attempt(Html.trust, 1))
  assert(not attempt(Html.trust_attr, {}))
  local url = untyped(Html.trust_url("x"))
  for _, other in ipairs({ html, attr }) do
    ok, why = attempt(Html.raw_url, other)
    assert(not ok and tostring(why):find("SafeUrl expected", 1, true), tostring(why))
  end
  assert(not attempt(Html.raw, url) and not attempt(Html.raw_attr, url))
  local urls: {any} = { Html.trust("a"), url }
  assert(not attempt(Html.concat, urls))
  assert(not attempt(Html.raw_url, "x"))
  assert(not attempt(Html.href, {}))
  assert(not attempt(Html.trust_url, {}))
end

--- What `href` makes of `input`, as a table a WHATWG-derived file of
--- (input, allowed) pairs could also fill: `allowed` is whether the text
--- must come back as it went in, and false that it must be `about:invalid`.
local type UrlCase = {string, boolean}

local URL_CASES <const>: {UrlCase} = {
  -- Schemes a browser would run.
  { "javascript:alert(1)", false },
  { "JaVaScRiPt:alert(1)", false },
  { " javascript:alert(1)", false },
  { "javascript:alert(1) ", false },
  { "java\tscript:alert(1)", false },
  { "java\nscript:alert(1)", false },
  { "java\rscript:alert(1)", false },
  { "\x01javascript:alert(1)", false },
  { "\0javascript:alert(1)", false },
  { "\x1fjavascript:alert(1)", false },
  { "\x7fjavascript:alert(1)", false },
  { "j\x7favascript:alert(1)", false },
  { "javascript\t:alert(1)", false },
  { "data:text/html,<script>alert(1)</script>", false },
  { "vbscript:msgbox(1)", false },
  { "file:///etc/passwd", false },
  { "ftp://host/", false },
  { "about:blank", false },
  { "httpx://ok", false },
  { "xhttp://ok", false },
  { "http+x://ok", false },
  { "h\xc3\xa9ttp://ok", false },
  -- Not a scheme, but a colon before any slash: refused, though a browser
  -- would read these as relative paths.
  { "%6Aavascript:alert(1)", false },
  { "1a:b", false },
  { "-a:b", false },
  { ":b", false },
  { "a b:c", false },
  { "path:with:colons/after", false },
  { "java script:alert(1)", false },
  -- A host without a scheme.
  { "//evil.com", false },
  { "\\\\evil.com", false },
  { "/\\evil.com", false },
  { "\\/evil.com", false },
  { "//", false },
  -- What passes.
  { "https://ok", true },
  { "HTTPS://ok", true },
  { "http://ok/a?b=c#d", true },
  { "HtTp://ok", true },
  { "mailto:a@b", true },
  { "MAILTO:a@b?subject=x y", true },
  { "http:relative", true },
  { "https:", true },
  { "/path?q=1#f", true },
  { "/path:with:colons", true },
  { "a/b:c", true },
  { "a?b:c", true },
  { "?x:y", true },
  { "#x:y", true },
  { "#", true },
  { "", true },
  { "relative", true },
  { "./a:b", true },
  { "../a", true },
  { "/", true },
  { "/a//b", true },
  { "\\", true },
  { "\\a", true },
  { "a\\b", true },
  { "a b", true },
  { "http://caf\xc3\xa9/\xff", true },
  { "\xc2\xa0javascript:x", false },
}

local function test_href_allows_what_a_browser_would_take_for_safe()
  for _, case in ipairs(URL_CASES) do
    local input, allowed = case[1], case[2]
    local out = Html.raw_url(Html.href(input))
    if allowed then
      assert(out == input, ("%q was changed to %q"):format(input, out))
    else
      -- U+00A0 is not a space a browser strips, but it is no scheme
      -- either: the case above is refused by its colon.
      assert(out == "about:invalid", ("%q was let through as %q"):format(input, out))
    end
  end
end

local function test_href_does_not_escape_the_url()
  assert(Html.raw_url(Html.href("/a?b=c&d=\"e\"<f>")) == "/a?b=c&d=\"e\"<f>")
  assert(Html.raw_attr(Html.escape_attr(Html.raw_url(Html.href("/a?b=c&d")))) == "&#47;a&#63;b&#61;c&#38;d")
end

local function test_trust_url_keeps_the_string_as_it_is()
  assert(Html.raw_url(Html.trust_url("javascript:x")) == "javascript:x")
  assert(Html.raw_url(Html.trust_url("")) == "")
end

--- Compiles `source` as the one module of a fresh fixture project: true,
--- or false and what the compile refused.
local function compiles(tmp: string, case: string, source: string): boolean, string
  local root = tmp .. "/" .. case
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/main.tl", source))
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return false, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return false, stage_trouble
  end
  local result, trouble = importer.compile(handle, built, "html-test")
  work.close(handle)
  if result == nil then
    return false, trouble
  end
  return true, ""
end

local function test_safe_values_type_check_where_they_belong(tmp: string)
  local ok, trouble = compiles(tmp, "valid", [[
local Html = require("cosmic.html")
local text: Html.SafeHtml = Html.escape("a")
local attr: Html.SafeAttr = Html.escape_attr("a")
local both: Html.SafeHtml = Html.concat({ text, Html.trust("<br>") })
return Html.raw(both) .. Html.raw_attr(attr)
]])
  assert(ok, trouble)
end

local function test_a_table_literal_is_no_safe_value(tmp: string)
  local ok, trouble = compiles(tmp, "table-html", [[
local Html = require("cosmic.html")
local forged: Html.SafeHtml = { raw = "<script>" }
return Html.raw(forged)
]])
  assert(not ok, "a table literal was taken for a SafeHtml")
  assert(trouble:find("not a userdata", 1, true), trouble)
  ok, trouble = compiles(tmp, "table-attr", [[
local Html = require("cosmic.html")
local forged: Html.SafeAttr = {}
return Html.raw_attr(forged)
]])
  assert(not ok, "a table literal was taken for a SafeAttr")
  assert(trouble:find("got {}, expected Html.SafeAttr", 1, true), trouble)
end

local function test_a_string_is_no_safe_value(tmp: string)
  local ok, trouble = compiles(tmp, "string-html", [[
local Html = require("cosmic.html")
local forged: Html.SafeHtml = "<script>"
return Html.raw(forged)
]])
  assert(not ok, "a string was taken for a SafeHtml")
  assert(trouble:find("SafeHtml", 1, true), trouble)
  ok, trouble = compiles(tmp, "string-arg", [[
local Html = require("cosmic.html")
return Html.concat({ "<script>" })
]])
  assert(not ok, "a string was taken for a SafeHtml in concat")
  assert(trouble:find("SafeHtml", 1, true), trouble)
end

local function test_one_safe_type_is_no_other(tmp: string)
  local ok, trouble = compiles(tmp, "attr-for-html", [[
local Html = require("cosmic.html")
local attr: Html.SafeAttr = Html.escape_attr("a")
local as_html: Html.SafeHtml = attr
return Html.raw(as_html)
]])
  assert(not ok, "a SafeAttr was taken for a SafeHtml")
  assert(trouble:find("SafeAttr is not a", 1, true), trouble)
  ok, trouble = compiles(tmp, "html-for-attr", [[
local Html = require("cosmic.html")
return Html.raw_attr(Html.escape("a"))
]])
  assert(not ok, "a SafeHtml was taken for a SafeAttr")
  assert(trouble:find("SafeHtml is not a", 1, true), trouble)
  ok, trouble = compiles(tmp, "attr-in-concat", [[
local Html = require("cosmic.html")
return Html.concat({ Html.escape_attr("a") })
]])
  assert(not ok, "a SafeAttr was joined as SafeHtml")
  assert(trouble:find("SafeAttr", 1, true) and trouble:find("is not a", 1, true) and
      trouble:find("SafeHtml", 1, true), trouble)
end

--- A safe value does not concatenate or print as a string.
local function test_a_safe_value_is_no_string_to_the_checker(tmp: string)
  local ok, trouble = compiles(tmp, "concat-operator", [[
local Html = require("cosmic.html")
return Html.escape("a") .. "b"
]])
  assert(not ok, "a SafeHtml was concatenated as a string")
  assert(trouble:find("cannot use operator '..'", 1, true) and trouble:find("SafeHtml", 1, true), trouble)
  ok, trouble = compiles(tmp, "as-string", [[
local Html = require("cosmic.html")
local s: string = Html.escape("a")
return s
]])
  assert(not ok, "a SafeHtml was taken for a string")
  assert(trouble:find("SafeHtml", 1, true), trouble)
end

local function test_a_safe_url_is_no_other_safe_type(tmp: string)
  local ok, trouble = compiles(tmp, "url-valid", [[
local Html = require("cosmic.html")
local url: Html.SafeUrl = Html.href("/a")
return Html.raw_url(url) .. Html.raw_url(Html.trust_url("b"))
]])
  assert(ok, trouble)
  ok, trouble = compiles(tmp, "url-for-html", [[
local Html = require("cosmic.html")
local url: Html.SafeUrl = Html.href("/a")
local as_html: Html.SafeHtml = url
return Html.raw(as_html)
]])
  assert(not ok, "a SafeUrl was taken for a SafeHtml")
  assert(trouble:find("SafeUrl is not a", 1, true), trouble)
  ok, trouble = compiles(tmp, "url-for-attr", [[
local Html = require("cosmic.html")
return Html.raw_attr(Html.href("/a"))
]])
  assert(not ok, "a SafeUrl was taken for a SafeAttr")
  assert(trouble:find("SafeUrl is not a", 1, true), trouble)
  ok, trouble = compiles(tmp, "attr-for-url", [[
local Html = require("cosmic.html")
return Html.raw_url(Html.escape_attr("a"))
]])
  assert(not ok, "a SafeAttr was taken for a SafeUrl")
  assert(trouble:find("SafeAttr is not a", 1, true), trouble)
  ok, trouble = compiles(tmp, "url-table", [[
local Html = require("cosmic.html")
local forged: Html.SafeUrl = {}
return Html.raw_url(forged)
]])
  assert(not ok, "a table literal was taken for a SafeUrl")
  assert(trouble:find("got {}, expected Html.SafeUrl", 1, true), trouble)
  ok, trouble = compiles(tmp, "url-string", [[
local Html = require("cosmic.html")
local forged: Html.SafeUrl = "javascript:x"
return Html.raw_url(forged)
]])
  assert(not ok, "a string was taken for a SafeUrl")
  assert(trouble:find("SafeUrl", 1, true), trouble)
  ok, trouble = compiles(tmp, "url-concat", [[
local Html = require("cosmic.html")
return Html.href("/a") .. "b"
]])
  assert(not ok, "a SafeUrl was concatenated as a string")
  assert(trouble:find("cannot use operator '..'", 1, true) and trouble:find("SafeUrl", 1, true), trouble)
end
