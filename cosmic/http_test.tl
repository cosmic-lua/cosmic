--- Coverage for cosmic.http without the network: option and URL
--- validation, a connection refused on a closed local port, and every
--- response-handling case through the scripted transport
--- ([`Http.Options.script`]), where each connection curl opens reads a canned
--- reply and records what curl sent.

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Signal = require("cosmic.signal")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Url = require("cosmic.url")

--- The next chunk of `reader`: raises where it ended or failed.
local function chunk_of(reader: Stream.Reader, max_bytes?: integer): string
  local chunk, why = reader:read(max_bytes)
  if chunk == nil then error(tostring(why), 2) end
  if chunk == false then error("the stream ended", 2) end
  return chunk
end

--- Requests to a closed local port, which a loopback alone answers:
--- the worker runs offline, and is keyed. The tests that start the
--- program, or read the roots its own database carries, are
--- cosmic/http_tool_test.tl's.
Test.policy{ loopback = { "127.0.0.1" } }

local url = "http://cosmic.test/"

--- A whole reply: a status line, `head`'s header lines, and `body`,
--- closing the connection after it.
local function reply(status: string, head: string, body?: string): string
  body = body or ""
  return "HTTP/1.1 " .. status .. "\r\n" .. head ..
    "Content-Length: " .. tostring(#body) .. "\r\nConnection: close\r\n\r\n" .. body
end

--- Opens `url` over `script`, reads the whole body, and returns the
--- response (closed), its body, and what curl sent.
local function fetch(script: {string}, opts?: Http.Options): Http.Response, string, string
  local given: Http.Options = opts or { timeout_ns = Clock.seconds(60) }
  local response = assert(Http.open(url, { ...given, script = script }))
  local parts: mut {string} = {}
  while true do
    local chunk, trouble = response:read()
    assert(chunk ~= nil, tostring(trouble))
    if chunk == false then
      break
    end
    parts[#parts + 1] = chunk
  end
  local sent = response:sent()
  local _, _ = response:close()
  return response, table.concat(parts), sent
end

local function count(haystack: string, needle: string): integer
  local n, at = 0, 1
  while true do
    local found = haystack:find(needle, at, true)
    if found == nil then return n end
    n, at = n + 1, found + 1
  end
end

--- A limit of 0, which curl reads as none, is refused, naming the field.
local function test_a_request_with_a_time_limit_of_0_raises()
  local ok, why = pcall(function()
    local _, _ = Http.request("GET", url, { timeout_ns = 0, script = {} })
  end)
  assert(not ok and tostring(why):find("timeout_ns is required", 1, true) ~= nil, tostring(why))
end

--- [`Http.FOREVER`] sets no limit on the whole request.
local function test_forever_is_a_request_with_no_limit()
  local response, body = fetch({ reply("200 OK", "", "hello") }, { timeout_ns = Http.FOREVER })
  assert(response.status == 200 and body == "hello")
end

local function test_a_plain_200_is_read_whole()
  local response, body, sent = fetch({ reply("200 OK", "X-One: 1\r\n", "hello") })
  assert(response.status == 200)
  assert(body == "hello")
  assert(response.headers["x-one"] == "1")
  assert(response.url == url)
  assert(sent:find("GET / HTTP/1.1\r\n", 1, true) == 1, sent)
  assert(sent:find("\r\nHost: cosmic.test\r\n", 1, true) ~= nil, sent)
end

local function test_every_3xx_with_a_location_is_followed_including_300()
  local response, body = fetch({
    reply("300 Multiple Choices", "Location: /next\r\nX-Hop: first\r\n", "skip"),
    reply("200 OK", "", "final"),
  })
  assert(response.status == 200, tostring(response.status))
  assert(body == "final", body)
  assert(response.headers["x-hop"] == nil, "a followed hop's headers do not leak")
  assert(response.url == url .. "next", response.url)
end

local function test_a_redirect_is_not_followed_when_follow_is_false()
  local response, body = fetch({ reply("302 Found", "Location: /next\r\n", "moved") },
    { timeout_ns = Clock.seconds(60), follow = false })
  assert(response.status == 302)
  assert(body == "moved")
  assert(response.headers["location"] == "/next")
end

local function test_a_redirect_to_a_scheme_outside_redirect_protocols_is_refused()
  local response, why = Http.open(url, { timeout_ns = Clock.seconds(60), redirect_protocols = { "https" },
    script = { reply("302 Found", "Location: http://other.test/next\r\n"), reply("200 OK", "", "no") } })
  assert(response == nil, "the redirect to http was followed")
  assert(tostring(why):find("disabled (in redirect)", 1, true) ~= nil, why)
end

local function test_a_redirect_to_a_listed_scheme_is_followed()
  local lists: {{string}} = { { "http" }, { "http", "https" } }
  for _, protocols in ipairs(lists) do
    local response, body = fetch({ reply("302 Found", "Location: http://other.test/next\r\n"), reply("200 OK", "", "yes") },
      { timeout_ns = Clock.seconds(60), redirect_protocols = protocols })
    assert(response.status == 200 and body == "yes", body)
  end
end

local function test_a_redirect_to_https_is_attempted_when_only_https_is_listed()
  -- a canned reply cannot finish a TLS handshake, so the hop fails there:
  -- what matters is that it is a TLS failure, not a refused scheme
  local response, why = Http.open(url, { timeout_ns = Clock.seconds(60), redirect_protocols = { "https" },
    script = { reply("302 Found", "Location: https://other.test/next\r\n"), reply("200 OK", "", "no") } })
  assert(response == nil)
  assert(tostring(why):find("not supported or disabled", 1, true) == nil, why)
  assert(tostring(why):find("Protocol", 1, true) == nil, why)
end

local function test_a_303_after_post_is_followed_with_get()
  local response, body, sent = fetch({
    reply("303 See Other", "Location: /done\r\n"),
    reply("200 OK", "", "got"),
  }, { timeout_ns = Clock.seconds(60), method = "POST", body = "payload" })
  assert(response.status == 200 and body == "got")
  assert(sent:find("POST / HTTP/1.1\r\n", 1, true) == 1, sent)
  assert(sent:find("GET /done HTTP/1.1\r\n", 1, true) ~= nil, sent)
  assert(count(sent, "payload") == 1, sent)
end

local function test_a_307_after_post_repeats_the_post_and_its_body()
  local response, _, sent = fetch({
    reply("307 Temporary Redirect", "Location: /again\r\n"),
    reply("200 OK", "", "ok"),
  }, { timeout_ns = Clock.seconds(60), method = "POST", body = "payload" })
  assert(response.status == 200)
  assert(sent:find("POST /again HTTP/1.1\r\n", 1, true) ~= nil, sent)
  assert(count(sent, "payload") == 2, sent)
end

--- A 301 or 302 after a method with a body other than POST repeats it,
--- body and all: only a POST's becomes a GET. A 303 still does.
local function test_a_301_or_302_after_put_repeats_the_put_and_its_body()
  for _, status in ipairs({ "301 Moved Permanently", "302 Found" }) do
    local response, _, sent = fetch({
      reply(status, "Location: /again\r\n"),
      reply("200 OK", "", "ok"),
    }, { timeout_ns = Clock.seconds(60), method = "PUT", body = "payload" })
    assert(response.status == 200)
    assert(sent:find("PUT /again HTTP/1.1\r\n", 1, true) ~= nil, sent)
    assert(count(sent, "payload") == 2, sent)
  end
  local _, _, sent = fetch({
    reply("303 See Other", "Location: /done\r\n"),
    reply("200 OK", "", "got"),
  }, { timeout_ns = Clock.seconds(60), method = "PUT", body = "payload" })
  assert(sent:find("GET /done HTTP/1.1\r\n", 1, true) ~= nil, sent)
  assert(count(sent, "payload") == 1, sent)
end

local function test_a_custom_method_is_sent_as_is()
  local _, _, sent = fetch({ reply("204 No Content", "") }, { timeout_ns = Clock.seconds(60), method = "PUT", body = "x" })
  assert(sent:find("PUT / HTTP/1.1\r\n", 1, true) == 1, sent)
end

local function test_a_method_that_is_no_token_is_refused()
  local response, trouble = Http.open(url, { timeout_ns = Clock.seconds(60), method = "GET / HTTP/1.1\r\nX-Evil: 1\r\n", script = {} })
  assert(response == nil)
  assert(tostring(trouble):find("method", 1, true) ~= nil, trouble)
end

local function test_informational_responses_before_the_final_one_are_skipped()
  local response, body = fetch({
    "HTTP/1.1 100 Continue\r\n\r\n" ..
      "HTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\n" ..
      reply("200 OK", "X-Final: yes\r\n", "ok"),
  })
  assert(response.status == 200, tostring(response.status))
  assert(body == "ok", body)
  assert(response.headers["link"] == nil)
  assert(response.headers["x-final"] == "yes")
end

local function test_head_reads_the_headers_and_no_body()
  local response, body, sent = fetch({
    "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n",
  }, { timeout_ns = Clock.seconds(60), method = "HEAD" })
  assert(response.status == 200)
  assert(response.headers["content-length"] == "1000")
  assert(body == "")
  assert(sent:find("HEAD / HTTP/1.1\r\n", 1, true) == 1, sent)
end

local function test_a_chunked_body_is_decoded()
  local _, body = fetch({
    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ..
      "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
  })
  assert(body == "hello world", body)
end

local function test_a_body_shorter_than_its_content_length_is_a_read_error()
  local response = assert(Http.open(url, { timeout_ns = Clock.seconds(60), script = {
    "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nonly ten b",
  } }))
  local chunk, _ = response:read()
  assert(chunk == "only ten b")
  local after, _ = response:read()
  assert(after == nil, "a truncated body is an error, not a clean end")
  local _, _ = response:close()
  local got, get_trouble = Http.get(url, { timeout_ns = Clock.seconds(60), script = {
    "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nonly ten b",
  } })
  assert(got == nil and tostring(get_trouble) ~= "")
end

local function test_open_returns_once_the_headers_arrive_before_any_body()
  -- The headers come, the body never does. An `open` that waited for
  -- the first body byte would fail here (and, on a live server that
  -- stalls after its headers, trip the low-speed limit) though the
  -- response's headers had arrived.
  local response, trouble = Http.open(url, { timeout_ns = Clock.seconds(60), script = {
    "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nX-Here: yes\r\n\r\n",
  } })
  assert(response ~= nil, trouble)
  assert(response.status == 200 and response.headers["x-here"] == "yes")
  local chunk, read_trouble = response:read()
  assert(chunk == nil, "a missing body is a read error")
  -- curl's message, with no newline left on the end of it
  assert(tostring(read_trouble):find("%s$") == nil, "[" .. tostring(read_trouble) .. "]")
  local _, _ = response:close()
end

local function test_open_waits_past_a_followed_redirect_for_the_final_headers()
  local response = assert(Http.open(url, { timeout_ns = Clock.seconds(60), script = {
    "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n",
  } }))
  assert(response.status == 200, tostring(response.status))
  assert(response.url:find("/next", 1, true) ~= nil, response.url)
  local _, _ = response:close()
end

--- The request line curl wrote for `target`, a URL's text past
--- "http://cosmic.test", answered over a script.
local function request_line(target: string): string
  local response = assert(Http.open("http://cosmic.test" .. target, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "ok") } }))
  local sent = response:sent()
  local _, _ = response:close()
  return (assert(sent:match("^GET (.-) HTTP/1%.1\r\n"), sent))
