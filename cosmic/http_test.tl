--- Coverage for cosmic.http without the network: option and URL
--- validation, a connection refused on a closed local port, and every
--- response-handling case through the scripted transport
--- (`Options.script`), where each connection curl opens reads a canned
--- reply and records what curl sent.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

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

local function test_open_returns_once_the_headers_arrive_before_any_body()
  -- The headers come, the body never does. `open` used to wait for the
  -- first body byte, so it failed here (and, on a live server that
  -- stalls after its headers, tripped the low-speed limit) though the
  -- response's headers had arrived.
  local response, trouble = Http.open(url, { script = {
    "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nX-Here: yes\r\n\r\n",
  } })
  assert(response ~= nil, trouble)
  assert(response.status == 200 and response.headers["x-here"] == "yes")
  local chunk, read_trouble = response:read()
  assert(chunk == nil and read_trouble ~= "", "a missing body is a read error")
  -- curl's message, with no newline left on the end of it
  assert(read_trouble:find("%s$") == nil, "[" .. read_trouble .. "]")
  response:close()
end

local function test_open_waits_past_a_followed_redirect_for_the_final_headers()
  local response = assert(Http.open(url, { script = {
    "HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n",
  } }))
  assert(response.status == 200, tostring(response.status))
  assert(response.url:find("/next", 1, true) ~= nil, response.url)
  response:close()
end

local function test_a_url_with_a_nul_byte_is_refused()
  -- curl reads the URL as a C string, which would stop at the NUL
  local response, trouble = Http.open(url .. "\0.evil/", { script = {} })
  assert(response == nil and trouble:find("NUL", 1, true) ~= nil, trouble)
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

