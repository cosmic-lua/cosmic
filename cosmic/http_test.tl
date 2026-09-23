--- Coverage for cosmic.http without the network: option and URL
--- validation, a connection refused on a closed local port, and every
--- response-handling case through the scripted transport
--- (`Options.script`), where each connection curl opens reads a canned
--- reply and records what curl sent.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")

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
  opts = opts or {}
  opts.script = script
  local response = assert(Http.open(url, opts))
  local parts: {string} = {}
  while true do
    local chunk, trouble = response:read()
    if chunk == nil then
      assert(trouble == "", trouble)
      break
    end
    parts[#parts + 1] = chunk
  end
  local sent = response:sent()
  response:close()
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
    { follow = false })
  assert(response.status == 302)
  assert(body == "moved")
  assert(response.headers["location"] == "/next")
end

local function test_a_303_after_post_is_followed_with_get()
  local response, body, sent = fetch({
    reply("303 See Other", "Location: /done\r\n"),
    reply("200 OK", "", "got"),
  }, { method = "POST", body = "payload" })
  assert(response.status == 200 and body == "got")
  assert(sent:find("POST / HTTP/1.1\r\n", 1, true) == 1, sent)
  assert(sent:find("GET /done HTTP/1.1\r\n", 1, true) ~= nil, sent)
  assert(count(sent, "payload") == 1, sent)
end

local function test_a_307_after_post_repeats_the_post_and_its_body()
  local response, _, sent = fetch({
    reply("307 Temporary Redirect", "Location: /again\r\n"),
    reply("200 OK", "", "ok"),
  }, { method = "POST", body = "payload" })
  assert(response.status == 200)
  assert(sent:find("POST /again HTTP/1.1\r\n", 1, true) ~= nil, sent)
  assert(count(sent, "payload") == 2, sent)
end

local function test_a_custom_method_is_sent_as_is()
  local _, _, sent = fetch({ reply("204 No Content", "") }, { method = "PUT", body = "x" })
  assert(sent:find("PUT / HTTP/1.1\r\n", 1, true) == 1, sent)
end

local function test_a_method_that_is_no_token_is_refused()
  local response, trouble = Http.open(url, { method = "GET / HTTP/1.1\r\nX-Evil: 1\r\n", script = {} })
  assert(response == nil)
  assert(trouble:find("method", 1, true) ~= nil, trouble)
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
  }, { method = "HEAD" })
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
  local response = assert(Http.open(url, { script = {
    "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nonly ten b",
  } }))
  local chunk = response:read()
  assert(chunk == "only ten b")
  local after, trouble = response:read()
  assert(after == nil)
  assert(trouble ~= "", "a truncated body is an error, not a clean end")
  response:close()
  local got, get_trouble = Http.get(url, { script = {
    "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nonly ten b",
  } })
  assert(got == nil and get_trouble ~= "")
end