end

local function test_a_url_with_a_space_control_or_non_ascii_byte_is_sent_escaped()
  assert(request_line("/two words.txt") == "/two%20words.txt")
  assert(request_line("/caf\xc3\xa9.txt") == "/caf%C3%A9.txt")
  assert(request_line("/a\tb?q=x\ny\127") == "/a%09b?q=x%0Ay%7F")
  assert(request_line('/"<>\\^`{|}') == "/%22%3C%3E%5C%5E%60%7B%7C%7D")
  local got = assert(Http.get(url .. "a b", { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "ok") } }))
  assert(got.status == 200 and got.body == "ok")
  got = assert(Http.request("PUT", url .. "a b", { timeout_ns = Clock.seconds(60), body = "x", script = { reply("200 OK", "", "ok") } }))
  assert(got.status == 200)
end

local function test_a_url_with_a_nul_byte_in_its_path_is_sent_escaped()
  -- curl reads the URL as a C string, which would stop at a raw NUL
  assert(request_line("/a\0.evil/") == "/a%00.evil/")
end

local function test_an_escaped_url_and_its_reserved_bytes_are_sent_as_written()
  local reserved = "/a:b@c;d,e=f+g$h!i'(j)*k[l]~%2F%C3%A9?q=1&r=/2"
  assert(request_line(reserved) == reserved, request_line(reserved))
  assert(request_line("/two%20words.txt") == "/two%20words.txt")
end

local function test_a_percent_not_before_two_hex_digits_is_sent_as_25()
  assert(request_line("/100%") == "/100%25")
  assert(request_line("/%%41%zz%4") == "/%25%41%25zz%254")
end

local function test_a_space_or_control_byte_before_the_path_is_refused_naming_it()
  local response, trouble = Http.open("http://cosmic.test\0.evil/", { timeout_ns = Clock.seconds(60), script = {} })
  assert(response == nil)
  assert(tostring(trouble) == "http: the URL holds a NUL at byte 19, in its host, which holds none", trouble)
  local got, why = Http.get("http://us er@cosmic.test/", { timeout_ns = Clock.seconds(60), script = {} })
  assert(got == nil and tostring(why) == "http: the URL holds a space at byte 10, in its user info; " ..
      "a user name or password goes in through Url.escape", why)
  got, why = Http.request("PUT", "cosmic\n.test/a b", { timeout_ns = Clock.seconds(60), script = {} })
  assert(got == nil and tostring(why):find("control byte 0x0a at byte 7, in its host,", 1, true) ~= nil, why)
  got, why = Http.get("http:/co smic.test/a", { timeout_ns = Clock.seconds(60), script = {} })
  assert(got == nil and tostring(why):find("a space at byte 9, in its host,", 1, true) ~= nil, why)
end

local function test_a_url_escaped_with_url_escape_is_sent_as_written()
  local response = assert(Http.open(url .. Url.escape("a b/c"), { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "ok") } }))
  assert(response.status == 200)
  local sent = response:sent()
  local _, _ = response:close()
  assert(sent:find("GET /a%20b%2Fc HTTP/1.1\r\n", 1, true), sent)
end

-- A pattern no two nearby offsets share, so a byte out of place shows.
local function big(size: integer): string
  local parts: mut {string} = {}
  for i = 1, size // 8 do
    parts[i] = string.format("%07x\n", i)
  end
  return table.concat(parts)
end