--- A TLS 1.2 server's first flight, as a script can send it: a
--- ServerHello choosing ECDHE-RSA with AES-128-GCM, then its
--- Certificate message holding `der` alone. The client verifies the
--- certificate the moment it reads the message, so nothing more of the
--- handshake is needed to see what it made of it.
local function first_flight(der: string): string
  local function message(kind: integer, body: string): string
    return string.char(kind) .. string.pack(">I3", #body) .. body
  end
  local hello = message(2, "\3\3" .. string.rep("B", 32) .. "\0" .. "\192\47" .. "\0")
  local certificate = message(11, string.pack(">I3", #der + 3) .. string.pack(">I3", #der) .. der)
  local records = hello .. certificate
  return "\22\3\3" .. string.pack(">I2", #records) .. records
end

--- A root the binary's own database carries (`ca_roots`), as DER.
local function carried_root(label: string): string
  local databases = Store.databases()
  local rows = assert(Sqlite.text_rows(databases[#databases],
    "SELECT hex(der) FROM ca_roots WHERE label = ?1", { { text = label } }))
  assert(#rows == 1, label .. " is not among the binary's CA roots")
  return (assert(Codec.unhex(rows[1][1])))
end

--- An https connection is verified against the CA roots the binary's
--- own database carries (core/http.c's `use_roots`): a server
--- presenting one of them is trusted -- and refused only because the
--- root names another host -- while the same certificate with its
--- signature broken is not.
local function test_an_https_peer_is_verified_against_the_carried_roots()
  local root = carried_root("ISRG Root X1")
  local _, trusted = Http.open("https://cosmic.test/", { script = { first_flight(root) } })
  assert(trusted:find("Common Name", 1, true), trusted)
  assert(not trusted:find("not correctly signed", 1, true),
    "a carried root is not trusted: " .. trusted)
  local broken = root:sub(1, -2) .. string.char(root:byte(-1) ~ 1)
  local _, refused = Http.open("https://cosmic.test/", { script = { first_flight(broken) } })
  assert(refused:find("not correctly signed by the trusted CA", 1, true), refused)
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

-- curl reads a method, header name and header value as C strings: a NUL
-- used to cut each short, so `X-A: v1` went out for "v1\0INJECT" and a
-- plain GET for "GET\0junk". Each is refused before any connection.
local function test_a_header_value_with_a_nul_is_rejected()
  local response, trouble = Http.open(url,
    { headers = { ["X-A"] = "v1\0INJECT" }, script = { reply("200 OK", "") } })
  assert(response == nil)
  assert(trouble:find("invalid header X-A", 1, true) ~= nil, trouble)
  assert(trouble:find("NUL", 1, true) ~= nil, trouble)
end

local function test_a_header_name_with_a_nul_is_rejected()
  local response, trouble = Http.open(url,
    { headers = { ["X-A\0junk"] = "v" }, script = { reply("200 OK", "") } })
  assert(response == nil)
  assert(trouble:find("invalid header X-A\0junk", 1, true) ~= nil, trouble)
  assert(trouble:find("NUL", 1, true) ~= nil, trouble)
end

local function test_a_method_with_a_nul_is_refused()
  local response, trouble = Http.open(url,
    { method = "GET\0junk", script = { reply("200 OK", "") } })
  assert(response == nil)
  assert(trouble:find("method", 1, true) ~= nil, trouble)
end

--- The message `Http.open` raises with for `opts`.
local function raised(opts: Http.Options): string
  opts.script = opts.script or {}
  local ok, err = pcall(Http.open, url, opts)
  assert(not ok, "expected a raise")
  return tostring(err)
end

local function test_an_integer_option_takes_no_numeric_string()
  local err = raised({ timeout_ms = "5" as integer })
  assert(err:find("opts.timeout_ms must be an integer", 1, true) ~= nil, err)
end

local function test_an_integer_option_takes_no_fraction()
  local err = raised({ connect_timeout_ms = 1.5 as integer })
  assert(err:find("opts.connect_timeout_ms must be an integer", 1, true) ~= nil, err)
end

local function test_a_negative_timeout_is_refused_not_ignored()
  -- curl refused -5 and kept its default: no timeout at all
  local err = raised({ timeout_ms = -5 })
  assert(err:find("opts.timeout_ms must be between 0 and", 1, true) ~= nil, err)
end

local function test_an_integer_option_curl_would_clamp_is_refused()
  local err = raised({ max_redirects = 40000 })
  assert(err:find("opts.max_redirects must be between 0 and 32767", 1, true) ~= nil, err)
  err = raised({ low_speed_seconds = 70000 })
  assert(err:find("opts.low_speed_seconds must be between 0 and 65535", 1, true) ~= nil, err)
end

local function test_zero_integer_options_are_accepted()
  local response, body = fetch({ reply("200 OK", "", "ok") }, { timeout_ms = 0,
    max_redirects = 0, low_speed_bytes = 0, low_speed_seconds = 0 })
  assert(response.status == 200 and body == "ok")
end

local function test_a_boolean_option_takes_only_a_boolean()
  local err = raised({ follow = "no" as boolean })
  assert(err:find("opts.follow must be a boolean", 1, true) ~= nil, err)
end

local function test_non_table_headers_raise_naming_the_option()
  -- used to be "bad extra argument #-1 to 'open'"
  local err = raised({ headers = "X-A: 1" as {string:string} })
  assert(err:find("opts.headers must be a table", 1, true) ~= nil, err)
  assert(err:find("#-1", 1, true) == nil, err)
end

local function test_a_non_string_script_entry_raises()
  -- used to become an empty reply
  local err = raised({ script = { reply("200 OK", ""), 42 as string } })
  assert(err:find("opts.script must be a list of strings", 1, true) ~= nil, err)
end

local function test_an_option_curl_refuses_is_an_error_naming_it()
  -- curl refuses a string option over 8 MB; the refusal used to be
  -- ignored, and the request went ahead with no URL set at all
  local response, trouble = Http.open(url .. string.rep("a", 8000000), { script = {} })
  assert(response == nil)
  assert(trouble:find("CURLOPT_URL", 1, true) ~= nil, trouble)
end

local function test_read_returns_an_empty_second_value_on_success()
  local response, opened = Http.open(url, { script = { reply("200 OK", "", "body") } })
  assert(response ~= nil and opened == "", opened)
  local chunk, trouble = response:read()
  assert(chunk == "body" and trouble == "", tostring(trouble))
  local after, end_trouble = response:read()
  assert(after == nil and end_trouble == "")
  response:close()
end

local function test_a_close_variable_closes_the_response()
  local kept: Http.Response
  do
    local response <close> = assert(Http.open(url, { script = { reply("200 OK", "", "x") } }))
    kept = response
  end
  local ok, err = pcall(kept.read, kept)
  assert(not ok and tostring(err):find("closed", 1, true) ~= nil, tostring(err))
  kept:close() -- closing again is harmless
end

local revived: {Http.Response} = {}

local function test_a_response_a_finalizer_revives_is_closed()
  -- The table's finalizer runs in the same collection as the handle's
  -- and brings the response back after the handle released its curl
  -- state: every method has to see a closed handle, not freed memory.
  do
    local response = assert(Http.open(url, { script = { reply("200 OK", "", "x") } }))
    local mt: metatable<{any:any}> = { __gc = function(_: {any:any})
      revived[1] = response
    end }
    setmetatable({} as {any:any}, mt)
  end
  collectgarbage()
  collectgarbage()
  local response = revived[1]
  assert(response ~= nil, "the finalizer ran")
  revived[1] = nil
  local ok, err = pcall(response.read, response)
  assert(not ok and tostring(err):find("closed", 1, true) ~= nil, tostring(err))
  ok, err = pcall(response.sent, response)
  assert(not ok and tostring(err):find("closed", 1, true) ~= nil, tostring(err))
  response:close()
end

--- The raw handle's close answers nothing: it cannot fail, so a `true`
--- would tell its caller nothing.
local function test_the_raw_handle_close_returns_no_values()
  -- The raw module is handed only to cosmic.http's own loader, as the
  -- store's searcher's second answer; asking the searcher by hand gets it.
  local raw: {string: function(string, {string: any}): any, string} = nil
  for _, searcher in ipairs(package.searchers as {function(string): any, any}) do
    local loader, extra = searcher("cosmic.http")
    if type(loader) == "function" and type(extra) == "table"
        and (extra as {string: any}).open ~= nil then
      raw = extra as {string: function(string, {string: any}): any, string}
    end
  end
  assert(raw ~= nil, "no searcher handed over the raw module")
  local handle = assert(raw.open(url, { script = { reply("200 OK", "", "body") } }))
    as {string: function(any): any...}
  assert(select("#", handle.close(handle)) == 0, "close returns no values")
  assert(select("#", handle.close(handle)) == 0, "closing twice returns no values")
end
