--- `cosmic lsp`: a Language Server Protocol server for Teal, so an editor
--- shows what `cosmic fix` and `cosmic test` would refuse as it is typed.
---
--- It serves one editor over standard input and output, or, with
--- `--listen [host:]port` or `--socket <path>`, each editor that connects
--- (a session of its own per connection, [`build.lsp.session`]) until
--- SIGINT or SIGTERM. Messages are JSON-RPC 2.0 framed by a
--- `Content-Length` header, as the protocol's base layer says
--- ([`build.lsp.protocol`]). A session checks a document as a build
--- checks it ([`build.lsp.check`]), its project's modules read from the
--- working database the build stages ([`build.lsp.source`]).
---
--- Over standard input and output it exits 0 after `shutdown`, at `exit`
--- or the stream's end, and 1 at an `exit` or an end that comes without
--- `shutdown`, or a stream that breaks. A listener exits 0 when SIGINT or
--- SIGTERM stops it, closing every connection still open, and 1 when it
--- cannot listen, a socket file already at its path among the reasons:
--- one a listener that crashed left looks the same as one a live
--- listener whose backlog is full holds, so it is left for a person to
--- remove. A command line it refuses exits 2.
---
--- Its `spec` (build/verb_spec.tl) is `bare`, since standard output is
--- the protocol's, `fresh`: in cosmic's own tree a tool older than the
--- tree rebuilds itself first, as `docs` does, and `reads`: where another
--- run holds the working database or the rebuild lock, it starts at once
--- and rebuilds no tool; where that left the tool unchecked against the
--- tree, it stages nothing for the session ([`reboot.unchecked`]). Complaints go to standard
--- error as `cosmic: lsp: ...`.

local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local bare = require("build.bare")
local protocol = require("build.lsp.protocol")
local session = require("build.lsp.session")
local verb_spec = require("build.verb_spec")

local record lsp
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
end

local spec = assert(Cli.verbs["lsp"]).spec or {}

local usage = "cosmic lsp [--stdio] [--listen [host:]port] [--socket path]"

--- Whether `host` is a numeric IPv4 address, four decimal octets.
local function ipv4(host: string): boolean
  if host:match("^%d+%.%d+%.%d+%.%d+$") == nil then return false end
  for octet in host:gmatch("%d+") do
    local value = math.tointeger(tonumber(octet))
    if #octet > 3 or value == nil or value > 255 then return false end
  end
  return true
end