local function test_a_body_over_the_pause_threshold_arrives_whole()
  -- Driving one transfer drives every open one, so reading `second`
  -- through leaves `first`'s body piling up unread until the write
  -- callback pauses it; reading `first` afterwards has to resume it.
  local data = big(3 * 1024 * 1024)
  local first = assert(Http.open(url, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", data) } }))
  local second = assert(Http.open(url, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", data) } }))
  for _, response in ipairs({ second, first }) do
    local parts: mut {string} = {}
    while true do
      local chunk, trouble = response:read(1 << 20)
      assert(chunk ~= nil, tostring(trouble))
      if chunk == false then
        break
      end
      parts[#parts + 1] = chunk
    end
    assert(table.concat(parts) == data)
    local _, _ = response:close()
  end
end

local function test_repeated_headers_keep_every_value()
  local response = fetch({ reply("200 OK",
    "X-Many: a\r\nx-many: b\r\nSet-Cookie: a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT\r\n" ..
      "Set-Cookie: b=2\r\n") })
  assert(response.headers["x-many"] == "a, b", response.headers["x-many"])
  assert(response.headers["set-cookie"] ==
      "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT\nb=2", response.headers["set-cookie"])
end

local function test_a_post_body_outlives_the_options_that_held_it()
  -- curl is still sending the body when `open` returns: the handle has
  -- to keep it alive through a collection, and the bytes that reach
  -- the far end have to be the ones given. The reply leaves the
  -- connection open, or curl would stop sending once it was read.
  local size = 8 * 1024 * 1024
  local opts: Http.Options? = { timeout_ns = Clock.seconds(60), method = "POST", body = string.rep("A", size),
    headers = { Expect = "" }, script = { "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" } }
  local response = assert(Http.open(url, opts))
  opts = nil
  collectgarbage()
  collectgarbage()
  local churn: mut {string} = {}
  for i = 1, 4 do
    churn[i] = string.rep(string.char(65 + i), size)
  end
  assert(chunk_of(response) == "ok")
  local after, trouble = response:read()
  assert(after == false, trouble)
  local sent = response:sent()
  local _, _ = response:close()
  assert(#sent > size)
  assert(sent:sub(-size) == string.rep("A", size), "the body arrived intact")
end

local function test_a_script_without_enough_connections_fails_cleanly()
  local response, trouble = Http.open(url, { timeout_ns = Clock.seconds(60), script = {} })
  assert(response == nil)
  assert(tostring(trouble) ~= "")
end

local function test_a_non_string_option_throws()
  local function raises(opts: Http.Options): boolean
    local ok, _ = pcall(function() local _, _ = Http.open(url, opts) end)
    return not ok
  end
  assert(raises({ timeout_ns = Clock.seconds(60), body = {} as string, script = {} })) -- checked: cast_refused, literal_needs_type
  assert(raises({ timeout_ns = Clock.seconds(60), headers = { X = 1 as string }, script = {} })) -- checked: cast_refused
  assert(raises({ timeout_ns = Clock.seconds(60), headers = { [1 as string] = "x" }, script = {} })) -- checked: cast_refused
end

local function test_a_malformed_url_fails()
  -- A port out of range is rejected outright (CURLE_URL_MALFORMAT), with
  -- no network access attempted. Other odd URLs would be looked up:
  -- curl reads "http:///no-host-here" as "http://no-host-here", and
  -- guesses "http://" onto a bare "example.com/".
  local response, trouble = Http.open("http://127.0.0.1:99999/", { timeout_ns = Clock.seconds(60) })
  assert(response == nil)
  assert(tostring(trouble):find("URL", 1, true) ~= nil, trouble)
end

local function test_an_unsupported_scheme_fails()
  local response, trouble = Http.open("ftp://example.com/", { timeout_ns = Clock.seconds(60) })
  assert(response == nil)
  assert(tostring(trouble) ~= "")
end

local function test_connection_refused_on_a_closed_local_port()
  -- Nothing binds port 1, so the connection is refused.
  local response, trouble = Http.open("http://127.0.0.1:1/",
    { timeout_ns = Clock.seconds(60), connect_timeout_ns = Clock.seconds(2) })
  assert(response == nil)
  assert(tostring(trouble) ~= "")
  assert(tostring(trouble):lower():find("refus", 1, true) ~= nil or
      tostring(trouble):lower():find("connect", 1, true) ~= nil, trouble)
end

local function test_get_reports_the_same_failure_as_open()
  local got, trouble = Http.get("http://127.0.0.1:1/",
    { timeout_ns = Clock.seconds(60), connect_timeout_ns = Clock.seconds(2) })
  assert(got == nil)
  assert(tostring(trouble) ~= "")
end

local function test_download_writes_verifies_and_renames(tmp: string)
  local path = tmp .. "/got"
  local data = "downloaded bytes"
  local ok, trouble = Http.download(url, path, { timeout_ns = Clock.seconds(60), digests = { ["sha256"] = Hash.hex_sha256(data) },
    script = { reply("200 OK", "", data) } })
  assert(ok, trouble)
  assert(assert(Fs.read(path)) == data)
  local names = (assert(Fs.list(tmp)))
  assert(#names == 1 and names[1] == "got", "a temporary file was left behind")
end

local function test_download_never_writes_through_a_planted_part_file(tmp: string)
  -- Opening path .. ".part" with O_TRUNC would follow a symlink someone
  -- else put there, and share the file with a concurrent download.
  local path = tmp .. "/got"
  assert(Fs.write(tmp .. "/victim", "keep me"))
  assert(Fs.symlink(tmp .. "/victim", path .. ".part"))
  local ok, trouble = Http.download(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "fresh") } })
  assert(ok, trouble)
  assert(assert(Fs.read(path)) == "fresh")
  assert(assert(Fs.read(tmp .. "/victim")) == "keep me")
end

local function test_download_removes_its_temporary_file_on_a_mismatch(tmp: string)
  local path = tmp .. "/bad"
  local ok, trouble = Http.download(url, path, { timeout_ns = Clock.seconds(60), digests = { ["sha256"] = string.rep("0", 64) },
    script = { reply("200 OK", "", "not what was promised") } })
  assert(not ok)
  assert(tostring(trouble):find("mismatch", 1, true) ~= nil, trouble)
  assert(not assert(Fs.status(path)).exists and #assert(Fs.list(tmp)) == 0)
end

local function test_download_removes_its_temporary_file_on_a_truncated_body(tmp: string)
  local path = tmp .. "/short"
  local ok, _ = Http.download(url, path, { timeout_ns = Clock.seconds(60), script = {
    "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nonly ten b",
  } })
  assert(not ok)
  assert(not assert(Fs.status(path)).exists and #assert(Fs.list(tmp)) == 0)
end

local function test_download_names_its_path_when_it_cannot_make_the_file(tmp: string)
  local path = tmp .. "/missing/got"
  local ok, trouble = Http.download(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "data") } })
  assert(not ok and tostring(trouble):find(path .. ": ", 1, true) == 1, trouble)
end

--- A body that stops short fails the download, leaves the destination as
--- it was, and removes the part it wrote.
local function test_download_keeps_the_old_file_when_the_body_stops_short(tmp: string)
  local path = tmp .. "/kept"
  assert(Fs.write(path, "old"))
  local ok, _ = Http.download(url, path, { timeout_ns = Clock.seconds(60), script = {
    "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nonly ten b",
  } })
  assert(not ok)
  assert(assert(Fs.read(path)) == "old" and #assert(Fs.list(tmp)) == 1)
end

local function test_download_fails_on_a_non_2xx_status(tmp: string)
  local ok, trouble = Http.download(url, tmp .. "/missing", { timeout_ns = Clock.seconds(60), script = {
    reply("404 Not Found", "", "no"),
  } })
  assert(not ok)
  assert(tostring(trouble):find("404", 1, true) ~= nil, trouble)
end

local function test_download_reports_the_same_failure_as_open(tmp: string)
  local ok, trouble = Http.download("http://127.0.0.1:1/", tmp .. "/unreached",
    { timeout_ns = Clock.seconds(60), connect_timeout_ns = Clock.seconds(2) })
  assert(not ok)
  assert(tostring(trouble) ~= "")
end

-- A header name or value carrying CR or LF could otherwise smuggle a
-- second header, or even a whole extra request, past curl and onto the
-- wire (CRLF/header injection). This is caught before any connection
-- is attempted: the script offers none, so a request that got that far
-- would fail for a different reason.
local function test_a_header_value_with_crlf_is_rejected()
  local response, trouble = Http.open(url,
    { timeout_ns = Clock.seconds(60), headers = { ["X-Evil"] = "value\r\nX-Injected: yes" }, script = {} })
  assert(response == nil)
  assert(tostring(trouble):lower():find("cr or lf", 1, true) ~= nil, trouble)
end

local function test_a_header_value_with_a_bare_lf_is_rejected()
  local response, trouble = Http.open(url,
    { timeout_ns = Clock.seconds(60), headers = { ["X-Evil"] = "value\nX-Injected: yes" }, script = {} })
  assert(response == nil)
  assert(tostring(trouble):find("invalid header", 1, true) ~= nil, trouble)
end

local function test_a_header_name_with_crlf_is_rejected()
  local response, trouble = Http.open(url,
    { timeout_ns = Clock.seconds(60), headers = { ["X-Evil\r\nX-Injected"] = "yes" }, script = {} })
  assert(response == nil)
  assert(tostring(trouble):find("invalid header", 1, true) ~= nil, trouble)
end

local function test_a_header_name_with_a_colon_is_rejected()
  local response, trouble = Http.open(url,
    { timeout_ns = Clock.seconds(60), headers = { ["X-Evil: yes\r\nX-Injected"] = "yes" }, script = {} })
  assert(response == nil)
  assert(tostring(trouble):find("invalid header", 1, true) ~= nil, trouble)
end

local function test_an_empty_header_name_is_rejected()
  local response, trouble = Http.open(url,
    { timeout_ns = Clock.seconds(60), headers = { [""] = "yes" }, script = {} })
  assert(response == nil)
  assert(tostring(trouble):find("invalid header", 1, true) ~= nil, trouble)
end

local function test_an_ordinary_header_is_sent()
  local _, _, sent = fetch({ reply("200 OK", "") },
    { timeout_ns = Clock.seconds(60), headers = { ["X-Fine"] = "a normal value" } })
  assert(sent:find("\r\nX-Fine: a normal value\r\n", 1, true) ~= nil, sent)
end

local function test_a_request_without_a_user_agent_sends_cosmic()
  local _, _, sent = fetch({ reply("200 OK", "") })
  assert(count(sent:lower(), "\r\nuser-agent:") == 1, sent)
  assert(sent:find("\r\nUser-Agent: cosmic\r\n", 1, true) ~= nil, sent)
end

-- curl lets a custom header replace its own, whatever the name's case.
local function test_the_default_user_agent_goes_with_decompress_headers()
  local _, _, sent = fetch({ reply("200 OK", "") }, { timeout_ns = Clock.seconds(60), decompress = true })
  assert(sent:find("\r\nUser-Agent: cosmic\r\n", 1, true) ~= nil, sent)
  assert(sent:find("\r\nAccept-Encoding: zstd, gzip, deflate\r\n", 1, true) ~= nil, sent)
  local _, _, own = fetch({ reply("200 OK", "") },
    { timeout_ns = Clock.seconds(60), decompress = true, headers = { ["user-agent"] = "mine/1" } })
  sent = own
  assert(count(sent:lower(), "\r\nuser-agent:") == 1, sent)
  assert(sent:find("\r\nuser-agent: mine/1\r\n", 1, true) ~= nil, sent)
  assert(sent:find("\r\nAccept-Encoding: zstd, gzip, deflate\r\n", 1, true) ~= nil, sent)
end

local function test_a_callers_user_agent_replaces_the_default()
  for _, name in ipairs({ "User-Agent", "user-agent" }) do
    local _, _, sent = fetch({ reply("200 OK", "") },
      { timeout_ns = Clock.seconds(60), headers = { [name] = "mine/1" } })
    assert(count(sent:lower(), "\r\nuser-agent:") == 1, sent)
    assert(sent:find("\r\n" .. name .. ": mine/1\r\n", 1, true) ~= nil, sent)
    assert(sent:find("cosmic\r\n", 1, true) == nil, sent)
  end
end

-- curl reads a method, header name and header value as C strings, so a
-- NUL would cut each short: `X-A: v1` would go out for "v1\0INJECT" and
-- a plain GET for "GET\0junk". Each is refused before any connection.
local function test_a_header_value_with_a_nul_is_rejected()
  local response, trouble = Http.open(url,
    { timeout_ns = Clock.seconds(60), headers = { ["X-A"] = "v1\0INJECT" }, script = { reply("200 OK", "") } })
  assert(response == nil)
  assert(tostring(trouble):find("invalid header X-A", 1, true) ~= nil, trouble)
  assert(tostring(trouble):find("NUL", 1, true) ~= nil, trouble)
end

local function test_a_header_name_with_a_nul_is_rejected()
  local response, trouble = Http.open(url,
    { timeout_ns = Clock.seconds(60), headers = { ["X-A\0junk"] = "v" }, script = { reply("200 OK", "") } })
  assert(response == nil)
  assert(tostring(trouble):find("invalid header X-A\0junk", 1, true) ~= nil, trouble)
  assert(tostring(trouble):find("NUL", 1, true) ~= nil, trouble)
end

local function test_a_method_with_a_nul_is_refused()
  local response, trouble = Http.open(url,
    { timeout_ns = Clock.seconds(60), method = "GET\0junk", script = { reply("200 OK", "") } })
  assert(response == nil)
  assert(tostring(trouble):find("method", 1, true) ~= nil, trouble)
end

--- The message [`Http.open`] raises with for `opts`.
local function raised(opts: Http.Options): string
  local ok, err = pcall(function()
    local _, _ = Http.open(url, { ...opts, script = opts.script or {} })
  end)
  assert(not ok, "expected a raise")
  return tostring(err)
end

local function test_a_negative_timeout_is_refused_not_ignored()
  -- curl refuses -5 and keeps its default, which is no timeout at all.
  local err = raised({ timeout_ns = -5 })
  assert(err:find("http: opts.timeout_ns must be between 0 and", 1, true) ~= nil, err)
end

local function test_an_integer_option_curl_would_clamp_is_refused()
  local err = raised({ timeout_ns = Clock.seconds(60), max_redirects = 40000 })
  assert(err:find("http: opts.max_redirects must be between 0 and 32767", 1, true) ~= nil, err)
  err = raised({ timeout_ns = Clock.seconds(60), low_speed_ns = Clock.seconds(70000) })
  assert(err:find("http: opts.low_speed_ns must be between 0 and " .. tostring(Clock.seconds(65535)), 1, true) ~= nil,
    err)
end

--- A refused option is raised at the line that called the public
--- entry point, whichever it is, and not inside cosmic.http: between the
--- lines that raise `mark` ahead of the call and behind it.
local function test_a_refused_option_is_raised_at_the_callers_line()
  -- Each answers a value, which a raise leaves `pcall` the message in
  -- place of.
  local entries: {string: function(Http.Options, string): string} = {
    open = function(opts: Http.Options, mark: string): string
      if mark == "ahead" then error("mark") end
      local _, _ = Http.open(url, opts)
      if mark == "behind" then error("mark") end
      return ""
    end,
    get = function(opts: Http.Options, mark: string): string
      if mark == "ahead" then error("mark") end
      local _, _ = Http.get(url, opts)
      if mark == "behind" then error("mark") end
      return ""
    end,
    request = function(opts: Http.Options, mark: string): string
      if mark == "ahead" then error("mark") end
      local _, _ = Http.request("PUT", url, opts)
      if mark == "behind" then error("mark") end
      return ""
    end,
    download = function(opts: Http.Options, mark: string): string
      if mark == "ahead" then error("mark") end
      local _, _ = Http.download(url, "never-written", opts)
      if mark == "behind" then error("mark") end
      return ""
    end,
    download_result = function(opts: Http.Options, mark: string): string
      if mark == "ahead" then error("mark") end
      local _ = Http.download_result(url, "never-written", opts)
      if mark == "behind" then error("mark") end
      return ""
    end,
  }
  --- Where `entry` raises, given `opts` and `mark`: its file and line.
  local function raised_at(entry: function(Http.Options, string): string, opts: Http.Options,
                           mark: string): string, integer
    local ok, err = pcall(entry, opts, mark)
    assert(not ok, mark .. ": expected a raise")
    local file, line = tostring(err):match("^(.-):(%d+): ")
    assert(file ~= nil, tostring(err))
    return file, math.tointeger(tonumber(line)) or 0
  end
  -- A limit out of range, and none at all, which the type checker
  -- refuses where the literal is written.
  local unlimited = { follow = false } as Http.Options -- checked: cast_refused
  local refusals: {Http.Options} = { { timeout_ns = -5, script = {} }, unlimited }
  for name, entry in pairs(entries) do
    local good: Http.Options = { timeout_ns = Clock.seconds(60), script = {} }
    local file, ahead = raised_at(entry, good, "ahead")
    local _, behind = raised_at(entry, good, "behind")
    for _, refusing in ipairs(refusals) do
      local refused, at = raised_at(entry, refusing, "")
      assert(refused == file and ahead < at and at < behind,
        name .. ": raised at " .. refused .. ":" .. tostring(at) .. ", not between " .. file .. ":" ..
          tostring(ahead) .. " and " .. tostring(behind))
    end
  end
  local _, why = pcall(function() local _, _ = Http.get(url, unlimited) end)
  assert(tostring(why):find("http: opts.timeout_ns is required", 1, true) ~= nil, tostring(why))
end

local function test_zero_integer_options_are_accepted()
  local response, body = fetch({ reply("200 OK", "", "ok") }, { timeout_ns = Clock.seconds(60),
    max_redirects = 0, low_speed_bytes = 0, low_speed_ns = 0 })
  assert(response.status == 200 and body == "ok")
end

local function test_redirect_protocols_takes_a_list_of_http_and_https()
  local err = raised({ timeout_ns = Clock.seconds(60), redirect_protocols = "https" as {string} }) -- checked: cast_refused
  assert(err:find("http: opts.redirect_protocols must be a list of one or more", 1, true) ~= nil, err)
  err = raised({ timeout_ns = Clock.seconds(60), redirect_protocols = {} })
  assert(err:find("http: opts.redirect_protocols must be a list of one or more", 1, true) ~= nil, err)
  err = raised({ timeout_ns = Clock.seconds(60), redirect_protocols = { "ftp" } })
  assert(err:find("http: opts.redirect_protocols must be a list of one or more", 1, true) ~= nil, err)
  err = raised({ timeout_ns = Clock.seconds(60), redirect_protocols = { "HTTPS" } })
  assert(err:find("http: opts.redirect_protocols must be a list of one or more", 1, true) ~= nil, err)
  -- a name is compared whole, not up to a NUL: "http\0s" is not "http"
  err = raised({ timeout_ns = Clock.seconds(60), redirect_protocols = { "http\0s" } })
  assert(err:find("http: opts.redirect_protocols must be a list of one or more", 1, true) ~= nil, err)
  err = raised({ timeout_ns = Clock.seconds(60), redirect_protocols = { "https\0" } })
  assert(err:find("http: opts.redirect_protocols must be a list of one or more", 1, true) ~= nil, err)
end

local function test_a_boolean_option_takes_only_a_boolean()
  local err = raised({ timeout_ns = Clock.seconds(60), follow = "no" as boolean }) -- checked: cast_refused
  assert(err:find("http: opts.follow must be a boolean", 1, true) ~= nil, err)
end

local function test_non_table_headers_raise_naming_the_option()
  -- The message names the option, not a bad argument number.
  local err = raised({ timeout_ns = Clock.seconds(60), headers = "X-A: 1" as {string:string} }) -- checked: cast_refused
  assert(err:find("http: opts.headers must be a table", 1, true) ~= nil, err)
  assert(err:find("#-1", 1, true) == nil, err)
end

local function test_a_non_string_script_entry_raises()
  -- A non-string entry is refused, not read as an empty reply.
  local err = raised({ timeout_ns = Clock.seconds(60), script = { reply("200 OK", ""), 42 as string } }) -- checked: cast_refused
  assert(err:find("http: opts.script must be a list of strings", 1, true) ~= nil, err)
end

local function test_an_option_curl_refuses_is_an_error_naming_it()
  -- curl refuses a string option over 8 MB. Ignoring the refusal would
  -- send the request with no URL set at all.
  local response, trouble = Http.open(url .. string.rep("a", 8000000), { timeout_ns = Clock.seconds(60), script = {} })
  assert(response == nil)
  assert(tostring(trouble):find("CURLOPT_URL", 1, true) ~= nil, trouble)
end

local function test_read_refuses_a_max_bytes_below_one()
  local response = assert(Http.open(url, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") } }))
  Test.raises(function() local _, _ = response:read(0) end, "http: read's max_bytes must be positive")
  local _, _ = response:close()
end

local function test_read_returns_an_empty_second_value_on_success()
  local response, opened = Http.open(url, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") } })
  assert(response ~= nil and opened == nil, tostring(opened))
  local chunk, trouble = response:read()
  assert(chunk == "body" and trouble == nil, tostring(trouble))
  local after, _ = response:read()
  assert(after == false)
  local _, _ = response:close()
end

local function test_a_close_variable_closes_the_response()
  local kept: Http.Response
  do
    local response <close> = assert(Http.open(url, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "x") } }))
    kept = response
  end
  local chunk, trouble = kept:read()
  assert(chunk == nil and tostring(trouble) == "http: the response is closed", trouble)
  local again, again_trouble = kept:close() -- closing again is harmless
  assert(again and again_trouble == nil)
end

--- A response is a [`cosmic.stream`] Reader: what takes a file's Reader
--- takes a body the same way.
local function test_a_response_is_a_stream_reader()
  local body = string.rep("0123456789", 10000)
  local response = assert(Http.open(url, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", body) } }))
  local reader: Stream.Reader = response
  local head = assert(Stream.read_exact(reader, 10))
  assert(head == "0123456789")
  local rest = Stream.collect()
  assert(assert(Stream.copy(reader, rest)) == #body - 10)
  assert(rest:result() == body:sub(11))
  assert(reader:close())
end

local revived: mut {integer: Http.Response} = {}

--- A table whose finalizer hands back the response it holds.
local class Reviver
  response: Http.Response
  function __gc(self)
    revived[1] = self.response
  end
end

local function test_a_response_a_finalizer_revives_is_closed()
  -- The table's finalizer runs in the same collection as the handle's
  -- and brings the response back after the handle released its curl
  -- state: every method has to see a closed handle, not freed memory.
  do
    local response = assert(Http.open(url, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "x") } }))
    local _: Reviver = { response = response }
  end
  collectgarbage()
  collectgarbage()
  local response = revived[1]
  assert(response ~= nil, "the finalizer ran")
  revived[1] = nil
  local ok, err = pcall(function() local _, _ = response:read() end)
  assert(not ok and tostring(err):find("http: the response is closed", 1, true) ~= nil, tostring(err))
  ok, err = pcall(function() response:sent() end)
  assert(not ok and tostring(err):find("http: the response is closed", 1, true) ~= nil, tostring(err))
  local _, _ = response:close()
end

--- The raw handle's close answers nothing: it cannot fail, so a `true`
--- would tell its caller nothing.
local function test_the_raw_handle_close_returns_no_values()
  local raw = require("cosmic.internal.http") as {string: function(string, {string: any}): any, string} -- cast: the table -- checked: cast_refused
  -- cosmic/internal/http.d.tl declares, called with a script that its `Options` have no field for
  local handle = assert(raw.open(url, { script = { reply("200 OK", "", "body") } })) -- checked: cast_refused
    as {string: function(any): any...}
  assert(select("#", handle.close(handle)) == 0, "close returns no values")
  assert(select("#", handle.close(handle)) == 0, "closing twice returns no values")
end

local function test_a_cancelled_download_removes_its_part_file_and_makes_no_target(tmp: string)
  local path = tmp .. "/got.bin"
  local asked: integer = 0
  local ok, why = Http.download(url, path, { timeout_ns = Clock.seconds(60),
    script = { reply("200 OK", "", string.rep("x", 200000)) },
    cancelled = function(): boolean
      asked = asked + 1
      return asked > 1
    end,
  })
  assert(not ok and tostring(why) == "interrupted", why)
  assert(asked > 1, "asked between chunks")
  assert(not assert(Fs.status(path)).exists, "the target was created")
  local names = (assert(Fs.list(tmp)))
  for _, name in ipairs(names) do
    assert(name ~= "got.bin" and not name:find("got.bin", 1, true), "left behind: " .. name)
  end
end

local function test_a_download_never_cancelled_completes(tmp: string)
  local path = tmp .. "/got.bin"
  local ok, why = Http.download(url, path, { timeout_ns = Clock.seconds(60),
    script = { reply("200 OK", "", "hello") },
    cancelled = function(): boolean return false end,
  })
  assert(ok, why)
  assert(assert(Fs.read(path)) == "hello")
end

local function test_a_download_cancelled_only_at_the_end_makes_no_target(tmp: string)
  local path = tmp .. "/got.bin"
  local asked: integer = 0
  local total: integer = 0
  -- the ask after the last chunk, before the rename, is the last: an
  -- interrupt that came in that window still leaves nothing
  local ok, why = Http.download(url, path, { timeout_ns = Clock.seconds(60),
    script = { reply("200 OK", "", "hello") },
    cancelled = function(): boolean
      asked = asked + 1
      total = asked
      return false
    end,
  })
  assert(ok, why)
  local last = total
  -- one ask before the chunk, one before the read that finds the end,
  -- and the last, with the body complete
  assert(last == 3, "asked " .. tostring(last))
  assert(Fs.remove(path))
  asked = 0
  ok, why = Http.download(url, path, { timeout_ns = Clock.seconds(60),
    script = { reply("200 OK", "", "hello") },
    cancelled = function(): boolean
      asked = asked + 1
      return asked == last
    end,
  })
  assert(not ok and tostring(why) == "interrupted", tostring(why))
  assert(not assert(Fs.status(path)).exists, "the target was created")
  local names = (assert(Fs.list(tmp)))
  assert(#names == 0, "left behind: " .. table.concat(names, ","))
end

local function test_a_caught_signal_ends_an_open_that_waits()
  local guard = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  local response, why = Http.open(url, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "x") } })
  local caught = assert(guard:release())
  assert(response == nil and tostring(why) == "interrupted", tostring(why))
  assert(caught == sys.SIGINT, tostring(caught))
end

local function test_a_download_checks_every_digest_it_is_given(tmp: string)
  local path = tmp .. "/two.bin"
  local s256 = Hash.hex_sha256("hello")
  local s512 = Codec.hex(Hash.digest("sha512", "hello"))
  local ok, why = Http.download(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "hello") },
    digests = { ["sha256"] = s256, ["sha512"] = s512:upper() } })
  assert(ok, why)
  assert(assert(Fs.read(path)) == "hello")
  local other = tmp .. "/other.bin"
  local bad, bad_why = Http.download(url, other, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "hello") },
    digests = { ["sha256"] = s256, ["sha512"] = string.rep("0", 128) } })
  assert(not bad and tostring(bad_why):find("sha512 mismatch: want " .. string.rep("0", 128) .. ", got " .. s512, 1, true) ~= nil, bad_why)
  assert(not assert(Fs.status(other)).exists, "the target was created")
  for _, name in ipairs((assert(Fs.list(tmp)))) do
    assert(name == "two.bin", "left behind: " .. name)
  end
