#!/usr/bin/env cosmic
local url = require("cosmic.url")

local function test_encode_spaces()
  local result = url.encode("hello world")
  assert(result == "hello%20world", "expected 'hello%20world', got '" .. result .. "'")
end
test_encode_spaces()

local function test_encode_special_chars()
  local result = url.encode("a,b&c=d")
  assert(result:match("%%2C"), "expected comma to be encoded")
  assert(result:match("%%26"), "expected ampersand to be encoded")
  assert(result:match("%%3D"), "expected equals to be encoded")
end
test_encode_special_chars()

local function test_encode_unreserved_chars()
  -- Most unreserved characters should not be encoded: A-Z a-z 0-9 - _ .
  -- Note: cosmo.EscapeParam encodes ~ as %7E (conservative but valid)
  local result = url.encode("ABC-xyz_123.test")
  assert(result == "ABC-xyz_123.test", "unreserved chars should pass through, got '" .. result .. "'")
end
test_encode_unreserved_chars()

local function test_decode_percent_sequences()
  local result = url.decode("hello%20world")
  assert(result == "hello world", "expected 'hello world', got '" .. tostring(result) .. "'")
end
test_decode_percent_sequences()

local function test_decode_plus_as_space()
  local result = url.decode("hello+world")
  assert(result == "hello world", "expected 'hello world', got '" .. tostring(result) .. "'")
end
test_decode_plus_as_space()

local function test_decode_mixed()
  local result = url.decode("a%2Cb%26c%3Dd")
  assert(result == "a,b&c=d", "expected 'a,b&c=d', got '" .. tostring(result) .. "'")
end
test_decode_mixed()

local function test_roundtrip_basic()
  local original = "hello world"
  local encoded = url.encode(original)
  local decoded = url.decode(encoded)
  assert(decoded == original, "roundtrip failed: expected '" .. original .. "', got '" .. tostring(decoded) .. "'")
end
test_roundtrip_basic()

local function test_roundtrip_special()
  local original = "name=value&foo=bar"
  local encoded = url.encode(original)
  local decoded = url.decode(encoded)
  assert(decoded == original, "roundtrip failed: expected '" .. original .. "', got '" .. tostring(decoded) .. "'")
end
test_roundtrip_special()

local function test_roundtrip_unicode()
  local original = "日本語テスト"
  local encoded = url.encode(original)
  local decoded = url.decode(encoded)
  assert(decoded == original, "unicode roundtrip failed")
end
test_roundtrip_unicode()

local function test_decode_invalid_trailing_percent()
  local result, err = url.decode("test%")
  assert(result == nil, "expected nil for trailing %")
  assert(err ~= nil, "expected error message")
  assert(err == "invalid percent-encoding", "expected 'invalid percent-encoding', got '" .. err .. "'")
end
test_decode_invalid_trailing_percent()

local function test_decode_invalid_single_hex()
  local result, err = url.decode("test%A")
  assert(result == nil, "expected nil for single hex digit")
  assert(err ~= nil, "expected error message")
end
test_decode_invalid_single_hex()

local function test_decode_invalid_non_hex()
  local result, err = url.decode("test%ZZ")
  assert(result == nil, "expected nil for non-hex digits")
  assert(err ~= nil, "expected error message")
end
test_decode_invalid_non_hex()

local function test_decode_empty_string()
  local result = url.decode("")
  assert(result == "", "expected empty string")
end
test_decode_empty_string()

local function test_encode_empty_string()
  local result = url.encode("")
  assert(result == "", "expected empty string")
end
test_encode_empty_string()

local function test_decode_lowercase_hex()
  local result = url.decode("%2f%3a")
  assert(result == "/:", "expected '/:' for lowercase hex, got '" .. tostring(result) .. "'")
end
test_decode_lowercase_hex()

local function test_decode_uppercase_hex()
  local result = url.decode("%2F%3A")
  assert(result == "/:", "expected '/:' for uppercase hex, got '" .. tostring(result) .. "'")
end
test_decode_uppercase_hex()

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
  -- The old parse() silently dropped every value but the last.
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
  local result = url.parse("https://user:pass@example.com:8080/path?foo=1&bar=2#frag")
  assert(result ~= nil, "parse should succeed")
  local u = result as url.Url
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
  -- The old url.parse treated its input as a query string, so a full URL
  -- came back as {["http://example.com/path?a"] = "1"}. It must parse as
  -- a URL now.
  local result = url.parse("http://example.com/path?a=1")
  assert(result ~= nil, "parse should succeed")
  local u = result as url.Url
  assert(u.scheme == "http", "expected scheme 'http', got '" .. tostring(u.scheme) .. "'")
  assert(u.host == "example.com", "expected host, got '" .. tostring(u.host) .. "'")
  assert(u.path == "/path", "expected path '/path', got '" .. tostring(u.path) .. "'")
  assert(u.query == "a=1", "expected query 'a=1', got '" .. tostring(u.query) .. "'")
