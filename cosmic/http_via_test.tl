--- [`Http.Options.via`]'s refusals and its place beside a script, none of
--- which connects to a socket.

local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Test = require("cosmic.test")
local raw_http = require("cosmic.internal.http")

Test.policy{ loopback = { "127.0.0.1" } }

local url = "http://cosmic.test/"

--- `via` takes a unix address alone: any other would name a host the
--- request is not sent to, so the option is refused, naming it, at the
--- line that called the entry point.
local function test_via_that_is_no_unix_address_raises_naming_it()
  local datagram: Net.Address = { kind = "udp", host = "127.0.0.1", port = 53, path = nil }
  for _, via in ipairs({ Net.tcp("127.0.0.1", 80), datagram }) do
    local ok, why = pcall(function(): Http.Body?
      local got = Http.get(url, { via = via })
      return got
    end)
    assert(not ok and tostring(why):find("http_via_test:%d+: http: opts.via must be a unix address") ~= nil,
      tostring(why))
  end
end

--- A path that is empty, or holds a NUL that curl's C string would cut
--- short, is data the request cannot be sent with: `nil, err`, not a raise.
local function test_an_empty_or_nul_socket_path_is_an_error_not_a_raise()
  local empty, empty_why = Http.get(url, { via = Net.unix("") })
  assert(empty == nil and empty_why == "invalid unix_socket: empty", tostring(empty_why))
  local nul, nul_why = Http.get(url, { via = Net.unix("/tmp/a\0b.sock") })
  assert(nul == nil and nul_why == "invalid unix_socket: contains a NUL byte", tostring(nul_why))
end

--- A scripted transfer takes its connections from the script, so `via`
--- beside it, to a socket that is not there, still reads the script.
local function test_a_script_is_read_whatever_the_socket()
  local reply = "HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nscripted"
  local got, why = Http.get(url, {
    via = Net.unix("/nonexistent/s.sock"), script = { reply },
  })
  assert(got ~= nil, tostring(why))
  assert(got.status == 200 and got.body == "scripted", got.body)
end

--- A transfer curl failed returns a third value naming the failure, so a
--- caller need not read its message: a connect failure is "couldnt_connect"
--- (here, at a loopback port nothing listens at, as `open` takes no options).
local function test_the_raw_open_names_a_connect_failure()
  local handle, why, code = raw_http.open("http://127.0.0.1:1/")
  assert(handle == nil and code == "couldnt_connect", tostring(why) .. " / " .. tostring(code))
end