end

local function test_a_download_with_only_a_sha512_checks_that_alone(tmp: string)
  local path = tmp .. "/only512.bin"
  local s512 = Codec.hex(Hash.digest("sha512", "hello"))
  local ok, why = Http.download(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "hello") }, digests = { ["sha512"] = s512 } })
  assert(ok, why)
  assert(assert(Fs.read(path)) == "hello")
  local other = tmp .. "/wrong512.bin"
  local zeros = string.rep("0", 128)
  local bad, bad_why = Http.download(url, other, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "hello") }, digests = { ["sha512"] = zeros } })
  assert(not bad and tostring(bad_why):find("sha512 mismatch: want " .. zeros .. ", got " .. s512, 1, true) ~= nil, bad_why)
  assert(not tostring(bad_why):find("sha256", 1, true), bad_why)
  assert(not assert(Fs.status(other)).exists, "the target was created")
end

--- A sha3-256, the digest sqlite.org publishes alone, is checked as the
--- others are: a wrong one fails naming it and leaves no file.
local function test_a_download_with_a_sha3_256_checks_it(tmp: string)
  local path = tmp .. "/sha3.bin"
  local sha3 = Codec.hex(Hash.digest("sha3-256", "hello"))
  local ok, why = Http.download(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "hello") },
    sha3_256 = sha3:upper() })
  assert(ok, why)
  assert(assert(Fs.read(path)) == "hello")
  local other = tmp .. "/wrong-sha3.bin"
  local zeros = string.rep("0", 64)
  local bad, bad_why = Http.download(url, other, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "hello") },
    sha256 = Hash.hex_sha256("hello"), sha3_256 = zeros })
  assert(not bad and tostring(bad_why):find("sha3-256 mismatch: want " .. zeros .. ", got " .. sha3, 1, true) ~= nil, bad_why)
  assert(not assert(Fs.status(other)).exists, "the target was created")
