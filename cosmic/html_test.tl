--- [`cosmic.html`]'s safe values: what each escaper makes of the bytes
--- that matter, that a safe value is opaque at run time and refused by
--- the type checker in another's place, and that `raw` and `concat`
--- hold to their types.
local Fs = require("cosmic.fs")
local Html = require("cosmic.html")
local Url = require("cosmic.url")
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

local function metatable_of(value: any): any
  return getmetatable(value)
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

--- What `href` makes of `input`, as a table of (input, allowed)
--- pairs: `allowed` is whether the text
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
  -- An absolute http(s) URL may name any host, with slashes either way.
  { "http:\\\\h", true },
  { "https:\\\\h", true },
  { "http:evil.com", true },
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
  -- A no-break space is no space a browser strips; the text is refused
  -- because its first byte is not a letter, with a colon ahead of any slash.
  { "\xc2\xa0javascript:x", false },
  { "/\t", false },
  { "/\x01/", false },
  { "http://a\0b", false },
  { "a\0b", false },
}

local function test_href_allows_what_a_browser_would_take_for_safe()
  for _, case in ipairs(URL_CASES) do
    local input, allowed = case[1], case[2]
    local out = Html.raw_url(Html.href(input))
    if allowed then
      assert(out == input, ("%q was changed to %q"):format(input, out))
    else
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

local function part_of(s: string | number): string
  return Html.raw_url_part(Html.url_part(s))
end

