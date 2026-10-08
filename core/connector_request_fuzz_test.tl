--- Fuzz property for the native connector's request parser
--- (core/connector.c's `connector_decode` and the checks `connector_serve`
--- makes of what it decodes): drawn requests, their fields at and beside
--- what each check refuses, are written to the real, confined connector
--- in pieces cut at drawn places, and every one must be answered once,
--- with its own tag, as a model of the protocol says. Replies may come in
--- any order, so they are matched by tag. The table holds one loopback
--- listener, and the public lists refuse every address but 127.0.0.0/8,
--- so nothing past this worker's own loopback is reached. `FUZZ_SEED` and
--- `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
local Fuzz = require("build.fuzz")
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")
local type _ = require("cosmic.child")
local type _net = require("cosmic.net")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
Test.policy{ loopback = { "127.0.0.1" }, promises = { "fork" } }
local type Searcher = function(string): any, any
local function table_for(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: a loader's extra is the raw table
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error("no raw table")
end
local process = table_for("cosmic.child") as raw_process -- cast: core/process.h's table
local socket = table_for("cosmic.net") as raw_socket -- cast: core/socket.h's table

local PUBLIC <const> = 0xffffffff
--- A drawn port that stands for the listener's, which is known only once
--- the check runs: past any port, so it is no port of its own.
local LISTENER <const> = 0x10000000
--- Every IPv4 address but 127.0.0.0/8, and all of 2000::/3, the IPv6
--- addresses the connector does not refuse by itself.
local DENY <const>: {string} = { "0.0.0.0/2", "64.0.0.0/3", "96.0.0.0/4", "112.0.0.0/5", "120.0.0.0/6",
  "124.0.0.0/7", "126.0.0.0/8", "128.0.0.0/1", "2000::/3" }

local function word(src: Fuzz.Source): integer
  return src:int(0, 0xffff) << 16 | src:int(0, 0xffff)
end

--- One request as drawn, 36 bytes, its port LISTENER where it stands for
--- the listener's: shaped as a table request, as a public one, or as
--- neither, each field at or beside what a check refuses.
local function gen_request(src: Fuzz.Source): string
  local zeros = string.rep("\0", 16)
  local shape = src:int(0, 2)
  local index, family: integer, integer
  local address = zeros
  if shape == 0 then
    index = Fuzz.pick(src, { 1, 1, 1, 1, 1, 0, 2, word(src) })
    family = Fuzz.pick(src, { 0, 0, 0, 0, 0, 4, word(src) })
    address = Fuzz.pick(src, { zeros, zeros, zeros, string.rep("\0", 15) .. "\1" })
  else
    index = shape == 1 and PUBLIC or word(src)
    family = Fuzz.pick(src, { 4, 4, 4, 6, 5, 0, word(src) })
    address = Fuzz.pick(src, {
      zeros,
      string.char(127, 0, 0, 1) .. string.rep("\0", 12),
      string.char(127, 0, 0, 1) .. string.rep("\0", 12),
      string.char(127, 0, 0, src:int(2, 255)) .. string.rep("\0", 12),
      string.char(src:int(0, 255), src:int(0, 255), 0, 1) .. string.rep("\0", 12),
      string.char(127, 0, 0, 1) .. string.rep("\0", 11) .. string.char(src:int(1, 255)),
      string.char(0x20, 1) .. string.rep("\0", 13) .. string.char(1),
    })
  end
  local port = Fuzz.pick(src, { LISTENER, LISTENER, LISTENER, LISTENER, LISTENER, 0, 1, 65535, 65536, word(src) })
  local wait = Fuzz.pick(src, { 0, 0, 1000, 60000, 0xffffffff, src:int(500, 70000) })
  return string.pack(">I4I4I4I4I4", word(src), index, port, wait, family) .. address
end

--- What the connector answers `request`, its port the listener's where
--- it was drawn so: the errnos it may answer, and whether a success
--- passes a socket.
local function expected(request: string, listener: integer): {integer: boolean}, boolean, string
  local _, index, port, _, family = string.unpack(">I4I4I4I4I4", request)
  local address = request:sub(21)
  local function zero(from: integer): boolean
    return address:sub(from):find("[^\0]") == nil
  end
  if index ~= PUBLIC then
    if family ~= 0 or not zero(1) then return { [sys.EINVAL] = true }, false, "malformed" end
    if index ~= 1 or port ~= listener then return { [sys.EPERM] = true }, false, "outside" end
    return { [0] = true }, true, "table"
  end
  local length = family == 4 and 4 or family == 6 and 16 or 0
  if length == 0 or port > 65535 or not zero(length + 1) then
    return { [sys.EINVAL] = true }, false, "malformed"
  end
  if length == 16 or address:byte(1) ~= 127 then
    return { [socket.CONNECTOR_DENIED] = true }, false, "denied"
  end
  if port == 0 then return { [0] = true }, false, "decision" end
  if port == listener and address:sub(1, 4) == string.char(127, 0, 0, 1) then
    return { [0] = true }, true, "public"
  end
  -- Nothing else listens on this loopback; a host that runs this worker
  -- unsandboxed may have something that does.
  return { [0] = true, [socket.ECONNREFUSED] = true }, true, "public"
end

local function read_whole(fd: integer, count: integer): string
  local got = ""
  while #got < count do
    local more = assert(sys.read(fd, count - #got))
    assert(more ~= "", "the connector ended before it replied")
    got = got .. more
  end
  return got
end

local function require_native_connector()
  local result, why, number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (number == sys.ENOSYS or number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector confinement: " .. why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. (why or ""))
end

local function test_every_request_is_answered_once_with_its_own_tag(tmp: string)
  require_native_connector()
  local listener <close> = assert(socket.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 64))
  local port = assert(socket.bound(listener:fd())).port
  local pair = assert(process.connector_pair())
  local child, why = process.connector_start({ { host = "127.0.0.1", port = port } }, pair[2], 2000,
    { deny = DENY })
  assert(sys.close(pair[2]))
  assert(child, why)
  assert(string.unpack(">I4", read_whole(pair[1], 4)) == socket.CONNECTOR_HELLO, "the connector said no hello")
  local seen = Fuzz.run({
    name = "connector requests are answered once with their own tag",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local list: {string} = {}
      while Fuzz.more(src, #list, 12) do list[#list + 1] = gen_request(src) end
      local cuts: {string} = {}
      while Fuzz.more(src, #cuts, 8) do cuts[#cuts + 1] = string.pack(">I2", src:int(1, 40)) end
      return Fuzz.pack({ table.concat(list), table.concat(cuts) })
    end,
    requires = { "table", "public", "decision", "denied", "malformed", "outside", "split" },
    -- Well under what a run reaches, so that a generator whose inputs
    -- mostly stop at the parser's refusals is found out.
    shares = { table = 0.1, public = 0.08 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      if #fields ~= 2 or #fields[1] % 36 ~= 0 or #fields[2] % 2 ~= 0 then
        return false, "a malformed input"
      end
      local waiting: {integer: {integer: boolean}} = {}
      local passes: {integer: boolean} = {}
      local stream: {string} = {}
      local count = 0
      for at = 1, #fields[1], 36 do
        local request = fields[1]:sub(at, at + 35)
        local tag, index, drawn = string.unpack(">I4I4I4", request)
        -- Tags are the request's own to choose; the check keeps them
        -- apart, so each reply names one request.
        while waiting[tag] ~= nil do tag = (tag + 1) & 0xffffffff end
        local wire = string.pack(">I4I4I4", tag, index, drawn == LISTENER and port or drawn) .. request:sub(13)
        local allowed, passed, kind = expected(wire, port)
        waiting[tag], passes[tag] = allowed, passed
        Fuzz.label(kind)
        stream[#stream + 1] = wire
        count = count + 1
      end
      local bytes = table.concat(stream)
      -- Written in pieces cut where the input says, the rest at once.
      local from = 1
      for at = 1, #fields[2], 2 do
        if from > #bytes then break end
        local size = string.unpack(">I2", fields[2], at)
        local piece = bytes:sub(from, from + size - 1)
        if (from - 1) % 36 ~= 0 or (from - 1 + #piece) % 36 ~= 0 then Fuzz.label("split") end
        assert(sys.write(pair[1], piece) == #piece)
        from = from + #piece
      end
      if from <= #bytes then assert(sys.write(pair[1], bytes:sub(from)) == #bytes - from + 1) end
      for _ = 1, count do
        local tag, errno = string.unpack(">I4I4", read_whole(pair[1], 8))
        local allowed = waiting[tag]
        if allowed == nil then
          return false, "a reply for tag " .. tag .. ", which no request waits for"
        end
        waiting[tag] = nil
        if not allowed[errno] then
          return false, "tag " .. tag .. " was answered errno " .. errno
        end
        if errno == 0 and passes[tag] then
          local received = assert(socket.recvfds(pair[1], 1))
          local peer = socket.peer(received[1]:fd())
          assert(received[1]:close())
          if peer ~= nil and peer.port == port and peer.host == "127.0.0.1" then
            -- What the listener took is let go, so its queue never fills.
            assert(socket.wait(listener:fd(), false, 2000))
            local accepted = assert(socket.accept(listener:fd()))
            assert(accepted:close())
          end
        end
      end
      return true, ""
    end,
  })
  assert(seen >= 0)
  assert(sys.close(pair[1]))
  assert(assert(process.waitpid(child, false)).code == 0)
end