end
test_parse_is_a_url_parser_not_a_query_parser()

local function test_parse_minimal()
  local result = url.parse("http://example.com")
  assert(result ~= nil, "parse should succeed")
  local u = result as url.Url
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
    tostring(result and (result as url.Url).port))
  assert(err ~= nil and err:find("invalid port") ~= nil,
    "expected invalid-port error, got '" .. tostring(err) .. "'")
end
test_parse_invalid_port()

local function test_parse_with_path_only()
  local result = url.parse("http://example.com/api/v1/users") as url.Url
  assert(result.scheme == "http", "expected 'http'")
  assert(result.host == "example.com", "expected 'example.com'")
  assert(result.path == "/api/v1/users", "expected '/api/v1/users', got '" .. tostring(result.path) .. "'")
end
test_parse_with_path_only()

local function test_parse_with_query_only()
  local result = url.parse("http://example.com?search=test") as url.Url
  assert(result.query == "search=test", "expected 'search=test', got '" .. tostring(result.query) .. "'")
end
test_parse_with_query_only()

local function test_parse_with_fragment_only()
  local result = url.parse("http://example.com#section") as url.Url
  assert(result.fragment == "section", "expected 'section', got '" .. tostring(result.fragment) .. "'")
end
test_parse_with_fragment_only()

-- format tests

local function test_format_roundtrip_basic()
  local u = url.parse("https://example.com:8080/path?foo=1&bar=2#frag") as url.Url
  local formatted = url.format(u)
  local reparsed = url.parse(formatted) as url.Url
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
  local u = url.parse("http://x.com/?a=x%26y") as url.Url
  local formatted = url.format(u)
  local reparsed = url.parse(formatted) as url.Url
  local params = url.parse_query(reparsed.query)
  assert(params.a ~= nil and params.a[1] == "x&y",
    "param 'a' must survive as 'x&y', got: " .. formatted)
end
test_format_preserves_encoded_delimiters()

local function test_format_minimal()
  local formatted = url.format({scheme = "http", host = "example.com", path = "/x"})
  local u = url.parse(formatted) as url.Url
  assert(u.scheme == "http" and u.host == "example.com" and u.path == "/x",
    "format of a hand-built Url must parse back, got: " .. formatted)
end
test_format_minimal()

-- parse_host tests

local function test_parse_host_with_port()
  local host, port = url.parse_host("example.com:8080")
  assert(host == "example.com", "expected 'example.com', got '" .. tostring(host) .. "'")
  assert(port == 8080, "expected 8080, got " .. tostring(port))
end
test_parse_host_with_port()

local function test_parse_host_without_port()
  local host, port = url.parse_host("example.com")
  assert(host == "example.com", "expected 'example.com', got '" .. tostring(host) .. "'")
  assert(port == nil, "expected nil port, got " .. tostring(port))
end
test_parse_host_without_port()

local function test_parse_host_ipv4()
  local host, port = url.parse_host("192.168.1.1:80")
  assert(host == "192.168.1.1", "expected '192.168.1.1', got '" .. tostring(host) .. "'")
  assert(port == 80, "expected 80, got " .. tostring(port))
end
test_parse_host_ipv4()

local function test_parse_host_ipv6_with_port()
  local host, port = url.parse_host("[::1]:8080")
  assert(host == "::1", "expected '::1', got '" .. tostring(host) .. "'")
  assert(port == 8080, "expected 8080, got " .. tostring(port))
end
test_parse_host_ipv6_with_port()

local function test_parse_host_ipv6_without_port()
  local host, port = url.parse_host("[::1]")
  assert(host == "::1", "expected '::1', got '" .. tostring(host) .. "'")
  assert(port == nil, "expected nil port, got " .. tostring(port))
end
test_parse_host_ipv6_without_port()

local function test_parse_host_unbracketed_ipv6_rejected()
  -- The old parser returned host ":" port 1 for "::1".
  local host, _, err = url.parse_host("::1")
  assert(host == nil, "unbracketed IPv6 must be rejected, got '" .. tostring(host) .. "'")
  assert(err ~= nil and err:find("bracket") ~= nil,
    "error should say brackets are required, got '" .. tostring(err) .. "'")
