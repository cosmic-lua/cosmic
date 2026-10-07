--- `cosmic sandbox connect HOST PORT`: the SOCKS5 client of the network
--- relay that `cosmic sandbox --connect` runs, for a program that speaks
--- no proxy protocol of its own and takes a command to reach a host
--- through: ssh's `ProxyCommand='cosmic sandbox connect %h %p'`.
---
--- It runs inside the sandbox, where the relay's variables are set: it
--- reads `ALL_PROXY` (`all_proxy` where that is unset), which must be the
--- relay's own SOCKS5 listener, `socks5h://127.0.0.1:1080`, or with the
--- sandbox's token `socks5h://user:token@127.0.0.1:1080` (the host is
--- exactly 127.0.0.1, and the userinfo is percent-decoded), and refuses any
--- other, naming it, and never one that carries credentials; a command line
--- or an environment that is not a sandbox's, with no such variable, is
--- refused saying what this is for.
--- It connects there, offers no authentication, or with a userinfo only
--- username and password, which it sends (RFC 1929; an empty user name is
--- sent as "cosmic", as the relay takes any) and which the relay may refuse,
--- exiting 1 with "the relay refused the sandbox's token", and asks the relay to
--- connect to HOST and PORT with HOST as a name for the relay to resolve
--- and judge, never resolved here (the sandbox has no DNS), or as an
--- address where HOST is a literal. An answer other than success exits 1
--- with one line naming what the reply code means; the relay's own line,
--- on the standard error of the `cosmic sandbox` that started it, says
--- which grant would allow the connection.
---
--- On success it copies standard input to the connection and the
--- connection to standard output, until both have ended: an end of one
--- side's bytes is passed on to the other as a half-close (a `shutdown` of
--- the connection's write side, and a close of standard output), and the
--- bytes the relay sent after its answer, in the same read, are the
--- connection's first. It exits 0 when both sides ended in order, 1 when
--- the connection failed.
---
--- Exit status: 0 for a connection that ended, 1 for a refusal or a failure
--- of the connection, 2 for a command line or an environment it refuses.

local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay")
local sys = require("cosmic.sys")
local bare = require("build.bare")
local plural = require("build.plural")

--- The pieces of the process the client uses: what a test stands in for.
local record sandbox_connect
  --- Where the client reads, writes and complains.
  record Io
    --- A variable of the environment, or nil.
    getenv: function(name: string): string | nil
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- The next bytes of the standard input the connection is sent, "" at
    --- its end; nil and why where it fails.
    read: function(): string | nil, string
    --- Writes all of `data` to the standard output the connection is
    --- written to. False and why where it fails.
    write: function(data: string): boolean, string
    --- Closes that standard output, which its reader hears as the end.
    finish: function(): boolean, string
    --- How long the relay has to answer the greeting and the request, each,
    --- in nanoseconds: 30 seconds when nil.
    answer_ns: integer
  end
end

--- The most bytes read from either side at a time.
local CHUNK <const> = 4096
--- How long connecting to the relay may take: it listens in this network.
local CONNECT_NS <const> = Clock.seconds(10)
--- How long the relay has to answer the greeting and the request, each: its
--- own connect timeout is 10 seconds, and a resolve comes before it.
local ANSWER_NS <const> = Clock.seconds(30)

--- The relay's listener as the sandbox sets `ALL_PROXY` to it.
local PROXY <const> = "socks5h://127.0.0.1:" .. Relay.Config.socks_port

--- The port of `text`, a whole number from 1 to 65535, or nil.
local function port_of(text: string): integer | nil
  if not text:match("^%d+$") or #text > 5 then return nil end
  local port = math.tointeger(tonumber(text))
  if port == nil or port < 1 or port > 65535 then return nil end
  return port
end

