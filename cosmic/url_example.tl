--- Worked examples for [`cosmic.url`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Url = require("cosmic.url")

local Example = {}

--- A file name or a search term goes into a URL escaped, one piece at a
--- time: the space, `&` and `/` it holds stay data rather than ending
--- the segment or the query value.
function Example.escape()
  local name = "Q3 report/final.pdf"
  local url = "https://example.com/files/" .. Url.escape(name) .. "?q=" .. Url.escape("a&b c")
  print(url) -- https://example.com/files/Q3%20report%2Ffinal.pdf?q=a%26b%20c
  assert(url == "https://example.com/files/Q3%20report%2Ffinal.pdf?q=a%26b%20c", url)
end

--- An escape reads back in either case; a `%` without two hex digits is
--- a failure the caller handles, naming its byte.
function Example.unescape()
  assert(Url.unescape("caf%C3%a9") == "caf\xc3\xa9")
  local text, why = Url.unescape("100%")
  print(why) -- url: '%' at byte 4 is not followed by two hex digits
  assert(text == nil and why == "url: '%' at byte 4 is not followed by two hex digits", why)
end

--- A server maps a request's path to a file under its root by the
--- segments: empty ones and `.` drop out, and one that would climb out
--- of the root, escaped or not, is refused.
function Example.segments()
  local segs = assert(Url.segments("/docs//a%20b/./index.html"))
  assert(table.concat(segs, "|") == "docs|a b|index.html")
  print("/srv/www/" .. table.concat(segs, "/")) -- /srv/www/docs/a b/index.html
  local none, why = Url.segments("/docs/%2e%2E/etc/passwd")
  assert(none == nil, "a climb was let through")
  print(why) -- url: the segment at byte 7 is '..', which climbs out of the path
end

--- An absolute URL's parts: the scheme and host lowercased, an IPv6
--- host out of its brackets, the rest as written.
function Example.parse()
  local parts = assert(Url.parse("HTTPS://user@[::1]:8443/a%2Fb?x=1#top"))
  assert(parts.scheme == "https" and parts.userinfo == "user" and parts.host == "::1")
  assert(parts.port == 8443 and parts.path == "/a%2Fb" and parts.query == "x=1" and parts.fragment == "top")
  local bad, why = Url.parse("https://example.com/a file")
  assert(bad == nil)
  print(why) -- url: the URL holds a space at byte 22; escape a path segment or query value with Url.escape
end

return Example
