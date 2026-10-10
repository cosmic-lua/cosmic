local Url = require("cosmic.url")

local function test_escape_keeps_only_the_unreserved_bytes()
  for byte = 0, 255 do
    local ch = string.char(byte)
    local want = ch:find("^[A-Za-z0-9._~-]$") and ch or ("%%%02X"):format(byte)
    assert(Url.escape(ch) == want, ("byte %d escaped as %q"):format(byte, Url.escape(ch)))
  end
  assert(Url.escape("") == "")
  assert(Url.escape("a b/c?d=e&f#g+h%") == "a%20b%2Fc%3Fd%3De%26f%23g%2Bh%25")
end

local function test_unescape_reads_either_case_and_any_byte()
  assert(Url.unescape("%41%6a%6A") == "Ajj")
  assert(Url.unescape("%00%2F%ff") == "\0/\xff")
  assert(Url.unescape("") == "")
  assert(Url.unescape("plain") == "plain")
end

local function test_unescape_leaves_a_plus_as_it_is()
  assert(Url.unescape("a+b%2B") == "a+b+")
end

local function test_unescape_refuses_a_percent_without_two_hex_digits_naming_its_byte()
  local cases: {string: integer} = { ["%"] = 1, ["a%4"] = 2, ["%4g"] = 1, ["%%41"] = 1, ["ok%41%"] = 6, ["%zz"] = 1 }
  for text, at in pairs(cases) do
    local bytes, why = Url.unescape(text)
    assert(bytes == nil, text)
    assert(why == ("url: '%%' at byte %d is not followed by two hex digits"):format(at), why)
  end
end

local function same(got: {string}, want: {string}): boolean
  if #got ~= #want then return false end
  for i, v in ipairs(want) do
    if got[i] ~= v then return false end
  end
  return true
end

local function test_segments_split_before_unescaping_and_drop_empty_and_dot()
  local cases: {string: {string}} = {
    ["/"] = {},
    ["//"] = {},
    ["/./%2e/%2E/"] = {},
    ["/a/b/"] = { "a", "b" },
    ["/a//b"] = { "a", "b" },
    ["/a%20b/c%3Fd"] = { "a b", "c?d" },
    ["/.../.a/a."] = { "...", ".a", "a." },
    ["/a?b"] = { "a?b" },
  }
  for path, want in pairs(cases) do
    local got, why = Url.segments(path)
    assert(got ~= nil, path .. ": " .. why)
    assert(why == "")
    assert(same(got, want), path .. " gave " .. table.concat(got, "|"))
  end
end

local function test_segments_refuse_a_climb_escaped_or_not()
  for _, path in ipairs({ "/..", "/a/../b", "/%2e%2e", "/%2E%2E/x", "/.%2e", "/%2e." }) do
    local got, why = Url.segments(path)
    assert(got == nil, path)
    assert(why:find("'..'", 1, true), why)
  end
end

local function test_segments_refuse_an_escaped_slash_or_nul()
  local got, why = Url.segments("/a/b%2Fc")
  assert(got == nil and why == "url: the segment at byte 4 holds an escaped '/'", why)
  got, why = Url.segments("/a%00")
  assert(got == nil and why == "url: the segment at byte 2 holds a NUL", why)
end

local function test_segments_name_a_bad_escape_by_its_byte_in_the_path()
  local got, why = Url.segments("/ab/c%z")
  assert(got == nil and why == "url: '%' at byte 6 is not followed by two hex digits", why)
end

local function test_segments_refuse_a_path_not_starting_with_a_slash()
  for _, path in ipairs({ "", "a/b", "%2Fa", "http://h/a" }) do
    local got, why = Url.segments(path)
    assert(got == nil and why == "url: the path does not start with '/'", path)
  end
end

local function test_parse_reads_every_part()
  local p = assert(Url.parse("HtTp://User:Pw@Example.COM:8080/A%20b/?q=1&r=%41#Frag?x"))
  assert(p.scheme == "http", p.scheme)
  assert(p.userinfo == "User:Pw", p.userinfo)
  assert(p.host == "example.com", p.host)
  assert(p.port == 8080)
  assert(p.path == "/A%20b/", p.path)
  assert(p.query == "q=1&r=%41", p.query)
  assert(p.fragment == "Frag?x", p.fragment)
end

local function test_parse_leaves_absent_parts_nil_and_an_absent_path_empty()
  local p = assert(Url.parse("https://example.com"))
  assert(p.host == "example.com" and p.path == "")
  assert(p.userinfo == nil and p.port == nil and p.query == nil and p.fragment == nil)
  p = assert(Url.parse("https://@h:?#"))
  assert(p.userinfo == "" and p.host == "h" and p.port == nil)
  assert(p.path == "" and p.query == "" and p.fragment == "")
  p = assert(Url.parse("https://h#a?b"))
  assert(p.query == nil and p.fragment == "a?b")
end