--- Whether `host` is a numeric IPv6 address: eight groups of up to four
--- hex digits, a run of them written `::` once at most, the last two an
--- IPv4 address where one ends it.
local function ipv6(host: string): boolean
  local text = host
  local groups = 0
  local tail = text:match(":(%d+%.%d+%.%d+%.%d+)$")
  if tail ~= nil then
    if not ipv4(tail) then return false end
    text = text:sub(1, #text - #tail) .. "0:0"
  end
  local first, last = text:find("::", 1, true)
  if first ~= nil and text:find("::", last, true) ~= nil then return false end
  local parts: {string} = {}
  if first ~= nil and last ~= nil then
    parts = { text:sub(1, first - 1), text:sub(last + 1) }
  else
    parts = { text }
  end
  for _, part in ipairs(parts) do
    if part ~= "" then
      for group in (part .. ":"):gmatch("([^:]*):") do
        if group:match("^%x%x?%x?%x?$") == nil then return false end
        groups = groups + 1
      end
    end
  end
  if first ~= nil then return groups < 8 end
  return groups == 8
end

--- The address `--listen` names: `port` alone is the loopback's, and a
--- host is a numeric IPv4 address or an IPv6 one in brackets.
local function listen_address(word: string): Net.Address | nil
  local host, port = word:match("^%[(.+)%]:(%d+)$")
  if host ~= nil and not ipv6(host) then return nil end
  if host == nil then
    host, port = word:match("^([^:]+):(%d+)$")
    if host ~= nil and not ipv4(host) then return nil end
  end
  if host == nil then host, port = "127.0.0.1", word:match("^(%d+)$") end
  if port == nil then return nil end
  local number = math.tointeger(tonumber(port))
  if number == nil or number > 65535 then return nil end
  return Net.tcp(host, number)
end

--- Whether `address` is reached only from this host.
local function loopback(address: Net.Address): boolean
  if address.kind == "unix" then return true end
  local host = address.host or ""
  return host:match("^127%.") ~= nil or host == "::1"
end

--- Where `address` listens, as a person reads it.
local function named(address: Net.Address): string
  if address.kind == "unix" then return address.path or "" end
  local host = address.host or ""
  if host:find(":", 1, true) ~= nil then host = "[" .. host .. "]" end
  return host .. ":" .. tostring(address.port)
end

--- What has arrived on standard input, read through `reader`
--- without waiting ([`protocol.Poll`]).
local function polled_input(reader: Stream.Reader): protocol.Poll
  return function(): string | nil, string
    local ready, _ = Poll.readable(0, 0)
    if not ready then return nil, "" end
    return reader:read()
  end
end

--- What has arrived on `conn`, read without waiting ([`protocol.Poll`]).
local function polled_conn(conn: Net.Conn): protocol.Poll
  return function(): string | nil, string
    conn:set_timeout(0)
    local chunk, why = conn:read()
    conn:set_timeout(nil)
    if chunk == nil then
      if why == Poll.TIMEOUT then return nil, "" end
      return nil, why
    end
    return chunk, ""
  end
end

--- The connections a listener has open, closed as it stops.
local record Open
  conns: {Net.Conn: boolean}
  stopping: boolean
end

--- How long a connection has to end once the server stops, after its
--- close: a session in a check ends the check first.
local GRACE_NS <const> = Clock.seconds(5)

--- Serves each editor that connects at `listeners`, a session of its own
--- below `root` each, until SIGINT or SIGTERM. Answers the exit code.
local function listen(root: string, listeners: {Net.Address}): integer
  local open: Open = { conns = {}, stopping = false }
  local ok, trouble = Net.serve({
    listeners = listeners,
    serve = function(conn: Net.Conn)
      open.conns[conn] = true
      local s = session.new(root, {
        -- A connection the stop closes ends its session, which has no
        -- complaint to make of it.
        err = function(line: string)
          if not open.stopping then bare.err(line) end
        end,
        store = nil,
      })
      local _ = session.serve(s, conn, function(text: string): boolean, string
        return conn:write(text)
      end, polled_conn(conn))
      open.conns[conn] = nil
    end,
    limits = nil,
    timeout_ns = nil,
    grace_ns = GRACE_NS,
    on_ready = function(addresses: {Net.Address}, _server: Net.Server)
      for _, address in ipairs(addresses) do
        bare.err("cosmic: lsp: listening at " .. named(address))
        if not loopback(address) then
          bare.err("cosmic: lsp: warning: " .. named(address) .. " is reached from beyond this " ..
              "host, and any client there reads the files below the root it names, unasked " ..
              "who it is")
        end
      end
    end,
    -- An editor holds its connection open and idle while it runs: the
    -- stop closes every one, or none would end.
    on_stop = function(_server: Net.Server)
      open.stopping = true
      local conns: {Net.Conn} = {}
      for conn in pairs(open.conns) do conns[#conns + 1] = conn end
      for _, conn in ipairs(conns) do
        local _, _ = conn:close()
      end
    end,
  })
  if not ok then
    bare.err("cosmic: lsp: " .. trouble)
    return bare.failed
  end
  return bare.ok
end

--- Why a listener does not listen at the socket file `path`, or nil
--- when nothing that is a socket is there: a socket file there may be a
--- live listener's, whose full backlog fails a connect as one nothing
--- listens at does, so it is never taken for one left behind. Anything
--- else at `path` is left for the listen to refuse.
local function socket_taken(path: string): string | nil
  local st, _ = Fs.stat(path)
  if st == nil or st.kind ~= "socket" then return nil end
  return path .. " is a socket file already; remove it if no server is running there"
end

--- Runs the command line `argv`, `lsp` at slot 1, and answers the exit
--- code.
local function run(argv: {integer:string}): integer
  local complain = bare.complainer("lsp", bare.err)
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end
  local given = parsed.words[1]
  if given ~= nil then
    complain("takes no words, given " .. given .. "; " .. usage)
    return bare.refused
  end
  local none: {string} = {}
  local listeners: {Net.Address} = {}
  for _, word in ipairs(parsed.all["--listen"] or none) do
    local address = listen_address(word)
    if address == nil then
      complain("--listen takes [host:]port, a numeric IPv4 host or an IPv6 one in brackets, given " ..
          word)
      return bare.refused
    end
    listeners[#listeners + 1] = address
  end
  for _, path in ipairs(parsed.all["--socket"] or none) do
    listeners[#listeners + 1] = Net.unix(path)
  end
  if parsed.set["--stdio"] == true and #listeners > 0 then
    complain("--stdio serves one editor, and takes no --listen or --socket; " .. usage)
    return bare.refused
  end
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    complain(root_trouble)
    return bare.failed
  end
  if #listeners == 0 then
    local input = Stream.from_fd(0)
    return session.serve(session.new(root), input, bare.out, polled_input(input))
  end
  for _, path in ipairs(parsed.all["--socket"] or none) do
    local taken = socket_taken(path)
    if taken ~= nil then
      complain(taken)
      return bare.failed
    end
  end
  return listen(root, listeners)
end

lsp.spec = {
  name = "lsp",
  run = run,
  bare = true,
  -- TODO: a tool the tree outdates while a session runs goes on checking
  -- with its own code until the editor starts it again, since `fresh`
  -- rebuilds it only before the verb runs. A session whose check went on
  -- without holding the tool to the tree, another run holding its
  -- database or rebuild lock ([`reboot.unchecked`]), serves the stubs last
  -- staged, or none where other code staged them ([`work.other_code`]),
  -- until it is restarted, staging nothing, even once the locks
  -- are free. The fix: at each stage, once no run holds them, check the
  -- tool against the tree, and where it is stale re-enter the rebuilt
  -- tool in this process, as [`build.reboot`] does, keeping the editor's
  -- stream and handing it the session's root, encoding and open
  -- documents. It waits on a check of the tool that stages and rebuilds
  -- without exec'ing ([`reboot.guard`] re-enters the command line), and
  -- on a way to hand a session to the tool it re-enters.
  fresh = true,
  reads = true,
  recheck_on_refusal = nil,
  summarizes_failure = nil,
  takes = "where to listen",
  exits = "`lsp` speaks the Language Server Protocol on its standard output and " ..
    "exits 0 after `shutdown`, at `exit` or the stream's end, 1 at an `exit` or an end " ..
    "with no `shutdown` before it or a stream that breaks; listening, it exits 0 when " ..
    "SIGINT or SIGTERM stops it and 1 when it cannot listen, as at a socket file already there; " ..
    "2 for a command line it refuses",
  passthrough = "it serves until its editor exits, which a case of the verb list cannot be",
  guide = "none: an editor starts it, not a person",
  tests = { "build.lsp.check_test", "build.lsp.dependents_test", "build.lsp.lines_test", "build.lsp.protocol_test", "build.lsp.session_test",
    "build.lsp.source_test", "build.lsp.tool_test" },
}

return lsp
