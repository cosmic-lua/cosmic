--- `cosmic sandbox connect` (build/sandbox_connect.tl) in this process,
--- against a relay of this test's own that listens on a port of its own at
--- 127.0.0.1 (the policy's `loopback`), which `ALL_PROXY` names: a host that
--- runs workers in its own network (macOS) has another process on 1080:
--- what it asks the relay for, how it answers each reply, the bytes it
--- carries each way with their half-closes, and what it refuses before
--- it connects anywhere.

local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local Wire = require("cosmic.relay_wire")
local connect = require("build.sandbox_connect")

Test.policy{
  loopback = { "127.0.0.1" },
}

--- The `ALL_PROXY` the sandbox sets, which a client refuses unless it is a
--- `socks5h` proxy at 127.0.0.1.
local PROXY <const> = "socks5h://127.0.0.1:1080"

--- The `ALL_PROXY` for a relay at `port`.
local function proxy_at(port: integer, userinfo?: string): string
  return "socks5h://" .. (userinfo ~= nil and (userinfo .. "@") or "") .. "127.0.0.1:" .. port
end

--- What a run of the client left.
local record Ran
  code: integer
  complaints: {string}
  --- The client's own step lines (COSMIC_CONNECT_TRACE), which a failure shows.
  trace: {string}
  --- What it wrote to its standard output, to its end.
  out: string
end

--- How long any wait of a test may last: short of the worker's own 10 seconds, so
--- that a hang fails with the client's steps and not by the worker's deadline.
local WAIT <const> = Clock.seconds(4)

--- The client's standard streams, held in memory: a host's own polling of
--- a named pipe (macOS's reports no end) is no part of what the client does,
--- and the descriptors' glue is the tool test's.
local record Streams
  --- What the program has sent and not yet been read, and whether it ended.
  waiting: string
  ended: boolean
  --- What the client wrote to its standard output, and whether it closed it.
  out: string
  closed: boolean
end

local function streams(): Streams
  return { waiting = "", ended = false, out = "", closed = false }
end

--- The `Io` of `held`, for the client, and `variables` as its environment.
local function io_of(held: Streams, variables: {string:string}, complaints: function(line: string),
                     answer_ns?: integer): connect.Io
  return {
    getenv = function(name: string): string | nil return variables[name] end,
    err = complaints,
    read = function(): string | nil, string
      while held.waiting == "" and not held.ended do
        local ok, why = Poll.delay(Clock.ms(1))
        if not ok then return nil, why end
      end
      local data = held.waiting
      held.waiting = ""
      return data, ""
    end,
    write = function(data: string): boolean, string
      held.out = held.out .. data
      return true, ""
    end,
    finish = function(): boolean, string
      held.closed = true
      return true, ""
    end,
    answer_ns = answer_ns,
  }
end

--- Exactly `count` bytes of `conn`, fewer where it ends first.
local function bytes(conn: Net.Conn, count: integer): string
  local data = ""
  while #data < count do
    local chunk = conn:read(count - #data)
    if chunk == nil then break end
    data = data .. chunk
  end
  return data
end

--- Runs `body(relay, send, finish)` in a run beside a client for `args`
--- with the variable `variable` (`ALL_PROXY` when nil) set to the relay's
--- listener: `relay` is the
--- relay's end of the one connection the client makes, `send` writes to
--- its standard input and `finish` ends it. Answers how the client ended.
local function against(args: {string}, body: function(relay: Net.Conn, send: function(string), finish: function()),
                       variable?: string, timeout_ns?: integer, userinfo?: string): Ran
  local ran: Ran = { code = -1, complaints = {}, trace = {}, out = "" }
  local held = streams()
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local variables = { [variable or "ALL_PROXY"] = proxy_at(listener.address.port, userinfo), COSMIC_CONNECT_TRACE = "1" }
    if variable == "all_proxy" then variables.all_proxy = variables.all_proxy .. "/" end
    local client = Poll.spawn(function()
      ran.code = connect.run(args, io_of(held, variables, function(line: string)
        if line:find("^connect trace ") then
          ran.trace[#ran.trace + 1] = line
        else
          ran.complaints[#ran.complaints + 1] = line
        end
      end, timeout_ns))
    end)
    local relay: Net.Conn | nil
    -- However the body ends, the listener and the connection are closed, so
    -- that one failing test leaves nothing for the next.
    local ok, trouble = pcall(function()
      local accepted = assert(listener:accept(WAIT))
      relay = accepted
      accepted:set_timeout(WAIT)
      body(accepted, function(data: string)
        held.waiting = held.waiting .. data
      end, function()
        held.ended = true
      end)
      held.ended = true
      local _, _ = accepted:close()
      assert(client:join(WAIT), "the client did not end")
      ran.out = held.out
    end)
    if relay ~= nil then local _, _ = relay:close() end
    client:cancel()
    local _, _ = listener:close()
    if not ok then
      error(tostring(trouble) .. "\nthe client's steps:\n" .. table.concat(ran.trace, "\n") ..
          "\nits complaints: " .. table.concat(ran.complaints, " | "), 0)
    end
  end)
  return ran
end

--- What a relay reads of a client's greeting and request, answering the
--- method it takes: the request's bytes, which `reply` then answers.
local function asked(relay: Net.Conn): string
  assert(bytes(relay, 3) == "\5\1\0", "the greeting offers no authentication")
  assert(relay:write(Wire.socks_method_reply(0)))
  local head = bytes(relay, 4)
  local rest: integer
  if head:byte(4) == 1 then
    rest = 6
  elseif head:byte(4) == 4 then
    rest = 18
  else
    local length = bytes(relay, 1)
    head = head .. length
    rest = length:byte(1) + 2
  end
  return head .. bytes(relay, rest)
end

local function test_a_name_is_asked_for_as_a_name_and_the_bytes_go_both_ways()
  local request: string
  local seen_end = false
  local ran = against({ "api.github.com", "443" }, function(relay: Net.Conn, send: function(string), finish: function())
    request = asked(relay)
    -- The relay's first bytes of the tunnel come in the same write as its answer.
    assert(relay:write(Wire.socks_reply("succeeded") .. "banner "))
    send("ping")
    assert(bytes(relay, 4) == "ping", "standard input reaches the relay")
    finish()
    -- The end of what the client sends reaches the relay as a half-close, and
    -- the relay can still answer.
    assert(relay:read(1) == nil, "the relay sees the end")
    seen_end = true
    assert(relay:write("pong"))
    assert(relay:shutdown("write"))
  end)
  assert(ran.code == 0, ran.code .. table.concat(ran.complaints, "\n"))
  assert(request == "\5\1\0\3\14api.github.com\1\187", "the host is a name: " .. request)
  assert(seen_end, "a half-close was seen")
  assert(ran.out == "banner pong", "the output is the tunnel's: " .. ran.out)
  assert(#ran.complaints == 0, table.concat(ran.complaints))
end

local function test_an_address_is_asked_for_as_an_address()
  local request: string
  local ran = against({ "127.0.0.2", "22" }, function(relay: Net.Conn, _: function(string), finish: function())
    request = asked(relay)
    assert(relay:write(Wire.socks_reply("succeeded")))
    finish()
    assert(relay:shutdown("write"))
  end)
  assert(ran.code == 0, table.concat(ran.complaints))
  assert(request == "\5\1\0\1\127\0\0\2\0\22", "an address of type 1")
  local ipv6: string
  assert(against({ "::1", "22" }, function(relay: Net.Conn, _: function(string), finish: function())
    ipv6 = asked(relay)
    assert(relay:write(Wire.socks_reply("succeeded")))
    finish()
    assert(relay:shutdown("write"))
  end).code == 0)
  assert(ipv6 == "\5\1\0\4" .. ("\0"):rep(15) .. "\1\0\22", "an address of type 4")
end

local function test_the_relay_ending_first_ends_the_output_and_the_run_ends_with_the_input()
  local ran = against({ "host.example", "80" }, function(relay: Net.Conn, _: function(string), finish: function())
    asked(relay)
    assert(relay:write(Wire.socks_reply("succeeded") .. "bye"))
    assert(relay:close())
    -- The client's output has ended, and the end of its input is what it waits for.
    finish()
  end)
  assert(ran.code == 0, ran.code .. table.concat(ran.complaints))
  assert(ran.out == "bye" and #ran.complaints == 0, ran.out .. table.concat(ran.complaints))
end

--- Each refusal the relay may answer, and what the client says of it.
local REFUSALS <const>: {{string}} = {
  { "failure", "general SOCKS server failure", "1" },
  { "not_allowed", "connection not allowed by ruleset", "2" },
  { "network_unreachable", "network unreachable", "3" },
  { "host_unreachable", "host unreachable", "4" },
  { "refused", "connection refused", "5" },
  { "ttl_expired", "TTL expired", "6" },
  { "command_not_supported", "command not supported", "7" },
  { "address_type_not_supported", "address type not supported", "8" },
}

local function test_a_refusal_exits_1_with_one_line_naming_what_the_reply_means()
  for _, case in ipairs(REFUSALS) do
    local ran = against({ "host.example", "443" }, function(relay: Net.Conn)
      asked(relay)
      assert(relay:write(Wire.socks_reply(case[1] as Wire.SocksReply)))
    end)
    assert(ran.code == 1, case[1] .. ": " .. ran.code)
    assert(#ran.complaints == 1, table.concat(ran.complaints, "\n"))
    local line = ran.complaints[1]
    assert(line:find("^cosmic: sandbox connect: host.example:443: " .. case[2] .. " %(SOCKS reply " .. case[3] .. "%)"),
      line)
    assert(ran.out == "", "nothing is written to standard output")
  end
  local unknown = against({ "h", "1" }, function(relay: Net.Conn)
    asked(relay)
    assert(relay:write("\5\200\0\1\0\0\0\0\0\0"))
  end)
  assert(unknown.code == 1 and unknown.complaints[1]:find("unknown reply code 200", 1, true), unknown.complaints[1])
end

local function test_a_relay_that_breaks_the_protocol_or_goes_away_is_a_failure()
  local version = against({ "h", "1" }, function(relay: Net.Conn)
    asked(relay)
    assert(relay:write("\4\90\0\0\0\0\0\0"))
  end)
  assert(version.code == 1 and version.complaints[1]:find("SOCKS version 4", 1, true), version.complaints[1])
  local silent = against({ "h", "1" }, function(relay: Net.Conn)
    asked(relay)
  end)
  assert(silent.code == 1 and silent.complaints[1]:find("closed the connection before it answered", 1, true),
    silent.complaints[1])
  local method = against({ "h", "1" }, function(relay: Net.Conn)
    assert(bytes(relay, 3) == "\5\1\0")
    assert(relay:write(Wire.socks_method_reply(255)))
  end)
  assert(method.code == 1 and method.complaints[1]:find("no authentication method", 1, true), method.complaints[1])
end

local function test_it_refuses_a_command_line_or_environment_that_is_not_a_sandboxs()
  local function refused(args: {string}, env: {string:string}, why: string)
    local complaints: {string} = {}
    local code = connect.run(args, {
      getenv = function(name: string): string | nil return env[name] end,
      err = function(line: string) complaints[#complaints + 1] = line end,
      read = function(): string | nil, string return "", "" end,
      write = function(): boolean, string return true, "" end,
      finish = function(): boolean, string return true, "" end,
    })
    assert(code == 2 and #complaints == 1, tostring(args[1]) .. " " .. tostring(args[2]) .. ": " .. code)
    assert(complaints[1]:find("^cosmic: sandbox connect: "), complaints[1])
    assert(complaints[1]:find(why, 1, true), complaints[1])
  end
  -- No relay listens in the worker's network but the one a run starts: all
  -- of these are refused before a connection is tried.
  refused({ "host", "22" }, {}, "ProxyCommand")
  refused({ "host", "22" }, { ALL_PROXY = "" }, "`cosmic sandbox --connect HOST:PORT`")
  refused({ "host", "22" }, { ALL_PROXY = "socks5://127.0.0.1:1080" }, "socks5h://127.0.0.1:PORT")
  refused({ "host", "22" }, { ALL_PROXY = "http://127.0.0.1:3128" }, "no other proxy is served")
  refused({ "host", "22" }, { ALL_PROXY = "socks5h://10.0.0.1:1080" }, "socks5h://10.0.0.1:1080")
  refused({ "host", "22" }, { ALL_PROXY = "socks5h://127.0.0.1:0" }, "no other proxy is served")
  refused({ "host", "22" }, { ALL_PROXY = "socks5h://127.0.0.1:65536" }, "no other proxy is served")
  refused({ "host", "22" }, { ALL_PROXY = "socks5h://127.0.0.1" }, "no other proxy is served")
  refused({ "host", "22" }, { ALL_PROXY = "socks5h://localhost:1080" }, "no other proxy is served")
  refused({}, { ALL_PROXY = PROXY }, "takes a host and a port")
  refused({ "host" }, { ALL_PROXY = PROXY }, "takes a host and a port")
  refused({ "host", "22", "extra" }, { ALL_PROXY = PROXY }, "takes a host and a port")
  refused({ "host", "0" }, { ALL_PROXY = PROXY }, "1 to 65535")
  refused({ "host", "65536" }, { ALL_PROXY = PROXY }, "1 to 65535")
  refused({ "host", "ssh" }, { ALL_PROXY = PROXY }, "not ssh")
  refused({ "", "22" }, { ALL_PROXY = PROXY }, "empty")
  refused({ ("a"):rep(256), "22" }, { ALL_PROXY = PROXY }, "255")
  -- The lower-case variable is read where the upper is not set.
  local ran = against({ "host.example", "1" }, function(relay: Net.Conn)
    asked(relay)
    assert(relay:write(Wire.socks_reply("refused")))
  end, "all_proxy")
  assert(ran.code == 1, table.concat(ran.complaints))
end

local function test_nothing_listening_is_a_failure_naming_the_relay(_: string)
  -- A port that was just listened at and is shut: nothing is there.
  local port: integer
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    port = listener.address.port
    assert(listener:close())
  end)
  local complaints: {string} = {}
  local code = connect.run({ "host", "22" }, {
    getenv = function(name: string): string | nil
      if name == "ALL_PROXY" then return proxy_at(port) end
      return nil
    end,
    err = function(line: string) complaints[#complaints + 1] = line end,
    read = function(): string | nil, string return "", "" end,
    write = function(): boolean, string return true, "" end,
    finish = function(): boolean, string return true, "" end,
  })
  assert(code == 1 and complaints[1]:find("the relay at " .. proxy_at(port), 1, true), tostring(complaints[1]))
end

local function test_a_relay_that_never_answers_is_a_failure_after_the_timeout_naming_the_relay()
  local started = Clock.monotonic_ns()
  local ran = against({ "host.example", "22" }, function(relay: Net.Conn)
    asked(relay)
    -- Holds the connection open and says nothing until the client has given up.
    local _, _ = relay:read(1)
  end, nil, Clock.seconds(1))
  assert(ran.code == 1 and #ran.complaints == 1, ran.code .. table.concat(ran.complaints))
  assert(ran.complaints[1]:find("host.example:22: the relay at socks5h://127.0.0.1:", 1, true) and
      ran.complaints[1]:find("did not answer in time", 1, true), ran.complaints[1])
  assert(Clock.monotonic_ns() - started < Clock.seconds(15), "it gave up in time")
end

--- What a relay with a token reads of a client's greeting, the message of
--- its username and password and its request, answering the method 2 and
--- `verdict` ("\1\0" accepts): the user, the password and the request's bytes
--- (nil where the verdict refused).
local function asked_with_login(relay: Net.Conn, verdict: string): string, string, string | nil
  assert(bytes(relay, 3) == "\5\1\2", "the greeting offers a password alone")
  assert(relay:write(Wire.socks_method_reply(2)))
  assert(bytes(relay, 1) == "\1", "RFC 1929's version")
  local user = bytes(relay, bytes(relay, 1):byte(1))
  local password = bytes(relay, bytes(relay, 1):byte(1))
  assert(relay:write(verdict))
  if verdict ~= "\1\0" then return user, password, nil end
  local head = bytes(relay, 4)
  local length = bytes(relay, 1)
  return user, password, head .. length .. bytes(relay, length:byte(1) + 2)
end

local function test_a_userinfo_is_sent_as_the_username_and_password_percent_decoded()
  local user, password, request: string, string, string | nil
  local ran = against({ "api.github.com", "443" }, function(relay: Net.Conn, _: function(string), finish: function())
    user, password, request = asked_with_login(relay, "\1\0")
    assert(relay:write(Wire.socks_reply("succeeded") .. "banner"))
    finish()
    assert(relay:shutdown("write"))
  end, nil, nil, "sandbox:tok%2Fen%40x%3a:%25")
  assert(ran.code == 0, ran.code .. table.concat(ran.complaints))
  assert(user == "sandbox" and password == "tok/en@x::%", "the userinfo is decoded: " .. tostring(password))
  assert(request == "\5\1\0\3\14api.github.com\1\187", "the request follows the login")
  assert(ran.out == "banner" and #ran.complaints == 0, ran.out .. table.concat(ran.complaints))
  -- An empty user name is sent as a name the relay takes.
  local named: string
  local anonymous = against({ "h", "1" }, function(relay: Net.Conn)
    named = asked_with_login(relay, "\1\0")
    assert(relay:write(Wire.socks_reply("refused")))
  end, nil, nil, ":tok")
  assert(anonymous.code == 1 and named == "cosmic", tostring(named))
end

local function test_a_relay_that_refuses_the_token_exits_1_naming_it_and_never_the_password()
  local secret <const> = "SECRET-token-1234"
  local seen: string
  local ran = against({ "host.example", "22" }, function(relay: Net.Conn)
    local _, got = asked_with_login(relay, "\1\1")
    seen = got
  end, nil, nil, "u:" .. secret)
  assert(seen == secret, "the relay was sent it")
  assert(ran.code == 1 and #ran.complaints == 1, ran.code .. table.concat(ran.complaints))
  assert(ran.complaints[1] == "cosmic: sandbox connect: host.example:22: the relay refused the sandbox's token",
    ran.complaints[1])
  local everything = table.concat(ran.complaints) .. table.concat(ran.trace)
  assert(not everything:find(secret, 1, true), "the password is in no message")
  assert(ran.out == "")
end

local function test_a_relay_that_answers_a_password_otherwise_is_a_failure()
  local none = against({ "h", "1" }, function(relay: Net.Conn)
    assert(bytes(relay, 3) == "\5\1\2")
    assert(relay:write(Wire.socks_method_reply(255)))
  end, nil, nil, "u:tok")
  assert(none.code == 1 and none.complaints[1]:find("no authentication method", 1, true), none.complaints[1])
  -- A relay that takes no token selects "no authentication", which was not offered.
  local open = against({ "h", "1" }, function(relay: Net.Conn)
    assert(bytes(relay, 3) == "\5\1\2")
    assert(relay:write(Wire.socks_method_reply(0)))
  end, nil, nil, "u:tok")
  assert(open.code == 1 and open.complaints[1]:find("the method 0 chosen is not one offered (only 2)", 1, true),
    open.complaints[1])
  local version = against({ "h", "1" }, function(relay: Net.Conn)
    asked_with_login(relay, "\5\0")
  end, nil, nil, "u:tok")
  assert(version.code == 1 and version.complaints[1]:find("username/password version 5", 1, true),
    version.complaints[1])
  local early = against({ "h", "1" }, function(relay: Net.Conn)
    assert(bytes(relay, 3) == "\5\1\2")
    assert(relay:write(Wire.socks_method_reply(2) .. "\1\0"))
  end, nil, nil, "u:tok")
  assert(early.code == 1 and early.complaints[1]:find("answered before it was asked", 1, true), early.complaints[1])
end

local function test_a_userinfo_that_cannot_be_used_is_refused_and_never_echoed()
  local secret <const> = "SECRET-token-1234"
  local function refused(value: string, why: string)
    local complaints: {string} = {}
    local code = connect.run({ "host", "22" }, {
      getenv = function(name: string): string | nil
        if name == "ALL_PROXY" then return value end
        return nil
      end,
      err = function(line: string) complaints[#complaints + 1] = line end,
      read = function(): string | nil, string return "", "" end,
      write = function(): boolean, string return true, "" end,
      finish = function(): boolean, string return true, "" end,
    })
    assert(code == 2 and #complaints == 1, value:gsub(secret, "<secret>") .. ": " .. code)
    assert(complaints[1]:find(why, 1, true), complaints[1])
    assert(not complaints[1]:find(secret, 1, true), "the password is echoed: " .. complaints[1])
  end
  -- The host is exactly 127.0.0.1, whatever the userinfo.
  refused("socks5h://u:" .. secret .. "@10.0.0.1:1080", "no other proxy is served")
  refused("socks5h://u:" .. secret .. "@localhost:1080", "no other proxy is served")
  refused("socks5h://u:" .. secret .. "@127.0.0.1.example:1080", "no other proxy is served")
  refused("socks5h://u:" .. secret .. "@127.0.0.1:1080@10.0.0.1:1080", "no other proxy is served")
  refused("socks5h://u:" .. secret .. "@127.0.0.1", "no other proxy is served")
  refused("socks5h://u:" .. secret .. "@127.0.0.1:0", "no other proxy is served")
  refused("socks5://u:" .. secret .. "@127.0.0.1:1080", "no other proxy is served")
  refused("socks5h://127.0.0.1:1080@" .. secret, "no other proxy is served")
  -- A token that is no password.
  refused("socks5h://onlyauser@127.0.0.1:1080", "not user:token")
  refused("socks5h://u:@127.0.0.1:1080", "not user:token")
  refused("socks5h://u:" .. ("p"):rep(256) .. "@127.0.0.1:1080", "the password is longer than 255 bytes")
  refused("socks5h://" .. ("u"):rep(256) .. ":" .. secret .. "@127.0.0.1:1080", "the username is longer than 255 bytes")
  refused("socks5h://u:%41" .. ("p"):rep(255) .. "@127.0.0.1:1080", "the password is longer than 255 bytes")
end
