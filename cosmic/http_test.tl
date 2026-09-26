--- Coverage for cosmic.http without the network: option and URL
--- validation, a connection refused on a closed local port, and every
--- response-handling case through the scripted transport
--- (`Options.script`), where each connection curl opens reads a canned
--- reply and records what curl sent.

local Child = require("cosmic.child")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")
local type Declared = require("build.inputs").Declared

--- Requests to a closed local port, and to a host that names none.
local _inputs: Declared = { network = { "127.0.0.1", "no-host-here" } }

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

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
  -- The carried roots may be what is stale: the failure says how to get
  -- newer ones.
  assert(refused:find("`cosmic refresh cacert --binary <this program> -o <copy>`", 1, true), refused)
  assert(not trusted:find("cosmic refresh", 1, true), trusted)
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

--- What a fresh process, $SSL_CERT_FILE naming `cert_file`, is told
--- when it opens a closed local port: the roots, that file's included,
--- are loaded once per process, at its first request.
local function refused_with_cert_file(tmp: string, cert_file: string): string
  local script = tmp .. "/open.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local _, trouble = Http.open("http://127.0.0.1:1/", { connect_timeout_ms = 2000 })
Fs.put(Fs.stdout, trouble or "")
]]))
  local result = assert(Child.run({ assert(Proc.executable()), "--standalone", script },
    { env = { SSL_CERT_FILE = cert_file, XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(result.code == 0, tostring(result.stderr))
  return result.stdout or ""
end

--- $SSL_CERT_FILE naming what holds no certificates -- a directory, a
--- named pipe, or a file of anything else -- adds none and refuses
--- nothing: a request fails as it would without it. A directory's size,
--- as seeking to its end tells it, once asked for more memory than there
--- was, refusing every request; a pipe, opened without O_NONBLOCK, waited
--- for a writer forever.
local function test_a_cert_file_holding_no_certificates_is_passed_over(tmp: string)
  local junk = tmp .. "/junk.pem"
  assert(Fs.write(junk, "no certificate here\n"))
  local pipe = tmp .. "/pipe.pem"
  assert(sys.mkfifo(pipe))
  for _, cert_file in ipairs({ tmp, junk, pipe, tmp .. "/missing.pem" }) do
    local trouble = refused_with_cert_file(tmp, cert_file)
    assert(not trouble:find("SSL_CERT_FILE", 1, true), cert_file .. ": " .. trouble)
    assert(trouble:lower():find("connect", 1, true) ~= nil, cert_file .. ": " .. trouble)
  end
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
  local chunk, trouble = kept:read()
  assert(chunk == nil and trouble:find("closed", 1, true) ~= nil, trouble)
  local again, again_trouble = kept:close() -- closing again is harmless
  assert(again and again_trouble == "")
end

--- A response is a `cosmic.stream` Reader: what takes a file's Reader
--- takes a body the same way.
local function test_a_response_is_a_stream_reader()
  local body = string.rep("0123456789", 10000)
  local response = assert(Http.open(url, { script = { reply("200 OK", "", body) } }))
  local reader: Stream.Reader = response
  local head = assert(Stream.read_exact(reader, 10))
  assert(head == "0123456789")
  local rest = Stream.collect()
  assert(assert(Stream.copy(reader, rest)) == #body - 10)
  assert(rest:result() == body:sub(11))
  assert(reader:close())
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

--- Every root this binary carries reads as a certificate; a DER
--- sequence that is none, and bytes that are no DER at all, do not,
--- and say why.
local function test_check_certificate_reads_what_the_binary_trusts()
  local databases = Store.databases()
  local roots = assert(Sqlite.rows(databases[#databases], "SELECT der, label FROM ca_roots"))
  assert(#roots > 0)
  for _, row in ipairs(roots) do
    local ok, why = Http.check_certificate(row[1].blob)
    assert(ok and why == "", row[2].text .. ": " .. why)
  end
  for _, der in ipairs({ "", "\x30\x03abc", "not der" }) do
    local ok, why = Http.check_certificate(der)
    assert(not ok and why ~= "", Codec.hex(der))
  end
end

--- A whole reply that leaves the connection open: a scripted reply
--- arrives before curl has sent the request, and one that closes the
--- connection would end an upload's body there.
local function kept_open(status: string, body: string): string
  return "HTTP/1.1 " .. status .. "\r\nContent-Length: " .. tostring(#body) ..
    "\r\n\r\n" .. body
end

--- Writes each of `chunks` to an upload over `script`, then answers
--- its response (whole body read, closed), that body, and what curl
--- sent.
local function upload(script: {string}, chunks: {string}, opts?: Http.Options):
    Http.Response, string, string
  opts = opts or {}
  opts.script = script
  local up = assert(Http.upload(url, opts))
  for _, chunk in ipairs(chunks) do assert(up:write(chunk)) end
  assert(up:close())
  local response = assert(up:response())
  local body = assert(Stream.read_all(response))
  local sent = response:sent()
  assert(response:close())
  return response, body, sent
end

--- A body of no given size goes chunked, a chunk per write, with no
--- `Expect: 100-continue` to wait on.
local function test_an_upload_sends_its_writes_chunked()
  local response, body, sent = upload({ kept_open("200 OK", "done") },
    { "hello, ", "cosmic!" })
  assert(response.status == 200 and body == "done")
  assert(sent:find("POST / HTTP/1.1\r\n", 1, true) == 1, sent)
  assert(sent:find("\r\nTransfer-Encoding: chunked\r\n", 1, true) ~= nil, sent)
  assert(sent:find("Expect:", 1, true) == nil, sent)
  assert(sent:find("\r\n\r\n7\r\nhello, \r\n7\r\ncosmic!\r\n0\r\n\r\n", 1, true) ~= nil, sent)
end

--- A given size is the Content-Length, and the body goes as written.
local function test_an_upload_of_a_given_size_sends_a_content_length()
  local _, _, sent = upload({ kept_open("201 Created", "") }, { "hello, ", "cosmic!" },
    { method = "PUT", body_size = 14, headers = { ["Content-Type"] = "text/plain" } })
  assert(sent:find("PUT / HTTP/1.1\r\n", 1, true) == 1, sent)
  assert(sent:find("\r\nContent-Length: 14\r\n", 1, true) ~= nil, sent)
  assert(sent:find("\r\nContent-Type: text/plain\r\n", 1, true) ~= nil, sent)
  assert(sent:find("chunked", 1, true) == nil, sent)
  assert(sent:sub(-18) == "\r\n\r\nhello, cosmic!", sent)
end

--- An upload is a `cosmic.stream` Writer: `Stream.copy` fills it from a
--- Reader, far more than one buffer's worth.
local function test_an_upload_is_a_stream_writer()
  local data = string.rep("0123456789abcdef", 256 * 1024)
  local up = assert(Http.upload(url, { body_size = #data,
    script = { kept_open("200 OK", "ok") } }))
  local writer: Stream.Writer = up
  assert(assert(Stream.copy(Stream.from_string(data), writer)) == #data)
  assert(writer:close())
  local response = assert(up:response())
  -- The reply came first, so curl may still be sending the body: the
  -- transfer is over, and all of it sent, once the reply is read out.
  assert(assert(Stream.read_all(response)) == "ok")
  local sent = response:sent()
  assert(sent:sub(-#data) == data, "the whole body was sent")
  assert(response:close())
end

--- `body` and a HEAD are refused, each as its kind of mistake.
local function test_an_upload_refuses_a_body_and_a_head()
  assert(not pcall(Http.upload, url, { body = "x", script = {} } as Http.Options))
  assert(not pcall(Http.upload, url, { body_size = -1, script = {} } as Http.Options))
  local up, trouble = Http.upload(url, { method = "HEAD", script = {} })
  assert(up == nil and trouble:find("HEAD", 1, true) ~= nil, trouble)
end

--- A request that fails says so from `close` and `response`, and
--- every later write fails too.
local function test_a_failed_upload_says_why()
  local up = assert(Http.upload(url, { script = {} }))
  local wrote, trouble = up:write("x")
  assert(not wrote and trouble ~= "", "a write with nowhere to go succeeded")
  local closed, close_trouble = up:close()
  assert(not closed and close_trouble ~= "", close_trouble)
  local response, why = up:response()
  assert(response == nil and why == close_trouble, why)
  local again, again_trouble = up:write("y")
  assert(not again and again_trouble:find("closed", 1, true) ~= nil, again_trouble)
end

--- An aborted upload sends no more and has no response.
local function test_an_aborted_upload_has_no_response()
  local up = assert(Http.upload(url, { script = { reply("200 OK", "", "") } }))
  assert(up:write("partial"))
  assert(up:abort())
  assert(up:abort())
  assert(up:close(), "a close after abort is harmless, as a second abort is")
  local response, why = up:response()
  assert(response == nil and why:find("aborted", 1, true) ~= nil, why)
  assert(not up:write("more"))
end

--- A server that refuses the request before its body is sent is heard:
--- the writes stop, and the response is the refusal.
local function test_a_refusal_before_the_body_is_all_sent_is_the_response()
  local up = assert(Http.upload(url, { script = {
    reply("413 Content Too Large", "", "too big") } }))
  local chunk = string.rep("x", 1 << 20)
  local refused = ""
  for _ = 1, 64 do
    local ok, trouble = up:write(chunk)
    if not ok then
      refused = trouble
      break
    end
  end
  assert(refused:find("answered before", 1, true) ~= nil, refused)
  local response = assert(up:response())
  assert(response.status == 413)
  assert(assert(Stream.read_all(response)) == "too big")
  assert(response:close())
end

--- A redirect that would send the body again cannot: what was written
--- is gone, so the request fails rather than send an empty body.
local function test_an_upload_redirected_by_a_307_fails()
  local up = assert(Http.upload(url, { script = {
    reply("307 Temporary Redirect", "Location: /again\r\n", ""),
    reply("200 OK", "", "ok") } }))
  local _, _ = up:write("payload")
  local closed, trouble = up:close()
  assert(not closed and trouble:find("rewind", 1, true) ~= nil, trouble)
end

--- A 303 needs no body resent: the request follows it as a GET.
local function test_an_upload_redirected_by_a_303_follows_as_a_get()
  local response, body, sent = upload({
    "HTTP/1.1 303 See Other\r\nLocation: /again\r\nContent-Length: 0\r\n\r\n",
    reply("200 OK", "", "fetched") }, { "payload" })
  assert(response.status == 200 and body == "fetched")
  assert(sent:find("POST / HTTP/1.1\r\n", 1, true) == 1, sent)
  assert(sent:find("GET /again HTTP/1.1\r\n", 1, true) ~= nil, sent)
end

--- A write that would take the body past its given size fails and
--- takes none of it; the body then written to its size goes through.
local function test_an_upload_refuses_a_body_past_its_size()
  local up = assert(Http.upload(url, { body_size = 4,
    script = { kept_open("200 OK", "ok") } }))
  assert(up:write("ab"))
  local wrote, trouble = up:write("cdef")
  assert(not wrote and trouble:find("longer than its body_size of 4", 1, true) ~= nil, trouble)
  assert(up:write("cd"))
  assert(up:close())
  local response = assert(up:response())
  assert(response:sent():sub(-8) == "\r\n\r\nabcd", response:sent())
  assert(response:close())
end

--- A body short of its given size fails the request at `close`.
local function test_an_upload_short_of_its_size_fails()
  local up = assert(Http.upload(url, { body_size = 10,
    script = { kept_open("200 OK", "ok") } }))
  assert(up:write("abc"))
  local closed, trouble = up:close()
  assert(not closed and trouble:find("shorter than its body_size of 10 bytes: 3 written",
    1, true) ~= nil, trouble)
end

--- A GET named with a streamed body goes as a GET, not a POST.
local function test_an_upload_names_its_method()
  local _, _, sent = upload({ kept_open("200 OK", "") }, { "q" }, { method = "GET" })
  assert(sent:find("GET / HTTP/1.1\r\n", 1, true) == 1, sent)
end

--- A server that answers first with more than the body buffer holds,
--- keeping the connection open, cannot hold a write up: the transfer is
--- paused on the unread answer, so the write stops and says so, and the
--- response is there to read.
local function test_a_large_early_answer_does_not_hang_a_write()
  local answer = string.rep("x", 3 * 1024 * 1024)
  local up = assert(Http.upload(url, { script = { kept_open("413 Content Too Large", answer) } }))
  local chunk = string.rep("y", 1 << 20)
  local refused = ""
  for _ = 1, 64 do
    local ok, trouble = up:write(chunk)
    if not ok then
      refused = trouble
      break
    end
  end
  assert(refused:find("answered before", 1, true) ~= nil, refused)
  local response = assert(up:response())
  assert(response.status == 413)
  assert(#assert(Stream.read_all(response)) == #answer)
  assert(response:close())
end

--- An upload left in a `<close>` variable before its `close` is aborted.
local function test_a_close_variable_aborts_an_upload()
  local kept: Http.Upload
  do
    local up <close> = assert(Http.upload(url, { script = { kept_open("200 OK", "") } }))
    assert(up:write("partial"))
    kept = up
  end
  local response, why = kept:response()
  assert(response == nil and why:find("aborted", 1, true) ~= nil, why)
end