--- Reads exactly what `reader` decides from `conn`, as the relay's answer to
--- one step: the bytes fed until it is no longer `more`.
--- @param conn the connection to the relay
--- @param relay its name, for what is said of it
--- @param feed feeds the next bytes to a reader, and answers its status, how
--- many bytes it took and why it refused
--- @return the bytes read beyond what the reader took, or nil
--- @return why it refused or the connection failed, when nil
local function answered(conn: Net.Conn, relay: string, feed: function(string): string, integer, string): string | nil, string
  while true do
    local data, why = conn:read(CHUNK)
    if data == nil then
      if why == "" then return nil, "the relay closed the connection before it answered" end
      if why == Poll.TIMEOUT then
        return nil, "the relay at " .. relay .. " did not answer in time"
      end
      return nil, "reading from the relay: " .. why
    end
    local status, consumed, reason = feed(data)
    if status == "refused" then return nil, reason end
    if status == "done" then return data:sub(consumed + 1), "" end
  end
end

--- Writes all of `data` to the descriptor `fd`, waiting where it takes no
--- more. False and why when it fails.
local function write_all(fd: integer, data: string): boolean, string
  local at = 1
  while at <= #data do
    -- The descriptor is the caller's own and may block: the wait for room is
    -- ours, and a write is no more than a pipe takes at once.
    -- TODO: make standard output non-blocking for the run and put its mode
    -- back, once cosmic.sys can read a descriptor's O_NONBLOCK (fd_flags
    -- answers FD_CLOEXEC alone): until then a full socket (not a pipe) can
    -- hold the whole run for one write.
    local ready, ready_why = Poll.writable(fd)
    if not ready then return false, ready_why end
    local count, why, errno = sys.write(fd, data:sub(at, at + CHUNK - 1))
    if count ~= nil then
      at = at + count
    elseif errno ~= sys.EAGAIN and errno ~= sys.EINTR then
      return false, why
    end
  end
  return true, ""
end

--- The standard input and output of this process, as descriptors: a read
--- waits for the descriptor in the run, so that the other tasks go on.
local function standard_io(input: integer, output: integer): sandbox_connect.Io
  return {
    getenv = sys.getenv, err = bare.err,
    read = function(): string | nil, string
      while true do
        local ready, ready_why = Poll.readable(input)
        if not ready then return nil, ready_why end
        local data, why, errno = sys.read(input, CHUNK)
        if data ~= nil then return data, "" end
        if errno ~= sys.EAGAIN and errno ~= sys.EINTR then return nil, why end
      end
    end,
    write = function(data: string): boolean, string
      return write_all(output, data)
    end,
    finish = function(): boolean, string
      local closed, why = sys.close(output)
      if not closed then return false, why end
      return true, ""
    end,
  }
end

--- The relay `ALL_PROXY` names.
local record Proxy
  port: integer
  --- The percent-decoded userinfo's user and password, or nil for none.
  user: string
  password: string
end

--- `text` with each `%XX` replaced by its byte.
local function percent_decoded(text: string): string
  return (text:gsub("%%(%x%x)", function(hex: string): string
    return string.char(tonumber(hex, 16))
  end))
end

--- The relay `ALL_PROXY` names, a `socks5h` proxy on 127.0.0.1 (the
--- sandbox's has the relay's port, and its network holds nothing else), with
--- the userinfo that is the sandbox's token where it has one, or nil and why
--- not. The reason never holds the value where it has a userinfo.
local function proxy_of(io: sandbox_connect.Io): Proxy | nil, string
  local value: string = io.getenv("ALL_PROXY") or io.getenv("all_proxy") or ""
  if value == "" then
    return nil, "ALL_PROXY is not set: this is ssh's ProxyCommand inside `cosmic sandbox --connect HOST:PORT`, " ..
      "which sets it to the relay's SOCKS5 listener (" .. PROXY .. ")"
  end
  local userinfo, text = value:match("^socks5h://([^/@]*)@127%.0%.0%.1:(%d+)/?$")
  if userinfo == nil then text = value:match("^socks5h://127%.0%.0%.1:(%d+)/?$") end
  local port = port_of(text or "")
  if port == nil then
    -- A value with an "@" may hold the token, wherever the pattern failed.
    local shown = value:find("@", 1, true) and "not shown, as it holds a userinfo" or bare.escape(value)
    return nil, "ALL_PROXY is " .. shown .. ", not a socks5h://127.0.0.1:PORT like " .. PROXY ..
      " (or socks5h://user:token@127.0.0.1:PORT), the sandbox relay's; no other proxy is served"
  end
  if userinfo == nil then return { port = port }, "" end
  local user, password = userinfo:match("^([^:]*):(.*)$")
  if user == nil or password == "" then
    return nil, "the userinfo of ALL_PROXY is not user:token (the token is the password, percent-encoded)"
  end
  user = percent_decoded(user)
  return { port = port, user = user ~= "" and user or "cosmic", password = percent_decoded(password) }, ""
