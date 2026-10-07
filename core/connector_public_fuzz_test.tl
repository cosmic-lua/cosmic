--- Differential fuzz property for the native connector's public
--- classifier (core/connector.c's `connector_public_allowed`): drawn IPv4
--- and IPv6 addresses, most of them at or beside the edge of a refused
--- prefix, are judged by the real, confined connector (a request for the
--- decision alone, port 0) and by [`cosmic.relay.address`]'s `check`,
--- which is what the relay holds in depth: the two must agree on every
--- address. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).
local Fuzz = require("build.fuzz")
local type raw_process = require("cosmic.internal.process")
local type _ = require("cosmic.child")
local type _net = require("cosmic.net")
local Test = require("cosmic.test")
local Relay = require("cosmic.relay")
local sys = require("cosmic.sys")
local REFUSED <const> = 65536 -- a refusal by the lists, past any errno
Test.policy{ promises = { "fork" } }
local type Searcher = function(string): any, any
local function process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: a loader's extra is the raw table
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then return extra as raw_process end -- cast: core/process.h's table
  end
  error("no raw table")
end
local process = process_table()

local OWN <const>: {string} = { "8.8.4.4", "2606:4700::6810:84e5", "203.0.113.9", "2a00:1450:4001:81b::200e" }
local NONE: {string} = {}

--- The first and last address of `cidr`, and its length in bytes.
local function span(cidr: string): {integer}, {integer}
  local address, bits = cidr:match("^(.-)/(%d+)$")
  local first = assert(Relay.Address.parse(address))
  local last: {integer} = { table.unpack(first) }
  local held = math.tointeger(tonumber(bits))
  for i = 1, #first do
    local kept = math.max(0, math.min(8, held - (i - 1) * 8))
    local mask = (0xff << (8 - kept)) & 0xff
    first[i] = first[i] & mask
    last[i] = first[i] | (~mask & 0xff)
  end
  return first, last
end

--- `bytes` moved by `delta` (a few, up or down), carrying between bytes.
local function moved(bytes: {integer}, delta: integer): {integer}
  local out: {integer} = { table.unpack(bytes) }
  local carry = delta
  for i = #out, 1, -1 do
    local value = out[i] + carry
    if value > 255 then
      out[i], carry = value - 256, 1
    elseif value < 0 then
      out[i], carry = value + 256, -1
    else
      out[i], carry = value, 0
    end
    if carry == 0 then break end
  end
  return out
end

local DENIED <const>: {string} = Relay.Address.deny_cidrs()
local GLOBAL <const>: {integer} = { 0x20, 0x21, 0x26, 0x2a, 0x2c, 0x30, 0x3f }

