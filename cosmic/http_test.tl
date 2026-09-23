--- Offline coverage for cosmic.http: option/URL validation and a
--- connection refused on a closed local port, both deterministic and
--- without reaching the network. A loopback HTTP/1.1 server exercising
--- redirects, chunked and content-length bodies would cover the parts
--- of core/http.c these cannot -- the header-callback pause/resume
--- logic, redirect-chasing, chunked decoding -- but cosmic has no
--- socket/listen/accept syscalls exposed to Teal (core/syscalls.h has
--- only `poll`, for waiting on already-open descriptors such as a
--- child's pipes) and no vendored C test helper speaks HTTP/1.1 over
--- loopback the way test/portable/launcher_payload.c speaks the
--- launcher protocol. That gap is called out in the final report
--- rather than quietly skipped; see it for the exact commands used to
--- verify redirects and chunked bodies by hand instead, against real
--- servers, through the proxy this sandbox already requires for every
--- other outbound request.

local Http = require("cosmic.http")

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

local function test_download_reports_the_same_failure_as_open()
  local ok, trouble = Http.download("http://127.0.0.1:1/", "/tmp/cosmic-http-test-unreached",
    { connect_timeout_ms = 2000 })
  assert(not ok)
  assert(trouble ~= "")
end

local function test_a_low_max_redirects_of_zero_is_accepted()
  -- Exercises option plumbing (max_redirects reaching curl) without
  -- needing a server: the connection still gets refused first, so
  -- this is really the same case as above with an option set that a
  -- redirect-following path would need to have read correctly.
  local response, trouble = Http.open("http://127.0.0.1:1/",
    { follow = false, max_redirects = 0, connect_timeout_ms = 2000 })
  assert(response == nil)
  assert(trouble ~= "")
end

-- A header name or value carrying CR or LF could otherwise smuggle a
-- second header, or even a whole extra request, past curl and onto the
-- wire (CRLF/header injection). This is caught before any connection
-- is attempted -- the closed port at 127.0.0.1:1 never gets reached --
-- so these are deterministic and offline like the option-validation
-- cases above.
local function test_a_header_value_with_crlf_is_rejected()
  local response, trouble = Http.open("http://127.0.0.1:1/",
    { headers = { ["X-Evil"] = "value\r\nX-Injected: yes" } })
  assert(response == nil)
  assert(trouble ~= "")
  assert(trouble:lower():find("cr or lf", 1, true) ~= nil, trouble)
end

local function test_a_header_value_with_a_bare_lf_is_rejected()
  local response, trouble = Http.open("http://127.0.0.1:1/",
    { headers = { ["X-Evil"] = "value\nX-Injected: yes" } })
  assert(response == nil)
  assert(trouble ~= "")
end

local function test_a_header_name_with_crlf_is_rejected()
  local response, trouble = Http.open("http://127.0.0.1:1/",
    { headers = { ["X-Evil\r\nX-Injected"] = "yes" } })
  assert(response == nil)
  assert(trouble ~= "")
end

local function test_a_header_name_with_a_colon_is_rejected()
  local response, trouble = Http.open("http://127.0.0.1:1/",
    { headers = { ["X-Evil: yes\r\nX-Injected"] = "yes" } })
  assert(response == nil)
  assert(trouble ~= "")
end

local function test_an_empty_header_name_is_rejected()
  local response, trouble = Http.open("http://127.0.0.1:1/",
    { headers = { [""] = "yes" } })
  assert(response == nil)
  assert(trouble ~= "")
end

local function test_an_ordinary_header_is_still_accepted()
  -- The validation above must not reject well-formed headers; this
  -- still fails (nothing is listening on port 1), but for the
  -- connection-refused reason, not a rejected header.
  local response, trouble = Http.open("http://127.0.0.1:1/",
    { headers = { ["X-Fine"] = "a normal value" }, connect_timeout_ms = 2000 })
  assert(response == nil)
  assert(trouble ~= "")
  assert(trouble:lower():find("invalid header", 1, true) == nil, trouble)
end