--- Strings from a fixed generator, spread over every byte, so the
--- agreement tests need no random source and name the same inputs each run.
local function sample_strings(count: integer): {string}
  local strings: {string} = {}
  local state = 12345
  for _ = 1, count do
    local bytes: {string} = {}
    for _ = 1, state % 9 do
      state = (state * 1103515245 + 12345) % 2147483648
      bytes[#bytes + 1] = string.char((state >> 8) % 256)
    end
    state = (state * 1103515245 + 12345) % 2147483648
    strings[#strings + 1] = table.concat(bytes)
  end
  return strings
end

local function test_url_part_keeps_the_unreserved_set_and_escapes_the_rest()
  assert(part_of("AZaz09-._~") == "AZaz09-._~")
  assert(part_of("") == "")
  assert(part_of("a b/c?d#e&f=g+h:i@j%k\\l") == "a%20b%2Fc%3Fd%23e%26f%3Dg%2Bh%3Ai%40j%25k%5Cl")
  assert(part_of("\0\n\127\xc3\xa9\xff") == "%00%0A%7F%C3%A9%FF")
end

local function test_url_part_writes_a_number_as_tostring_does()
  assert(part_of(7) == "7")
  assert(part_of(-7) == "-7")
  assert(part_of(1.5) == "1.5")
  assert(part_of(1e100) == "1e%2B100")
  assert(part_of(math.huge) == "inf")
  assert(part_of(math.mininteger) == tostring(math.mininteger))
end

local function test_url_part_agrees_with_url_escape_on_every_byte_and_many_strings()
  for byte = 0, 255 do
    local c = string.char(byte)
    if c ~= "." then
      assert(part_of(c) == Url.escape(c), "byte " .. byte)
    end
  end
  for _, text in ipairs(sample_strings(500)) do
    if text ~= "." and text ~= ".." then
      assert(part_of(text) == Url.escape(text), ("%q"):format(text))
    end
  end
end

local function test_url_part_writes_a_whole_dot_segment_with_its_percent_escaped()
  assert(part_of(".") == "%252E")
  assert(part_of("..") == "%252E%252E")
  -- Only the whole value is a dot segment; the rest is escaped as ever.
  for _, text in ipairs({ "...", ".a", "a.", "a..", "..a", " .", "%2e", "%2e%2e", "./", "" }) do
    assert(part_of(text) == Url.escape(text), text)
  end
  assert(Url.unescape(part_of("..")) == "%2E%2E")
end

local function test_url_part_refuses_a_value_that_is_not_text()
  local others: {any} = { {}, true, false, Html.escape("x") }
  for _, other in ipairs(others) do
    local ok, why = attempt(Html.url_part, other)
    assert(not ok and tostring(why):find("string or number expected", 1, true), tostring(why))
  end
  assert(not attempt(Html.url_part))
end

local function test_url_query_joins_escaped_pairs_in_order()
  local query = (assert(Html.url_query({ { "q", "a b" }, { "tag", "x&y" }, { "tag", "z=1" } })))
  assert(Html.raw_url_part(query) == "q=a%20b&tag=x%26y&tag=z%3D1")
  assert(Html.raw_url_part((assert(Html.url_query({})))) == "")
  assert(Html.raw_url_part((assert(Html.url_query({ { "", "" } })))) == "=")
  assert(Html.raw_url_part((assert(Html.url_query({ { "a&b=c", "\xc3\xa9" } })))) == "a%26b%3Dc=%C3%A9")
  -- A dot segment is about a path; in a query a dot is a dot.
  assert(Html.raw_url_part((assert(Html.url_query({ { ".", ".." } })))) == ".=..")
end

local function test_url_query_names_a_pair_that_is_not_two_strings()
  local cases: {{any}} = {
    { { "a" } }, { { "a", "b", "c" } }, { { "a", 1 } }, { { 1, "a" } }, { "ab" }, { {} },
    { { "a", "b" }, { "c" } },
  }
  for _, given in ipairs(cases) do
    local part, why = (Html.url_query as function(any): any, string)(given)
    assert(part == nil and why:find("is not two strings", 1, true), tostring(why))
  end
  local part, why = (Html.url_query as function(any): any, string)({ { "a", "b" }, { "c" } })
  assert(part == nil and why == "html: pair 2 is not two strings", why)
end

local function test_url_query_raises_for_a_table_that_is_no_sequence()
  local holes = table_of({ "a", "b" })
  holes[3] = { "c", "d" }
  local extra = table_of({ "a", "b" })
  extra["note"] = 1
  local cases: {{any: any}} = { holes, extra }
  for _, given in ipairs(cases) do
    local ok, why = attempt(Html.url_query, given)
    assert(not ok and tostring(why):find("pairs is not a sequence", 1, true), tostring(why))
  end
  assert(not attempt(Html.url_query, "a=b"))
end

local function test_raw_url_part_holds_to_its_type()
  local html = untyped(Html.escape("x"))
  local url = untyped(Html.trust_url("x"))
  local part = untyped(Html.url_part("x"))
  for _, other in ipairs({ html, url }) do
    local ok, why = attempt(Html.raw_url_part, other)
    assert(not ok and tostring(why):find("SafeUrlPart expected", 1, true), tostring(why))
  end
  assert(not attempt(Html.raw_url_part, "x"))
  assert(not attempt(Html.raw_url, part) and not attempt(Html.raw, part) and not attempt(Html.raw_attr, part))
  assert(type(part) == "userdata" and metatable_of(part) == false)
  assert(not lua("return ... .. 'y'", part))
end

local LOCAL_CASES <const>: {UrlCase} = {
  { "/a/b?c=d#e", true },
  { "a/b", true },
  { "?x:y", true },
  { "#x:y", true },
  { "/a:b", true },
  { "", true },
  { "caf\xc3\xa9/ x", true },
  { "https://example.com/", false },
  { "http:evil.com", false },
  { "mailto:a@b", false },
  { "javascript:alert(1)", false },
  { "a:b", false },
  { ":x", false },
  { "//host/x", false },
  { "\\\\host", false },
  { "/\\host", false },
  { "\\/host", false },
  { " /a", false },
  { "/a ", false },
  { "/a\tb", false },
  { "/a\nb", false },
  { "/a\0b", false },
  { "/a\127b", false },
}

local function test_local_href_lets_only_a_relative_reference_through()
  for _, case in ipairs(LOCAL_CASES) do
    local input, allowed = case[1], case[2]
    local out = Html.raw_url(Html.local_href(input))
    if allowed then
      assert(out == input, ("%q was changed to %q"):format(input, out))
    else
      assert(out == "about:invalid", ("%q was let through as %q"):format(input, out))
    end
  end
  assert(not attempt(Html.local_href, {}))
end

--- `CSS.escape` as the plan for [`Html.escape_css_attr`] states it, written
--- on its own: a leading digit (or one after a leading `-`), a lone `-`
--- and every ASCII byte but a letter, digit, `-` and `_` is a hex escape
--- ending in a space, and NUL is U+FFFD.
local function css_escape(s: string): string
  local out: {string} = {}
  for i = 1, #s do
    local c = s:sub(i, i)
    local byte = c:byte()
    local leading_digit = c:find("^%d$") and (i == 1 or (i == 2 and s:sub(1, 1) == "-"))
    if byte == 0 then
      out[#out + 1] = "\xef\xbf\xbd"
    elseif byte >= 128 or (c:find("^[%w_-]$") and not leading_digit and not (c == "-" and #s == 1)) then
      out[#out + 1] = c
    else
      out[#out + 1] = ("\\%x "):format(byte)
    end
  end
  return table.concat(out)
end

--- Reads CSS escapes as a parser does: `\` and one to six hex digits and
--- an optional single space is that code point, `\` and any other
--- character is that character. `text` is attribute text, so the character
--- references the escaper writes are decoded first.
local function css_unescape(text: string): string
  local plain = text:gsub("&#(%d+);", function(code: string): string
    return string.char(tonumber(code) as integer)
  end)
  local out: {string} = {}
  local i = 1
  while i <= #plain do
    local c = plain:sub(i, i)
    if c ~= "\\" then
      out[#out + 1] = c
      i = i + 1
    else
      local hex = plain:match("^%x%x?%x?%x?%x?%x?", i + 1)
      if hex then
        out[#out + 1] = utf8.char(tonumber(hex, 16) as integer)
        i = i + 1 + #hex
        if plain:sub(i, i) == " " then
          i = i + 1
        end
      else
        out[#out + 1] = plain:sub(i + 1, i + 1)
        i = i + 2
      end
    end
  end
  return table.concat(out)
end

local function css_attr_of(s: string | number): string
  return Html.raw_attr(Html.escape_css_attr(s))
end

local function test_escape_css_attr_escapes_what_a_selector_would_read()
  assert(css_attr_of("row") == "row")
  assert(css_attr_of("x, body") == "x&#92;2c&#32;&#92;20&#32;body")
  assert(css_attr_of("a.b#c") == "a&#92;2e&#32;b&#92;23&#32;c")
  assert(css_attr_of("row-123") == "row&#45;123")
  assert(css_attr_of("a_b") == "a&#95;b")
  assert(css_attr_of("123") == "&#92;31&#32;23")
  assert(css_attr_of("-1") == "&#45;&#92;31&#32;")
  assert(css_attr_of("-") == "&#92;2d&#32;")
  assert(css_attr_of("--") == "&#45;&#45;")
  assert(css_attr_of("a\0b") == "a\xef\xbf\xbdb")
  assert(css_attr_of("\1\127") == "&#92;1&#32;&#92;7f&#32;")
  assert(css_attr_of("caf\xc3\xa9") == "caf\xc3\xa9")
  assert(css_attr_of(42) == "&#92;34&#32;2")
  assert(css_attr_of("") == "")
end

--- Outputs of `CSS.escape` written down from the CSSOM specification, not
--- computed here. `escape_css_attr` always writes a hex escape and its
--- space where `CSS.escape` writes a backslash and the character (`\-`,
--- `\ `, `\.`): the two read as the same text, which is what this checks,
--- and the hex form needs no case for where the character stands. A hex
--- escape's space also keeps a following literal space a combinator.
local function test_escape_css_attr_reads_as_the_spec_css_escape()
  local spec: {{string}} = {
    { "0a", "\\30 a" },
    { "-", "\\-" },
    { "-0", "-\\30 " },
    { "--", "--" },
    { "a b", "a\\ b" },
    { "a.b", "a\\.b" },
    { "x, body", "x\\,\\ body" },
    { "\1", "\\1 " },
    { "\127", "\\7f " },
    { "a\0b", "a\xef\xbf\xbdb" },
    { "caf\xc3\xa9", "caf\xc3\xa9" },
    { "a_b-c", "a_b-c" },
  }
  for _, case in ipairs(spec) do
    local input, expected = case[1], case[2]
    assert(css_unescape(css_attr_of(input)) == css_unescape(expected), ("%q"):format(input))
    assert(css_unescape(expected) == css_unescape(css_escape(input)), ("%q"):format(input))
  end
  -- The one place the text differs: CSS.escape's `\-` and `\ ` are not hex.
  assert(css_attr_of("-") == "&#92;2d&#32;")
  assert(css_attr_of("a b") == "a&#92;20&#32;b")
end

local function test_escape_css_attr_is_css_escape_then_escape_attr()
  for byte = 0, 255 do
    for _, text in ipairs({ string.char(byte), "a" .. string.char(byte), "-" .. string.char(byte),
        string.char(byte) .. "1" }) do
      assert(css_attr_of(text) == Html.raw_attr(Html.escape_attr(css_escape(text))), ("%q"):format(text))
    end
  end
  for _, text in ipairs(sample_strings(500)) do
    assert(css_attr_of(text) == Html.raw_attr(Html.escape_attr(css_escape(text))), ("%q"):format(text))
  end
end

local function test_escape_css_attr_refuses_a_value_that_is_not_text()
  local others: {any} = { {}, true, Html.escape("x") }
  for _, other in ipairs(others) do
    assert(not attempt(Html.escape_css_attr, other))
  end
end

local function test_json_holds_the_encoded_value()
  local json = (assert(Html.json({ id = 7, kind = "note" })))
  local text = Html.raw_json(json)
  assert(text == '{"id":7,"kind":"note"}' or text == '{"kind":"note","id":7}', text)
  assert(Html.raw_json((assert(Html.json("a\"b<c>&'")))) == '"a\\"b<c>&\'"')
  assert(Html.raw_json((assert(Html.json(nil)))) == "null")
  assert(Html.raw_json((assert(Html.json({ "x", 1, true })))) == '["x",1,true]')
  -- The text is JSON, not attribute text: the slot escapes it.
  assert(Html.raw(Html.escape(Html.raw_json((assert(Html.json({ a = "b" })))))) == "{&quot;a&quot;:&quot;b&quot;}")
end

local function test_json_names_what_it_cannot_encode()
  local json, why = Html.json({ users = { { name = print } } })
  assert(json == nil and why:find("/users/0/name", 1, true), tostring(why))
  json, why = Html.json(0 / 0)
  assert(json == nil and why ~= "")
  local cycle: {string: any} = {}
  cycle.me = cycle
  json, why = Html.json(cycle)
  assert(json == nil and why ~= "")
  json, why = Html.json("\xff")
  assert(json == nil and why ~= "")
end

local function test_json_text_wraps_only_text_that_is_json()
  assert(Html.raw_json((assert(Html.json_text(' {"a": [1, 2]} ')))) == ' {"a": [1, 2]} ')
  for _, text in ipairs({ "", "{", "{'a':1}", "<script>", "1 2", "alert(1)" }) do
    local json, why = Html.json_text(text)
    assert(json == nil and why ~= "", text)
  end
end

local function test_json_has_no_unchecked_door_and_holds_to_its_type()
  local html_module: {string: any} = Html as {string: any}
  assert(html_module.trust_json == nil and html_module.trust_json_text == nil)
  local json = untyped((assert(Html.json(1))))
  assert(type(json) == "userdata" and metatable_of(json) == false)
  assert(not lua("return ... .. 'y'", json))
  for _, other in ipairs({ untyped(Html.escape("1")), untyped(Html.url_part("1")), "1", 1 }) do
    local ok, why = attempt(Html.raw_json, other)
    assert(not ok and tostring(why):find("SafeJson expected", 1, true), tostring(why))
  end
  assert(not attempt(Html.raw, json) and not attempt(Html.raw_attr, json) and not attempt(Html.raw_url_part, json))
end

local function test_url_parts_and_json_type_check_where_they_belong(tmp: string)
  local ok, trouble = compiles(tmp, "part-valid", [[
local Html = require("cosmic.html")
local part: Html.SafeUrlPart = Html.url_part("a")
local json = (assert(Html.json({})))
local as_json: Html.SafeJson = json
local url: Html.SafeUrl = Html.local_href("/a")
return Html.raw_url_part(part) .. Html.raw_json(as_json) .. Html.raw_url(url)
]])
  assert(ok, trouble)
  local forged_cases: {{string}} = {
    { "part-string", 'local f: Html.SafeUrlPart = "a"\nreturn Html.raw_url_part(f)', "SafeUrlPart" },
    { "part-table", 'local f: Html.SafeUrlPart = {}\nreturn Html.raw_url_part(f)', "got {}, expected Html.SafeUrlPart" },
    { "json-string", 'local f: Html.SafeJson = "{}"\nreturn Html.raw_json(f)', "SafeJson" },
    { "json-table", 'local f: Html.SafeJson = {}\nreturn Html.raw_json(f)', "got {}, expected Html.SafeJson" },
    { "url-for-part", 'return Html.raw_url_part(Html.href("/a"))', "SafeUrl is not a" },
    { "part-for-url", 'return Html.raw_url(Html.url_part("a"))', "SafeUrlPart is not a" },
    { "json-for-attr", 'local j = assert(Html.json({}))\nreturn Html.raw_attr(j)', "SafeJson is not a" },
    { "json-for-html", 'return Html.raw(Html.escape("a")) .. Html.raw_json(Html.escape("a"))', "SafeHtml is not a" },
    { "part-concat", 'return Html.url_part("a") .. "b"', "cannot use operator '..'" },
  }
  for _, case in ipairs(forged_cases) do
    ok, trouble = compiles(tmp, case[1], 'local Html = require("cosmic.html")\n' .. case[2] .. "\n")
    assert(not ok, case[1] .. " type-checked")
    assert(trouble:find(case[3], 1, true), case[1] .. ": " .. trouble)
  end
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