local function test_parse_reads_an_ipv6_host_out_of_its_brackets()
  local p = assert(Url.parse("http://[2001:DB8::1]:80/"))
  assert(p.host == "2001:db8::1" and p.port == 80 and p.path == "/")
  p = assert(Url.parse("http://[::ffff:127.0.0.1]"))
  assert(p.host == "::ffff:127.0.0.1" and p.port == nil)
end

local function test_parse_takes_only_a_well_formed_ipv6_host()
  for _, host in ipairs({ "::", "1::", "1:2:3:4:5:6:7:8", "1::8", "1:2:3:4:5:6:1.2.3.4", "::1.2.3.4",
      "1:2:3:4:5:6:7::", "::2:3:4:5:6:7:8" }) do
    local p, why = Url.parse("http://[" .. host .. "]/")
    assert(p ~= nil and p.host == host, host .. ": " .. why)
  end
  for _, host in ipairs({ ":", ":::", ":::::", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7", "1::2::3", "12345::",
      "g::", "1:2:3:4:5:6:7:8::", "::1.2.3.256", "::1.2.3", "1:2:3:4:5:6:7:1.2.3.4", ":1::", "1::2:",
      "::0001.2.3.4", "::01.2.3.4", "::ffff:1.2.3.04", "::1:2:3:4:5:6:7:8", "fe80::1%25eth0" }) do
    local p, why = Url.parse("http://[" .. host .. "]/")
    assert(p == nil and why == "url: the host in brackets is not an IPv6 address", host)
  end
end

local function test_parse_reads_a_port_from_0_to_65535()
  assert(assert(Url.parse("http://h:0/")).port == 0)
  assert(assert(Url.parse("http://h:65535/")).port == 65535)
  assert(assert(Url.parse("http://h:000080/")).port == 80)
  for _, url in ipairs({ "http://h:65536/", "http://h:100000/", "http://h:99999999999999999999999/" }) do
    local p, why = Url.parse(url)
    assert(p == nil and why == "url: the port is not a number from 0 to 65535", url)
  end
  local p, why = Url.parse("http://h:8o/")
  assert(p == nil and why == "url: the port holds a byte other than a digit", why)
  p, why = Url.parse("http://h:-1/")
  assert(p == nil and why == "url: the port holds a byte other than a digit", why)
end

local function test_parse_refuses_what_is_not_an_absolute_url_naming_a_host()
  local cases: {string: string} = {
    ["/just/a/path"] = "does not start with a scheme",
    ["example.com/x"] = "does not start with a scheme",
    ["mailto:a@b.c"] = "does not start with a scheme",
    ["1http://h/"] = "does not start with a scheme",
    [""] = "does not start with a scheme",
    ["file:///etc/passwd"] = "names no host",
    ["http://u@/x"] = "names no host",
    ["http://:80/"] = "names no host",
    ["http://a@b@c/"] = "more than one '@'",
    ["http://[::1/"] = "missing its closing ']'",
    ["http://[]/"] = "not an IPv6 address",
    ["http://[127.0.0.1]/"] = "not an IPv6 address",
    ["http://[fe80::1%25eth0]/"] = "not an IPv6 address",
    ["http://[::1]x/"] = "followed by something other than ':'",
    ["http://::1/"] = "more than one ':'",
    ["http://a]b/"] = "bracket outside an IPv6 address",
  }
  for url, says in pairs(cases) do
    local p, why = Url.parse(url)
    assert(p == nil, url)
    assert(why:find(says, 1, true), url .. ": " .. why)
  end
end

local function test_parse_refuses_a_space_or_control_byte_naming_url_escape()
  local p, why = Url.parse("http://h/a b")
  assert(p == nil)
  assert(why == "url: the URL holds a space at byte 11; escape a path segment or query value with Url.escape", why)
  p, why = Url.parse("http://h/\0")
  assert(p == nil and why:find("holds a NUL at byte 10;", 1, true), why)
  p, why = Url.parse("http://h/?a=\n")
  assert(p == nil and why:find("holds control byte 0x0a at byte 13;", 1, true), why)
  p, why = Url.parse("http://h\127/")
  assert(p == nil and why:find("holds control byte 0x7f at byte 9;", 1, true), why)
end

local function test_parse_keeps_bytes_past_ascii_as_written()
  local p = assert(Url.parse("http://h/caf\xc3\xa9"))
  assert(p.path == "/caf\xc3\xa9")
end