end

local function test_download_result_success_has_no_failure_fields(tmp: string)
  local path = tmp .. "/got"
  assert(Fs.write(path, "old"))
  local data = string.rep("new", 100000)
  local result = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", data) },
    digests = { ["sha256"] = Hash.hex_sha256(data):upper(), ["sha512"] = Codec.hex(Hash.digest("sha512", data)):upper() } })
  assert(result.kind == "downloaded" and result.reason == "")
  assert(result.status == nil and result.algorithm == nil and result.expected == nil and result.actual == nil)
  assert(assert(Fs.read(path)) == data and #assert(Fs.list(tmp)) == 1)
  assert(Http.download(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", data) } }))
end

local function test_download_result_status_is_typed_and_url_neutral(tmp: string)
  local path = tmp .. "/got"
  assert(Fs.write(path, "old"))
  for _, status in ipairs({ 302, 404, 503 }) do
    local options: Http.Options = { timeout_ns = Clock.seconds(60), follow = false,
      script = { reply(tostring(status) .. " sha256 mismatch", "", "ignored") } }
    local result = Http.download_result(url, path, options)
    assert(result.kind == "http_status" and result.status == status)
    assert(result.reason == "HTTP " .. tostring(status), result.reason)
    assert(result.algorithm == nil and result.expected == nil and result.actual == nil)
    local ok, why = Http.download(url, path, options)
    assert(not ok and tostring(why) == url .. ": HTTP " .. tostring(status), why)
    assert(assert(Fs.read(path)) == "old" and #assert(Fs.list(tmp)) == 1)
  end
end

local function test_download_result_checksums_keep_typed_digests_and_legacy_text(tmp: string)
  local path = tmp .. "/got"
  assert(Fs.write(path, "old"))
  local algorithms: {Hash.Algorithm} = { "sha256", "sha512" }
  for _, algorithm in ipairs(algorithms) do
    for _, expected in ipairs({ "ABC", "not HEX", string.rep("0", if algorithm == "sha256" then 64 else 128 end) }) do
      local options: Http.Options = { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") },
        sha256 = if algorithm == "sha256" then expected else nil end,
        sha512 = if algorithm == "sha256" then nil else expected end }
      local result = Http.download_result(url, path, options)
      local actual = Codec.hex(Hash.digest(algorithm, "body"))
      assert(result.kind == "digest_mismatch" and result.status == nil)
      assert(result.algorithm == algorithm and result.expected == expected:lower() and result.actual == actual)
      local reason = path .. ": " .. algorithm .. " mismatch: want " .. expected:lower() .. ", got " .. actual
      assert(result.reason == reason, result.reason)
      local ok, why = Http.download(url, path, options)
      assert(not ok and tostring(why) == reason and why.path == path, tostring(why))
      assert(assert(Fs.read(path)) == "old" and #assert(Fs.list(tmp)) == 1)
    end
  end
  local empty = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), sha256 = "", sha512 = "",
    script = { reply("200 OK", "", "unchecked") } })
  assert(empty.kind == "downloaded" and assert(Fs.read(path)) == "unchecked")
end

local function test_download_result_bad_checksum_shape_raises_before_publication(tmp: string)
  local path = tmp .. "/got"
  local options: Http.Options = { timeout_ns = Clock.seconds(60), sha256 = true as string, script = {} } -- checked: cast_refused
  local ok = pcall(Http.download_result, url, path, options) -- checked: alternatives_as_value
  assert(not ok and #assert(Fs.list(tmp)) == 0)
end

local function test_a_download_checks_a_digest_of_any_algorithm(tmp: string)
  local path = tmp .. "/got"
  local s384 = Codec.hex(Hash.digest("sha384", "body"))
  assert(Http.download(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") },
    digests = { ["sha384"] = s384, ["md5"] = Codec.hex(Hash.digest("md5", "body")) } }))
  assert(assert(Fs.read(path)) == "body")
  local wrong = Http.download_result(url, tmp .. "/wrong", { timeout_ns = Clock.seconds(60),
    script = { reply("200 OK", "", "body") }, digests = { ["sha3-512"] = string.rep("0", 128) } })
  assert(wrong.kind == "digest_mismatch" and wrong.algorithm == "sha3-512", wrong.reason)
end

local function test_a_download_refuses_an_empty_digest_and_two_that_differ(tmp: string)
  local path = tmp .. "/got"
  local empty = Test.raises(function()
    local _ = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), script = {}, digests = { ["sha256"] = "" } })
  end, 'opts.digests["sha256"] must be a digest in hex')
  assert(empty:find("^cosmic%.http_test:%d+: ") ~= nil, empty)
  local differ = Test.raises(function()
    local _ = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), script = {},
      sha256 = string.rep("a", 64), digests = { ["sha256"] = string.rep("b", 64) } })
  end, 'opts.sha256 and opts.digests["sha256"] differ')
  assert(differ:find("^cosmic%.http_test:%d+: ") ~= nil, differ)
  assert(#assert(Fs.list(tmp)) == 0)
  local same = string.rep("A", 64)
  local agreed = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") },
    sha256 = same, digests = { ["sha256"] = same:lower() } })
  assert(agreed.kind == "digest_mismatch" and agreed.expected == same:lower(), agreed.reason)