--- One address as a 17-byte string: its length (4 or 16) and 16 bytes.
local function packed(bytes: {integer}): string
  return string.char(#bytes) .. string.char(table.unpack(bytes)) .. string.rep("\0", 16 - #bytes)
end

local function random_bytes(src: Fuzz.Source, count: integer): {integer}
  local out: {integer} = {}
  for i = 1, count do
    out[i] = src:int(0, 3) == 0 and src:int(0, 255) or Fuzz.pick(src, { 0, 1, 127, 128, 254, 255, src:int(0, 255) })
  end
  return out
end

--- One address, drawn: random, beside the edge of a refused prefix, a
--- random one in that prefix, with one bit flipped, one of the host's own
--- addresses or its neighbour, or in 2000::/3 so that only the lists judge it.
local function gen_address(src: Fuzz.Source): string
  local kind = src:int(0, 6)
  if kind == 0 then return packed(random_bytes(src, 4)) end
  if kind == 1 then return packed(random_bytes(src, 16)) end
  if kind == 2 then
    local own = assert(Relay.Address.parse(Fuzz.pick(src, OWN)))
    return packed(moved(own, src:int(-1, 1)))
  end
  local first, last = span(Fuzz.pick(src, DENIED))
  if kind == 3 or kind == 4 then
    return packed(moved(src:int(0, 1) == 0 and first or last, src:int(-2, 2)))
  end
  if kind == 5 then
    local inside: {integer} = {}
    for i = 1, #first do inside[i] = first[i] + src:int(0, last[i] - first[i]) end
    local at = src:int(0, #first * 8)
    if at >= 1 then
      local index = (at - 1) // 8 + 1
      inside[index] = inside[index] ~ (1 << (7 - (at - 1) % 8))
    end
    return packed(inside)
  end
  local bytes = random_bytes(src, 16)
  bytes[1] = Fuzz.pick(src, GLOBAL)
  return packed(bytes)
end

local function spelled(bytes: {integer}): string
  if #bytes == 4 then return table.concat(bytes, ".") end
  local groups: {string} = {}
  for i = 1, 16, 2 do groups[#groups + 1] = ("%x"):format(bytes[i] * 256 + bytes[i + 1]) end
  return table.concat(groups, ":")
end

local function require_native_connector()
  local result, why, number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (number == sys.ENOSYS or number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector confinement: " .. why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. (why or ""))
end

--- The connector's decision for `item`, 17 bytes as [`packed`] leaves them.
local function read_whole(fd: integer, count: integer): string
  local got = ""
  while #got < count do
    local more = assert(sys.read(fd, count - #got))
    assert(more ~= "", "the connector ended before it replied")
    got = got .. more
  end
  return got
end

local function decided(fd: integer, item: string): boolean
  local family = item:byte(1) == 4 and 4 or 6
  assert(sys.write(fd, string.pack(">I4I4I4I4I4", 3, 0xffffffff, 0, 0, family) .. item:sub(2)) == 36)
  local tag, errno = string.unpack(">I4I4", read_whole(fd, 8))
  assert(tag == 3, "the reply carries another tag: " .. tag)
  assert(errno == 0 or errno == REFUSED, "errno " .. errno)
  return errno == 0
end

local function test_the_connector_and_the_relay_s_check_agree_on_every_address(tmp: string)
  require_native_connector()
  local pair = assert(process.connector_pair())
  local child, why = process.connector_start({}, pair[2], 500, { deny = DENIED, own = OWN })
  assert(sys.close(pair[2]))
  assert(child, why)
  assert(string.unpack(">I4", read_whole(pair[1], 4)) == 0x434e4302, "the connector said no hello")
  local own = Relay.Address.own_addresses(OWN)
  local seen = Fuzz.run({
    name = "connector public classifier agrees with Relay.Address",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local list: {string} = {}
      while Fuzz.more(src, #list, 8) do list[#list + 1] = gen_address(src) end
      return Fuzz.pack(list)
    end,
    requires = { "allowed", "refused", "ipv4", "ipv6", "own", "outside" },
    shares = { allowed = 0.1, refused = 0.2, ipv4 = 0.3, ipv6 = 0.3, own = 0.01, outside = 0.1 },
    check = function(input: string): boolean, string
      for _, item in ipairs(Fuzz.unpack(input)) do
        local length = item:byte(1)
        if (length ~= 4 and length ~= 16) or #item ~= 17 then return false, "a malformed item" end
        local bytes = { item:byte(2, 1 + length) }
        local text = spelled(bytes)
        local want = Relay.Address.check(text, 443, NONE, own)
        local got = decided(pair[1], item)
        if got ~= want then
          return false, text .. ": the connector " .. (got and "allows" or "refuses") ..
            " it and the relay's check " .. (want and "allows" or "refuses") .. " it"
        end
        Fuzz.label(got and "allowed" or "refused")
        Fuzz.label(length == 4 and "ipv4" or "ipv6")
        if length == 16 and bytes[1] & 0xe0 ~= 0x20 then Fuzz.label("outside") end
        for _, mine in ipairs(own) do
          if table.concat(mine, ",") == table.concat(bytes, ",") then Fuzz.label("own") end
        end
      end
      return true, ""
    end,
  })
  assert(seen >= 0)
  assert(sys.close(pair[1]))
  assert(assert(process.waitpid(child, false)).code == 0)
end