end

--- Passes standard input to `conn` and `conn` to standard output, `first`
--- the bytes that came after the relay's answer, until both sides have
--- ended. False and why when either side failed.
local function carry(conn: Net.Conn, first: string, io: sandbox_connect.Io, trace: function(step: string)): boolean, string
  local trouble = ""
  -- Whether the far side has ended what it sends, after which a write to it
  -- that fails is its closing and no fault of the connection.
  local far_ended = false
  local write_failed = ""
  local function fail(why: string)
    if trouble == "" then trouble = why end
  end
  conn:set_timeout(nil)
  local function up()
    while true do
      trace("up: waiting for standard input")
      local data, why = io.read()
      trace("up: read " .. (data ~= nil and plural.count(#data, "byte") or "failed: " .. tostring(why)))
      if data == nil then
        return fail("standard input: " .. why)
      elseif data == "" then
        -- What the program sends has ended: the far side hears it as one.
        local shut, shut_why = conn:shutdown("write")
        trace("up: end of input, shutdown(write) " .. (shut and "ok" or "failed: " .. tostring(shut_why)))
        return
      else
        local sent, send_why = conn:write(data)
        trace("up: wrote " .. plural.count(#data, "byte") .. " to the relay: " .. (sent and "ok" or tostring(send_why)))
        if not sent then
          -- Whether this is a fault or the far side's closing is known once
          -- the other task has read to the end of what it sends.
          write_failed = "writing to the relay: " .. send_why
          return
        end
      end
    end
  end
  local function down()
    local data = first
    while true do
      if data ~= "" then
        local wrote, write_why = io.write(data)
        trace("down: wrote " .. plural.count(#data, "byte") .. " to standard output: " .. (wrote and "ok" or tostring(write_why)))
        if not wrote then return fail("standard output: " .. write_why) end
      end
      trace("down: waiting for the relay")
      local more, why = conn:read(CHUNK)
      trace("down: read " .. (more ~= nil and plural.count(#more, "byte") or "end or failure: " .. tostring(why)))
      if more == nil then
        if why ~= "" then return fail("reading from the relay: " .. why) end
        -- The far side has ended what it sends: ours hears it as the end of
        -- standard output.
        far_ended = true
        local closed, closed_why = io.finish()
        trace("down: standard output closed " .. (closed and "ok" or tostring(closed_why)))
        return
      end
      data = more
    end
  end
  local reading = Poll.spawn(up)
  local writing = Poll.spawn(down)
  local _, _ = writing:join()
  -- A failure of the connection ends both; otherwise the side that sends
  -- has until standard input ends: a far side that has ended what it sends
  -- may still be reading, so the client does not stop at its end.
  if trouble ~= "" then reading:cancel() end
  local _, _ = reading:join()
  if write_failed ~= "" and not far_ended then fail(write_failed) end
  local _, _ = conn:close()
  if trouble ~= "" then return false, trouble end
  return true, ""
end

--- Runs the client for `args`, the words after `connect`: the status.
local function run_in(args: {string}, io: sandbox_connect.Io): integer
  local complain = bare.complainer("sandbox connect", io.err)
  -- COSMIC_CONNECT_TRACE=1 says each step on standard error, with the time
  -- since the start: for a hang that only a host's own behaviour explains.
  local tracing = io.getenv("COSMIC_CONNECT_TRACE") == "1"
  local began = Clock.monotonic_ns()
  local function trace(step: string)
    if tracing then
      io.err(("connect trace +%dms: %s"):format((Clock.monotonic_ns() - began) // 1000000, step))
    end
  end
  local host, text = args[1], args[2]
  if host == nil or text == nil or args[3] ~= nil then
    complain("takes a host and a port, as ssh's ProxyCommand='cosmic sandbox connect %h %p'")
    return bare.refused
  end
  local port = port_of(text)
  if port == nil then
    complain("the port is a number from 1 to 65535, not " .. bare.escape(text))
    return bare.refused
  end
  local request, request_why = Relay.Wire.socks_client_request(host, port)
  if request == nil then
    complain(bare.escape(host) .. ": " .. request_why)
    return bare.refused
  end
  local proxy, proxy_why = proxy_of(io)
  if proxy == nil then
    complain(proxy_why)
    return bare.refused
  end
  local login: string | nil
  if proxy.password ~= nil then
    local message, login_why = Relay.Wire.socks_client_auth(proxy.user, proxy.password)
    if message == nil then
      complain("the userinfo of ALL_PROXY: " .. login_why)
      return bare.refused
    end
    login = message
  end
  local relay_port = proxy.port
  local relay = "socks5h://127.0.0.1:" .. relay_port
  local made, connect_why = Net.connect(Net.tcp("127.0.0.1", relay_port), { timeout_ns = CONNECT_NS })
  if made == nil then
    complain("the relay at " .. relay .. ": " .. connect_why)
    return bare.failed
  end
  local conn: Net.Conn = made
  conn:set_timeout(io.answer_ns or ANSWER_NS)
  trace("connected to " .. relay)
  local where = bare.escape(host) .. ":" .. port
  local function fail(why: string): integer
    local _, _ = conn:close()
    complain(where .. ": " .. why)
    return bare.failed
  end
  local sent, sent_why = conn:write(Relay.Wire.socks_client_greeting(login ~= nil))
  if not sent then return fail("writing to the relay: " .. sent_why) end
  trace("greeting sent")
  local method = Relay.Wire.socks_method_reader(login ~= nil)
  local after_method, method_why = answered(conn, relay, function(chunk: string): string, integer, string
    local seen = method:feed(chunk)
    return seen.status, seen.consumed, seen.reason
  end)
  if after_method == nil then return fail(method_why) end
  trace("method read")
  if after_method ~= "" then return fail("the relay answered before it was asked") end
  if login ~= nil then
    local logged, logged_why = conn:write(login)
    if not logged then return fail("writing to the relay: " .. logged_why) end
    trace("token sent")
    local verdict = Relay.Wire.socks_auth_status_reader()
    local accepted = false
    local after_auth, auth_why = answered(conn, relay, function(chunk: string): string, integer, string
      local seen = verdict:feed(chunk)
      accepted = seen.accepted
      return seen.status, seen.consumed, seen.reason
    end)
    if after_auth == nil then return fail(auth_why) end
    if not accepted then return fail("the relay refused the sandbox's token") end
    if after_auth ~= "" then return fail("the relay answered before it was asked") end
    trace("token accepted")
  end
  local asked, asked_why = conn:write(request)
  if not asked then return fail("writing to the relay: " .. asked_why) end
  trace("request sent")
  local reader = Relay.Wire.socks_answer_reader()
  local code = 0
  local rest, answer_why = answered(conn, relay, function(chunk: string): string, integer, string
    local seen = reader:feed(chunk)
    code = seen.code
    return seen.status, seen.consumed, seen.reason
  end)
  if rest == nil then return fail(answer_why) end
  trace("answer read, code " .. code .. ", " .. plural.count(#rest, "byte") .. " after it")
  if code ~= 0 then
    return fail(Relay.Wire.socks_reply_meaning(code) .. " (SOCKS reply " .. code .. "); the relay's log line says why")
  end
  local carried, carry_why = carry(conn, rest, io, trace)
  if not carried then
    complain(where .. ": " .. carry_why)
    return bare.failed
  end
  return bare.ok
end

--- Runs the client for `args`, the words after `connect` on the command
--- line, and answers its exit status.
--- @param args the host and the port
--- @param io the environment, descriptors and complaints; the process's own when nil
--- @return the exit status
function sandbox_connect.run(args: {string}, io?: sandbox_connect.Io): integer
  local here = io or standard_io(0, 1)
  -- A caller that is a task of a run already (a test) has the run it needs.
  if Poll.in_task() then return run_in(args, here) end
  local status = bare.failed
  Poll.run(function()
    status = run_in(args, here)
  end)
  return status
end

return sandbox_connect