end

local function test_a_download_refuses_a_digest_of_no_known_algorithm(tmp: string)
  local path = tmp .. "/got"
  local options: Http.Options = { timeout_ns = Clock.seconds(60), script = {},
    digests = { ["sha999"] = "ab" } as {Hash.Algorithm:string} } -- checked: cast_refused
  local why = Test.raises(function() local _, _ = Http.download(url, path, options) end,
    "opts.digests names sha999, which is no Hash.Algorithm")
  assert(why:find("^cosmic%.http_test:%d+: ") ~= nil, why)
  assert(#assert(Fs.list(tmp)) == 0)
end

local function test_a_download_reports_the_first_mismatch_in_a_fixed_order(tmp: string)
  for _ = 1, 4 do
    local result = Http.download_result(url, tmp .. "/got", { timeout_ns = Clock.seconds(60),
      script = { reply("200 OK", "", "body") },
      digests = { ["md5"] = string.rep("0", 32), ["sha3-256"] = string.rep("0", 64), ["sha512"] = string.rep("0", 128) } })
    assert(result.kind == "digest_mismatch" and result.algorithm == "sha512", result.reason)
  end
end

local function test_download_result_transport_and_create_failures_are_not_status(tmp: string)
  local failed = Http.download_result("file:///not-http", tmp .. "/got", { timeout_ns = Clock.seconds(60) })
  assert(failed.kind == "failed" and failed.reason ~= "" and failed.status == nil)
  local path = tmp .. "/missing/HTTP 404 sha256 mismatch"
  local result = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") } })
  assert(result.kind == "failed" and result.status == nil and result.algorithm == nil)
  assert(result.reason:find(path, 1, true) == 1, result.reason)
  assert(#assert(Fs.list(tmp)) == 0)
end

local function test_download_result_write_and_sync_failures_abort_without_classifying_text(tmp: string)
  local path = tmp .. "/got"
  assert(Fs.write(path, "old"))
  local real_write, real_sync = sys.write, sys.fsync
  local reason = "HTTP 503: sha256 mismatch: want x, got y"
  sys.write = function(_fd: integer, _data: string): integer?, string, integer -- checked: field_fixed
    return nil, reason, 0
  end
  local written = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") } })
  sys.write = real_write -- checked: field_fixed
  assert(written.kind == "failed" and written.reason == path .. ": " .. reason)
  assert(written.status == nil and written.algorithm == nil)
  assert(assert(Fs.read(path)) == "old" and #assert(Fs.list(tmp)) == 1)
  sys.fsync = function(_fd: integer): boolean, string, integer -- checked: field_fixed
    return false, reason, 0
  end
  local synced = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") } })
  sys.fsync = real_sync -- checked: field_fixed
  assert(synced.kind == "failed" and synced.reason == path .. ": " .. reason)
  assert(synced.status == nil and synced.algorithm == nil)
  assert(assert(Fs.read(path)) == "old" and #assert(Fs.list(tmp)) == 1)
end

local function test_download_result_rename_failure_keeps_target_and_removes_stage(tmp: string)
  local path = tmp .. "/directory"
  assert(Fs.mkdirs(path))
  assert(Fs.write(path .. "/kept", "old"))
  local result = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") } })
  assert(result.kind == "failed" and result.reason ~= "")
  assert(assert(Fs.read(path .. "/kept")) == "old" and #assert(Fs.list(tmp)) == 1)
end

local function test_download_result_cancel_and_callback_exception_keep_target(tmp: string)
  local path = tmp .. "/got"
  assert(Fs.write(path, "old"))
  for _, at in ipairs({ 1, 2, 3 }) do
    local asked: integer = 0
    local result = Http.download_result(url, path, { timeout_ns = Clock.seconds(60),
      script = { reply("200 OK", "", "body") },
      cancelled = function(): boolean
        asked = asked + 1
        return asked == at
      end,
    })
    assert(result.kind == "failed" and result.reason == "interrupted")
    assert(result.status == nil and result.algorithm == nil)
    assert(assert(Fs.read(path)) == "old" and #assert(Fs.list(tmp)) == 1)
  end
  local options: Http.Options = { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") },
    cancelled = function(): boolean error("callback failed") end }
  Test.raises(function() Http.download_result(url, path, options) end, "callback failed")
  assert(assert(Fs.read(path)) == "old" and #assert(Fs.list(tmp)) == 1)
end

local function test_download_result_truncated_body_preserves_existing_target(tmp: string)
  local path = tmp .. "/got"
  assert(Fs.write(path, "old"))
  local result = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), script = {
    "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nshort",
  } })
  assert(result.kind == "failed" and result.reason ~= "")
  assert(assert(Fs.read(path)) == "old" and #assert(Fs.list(tmp)) == 1)
end

local function test_download_result_digest_failure_is_not_a_mismatch(tmp: string)
  local path = tmp .. "/got"
  assert(Fs.write(path, "old"))
  local hashing = Stream.hashing
  local reason = "sha512 mismatch: digest engine failed"
  Stream.hashing = function(algorithm: Hash.Algorithm, key?: string): (Stream.Hashing) | (nil, Failure) -- checked: field_fixed
    local writer, why = hashing(algorithm, key)
    if writer == nil then return nil, why end
    writer.digest = function(_self: Stream.Hashing): string?, string -- checked: field_fixed
      return nil, reason
    end
    return writer
  end
  local result = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), digests = { ["sha256"] = Hash.hex_sha256("body") },
    script = { reply("200 OK", "", "body") } })
  Stream.hashing = hashing -- checked: field_fixed
  assert(result.kind == "failed" and result.reason == reason)
  assert(result.algorithm == nil and result.expected == nil and result.actual == nil)
  assert(assert(Fs.read(path)) == "old" and #assert(Fs.list(tmp)) == 1)
end

local function test_download_result_preserves_underlying_url_text_without_classifying_it(tmp: string)
  local open = Http.open
  local reason = url .. ": HTTP 404; sha256 mismatch in transport diagnostic"
  Http.open = function(_url: string, _opts?: Http.Options): (Http.Response) | (nil, Failure) -- checked: field_fixed
    return nil, Failure.new(reason)
  end
  local result = Http.download_result(url, tmp .. "/got", { timeout_ns = Clock.seconds(60) })
  local ok, why = Http.download(url, tmp .. "/got", { timeout_ns = Clock.seconds(60) })
  Http.open = open -- checked: field_fixed
  assert(result.kind == "failed" and result.reason == reason)
  assert(result.status == nil and result.algorithm == nil)
  assert(not ok and tostring(why) == reason and #assert(Fs.list(tmp)) == 0)
end

local function test_download_result_guard_interruption_stays_available(tmp: string)
  local guard = assert(Signal.guard())
  assert(sys.kill(sys.getpid(), sys.SIGINT))
  local result = Http.download_result(url, tmp .. "/got", { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "body") } })
  local caught = assert(guard:release())
  assert(result.kind == "failed" and result.reason == "interrupted")
  assert(caught == sys.SIGINT and #assert(Fs.list(tmp)) == 0)
end

local function test_download_result_interleaved_publishers_own_their_staged_files(tmp: string)
  local path = tmp .. "/got"
  for _, mismatch in ipairs({ false, true }) do
    local published: boolean = false
    local result = Http.download_result(url, path, { timeout_ns = Clock.seconds(60),
      script = { reply("200 OK", "", "outer") },
      digests = { ["sha256"] = if mismatch then string.rep("0", 64) else Hash.hex_sha256("outer") end },
      cancelled = function(): boolean
        if not published then
          published = true
          local other = Http.download_result(url, path, { timeout_ns = Clock.seconds(60), script = { reply("200 OK", "", "inner") } })
          assert(other.kind == "downloaded", other.reason)
          assert(assert(Fs.read(path)) == "inner")
        end
        return false
      end,
    })
    local expected: Http.DownloadKind = if mismatch then "digest_mismatch" else "downloaded" end
    assert(result.kind == expected, result.reason)
    assert(assert(Fs.read(path)) == (if mismatch then "inner" else "outer" end))
    assert(#assert(Fs.list(tmp)) == 1, "one publisher left its staged file behind")
  end
end

local function test_request_reads_the_whole_response()
  local got, trouble = Http.request("PATCH", url,
    { timeout_ns = Clock.seconds(60), body = "x", script = { reply("201 Created", "X-One: 1\r\n", "made") } })
  assert(got ~= nil, trouble)
  assert(got.status == 201 and got.body == "made" and got.headers["x-one"] == "1", got.body)
end

--- The method reaches the transfer: a HEAD reads no body, where a GET
--- of the same reply would wait for the 1000 bytes it promises and fail.
local function test_request_sends_its_method()
  local head = "HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n"
  local got, trouble = Http.request("HEAD", url, { timeout_ns = Clock.seconds(60), script = { head } })
  assert(got ~= nil and got.body == "", trouble)
  local get, _ = Http.request("GET", url, { timeout_ns = Clock.seconds(60), script = { head } })
  assert(get == nil, "a GET read a body that never came")
end

--- The request is the one asked for, or none: an empty method, an
--- `opts.method` that differs from the argument, and a body with GET or
--- HEAD raise before anything is sent.
local function test_request_refuses_what_it_would_not_send_as_asked()
  local script = { reply("200 OK", "") }
  for method, opts in pairs({ -- checked: cast_refused, literal_shape
      [""] = { script = script },
      PUT = { method = "POST", script = script },
      GET = { body = "x", script = script },
      HEAD = { body = "x", script = script },
  } as {string:Http.Options}) do
    local ok, why = pcall(function() local _, _ = Http.request(method, url, opts) end)
    assert(not ok and tostring(why):find("Http.request", 1, true) ~= nil, method .. ": " .. tostring(why))
  end
  local got, trouble = Http.request("PUT", url, { timeout_ns = Clock.seconds(60), method = "PUT", script = script })
  assert(got ~= nil and got.status == 200, trouble)
end

--- The options a caller passes are left as they were.
local function test_request_leaves_its_options_alone()
  local opts: Http.Options = { timeout_ns = Clock.seconds(60), body = "x", script = { reply("204 No Content", "") } }
  assert(Http.request("PUT", url, opts))
  assert(opts.method == nil and opts.body == "x")
end

--- Http.get sends a GET: another method, or a body, which would make it
--- a POST, raises and names Http.request.
local function test_get_refuses_another_method_and_a_body()
  local script = { reply("200 OK", "") }
  for _, opts in ipairs({ -- checked: cast_refused
      { method = "PUT", script = script },
      { method = "HEAD", script = script },
      { body = "x", script = script },
  } as {Http.Options}) do
    Test.raises(function() local _, _ = Http.get(url, opts) end, "Http.request")
  end
  local got, trouble = Http.get(url, { timeout_ns = Clock.seconds(60), method = "GET", script = script })
  assert(got ~= nil and got.status == 200, trouble)
end

--- `plain` compressed as `coding` names it, through cosmic.compress.
local function encoded(coding: string, plain: string): string
  local codec: Compress.Stream
  if coding == "zstd" then
    codec = assert(Compress.encoder("zstd"))
  elseif coding == "zlib" then
    codec = assert(Compress.encoder("zlib"))
  elseif coding == "raw" then
    codec = assert(Compress.encoder("raw"))
  elseif coding == "gzip" then
    codec = assert(Compress.encoder("gzip"))
  else
    error("no encoder for " .. coding)
  end
  return assert(codec:update(plain)) .. assert(codec:finish())
end

local function test_decompress_asks_for_and_decodes_each_coding()
  local plain = string.rep("a compressed body, ", 200)
  local record Coding
    header: string
    coding: string
  end
  local cases: {Coding} = {
    { header = "zstd", coding = "zstd" }, { header = "gzip", coding = "gzip" },
    { header = "x-gzip", coding = "gzip" }, { header = "GZip", coding = "gzip" },
    -- deflate is zlib by RFC 9110, and raw deflate as servers also send it.
    { header = "deflate", coding = "zlib" }, { header = "deflate", coding = "raw" },
  }
  for _, case in ipairs(cases) do
    local body = encoded(case.coding, plain)
    local response, got, sent = fetch({ reply("200 OK", "Content-Encoding: " .. case.header .. "\r\n", body) },
      { timeout_ns = Clock.seconds(60), decompress = true })
    assert(got == plain, case.header .. "/" .. case.coding .. ": " .. tostring(#got))
    assert(sent:find("\r\nAccept-Encoding: zstd, gzip, deflate\r\n", 1, true) ~= nil, sent)
    -- The headers stay as the server sent them.
    assert(response.headers["content-encoding"] == case.header)
    assert(response.headers["content-length"] == tostring(#body))
    assert(response.status == 200 and response.url == url)
  end
end

local function test_a_close_variable_closes_a_decoded_response()
  local kept: Http.Response
  do
    local response <close> = assert(Http.open(url, { timeout_ns = Clock.seconds(60), decompress = true,
      script = { reply("200 OK", "Content-Encoding: gzip\r\n", encoded("gzip", "x")) } }))
    kept = response
    assert(chunk_of(response) == "x")
  end
  local chunk, trouble = kept:read()
  assert(chunk == nil and tostring(trouble) == "http: the response is closed", trouble)
  local again, again_trouble = kept:close() -- closing again is harmless
  assert(again and again_trouble == nil)
  local ok, err = pcall(function() kept:sent() end)
  assert(not ok and tostring(err):find("http: the response is closed", 1, true) ~= nil, tostring(err))
end

local function test_decompress_decodes_stacked_codings_last_first()
  local plain = "twice compressed"
  local body = encoded("zstd", encoded("gzip", plain))
  local _, got = fetch({ reply("200 OK", "Content-Encoding: gzip, identity,zstd\r\n", body) },
    { timeout_ns = Clock.seconds(60), decompress = true })
  assert(got == plain, got)
end

local function test_without_decompress_the_body_comes_as_sent()
  local body = encoded("gzip", "plain")
  local _, got, sent = fetch({ reply("200 OK", "Content-Encoding: gzip\r\n", body) })
  assert(got == body)
  assert(sent:lower():find("accept-encoding", 1, true) == nil, sent)
  _, got = fetch({ reply("200 OK", "Content-Encoding: identity\r\n", "plain") }, { timeout_ns = Clock.seconds(60), decompress = true })
  assert(got == "plain", got)
end

local function test_decompress_keeps_an_accept_encoding_the_caller_names()
  local headers: {string:string} = { ["accept-encoding"] = "gzip", ["X-Other"] = "1" }
  local _, got, sent = fetch({ reply("200 OK", "Content-Encoding: gzip\r\n", encoded("gzip", "mine")) },
    { timeout_ns = Clock.seconds(60), decompress = true, headers = headers })
  assert(got == "mine", got)
  assert(count(sent:lower(), "accept-encoding:") == 1, sent)
  assert(sent:find("\r\naccept-encoding: gzip\r\n", 1, true) ~= nil, sent)
  -- The caller's table is not written to.
  assert(headers["Accept-Encoding"] == nil and headers["accept-encoding"] == "gzip")
end

local function test_decompress_refuses_a_coding_it_cannot_read()
  local response, trouble = Http.open(url, { timeout_ns = Clock.seconds(60), decompress = true,
    script = { reply("200 OK", "Content-Encoding: gzip, br\r\n", "whatever") } })
  assert(response == nil and tostring(trouble) == 'http: cannot decode a body of Content-Encoding "br"', trouble)
end

local function test_decompress_fails_a_corrupt_truncated_or_trailed_body()
  local packed = encoded("zstd", string.rep("z", 1000))
  local record Corrupt
    body: string
    trouble: string
  end
  local cases: {Corrupt} = {
    { body = "garbage!", trouble = "http: cannot decode the zstd body: compress: not a zstd stream" },
    { body = packed:sub(1, -3), trouble = "http: cannot decode the zstd body: compress: truncated zstd stream" },
    { body = packed .. "more", trouble = "http: cannot decode the zstd body: bytes follow the compressed data" },
    { body = "z", trouble = "http: cannot decode the zstd body: compress: not a zstd stream" },
    -- The first byte of the magic alone, shorter than any frame.
    { body = "\40", trouble = "http: cannot decode the zstd body: compress: truncated zstd stream" },
  }
  for _, case in ipairs(cases) do
    local response = assert(Http.open(url, { timeout_ns = Clock.seconds(60), decompress = true,
      script = { reply("200 OK", "Content-Encoding: zstd\r\n", case.body) } }))
    local trouble: string
    while true do
      local chunk, why = response:read()
      if chunk == nil then
        trouble = tostring(why)
        break
      end
    end
    assert(trouble == case.trouble, trouble)
    -- And again: a failed body stays failed.
    local again, why = response:read()
    assert(again == nil and tostring(why) == case.trouble, why)
    local _, _ = response:close()
  end
end

local function test_decompress_fails_a_one_byte_deflate_body_without_raising()
  local bodies: {string} = { "x", "\8" }
  for _, body in ipairs(bodies) do
    local response = assert(Http.open(url, { timeout_ns = Clock.seconds(60), decompress = true,
      script = { reply("200 OK", "Content-Encoding: deflate\r\n", body) } }))
    local chunk, why = response:read()
    while chunk ~= nil do chunk, why = response:read() end
    assert(tostring(why):find("^http: cannot decode the deflate body: ") ~= nil, why)
    local _, _ = response:close()
  end
end

local function test_decompress_reads_an_empty_body_as_empty()
  local response, body = fetch({
    "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n",
  }, { timeout_ns = Clock.seconds(60), method = "HEAD", decompress = true })
  assert(response.status == 200 and body == "", body)
  local _, none = fetch({ reply("204 No Content", "Content-Encoding: zstd\r\n") }, { timeout_ns = Clock.seconds(60), decompress = true })
  assert(none == "", none)
end

local function test_decompress_gives_a_bomb_out_in_pieces_no_larger_than_asked()
  local plain = string.rep("\0", 4 << 20)
  local response = assert(Http.open(url, { timeout_ns = Clock.seconds(60), decompress = true,
    script = { reply("200 OK", "Content-Encoding: zstd\r\n", encoded("zstd", plain)) } }))
  local total = 0
  while true do
    local chunk, trouble = response:read(4096)
    assert(chunk ~= nil, tostring(trouble))
    if chunk == false then
      break
    end
    assert(#chunk <= 4096, tostring(#chunk))
    total = total + #chunk
  end
  local _, _ = response:close()
  assert(total == #plain, tostring(total))
end

local function test_request_and_download_decompress_too(tmp: string)
  local plain = string.rep("downloaded and decoded ", 100)
  local script = { reply("200 OK", "Content-Encoding: gzip\r\n", encoded("gzip", plain)) }
  local got = assert(Http.get(url, { timeout_ns = Clock.seconds(60), decompress = true, script = script }))
  assert(got.body == plain)
  local path = tmp .. "/decoded"
  assert(Http.download(url, path, { timeout_ns = Clock.seconds(60), decompress = true, digests = { ["sha256"] = Hash.hex_sha256(plain) }, script = script }))
  assert(assert(Fs.read(path)) == plain)
end

--- A `false` where a method is wanted is a method that is not GET, not an
--- absent one: both raise as any other method does.
local function test_a_method_that_is_false_is_refused_not_taken_for_none()
  local script = { reply("200 OK", "") }
  local opts = { method = false, script = script } as any as Http.Options -- checked: cast_refused*2
  local ok, why = pcall(function() local _, _ = Http.get(url, opts) end)
  assert(not ok and tostring(why):find("Http.request", 1, true) ~= nil, tostring(why))
  ok, why = pcall(function() local _, _ = Http.request("PUT", url, opts) end)
  assert(not ok and tostring(why):find("leave opts.method out", 1, true) ~= nil, tostring(why))
end

--- Request headers for the redirect tests: six that may be credentials,
--- each value holding "secret-", and two that describe the request.
local CREDENTIALS <const>: {string:string} = {
  Authorization = "Bearer secret-a", Cookie = "id=secret-c", ["Proxy-Authorization"] = "Basic secret-p",
  ["X-Api-Key"] = "secret-k", Signature = "secret-s", DPoP = "secret-d",
  Accept = "application/json", ["If-None-Match"] = "\"v1\"",
}

--- What curl sent to the hop whose request line starts with `line`:
--- from that line to the blank line that ends its head.
local function hop(sent: string, line: string): string
  local at = assert(sent:find(line, 1, true), sent)
  local after = sent:find("\r\n\r\n", at, true) or #sent
  return sent:sub(at, after + 1)
end

--- Whether `head` holds every header of [`CREDENTIALS`] that describes
--- the request and none that may be a credential.
local function stripped(head: string): boolean
  return head:find("secret-", 1, true) == nil and
    head:find("\r\nAccept: application/json\r\n", 1, true) ~= nil and
    head:find("\r\nIf-None-Match: \"v1\"\r\n", 1, true) ~= nil
end

--- A redirect to another origin -- another host or port, scheme-relative,
--- IPv6, or naming the first host as user info -- drops every header but
--- those that describe the request from that hop on, a hop back to the
--- first origin included; curl alone drops only Authorization and
--- Cookie, and sends them again there.
local function test_a_redirect_to_another_origin_drops_credentials()
  for _, target in ipairs({ "http://other.test/next", "http://cosmic.test:8080/next", "//other.test/next",
      "http://[::1]/next", "http://cosmic.test@other.test/next" }) do
    local response, _, sent = fetch({
      reply("302 Found", "Location: " .. target .. "\r\n"),
      reply("302 Found", "Location: http://cosmic.test/back\r\n"),
      reply("200 OK", "", "done"),
    }, { timeout_ns = Clock.seconds(60), headers = CREDENTIALS })
    assert(response.status == 200, tostring(response.status))
    local first = hop(sent, "GET / HTTP/1.1")
    assert(count(first, "secret-") == 6, first)
    for _, line in ipairs({ "GET /next HTTP/1.1", "GET /back HTTP/1.1" }) do
      local later = hop(sent, line)
      assert(stripped(later), target .. ": " .. later)
    end
  end
end

--- Two hops: one within the origin keeps every header, the next, to
--- another, drops them.
local function test_a_second_redirect_that_leaves_the_origin_drops_credentials()
  local _, _, sent = fetch({
    reply("302 Found", "Location: /middle\r\n"),
    reply("302 Found", "Location: http://other.test/last\r\n"),
    reply("200 OK", "", "done"),
  }, { timeout_ns = Clock.seconds(60), headers = CREDENTIALS })
  local middle = hop(sent, "GET /middle HTTP/1.1")
  assert(count(middle, "secret-") == 6, middle)
  local last = hop(sent, "GET /last HTTP/1.1")
  assert(stripped(last), last)
end

--- A redirect within the origin, relative or naming it in another case
--- and with its default port, keeps every header.
local function test_a_redirect_within_the_origin_keeps_credentials()
  for _, target in ipairs({ "/next", "http://COSMIC.test:80/next" }) do
    local _, _, sent = fetch({
      reply("302 Found", "Location: " .. target .. "\r\n"),
      reply("200 OK", "", "done"),
    }, { timeout_ns = Clock.seconds(60), headers = CREDENTIALS })
    local later = hop(sent, "GET /next HTTP/1.1")
    assert(count(later, "secret-") == 6, target .. ": " .. later)
  end
end

--- A redirect to another origin that would send the request's body
--- again -- a 307 or a 308, or a 301 or 302 after a method curl keeps
--- the body for -- fails the request before that hop; one within the
--- origin sends it, and one that turns the request into a GET sends none.
local function test_a_redirect_to_another_origin_never_sends_the_body_there()
  local function to(status: string, location: string, method: string): Http.Response?, string, string
    local response, why = Http.open(url, { timeout_ns = Clock.seconds(60), method = method, body = "secret-body",
      script = { reply(status, "Location: " .. location .. "\r\n"), reply("200 OK", "", "done") } })
    if response == nil then return nil, tostring(why), "" end
    while true do
      local chunk, trouble = response:read()
      assert(chunk ~= nil, tostring(trouble))
      if chunk == false then
        break
      end
    end
    local sent = response:sent()
    local _, _ = response:close()
    return response, "", sent
  end
  for _, case in ipairs({ { "307 Temporary Redirect", "POST" }, { "308 Permanent Redirect", "POST" },
      { "302 Found", "PUT" }, { "301 Moved Permanently", "PATCH" }, { "307 Temporary Redirect", "PUT" } }) do
    local status, method = assert(case[1]), assert(case[2])
    local response, why = to(status, "http://other.test/next", method)
    assert(response == nil and why:find("another origin would send the request's body", 1, true) ~= nil,
      status .. " " .. method .. ": " .. tostring(why))
  end
  local kept, _, sent = to("307 Temporary Redirect", "/next", "POST")
  assert(kept ~= nil and kept.status == 200)
  local again = assert((sent:find("POST /next HTTP/1.1", 1, true)))
  assert(count(sent:sub(again), "secret-body") == 1, sent)
  local turned, _, after = to("303 See Other", "http://other.test/next", "POST")
  assert(turned ~= nil and turned.status == 200)
  local turned_at = assert((after:find("GET /next HTTP/1.1", 1, true)))
  assert(count(after:sub(turned_at), "secret-body") == 0, after)
  -- Once a 303 has made it a GET, a later 307 has no body to send.
  local through = assert(Http.open(url, { timeout_ns = Clock.seconds(60), method = "POST", body = "secret-body",
    script = { reply("303 See Other", "Location: /a\r\n"), reply("307 Temporary Redirect",
      "Location: http://other.test/n\r\n"), reply("200 OK", "", "done") } }))
  assert(through.status == 200)
  local _, _ = through:close()
end

--- A body longer than `max_bytes` fails the request: at once when its
--- Content-Length says so, else once the byte past the limit arrives.
local function test_a_body_over_max_bytes_fails_the_request()
  local script = { reply("200 OK", "", "hello") }
  local got, why = Http.request("GET", url, { timeout_ns = Clock.seconds(60), max_bytes = 4, script = script })
  assert(got == nil and tostring(why) == "http: the body is longer than opts.max_bytes, 4 bytes", why)
  local chunked = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n" ..
    "3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n"
  got, why = Http.get(url, { timeout_ns = Clock.seconds(60), max_bytes = 5, script = { chunked } })
  assert(got == nil and tostring(why) == "http: the body is longer than opts.max_bytes, 5 bytes", why)
  got, why = Http.get(url, { timeout_ns = Clock.seconds(60), max_bytes = 6, script = { chunked } })
  assert(got ~= nil and got.body == "abcdef", why)
  got, why = Http.get(url, { timeout_ns = Clock.seconds(60), max_bytes = 5, script = script })
  assert(got ~= nil and got.body == "hello", why)
end

--- With no `max_bytes`, a body over 16 MiB is refused: this one only says
--- it is, and is refused before a byte of it is awaited.
local function test_a_body_over_the_default_limit_is_refused_unread()
  local head = "HTTP/1.1 200 OK\r\nContent-Length: " .. tostring((16 << 20) + 1) .. "\r\nConnection: close\r\n\r\n"
  local got, why = Http.get(url, { timeout_ns = Clock.seconds(60), script = { head } })
  assert(got == nil and tostring(why) == "http: the body is longer than opts.max_bytes, 16777216 bytes", why)
end

--- The decoded bytes count against `max_bytes`, not the compressed ones.
local function test_max_bytes_counts_the_decoded_body()
  local plain = string.rep("a", 1000)
  local script = { reply("200 OK", "Content-Encoding: gzip\r\n", encoded("gzip", plain)) }
  local got, why = Http.get(url, { timeout_ns = Clock.seconds(60), decompress = true, max_bytes = 999, script = script })
  assert(got == nil and tostring(why):find("max_bytes", 1, true) ~= nil, why)
  got, why = Http.get(url, { timeout_ns = Clock.seconds(60), decompress = true, max_bytes = 1000, script = script })
  assert(got ~= nil and got.body == plain, why)
end

local function test_max_bytes_takes_an_integer_of_at_least_0()
  local ok, why = pcall(function()
    local _, _ = Http.get(url, { timeout_ns = Clock.seconds(60), max_bytes = -1, script = { reply("200 OK", "") } })
  end)
  assert(not ok and tostring(why):find("opts.max_bytes must be an integer", 1, true) ~= nil, tostring(why))
end

--- A Content-Length that names no body sent -- a HEAD's, a 204's, a
--- 304's -- refuses nothing, however large.
local function test_a_bodiless_response_is_not_refused_for_its_content_length()
  local large = "Content-Length: 20000000\r\nConnection: close\r\n\r\n"
  local got, why = Http.request("HEAD", url, { timeout_ns = Clock.seconds(60), script = { "HTTP/1.1 200 OK\r\n" .. large } })
  assert(got ~= nil and got.status == 200 and got.body == "", why)
  for _, status in ipairs({ "204 No Content", "304 Not Modified" }) do
    got, why = Http.get(url, { timeout_ns = Clock.seconds(60), script = { "HTTP/1.1 " .. status .. "\r\n" .. large } })
    assert(got ~= nil and got.body == "", status .. ": " .. tostring(why))
  end
end