local function names_values(q: Url.Query): string
  local out: {string} = {}
  for _, p in ipairs(q.pairs) do
    out[#out + 1] = p.name .. "=" .. p.value
  end
  return table.concat(out, "|")
end

local function decoded(text: string, opts?: Url.QueryOptions): Url.Query
  local q, why = Url.decode_query(text, opts)
  assert(q ~= nil, text .. ": " .. why)
  assert(why == "")
  return q
end

local function test_decode_query_splits_on_ampersand_and_first_equals()
  assert(names_values(decoded("a=1&b=2=3&c")) == "a=1|b=2=3|c=")
  assert(names_values(decoded("=v&a=")) == "=v|a=")
  assert(#decoded("").pairs == 0)
end

local function test_decode_query_skips_empty_pieces_without_counting_them()
  assert(names_values(decoded("&&a=1&&b=2&")) == "a=1|b=2")
  assert(#decoded("&&&&&&", { max_pairs = 1 }).pairs == 0)
end

local function test_decode_query_reads_plus_as_space_and_percent_2b_as_plus()
  assert(names_values(decoded("a+b=c+d%2Be%20f")) == "a b=c d+e f")
end

local function test_decode_query_does_not_split_on_semicolon_or_brackets()
  local q = decoded("a=1;b=2&x[]=1&x[y]=2")
  assert(names_values(q) == "a=1;b=2|x[]=1|x[y]=2")
end

local function test_decode_query_keeps_order_and_repeated_names()
  local q = decoded("a=1&b=2&a=3&a=")
  assert(names_values(q) == "a=1|b=2|a=3|a=")
  assert(Url.query_first(q, "a") == "1")
  assert(Url.query_last(q, "a") == "")
  assert(table.concat(Url.query_all(q, "a"), ",") == "1,3,")
  assert(Url.query_first(q, "z") == nil and Url.query_last(q, "z") == nil)
  assert(#Url.query_all(q, "z") == 0)
  Url.query_all(q, "a")[1] = "changed"
  assert(Url.query_first(q, "a") == "1")
end

local function test_decode_query_refuses_a_bad_escape_naming_its_byte_in_the_whole_text()
  local cases: {string: integer} = { ["a=1&b=%"] = 7, ["%zz=1"] = 1, ["a=1&bb=2&c%4=3"] = 11, ["a=x%4&b"] = 4 }
  for text, at in pairs(cases) do
    local q, why = Url.decode_query(text)
    assert(q == nil, text)
    assert(why == ("url: '%%' at byte %d is not followed by two hex digits"):format(at), text .. ": " .. why)
  end
end

local function test_decode_query_lenient_keeps_a_stray_percent()
  assert(names_values(decoded("q=100%&r=%4&s=%41%zz", { lenient = true })) == "q=100%|r=%4|s=A%zz")
end

local function test_decode_query_refuses_invalid_utf8_unless_told_not_to()
  local q, why = Url.decode_query("a=1&b=%FF")
  assert(q == nil and why == "url: the name or value of pair 2 is not valid UTF-8", why)
  assert(Url.decode_query("%ED%A0%80=1") == nil)
  assert(Url.decode_query("a=%C0%80") == nil, "overlong NUL")
  assert(Url.decode_query("a=%F4%90%80%80") == nil, "past U+10FFFF")
  assert(names_values(decoded("a=%C3%A9")) == "a=\xc3\xa9")
  assert(names_values(decoded("b=%FF%00", { utf8 = false })) == "b=\xff\0")
end

local function test_decode_query_lenient_without_utf8_keeps_stray_percent_and_raw_bytes()
  local text = "a=%FF%&b=%4"
  assert(Url.decode_query(text, { lenient = true }) == nil)
  assert(names_values(decoded(text, { lenient = true, utf8 = false })) == "a=\xff%|b=%4")
end

local function test_decode_query_caps_pairs_and_bytes()
  local many: {string} = {}
  for i = 1, 1001 do many[i] = "a=" .. i end
  local q, why = Url.decode_query(table.concat(many, "&"))
  assert(q == nil and why == "url: the query holds more pairs than max_pairs (1000)", why)
  assert(#decoded(table.concat(many, "&", 1, 1000)).pairs == 1000)
  assert(Url.decode_query("a=1&b=2&c=3", { max_pairs = 2 }) == nil)
  local _, bytes_why = Url.decode_query("abcdef", { max_bytes = 5 })
  assert(bytes_why == "url: the query is longer than max_bytes (5)", bytes_why)
  assert(Url.decode_query("abcde", { max_bytes = 5 }) ~= nil)
end

local function test_decode_query_raises_on_a_text_that_is_no_string()
  local ok = pcall(function() Url.decode_query(nil as string) end)
  assert(not ok)
end

local function test_encode_query_writes_plus_for_space_and_round_trips()
  local pairs_: {Url.Pair} = { { name = "a b", value = "c&d=e" }, { name = "", value = "" },
    { name = "q", value = "+%\xff" }, { name = "q", value = "~" } }
  local text = Url.encode_query(pairs_)
  assert(text == "a+b=c%26d%3De&=&q=%2B%25%FF&q=~", text)
  assert(Url.encode_query({}) == "")
  local q = decoded(text, { utf8 = false })
  assert(#q.pairs == #pairs_)
  for i, p in ipairs(pairs_) do
    assert(q.pairs[i].name == p.name and q.pairs[i].value == p.value)
  end
end

local function test_encode_query_raises_on_a_value_that_is_no_string()
  local ok = pcall(function() Url.encode_query({ { name = "a", value = 1 as string } }) end)
  assert(not ok)
end