-- A pattern no two nearby offsets share, so a byte out of place shows.
local function big(size: integer): string
  local parts: {string} = {}
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
  local first = assert(Http.open(url, { script = { reply("200 OK", "", data) } }))
  local second = assert(Http.open(url, { script = { reply("200 OK", "", data) } }))
  for _, response in ipairs({ second, first }) do
    local parts: {string} = {}
    while true do
      local chunk, trouble = response:read(1 << 20)
      if chunk == nil then
        assert(trouble == "", trouble)
        break
      end
      parts[#parts + 1] = chunk
    end
    assert(table.concat(parts) == data)
    response:close()
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
  local opts: Http.Options = { method = "POST", body = string.rep("A", size),
    headers = { Expect = "" }, script = { "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" } }
  local response = assert(Http.open(url, opts))
  opts = nil
  collectgarbage()
  collectgarbage()
  local churn: {string} = {}
  for i = 1, 4 do
    churn[i] = string.rep(string.char(65 + i), size)
  end
  assert(response:read() == "ok")
  local after, trouble = response:read()
  assert(after == nil and trouble == "", trouble)
  local sent = response:sent()
  response:close()
  assert(#sent > size)
  assert(sent:sub(-size) == string.rep("A", size), "the body arrived intact")
end

local function test_a_script_without_enough_connections_fails_cleanly()
  local response, trouble = Http.open(url, { script = {} })
  assert(response == nil)
  assert(trouble ~= "")
end

local function test_a_non_string_option_throws()
  local ok = pcall(Http.open, url, { body = {} as string, script = {} })
  assert(not ok)
  ok = pcall(Http.open, url, { headers = { X = 1 as string }, script = {} })
  assert(not ok)
  ok = pcall(Http.open, url, { headers = { [1 as string] = "x" }, script = {} })
  assert(not ok)
end

local function test_a_malformed_url_fails()
  -- No host at all: curl rejects this outright (CURLE_URL_MALFORMAT),
  -- with no network access attempted -- unlike a bare "example.com/"
  -- with no scheme, which curl happily guesses "http://" onto and
  -- would actually try to reach.
  local response, trouble = Http.open("http:///no-host-here")
  assert(response == nil)
  assert(trouble ~= "")
end

local function test_an_unsupported_scheme_fails()
  local response, trouble = Http.open("ftp://example.com/")
  assert(response == nil)
  assert(trouble ~= "")
end

local function test_connection_refused_on_a_closed_local_port()
  -- Port 1 is the classic "closed, and never going to be listening"
  -- probe port; nothing here binds it, and it is not a privileged
  -- range issue since we are only connecting, not binding.
  local response, trouble = Http.open("http://127.0.0.1:1/",
    { connect_timeout_ms = 2000 })
  assert(response == nil)
  assert(trouble ~= "")
  assert(trouble:lower():find("refus", 1, true) ~= nil or
    trouble:lower():find("connect", 1, true) ~= nil, trouble)
end

local function test_get_reports_the_same_failure_as_open()
  local got, trouble = Http.get("http://127.0.0.1:1/",
    { connect_timeout_ms = 2000 })
  assert(got == nil)
  assert(trouble ~= "")
end

local function test_download_writes_verifies_and_renames(tmp: string)
  local path = tmp .. "/got"
  local data = "downloaded bytes"
  local ok, trouble = Http.download(url, path, { sha256 = Hash.hex_sha256(data),
    script = { reply("200 OK", "", data) } })
  assert(ok, trouble)
  assert(Fs.read(path) == data)
  local names = assert(Fs.list(tmp))
  assert(#names == 1 and names[1] == "got", "a temporary file was left behind")
end

local function test_download_never_writes_through_a_planted_part_file(tmp: string)
  -- it used to open path .. ".part" with O_TRUNC, following a symlink
  -- someone else put there, and sharing it with a concurrent download
  local path = tmp .. "/got"
  assert(Fs.write(tmp .. "/victim", "keep me"))
  assert(Fs.symlink(tmp .. "/victim", path .. ".part"))
  local ok, trouble = Http.download(url, path, { script = { reply("200 OK", "", "fresh") } })
  assert(ok, trouble)
  assert(Fs.read(path) == "fresh")
  assert(Fs.read(tmp .. "/victim") == "keep me")
end

local function test_download_removes_its_temporary_file_on_a_mismatch(tmp: string)
  local path = tmp .. "/bad"
  local ok, trouble = Http.download(url, path, { sha256 = string.rep("0", 64),
    script = { reply("200 OK", "", "not what was promised") } })
  assert(not ok)
  assert(trouble:find("mismatch", 1, true) ~= nil, trouble)
  assert(not Fs.exists(path) and #assert(Fs.list(tmp)) == 0)
end

local function test_download_removes_its_temporary_file_on_a_truncated_body(tmp: string)
  local path = tmp .. "/short"
  local ok = Http.download(url, path, { script = {
    "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nonly ten b",
  } })
  assert(not ok)
  assert(not Fs.exists(path) and #assert(Fs.list(tmp)) == 0)
end

local function test_download_fails_on_a_non_2xx_status(tmp: string)
  local ok, trouble = Http.download(url, tmp .. "/missing", { script = {
    reply("404 Not Found", "", "no"),
  } })
  assert(not ok)
  assert(trouble:find("404", 1, true) ~= nil, trouble)
end

local function test_download_reports_the_same_failure_as_open(tmp: string)
  local ok, trouble = Http.download("http://127.0.0.1:1/", tmp .. "/unreached",
    { connect_timeout_ms = 2000 })
  assert(not ok)
  assert(trouble ~= "")
end

-- A header name or value carrying CR or LF could otherwise smuggle a
-- second header, or even a whole extra request, past curl and onto the
-- wire (CRLF/header injection). This is caught before any connection
-- is attempted: the script offers none, so a request that got that far
-- would fail for a different reason.
local function test_a_header_value_with_crlf_is_rejected()
  local response, trouble = Http.open(url,
    { headers = { ["X-Evil"] = "value\r\nX-Injected: yes" }, script = {} })
  assert(response == nil)
  assert(trouble:lower():find("cr or lf", 1, true) ~= nil, trouble)
end

local function test_a_header_value_with_a_bare_lf_is_rejected()
  local response, trouble = Http.open(url,
    { headers = { ["X-Evil"] = "value\nX-Injected: yes" }, script = {} })
  assert(response == nil)
  assert(trouble:find("invalid header", 1, true) ~= nil, trouble)
end

local function test_a_header_name_with_crlf_is_rejected()
  local response, trouble = Http.open(url,
    { headers = { ["X-Evil\r\nX-Injected"] = "yes" }, script = {} })
  assert(response == nil)
  assert(trouble:find("invalid header", 1, true) ~= nil, trouble)
end

local function test_a_header_name_with_a_colon_is_rejected()
  local response, trouble = Http.open(url,
    { headers = { ["X-Evil: yes\r\nX-Injected"] = "yes" }, script = {} })
  assert(response == nil)
  assert(trouble:find("invalid header", 1, true) ~= nil, trouble)
end

local function test_an_empty_header_name_is_rejected()
  local response, trouble = Http.open(url,
    { headers = { [""] = "yes" }, script = {} })
  assert(response == nil)
  assert(trouble:find("invalid header", 1, true) ~= nil, trouble)
end

local function test_an_ordinary_header_is_sent()
  local _, _, sent = fetch({ reply("200 OK", "") },
    { headers = { ["X-Fine"] = "a normal value" } })
  assert(sent:find("\r\nX-Fine: a normal value\r\n", 1, true) ~= nil, sent)
end
