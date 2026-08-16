#!/usr/bin/env cosmic
local check = require("cosmic.check")
local url = require("cosmic.url")

-- parse_query tests

local function test_parse_query_basic()
  local result = url.parse_query("key=value")
  assert(#result.key == 1, "expected one value for key")
  assert(result.key[1] == "value", "expected 'value', got '" .. tostring(result.key[1]) .. "'")
end
test_parse_query_basic()

local function test_parse_query_multiple_params()
  local result = url.parse_query("a=1&b=2&c=3")
  assert(result.a[1] == "1", "expected '1' for a")
  assert(result.b[1] == "2", "expected '2' for b")
  assert(result.c[1] == "3", "expected '3' for c")
end
test_parse_query_multiple_params()

local function test_parse_query_repeated_key_keeps_all_values()
  -- Repeated keys must all survive, not collapse to the last value.
  local result = url.parse_query("tag=a&tag=b&tag=c")
  assert(#result.tag == 3, "expected 3 values, got " .. #result.tag)
  assert(result.tag[1] == "a" and result.tag[2] == "b" and result.tag[3] == "c",
    "values must arrive in order")
end
test_parse_query_repeated_key_keeps_all_values()

local function test_parse_query_encoded_values()
  local result = url.parse_query("name=hello%20world")
  assert(result.name[1] == "hello world", "expected 'hello world', got '" .. tostring(result.name[1]) .. "'")
end
test_parse_query_encoded_values()

local function test_parse_query_empty_string()
  local result = url.parse_query("")
  local count = 0
  for _ in pairs(result) do
    count = count + 1
  end
  assert(count == 0, "expected empty table for empty string")
end
test_parse_query_empty_string()

local function test_parse_query_empty_value()
  local result = url.parse_query("key=")
  assert(result.key[1] == "", "expected empty string for 'key='")
end
test_parse_query_empty_value()

local function test_parse_query_flag_key()
  -- A key with no '=' yields one empty-string value, not nil.
  local result = url.parse_query("flag")
  assert(#result.flag == 1 and result.flag[1] == "", "expected {''} for flag key")
end
test_parse_query_flag_key()

local function test_parse_query_plus_as_space()
  local result = url.parse_query("msg=hello+world")
  assert(result.msg[1] == "hello world", "expected 'hello world', got '" .. tostring(result.msg[1]) .. "'")
end
test_parse_query_plus_as_space()

-- parse tests (url.parse is the URL parser; query strings are parse_query)

local function test_parse_full()
  local u = check.must(url.parse("https://user:pass@example.com:8080/path?foo=1&bar=2#frag"))
  assert(u.scheme == "https", "expected 'https', got '" .. tostring(u.scheme) .. "'")
  assert(u.user == "user", "expected 'user', got '" .. tostring(u.user) .. "'")
  assert(u.pass == "pass", "expected 'pass', got '" .. tostring(u.pass) .. "'")
  assert(u.host == "example.com", "expected 'example.com', got '" .. tostring(u.host) .. "'")
  assert(u.port == 8080, "expected 8080, got " .. tostring(u.port))
  assert(u.path == "/path", "expected '/path', got '" .. tostring(u.path) .. "'")
  assert(u.query == "foo=1&bar=2", "expected 'foo=1&bar=2', got '" .. tostring(u.query) .. "'")
  assert(u.fragment == "frag", "expected 'frag', got '" .. tostring(u.fragment) .. "'")
end
test_parse_full()

local function test_parse_is_a_url_parser_not_a_query_parser()
  -- url.parse takes a full URL, not a bare query string: treating the
  -- input as a query yields {["http://example.com/path?a"] = "1"}. It must parse as
  -- a URL now.
  local u = check.must(url.parse("http://example.com/path?a=1"))
  assert(u.scheme == "http", "expected scheme 'http', got '" .. tostring(u.scheme) .. "'")
  assert(u.host == "example.com", "expected host, got '" .. tostring(u.host) .. "'")
  assert(u.path == "/path", "expected path '/path', got '" .. tostring(u.path) .. "'")
  assert(u.query == "a=1", "expected query 'a=1', got '" .. tostring(u.query) .. "'")
end
test_parse_is_a_url_parser_not_a_query_parser()

local function test_parse_minimal()
  local u = check.must(url.parse("http://example.com"))
  assert(u.scheme == "http", "expected 'http', got '" .. tostring(u.scheme) .. "'")
  assert(u.host == "example.com", "expected 'example.com', got '" .. tostring(u.host) .. "'")
  assert(u.port == nil, "expected nil port, got " .. tostring(u.port))
  assert(u.path == "" or u.path == nil, "expected empty path, got '" .. tostring(u.path) .. "'")
  assert(u.query == nil, "expected nil query, got '" .. tostring(u.query) .. "'")
end
test_parse_minimal()

local function test_parse_empty_url()
  local result, err = url.parse("")
  assert(result == nil, "expected nil for empty URL")
  assert(err == "empty URL", "expected 'empty URL', got '" .. tostring(err) .. "'")
end
test_parse_empty_url()

local function test_parse_invalid_port()
  local result, err = url.parse("http://example.com:99999/")
  assert(result == nil, "port 99999 must be rejected, got port " ..
    tostring(result ~= nil and result.port))
  assert(err ~= nil and err:find("invalid port") ~= nil,
    "expected invalid-port error, got '" .. tostring(err) .. "'")
end
test_parse_invalid_port()

local function test_parse_with_path_only()
  local result = check.must(url.parse("http://example.com/api/v1/users"))
  assert(result.scheme == "http", "expected 'http'")
  assert(result.host == "example.com", "expected 'example.com'")
  assert(result.path == "/api/v1/users", "expected '/api/v1/users', got '" .. tostring(result.path) .. "'")
end
test_parse_with_path_only()

local function test_parse_with_query_only()
  local result = check.must(url.parse("http://example.com?search=test"))
  assert(result.query == "search=test", "expected 'search=test', got '" .. tostring(result.query) .. "'")
end
test_parse_with_query_only()

local function test_parse_with_fragment_only()
  local result = check.must(url.parse("http://example.com#section"))
  assert(result.fragment == "section", "expected 'section', got '" .. tostring(result.fragment) .. "'")
end
test_parse_with_fragment_only()

-- format tests

local function test_format_roundtrip_basic()
  local u = check.must(url.parse("https://example.com:8080/path?foo=1&bar=2#frag"))
  local formatted = url.format(u)
  local reparsed = check.must(url.parse(formatted))
  assert(reparsed.scheme == "https" and reparsed.host == "example.com"
    and reparsed.port == 8080 and reparsed.path == "/path"
    and reparsed.fragment == "frag",
    "roundtrip must preserve components, got: " .. formatted)
  local params = url.parse_query(reparsed.query)
  assert(params.foo[1] == "1" and params.bar[1] == "2",
    "roundtrip must preserve query params, got: " .. formatted)
end
test_format_roundtrip_basic()

local function test_format_preserves_encoded_delimiters()
  -- ?a=x%26y is ONE param whose value contains '&'; format must keep it
  -- one param instead of decoding %26 into a delimiter.
  local u = check.must(url.parse("http://x.com/?a=x%26y"))
  local formatted = url.format(u)
  local reparsed = check.must(url.parse(formatted))
  local params = url.parse_query(reparsed.query)
  assert(params.a ~= nil and params.a[1] == "x&y",
    "param 'a' must survive as 'x&y', got: " .. formatted)
end
test_format_preserves_encoded_delimiters()

local function test_format_minimal()
  local formatted = url.format({scheme = "http", host = "example.com", path = "/x"})
  local u = check.must(url.parse(formatted))
  assert(u.scheme == "http" and u.host == "example.com" and u.path == "/x",
    "format of a hand-built Url must parse back, got: " .. formatted)
end
test_format_minimal()

-- format: a path with no authority may not emit a leading "//" — that
-- would re-read as a protocol-relative reference and steer the first
-- path segment into becoming the host on reparse.

local function test_format_no_authority_escapes_double_slash_host_spoof()
  local u = check.must(url.parse("/%2Fevil.example.com/x"))
  assert(u.host == nil, "expected no host, got '" .. tostring(u.host) .. "'")
  local formatted = url.format(u)
  assert(formatted == "/%2Fevil.example.com/x", "expected '/%2Fevil.example.com/x', got '" .. formatted .. "'")
  local reparsed = check.must(url.parse(formatted))
  assert(reparsed.host == nil, "reparse must not spoof a host, got '" .. tostring(reparsed.host) .. "'")
end
test_format_no_authority_escapes_double_slash_host_spoof()

local function test_format_no_authority_escapes_bare_double_slash()
  local u = check.must(url.parse("/%2F"))
  local formatted = url.format(u)
  assert(formatted == "/%2F", "expected '/%2F', got '" .. formatted .. "'")
end
test_format_no_authority_escapes_bare_double_slash()

local function test_format_no_authority_escapes_double_slash_before_colon()
  -- Without the fix, this round trip mis-parses "//:fkiw" as an
  -- authority with an invalid port and REFUSES on reparse.
  local u = check.must(url.parse("/%2F:fkiw"))
  local formatted = url.format(u)
  assert(formatted == "/%2F:fkiw", "expected '/%2F:fkiw', got '" .. formatted .. "'")
  check.must(url.parse(formatted))
end
test_format_no_authority_escapes_double_slash_before_colon()

local function test_format_no_authority_double_slash_is_a_fixpoint()
  for _, s in ipairs({"/%2Fevil.example.com/x", "/%2F", "/%2F:fkiw"}) do
    local once = url.format(check.must(url.parse(s)))
    local twice = url.format(check.must(url.parse(once)))
    assert(once == twice, "not a fixpoint for '" .. s .. "': '" .. once .. "' vs '" .. twice .. "'")
  end
end
test_format_no_authority_double_slash_is_a_fixpoint()

local function test_format_with_authority_double_slash_path_unchanged()
  -- With a real authority in front, the same escaped slash is harmless
  -- and must NOT be rewritten.
  local u = check.must(url.parse("http://h/%2Fa"))
  local formatted = url.format(u)
  assert(formatted == "http://h//a", "expected 'http://h//a', got '" .. formatted .. "'")
  local reparsed = check.must(url.parse(formatted))
  assert(reparsed.host == "h", "expected host 'h', got '" .. tostring(reparsed.host) .. "'")
  assert(reparsed.path == "//a", "expected path '//a', got '" .. tostring(reparsed.path) .. "'")
end
test_format_with_authority_double_slash_path_unchanged()

-- parse_host tests

local function test_parse_host_with_port()
  local hp = check.must(url.parse_host("example.com:8080"))
  assert(hp.host == "example.com", "expected 'example.com', got '" .. tostring(hp.host) .. "'")
  assert(hp.port == 8080, "expected 8080, got " .. tostring(hp.port))
end
test_parse_host_with_port()

local function test_parse_host_without_port()
  local hp = check.must(url.parse_host("example.com"))
  assert(hp.host == "example.com", "expected 'example.com', got '" .. tostring(hp.host) .. "'")
  assert(hp.port == nil, "expected nil port, got " .. tostring(hp.port))
end
test_parse_host_without_port()

local function test_parse_host_ipv4()
  local hp = check.must(url.parse_host("192.168.1.1:80"))
  assert(hp.host == "192.168.1.1", "expected '192.168.1.1', got '" .. tostring(hp.host) .. "'")
  assert(hp.port == 80, "expected 80, got " .. tostring(hp.port))
end
test_parse_host_ipv4()

local function test_parse_host_ipv6_with_port()
  local hp = check.must(url.parse_host("[::1]:8080"))
  assert(hp.host == "::1", "expected '::1', got '" .. tostring(hp.host) .. "'")
  assert(hp.port == 8080, "expected 8080, got " .. tostring(hp.port))
end
test_parse_host_ipv6_with_port()

local function test_parse_host_ipv6_without_port()
  local hp = check.must(url.parse_host("[::1]"))
  assert(hp.host == "::1", "expected '::1', got '" .. tostring(hp.host) .. "'")
  assert(hp.port == nil, "expected nil port, got " .. tostring(hp.port))
end
test_parse_host_ipv6_without_port()

local function test_parse_host_unbracketed_ipv6_rejected()
  -- A bare IPv6 address is all host: no port to split off.
  local hp, err = url.parse_host("::1")
  assert(hp == nil, "unbracketed IPv6 must be rejected")
  assert(err ~= nil and err:find("bracket") ~= nil,
    "error should say brackets are required, got '" .. tostring(err) .. "'")
end
test_parse_host_unbracketed_ipv6_rejected()

local function test_parse_host_port_out_of_range()
  -- Ports above 65535 are not ports.
  local hp, err = url.parse_host("example.com:99999")
  assert(hp == nil, "port 99999 must be rejected")
  assert(err ~= nil and err:find("invalid port") ~= nil,
    "expected invalid-port error, got '" .. tostring(err) .. "'")
end
test_parse_host_port_out_of_range()

local function test_parse_host_port_zero_rejected()
  local hp, err = url.parse_host("example.com:0")
  assert(hp == nil, "port 0 must be rejected")
  assert(err ~= nil, "expected error for port 0")
end
test_parse_host_port_zero_rejected()

local function test_parse_host_trailing_colon_rejected()
  local hp, err = url.parse_host("example.com:")
  assert(hp == nil, "trailing colon without digits must be rejected")
  assert(err ~= nil, "expected error message")
end
test_parse_host_trailing_colon_rejected()

local function test_parse_host_empty()
  local hp, err = url.parse_host("")
  assert(hp == nil, "expected nil result for empty string")
  assert(err ~= nil, "expected error for empty string")
end
test_parse_host_empty()

local function test_parse_host_empty_host_rejected()
  local hp, err = url.parse_host(":8080")
  assert(hp == nil, "empty host must be rejected")
  assert(err ~= nil, "expected error message")
end
test_parse_host_empty_host_rejected()

-- parse must preserve percent-encoding in the query field: ?a=x%26y has
-- ONE param (key=a, value=x&y); the reconstructed query must not turn %26
-- into a literal & (which would look like two params).

local function test_parse_query_field_preserves_encoding()
  local result = check.must(url.parse("http://x.com/?a=x%26y"))
  assert(result.query ~= nil, "query should not be nil")
  assert(result.query ~= "a=x&y",
    "query must not decode %26 to &, got: " .. tostring(result.query))
  local params = url.parse_query(result.query)
  assert(params.a[1] == "x&y",
    "parsed param 'a' must equal 'x&y', got: " .. tostring(params.a and params.a[1]))
end
test_parse_query_field_preserves_encoding()

local function test_parse_query_field_flag_param()
  -- ?flag has a key with no value; reconstructing must not emit a bare "=".
  local result = check.must(url.parse("http://x.com/?flag"))
  assert(result.query ~= nil, "query should not be nil for flag param")
  assert(result.query:match("flag"), "query should contain 'flag'")
  assert(not result.query:match("flag=$"), "query must not end with 'flag='")
end
test_parse_query_field_flag_param()

-- format_host: the inverse parse_host was missing — reassembling
-- host:port requires the IPv6 bracketing rule only parse_host knew.
local function test_format_host_roundtrip()
  local hp = check.must(url.parse_host("example.com:8080"))
  assert(url.format_host(hp) == "example.com:8080")
  local v6 = check.must(url.parse_host("[::1]:443"))
  assert(url.format_host(v6) == "[::1]:443", "IPv6 hosts re-bracket")
  local bare = check.must(url.parse_host("example.com"))
  assert(url.format_host(bare) == "example.com", "nil port yields bare host")
end
test_format_host_roundtrip()

-- format_query accepts plain-string values beside lists, so a parsed
-- query and fetch's one-value map both feed it without wrapping.
local function test_format_query_string_values()
  assert(url.format_query({b = "2", a = "1"}) == "a=1&b=2")
  assert(url.format_query({k = {"1", "2"}, s = "x"}) == "k=1&k=2&s=x")
end
test_format_query_string_values()
