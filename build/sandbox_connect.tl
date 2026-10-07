--- `cosmic sandbox connect HOST PORT`: the SOCKS5 client of the network
--- relay that `cosmic sandbox --connect` runs, for a program that speaks
--- no proxy protocol of its own and takes a command to reach a host
--- through: ssh's `ProxyCommand='cosmic sandbox connect %h %p'`.
---
--- It runs inside the sandbox, where the relay's variables are set: it
--- reads `ALL_PROXY` (`all_proxy` where that is unset), which must be the
--- relay's own SOCKS5 listener, `socks5h://127.0.0.1:1080`, and refuses any
--- other, naming it; a command line or an environment that is not a
--- sandbox's, with no such variable, is refused saying what this is for.
--- It connects there, offers no authentication, and asks the relay to
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
local RelayConfig = require("cosmic.relay_config")
local Wire = require("cosmic.relay_wire")
local sys = require("cosmic.sys")
local bare = require("build.bare")

--- The pieces of the process the client uses: what a test stands in for.
local record sandbox_connect
  --- Where the client reads, writes and complains.
  record Io
    --- A variable of the environment, or nil.
    getenv: function(name: string): string | nil
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- The descriptor of the standard input the connection is sent.
    input: integer
    --- The descriptor of the standard output the connection is written to.
    output: integer
  end
end

--- The most bytes read from either side at a time.
local CHUNK <const> = 4096
--- How long the relay has to answer the greeting and the request: its own
--- connect timeout is 10 seconds, and a resolve comes before it.
local ANSWER_NS <const> = Clock.seconds(60)

--- The relay's listener, which is the one `ALL_PROXY` the sandbox sets
--- names.
local PROXY <const> = "socks5h://127.0.0.1:" .. RelayConfig.socks_port

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
--- @param feed feeds the next bytes to a reader, and answers its status, how
--- many bytes it took and why it refused
--- @return the bytes read beyond what the reader took, or nil
--- @return why it refused or the connection failed, when nil
local function answered(conn: Net.Conn, feed: function(string): string, integer, string): string | nil, string
  while true do
    local data, why = conn:read(CHUNK)
    if data == nil then
      if why == "" then return nil, "the relay closed the connection before it answered" end
      if why == Poll.TIMEOUT then return nil, "the relay did not answer in time" end
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

--- Whether the environment names the relay's listener, and why not.
local function proxy_named(io: sandbox_connect.Io): boolean, string
  local value = io.getenv("ALL_PROXY") or io.getenv("all_proxy")
  if value == nil or value == "" then
    return false, "ALL_PROXY is not set: this is ssh's ProxyCommand inside `cosmic sandbox --connect HOST:PORT`, " ..
      "which sets it to the relay's SOCKS5 listener (" .. PROXY .. ")"
  end
  if value ~= PROXY and value ~= PROXY .. "/" then
    return false, "ALL_PROXY is " .. bare.escape(value) .. ", not " .. PROXY ..
      ", the sandbox relay's; no other proxy is served"
  end
  return true, ""
end

--- Passes standard input to `conn` and `conn` to standard output, `first`
--- the bytes that came after the relay's answer, until both sides have
--- ended. False and why when either side failed.
local function carry(conn: Net.Conn, first: string, io: sandbox_connect.Io): boolean, string
  local trouble = ""
  -- Whether the far side has ended what it sends, after which a write to it
  -- that fails is its closing and no fault of the connection.
  local far_ended = false
  local function fail(why: string)
    if trouble == "" then trouble = why end
  end
  conn:set_timeout(nil)
  local function up()
    while true do
      local ready, ready_why = Poll.readable(io.input)
      if not ready then return fail("standard input: " .. ready_why) end
      local data, why, errno = sys.read(io.input, CHUNK)
      if data == nil then
        if errno ~= sys.EAGAIN and errno ~= sys.EINTR then
          return fail("standard input: " .. why)
        end
      elseif data == "" then
        -- What the program sends has ended: the far side hears it as one.
        local _, _ = conn:shutdown("write")
        return
      else
        local sent, send_why = conn:write(data)
        if not sent then
          if far_ended then return end
          return fail("writing to the relay: " .. send_why)
        end
      end
    end
  end
  local function down()
    local data = first
    while true do
      if data ~= "" then
        local wrote, write_why = write_all(io.output, data)
        if not wrote then return fail("standard output: " .. write_why) end
      end
      local more, why = conn:read(CHUNK)
      if more == nil then
        if why ~= "" then return fail("reading from the relay: " .. why) end
        -- The far side has ended what it sends: ours hears it as the end of
        -- standard output.
        far_ended = true
        local _, _ = sys.close(io.output)
        return
      end
      data = more
    end
  end
  local reading = Poll.spawn(up)
  local writing = Poll.spawn(down)
  local _, _ = writing:join()
  -- A failure of the connection ends both; otherwise the side that sends
  -- has until standard input ends.
  if trouble ~= "" then reading:cancel() end
  local _, _ = reading:join()
  local _, _ = conn:close()
  if trouble ~= "" then return false, trouble end
  return true, ""
end

--- Runs the client for `args`, the words after `connect`: the status.
local function run_in(args: {string}, io: sandbox_connect.Io): integer
  local complain = bare.complainer("sandbox connect", io.err)
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
  local request, request_why = Wire.socks_client_request(host, port)
  if request == nil then
    complain(bare.escape(host) .. ": " .. request_why)
    return bare.refused
  end
  local named, proxy_why = proxy_named(io)
  if not named then
    complain(proxy_why)
    return bare.refused
  end
  local made, connect_why = Net.connect(Net.tcp("127.0.0.1", RelayConfig.socks_port), { timeout_ns = ANSWER_NS })
  if made == nil then
    complain("the relay at " .. PROXY .. ": " .. connect_why)
    return bare.failed
  end
  local conn: Net.Conn = made
  local where = bare.escape(host) .. ":" .. port
  local function fail(why: string): integer
    local _, _ = conn:close()
    complain(where .. ": " .. why)
    return bare.failed
  end
  local sent, sent_why = conn:write(Wire.socks_client_greeting())
  if not sent then return fail("writing to the relay: " .. sent_why) end
  local method = Wire.socks_method_reader()
  local after_method, method_why = answered(conn, function(chunk: string): string, integer, string
    local seen = method:feed(chunk)
    return seen.status, seen.consumed, seen.reason
  end)
  if after_method == nil then return fail(method_why) end
  if after_method ~= "" then return fail("the relay answered before it was asked") end
  local asked, asked_why = conn:write(request)
  if not asked then return fail("writing to the relay: " .. asked_why) end
  local reader = Wire.socks_answer_reader()
  local code = 0
  local rest, answer_why = answered(conn, function(chunk: string): string, integer, string
    local seen = reader:feed(chunk)
    code = seen.code
    return seen.status, seen.consumed, seen.reason
  end)
  if rest == nil then return fail(answer_why) end
  if code ~= 0 then
    return fail(Wire.socks_reply_meaning(code) .. " (SOCKS reply " .. code .. "); the relay's log line says why")
  end
  local carried, carry_why = carry(conn, rest, io)
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
  local here: sandbox_connect.Io = io or {
    getenv = sys.getenv, err = bare.err, input = 0, output = 1,
  }
  -- A caller that is a task of a run already (a test) has the run it needs.
  if Poll.in_task() then return run_in(args, here) end
  local status = bare.failed
  Poll.run(function()
    status = run_in(args, here)
  end)
  return status
end

return sandbox_connect