end
test_parse_host_unbracketed_ipv6_rejected()

local function test_parse_host_port_out_of_range()
  -- The old parser accepted port 99999.
  local host, _, err = url.parse_host("example.com:99999")
  assert(host == nil, "port 99999 must be rejected")
  assert(err ~= nil and err:find("invalid port") ~= nil,
    "expected invalid-port error, got '" .. tostring(err) .. "'")
end
test_parse_host_port_out_of_range()

local function test_parse_host_port_zero_rejected()
  local host, _, err = url.parse_host("example.com:0")
  assert(host == nil, "port 0 must be rejected")
  assert(err ~= nil, "expected error for port 0")
end
test_parse_host_port_zero_rejected()

local function test_parse_host_trailing_colon_rejected()
  local host, _, err = url.parse_host("example.com:")
  assert(host == nil, "trailing colon without digits must be rejected")
  assert(err ~= nil, "expected error message")
end
test_parse_host_trailing_colon_rejected()

local function test_parse_host_empty()
  local host, port, err = url.parse_host("")
  assert(host == nil, "expected nil host for empty string")
  assert(port == nil, "expected nil port for empty string")
  assert(err ~= nil, "expected error for empty string")
end
test_parse_host_empty()

local function test_parse_host_empty_host_rejected()
  local host, _, err = url.parse_host(":8080")
  assert(host == nil, "empty host must be rejected")
  assert(err ~= nil, "expected error message")
end
test_parse_host_empty_host_rejected()

-- escape tests

local function test_escape_host_basic()
  local result = url.escape_host("example.com")
  assert(result == "example.com", "expected 'example.com', got '" .. result .. "'")
end
test_escape_host_basic()

local function test_escape_path_basic()
  local result = url.escape_path("/api/users")
  assert(result == "/api/users", "expected '/api/users', got '" .. result .. "'")
end
test_escape_path_basic()

local function test_escape_path_with_spaces()
  local result = url.escape_path("/my files/doc")
  assert(result:match("%%20") or result:match("%+"), "expected space to be encoded")
end
test_escape_path_with_spaces()

local function test_escape_path_preserves_slashes()
  local result = url.escape_path("/a/b/c")
  assert(result == "/a/b/c", "expected slashes to be preserved, got '" .. result .. "'")
end
test_escape_path_preserves_slashes()

local function test_escape_segment_escapes_slash()
  local result = url.escape_segment("foo/bar")
  assert(result:match("%%2F") or result:match("%%2f"), "expected / to be encoded, got '" .. result .. "'")
end
test_escape_segment_escapes_slash()

local function test_escape_fragment_with_spaces()
  local result = url.escape_fragment("section 1")
  assert(result:match("%%20") or result:match("%+"), "expected space to be encoded")
end
test_escape_fragment_with_spaces()

local function test_escape_literal_basic()
  local result = url.escape_literal("test")
  assert(result == "test", "expected 'test', got '" .. result .. "'")
end
test_escape_literal_basic()

local function test_escape_user_with_special_chars()
  local result = url.escape_user("user@domain")
  assert(result:match("%%40") or result:match("%%2540"), "expected @ to be encoded")
end
test_escape_user_with_special_chars()

local function test_escape_pass_with_special_chars()
  local result = url.escape_pass("p@ss:word")
  assert(result:match("%%"), "expected special chars to be encoded")
end
test_escape_pass_with_special_chars()

local function test_escape_ip_ipv4()
  local result = url.escape_ip("192.168.1.1")
  assert(result == "192.168.1.1", "expected '192.168.1.1', got '" .. result .. "'")
end
test_escape_ip_ipv4()

local function test_escape_ip_ipv6()
  local result = url.escape_ip("::1")
  assert(result:match("::1") or result:match("%%3A"), "expected ipv6 to be handled, got '" .. result .. "'")
end
test_escape_ip_ipv6()

-- parse must preserve percent-encoding in the query field: ?a=x%26y has
-- ONE param (key=a, value=x&y); the reconstructed query must not turn %26
-- into a literal & (which would look like two params).

local function test_parse_query_field_preserves_encoding()
  local result = url.parse("http://x.com/?a=x%26y") as url.Url
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
  local result = url.parse("http://x.com/?flag") as url.Url
  assert(result.query ~= nil, "query should not be nil for flag param")
  assert(result.query:match("flag"), "query should contain 'flag'")
  assert(not result.query:match("flag=$"), "query must not end with 'flag='")
end
test_parse_query_field_flag_param()
