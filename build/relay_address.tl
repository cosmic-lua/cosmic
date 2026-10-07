--- Which destination addresses the sandbox relay may connect to: the
--- pure half of its address checks (doc/plans/sandbox.md, "The relay and
--- the terminal"). A granted name is resolved once; [`relay_address.select`]
--- classifies every answer and picks the first allowed one, so a name whose
--- answers mix allowed and forbidden addresses still reaches an allowed
--- one and never a forbidden one.
---
--- An address is refused unless a literal grant names exactly it: a
--- `connect` target whose host is that address (and whose port is the
--- one asked for, or "*"). The classes refused:
---
--- - loopback (127/8, ::1) and unspecified (0.0.0.0/8, ::);
--- - link-local (169.254/16, fe80::/10);
--- - multicast (224/4, ff00::/8), broadcast (255.255.255.255) and the
---   rest of the reserved 240/4;
--- - private (10/8, 172.16/12, 192.168/16, fc00::/7, and the deprecated
---   site-local fec0::/10);
--- - carrier-grade NAT (100.64/10);
--- - cloud metadata services: 169.254.169.254, fd00:ec2::254 and 100.100.100.200,
---   named though a range above holds each, so the refusal says what it is;
--- - documentation and benchmarking ranges (192.0.2/24, 198.51.100/24,
---   203.0.113/24, 198.18/15, 2001:db8::/32, 3fff::/20, 2001:2::/48). Nothing
---   legitimate answers there, and some networks route them to something
---   internal (198.18/15 is a common fake-IP range of local proxies), so a
---   name that resolves to one is refused rather than trusted;
--- - the host's own addresses, which the caller lists.
---
--- An IPv6 address that carries an IPv4 one is the IPv4 address it
--- carries, and refused when that one is: IPv4-mapped ::ffff:0:0/96,
--- IPv4-compatible ::/96 and NAT64 (64:ff9b::/96 and, as RFC 6052 lays
--- the address out in a /48, 64:ff9b:1::/48). 6to4 (2002::/16) and Teredo
--- (2001::/32) are refused outright with a reason of their own: decoding
--- either is a way to get it wrong, and a name that answers with one is
--- not one a sandbox needs. A literal grant of the carrier opens only the
--- carrier's own spelling; a grant of the IPv4 address it carries does not.
---
--- Addresses are in the strict grammar the core's numeric hosts take
--- (core/socket.c's `cosmic_numeric_host`): IPv4 as four decimal octets
--- with no leading zeros, IPv6 in hex groups of one to four digits with at
--- most one "::" and an IPv4 tail, no zone. Anything else is refused as
--- not numeric: an answer is untrusted bytes from DNS.

local record relay_address
  --- One answer of a name, as `Net.resolve` returns it.
  record Answer
    --- The numeric address text.
    address: string
    --- Its family, kept with the answer and not consulted: the address's
    --- own text decides how it is read.
    family: string
  end
end

--- The longest text of an IPv6 address, "ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255".
local MAX_ADDRESS <const> = 45

--- What each class is called in a refusal.
local PHRASES <const>: {string: string} = {
  loopback = "a loopback address",
  unspecified = "an unspecified address",
  ["link-local"] = "a link-local address",
  multicast = "a multicast address",
  broadcast = "the broadcast address",
  reserved = "a reserved address",
  private = "a private address",
  cgnat = "a carrier-grade NAT address",
  metadata = "a metadata address",
  documentation = "a documentation address",
  benchmark = "a benchmarking address",
  own = "one of this host's own addresses",
}

--- The IPv4 octets of `text` (four decimal numbers, none with a leading
--- zero), or nil.
local function parse4(text: string): {integer} | nil
  local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a == nil then return nil end
  local out: {integer} = {}
  for _, part in ipairs({ a, b, c, d }) do
    if #part > 3 or (#part > 1 and part:sub(1, 1) == "0") then return nil end
    local n = math.tointeger(tonumber(part))
    if n > 255 then return nil end
    out[#out + 1] = n
  end
  return out
end

--- The 16-bit groups of `list`, colon-separated, as numbers, with an
--- IPv4 tail (when `tail4`, and only as the last part) as its two. Nil
--- for an empty part, one of more than four digits or that is no hex.
local function groups(list: string, tail4: boolean): {integer} | nil
  local parts: {string} = {}
  local out: {integer} = {}
  if list == "" then return out end
  for part in (list .. ":"):gmatch("([^:]*):") do parts[#parts + 1] = part end
  for i, part in ipairs(parts) do
    if part:find(".", 1, true) then
      local v4 = tail4 and i == #parts and parse4(part)
      if not v4 then return nil end
      out[#out + 1] = v4[1] * 256 + v4[2]
      out[#out + 1] = v4[3] * 256 + v4[4]
    else
      if #part < 1 or #part > 4 or part:find("%X") then return nil end
      out[#out + 1] = tonumber(part, 16)
    end
  end
  return out
end

--- The 16 bytes of the IPv6 address `text`, or nil.
local function parse6(text: string): {integer} | nil
  local start = text:find("::", 1, true)
  local head, tail, elided: string, string, boolean
  if start then
    if text:find("::", start + 1, true) then return nil end
    head, tail, elided = text:sub(1, start - 1), text:sub(start + 2), true
  else
    head, tail, elided = text, "", false
  end
  -- Without "::" the address is one list whose last group may be the
  -- IPv4 tail; with it the head has none, and the tail's last group may.
  local first = groups(head, not elided)
  local second = groups(tail, true)
  if first == nil or second == nil then return nil end
  local all: {integer} = {}
  for _, g in ipairs(first) do all[#all + 1] = g end
  local gap = 8 - #first - #second
  if elided then
    if gap < 1 then return nil end
    for _ = 1, gap do all[#all + 1] = 0 end
  elseif gap ~= 0 then
    return nil
  end
  for _, g in ipairs(second) do all[#all + 1] = g end
  local out: {integer} = {}
  for _, g in ipairs(all) do
    out[#out + 1] = g >> 8
    out[#out + 1] = g & 0xff
  end
  return out
end

--- The bytes of the numeric address `address`, most significant first: 4
--- for an IPv4 one, 16 for an IPv6 one. Nil for anything else, which
--- never raises.
--- @param address string The text to read
--- @return {integer}|nil The bytes
function relay_address.parse(address: string): {integer} | nil
  if type(address) ~= "string" or address == "" or #address > MAX_ADDRESS then
    return nil
  end
  if address:find(":", 1, true) then return parse6(address) end
  return parse4(address)
end

local function same(a: {integer}, b: {integer}): boolean
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

--- Whether `bytes` begins with `prefix`.
local function begins(bytes: {integer}, prefix: {integer}): boolean
  for i = 1, #prefix do
    if bytes[i] ~= prefix[i] then return false end
  end
  return true
end

local METADATA <const>: {{integer}} = {
  { 169, 254, 169, 254 },
  { 100, 100, 100, 200 },
  { 0xfd, 0x00, 0x0e, 0xc2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x54 },
}

--- The class an IPv4 address is refused as, or nil. `own` holds the host's
--- addresses as bytes.
local function class4(b: {integer}, own: {{integer}}): string | nil
  local a, c, d = b[1], b[2], b[3]
  for _, m in ipairs(METADATA) do
    if same(b, m) then return "metadata" end
  end
  for _, o in ipairs(own) do
    if same(b, o) then return "own" end
  end
  if a == 0 then return "unspecified" end
  if a == 10 then return "private" end
  if a == 100 and c & 0xc0 == 64 then return "cgnat" end
  if a == 127 then return "loopback" end
  if a == 169 and c == 254 then return "link-local" end
  if a == 172 and c & 0xf0 == 16 then return "private" end
  if a == 192 and c == 168 then return "private" end
  if a == 192 and c == 0 and d == 2 then return "documentation" end
  if a == 198 and c & 0xfe == 18 then return "benchmark" end
  if a == 198 and c == 51 and d == 100 then return "documentation" end
  if a == 203 and c == 0 and d == 113 then return "documentation" end
  if a >= 224 and a <= 239 then return "multicast" end
  if a == 255 and c == 255 and d == 255 and b[4] == 255 then return "broadcast" end
  if a >= 240 then return "reserved" end
  return nil
end

--- How an IPv6 address carries an IPv4 one, the IPv4 address's bytes,
--- or nil for one that carries none.
local function carried(b: {integer}): string | nil, {integer} | nil
  local function last(): {integer}
    return { b[13], b[14], b[15], b[16] }
  end
  local zero10 = true
  for i = 1, 10 do
    if b[i] ~= 0 then zero10 = false end
  end
  if zero10 and b[11] == 0xff and b[12] == 0xff then return "an IPv4-mapped", last() end
  if zero10 and b[11] == 0 and b[12] == 0 then return "an IPv4-compatible", last() end
  if begins(b, { 0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0 }) then
    return "a NAT64", last()
  end
  -- RFC 6052: after a /48 prefix the address is bits 48-63 and 72-87,
  -- the bits between (64-71) being zero.
  if begins(b, { 0x00, 0x64, 0xff, 0x9b, 0x00, 0x01 }) then
    return "a NAT64", { b[7], b[8], b[10], b[11] }
  end
  return nil
end

--- The class an IPv6 address is refused as, or nil.
local function class6(b: {integer}, own: {{integer}}): string | nil
  for _, m in ipairs(METADATA) do
    if same(b, m) then return "metadata" end
  end
  for _, o in ipairs(own) do
    if same(b, o) then return "own" end
  end
  if same(b, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }) then return "unspecified" end
  if same(b, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }) then return "loopback" end
  local first, second = b[1], b[2]
  if first == 0xfe and second & 0xc0 == 0x80 then return "link-local" end
  if first == 0xfe and second & 0xc0 == 0xc0 then return "private" end
  if first & 0xfe == 0xfc then return "private" end
  if first == 0xff then return "multicast" end
  if begins(b, { 0x20, 0x01, 0x0d, 0xb8 }) then return "documentation" end
  if first == 0x3f and second == 0xff and b[3] & 0xf0 == 0 then return "documentation" end
  if begins(b, { 0x20, 0x01, 0x00, 0x02, 0x00, 0x00 }) then return "benchmark" end
  return nil
end

local function dotted(b: {integer}): string
  return table.concat({ b[1], b[2], b[3], b[4] }, ".")
end

--- `address` as the host of a `connect` grant.
local function target(address: string, port: integer): string
  local host = address:find(":", 1, true) and "[" .. address .. "]" or address
  return host .. ":" .. port
end

--- Whether a `connect` target in `grants` names exactly `bytes` for
--- `port`: its host is that numeric address (an IPv6 one in brackets)
--- and its port the one asked for or "*". A grant of a name opens no address.
local function granted(bytes: {integer}, port: integer, grants: {string}): boolean
  for _, grant in ipairs(grants) do
    local host, at = grant:match("^(.+):([^:]+)$")
    if host ~= nil then
      local inner = host:match("^%[(.*)%]$")
      if inner ~= nil then
        host = inner
        if not inner:find(":", 1, true) then host = "" end
      elseif host:find(":", 1, true) then
        host = ""
      end
      local parsed = host ~= "" and relay_address.parse(host)
      if parsed and same(parsed, bytes) and (at == "*" or at == tostring(port)) then
        return true
      end
    end
  end
  return false
end

--- Whether the relay may connect to the numeric `address` on `port`.
--- Allowed answers `true` and "". Refused answers `false` and a reason
--- that names the class and the remedy, a literal grant:
--- "169.254.169.254 is a metadata address: grant it literally with
--- --connect 169.254.169.254:80". Text that is no numeric address is
--- refused too.
--- @param address string The numeric address text, as an answer holds it
--- @param port integer The port the program asked for
--- @param grants {string} The policy's `connect` targets (`host:port`)
--- @param own {string} The host's own addresses, numeric; one that is no
--- numeric address raises
--- @return boolean Whether the connection is allowed
--- @return string The reason it is refused, "" when it is allowed
function relay_address.check(address: string, port: integer, grants: {string},
                             own: {string}): boolean, string
  local bytes = relay_address.parse(address)
  if bytes == nil then
    local shown = tostring(address):gsub("[%c\128-\255]", "?")
    return false, "\"" .. shown .. "\" is not a numeric address"
  end
  local mine: {{integer}} = {}
  for _, text in ipairs(own) do
    local parsed = relay_address.parse(text)
    if parsed == nil then error("own address \"" .. text .. "\" is not numeric", 2) end
    mine[#mine + 1] = parsed
  end
  if granted(bytes, port, grants) then return true, "" end
  local remedy = ": grant it literally with --connect " .. target(address, port)
  if #bytes == 4 then
    local class = class4(bytes, mine)
    if class then return false, address .. " is " .. PHRASES[class] .. remedy end
    return true, ""
  end
  local direct = class6(bytes, mine)
  if direct then return false, address .. " is " .. PHRASES[direct] .. remedy end
  local form, v4 = carried(bytes)
  if form and v4 then
    local class = class4(v4, mine)
    if class then
      return false, address .. " is " .. form .. " address carrying " .. dotted(v4) ..
        ", " .. PHRASES[class] .. remedy
    end
    return true, ""
  end
  if begins(bytes, { 0x20, 0x02 }) then
    return false, address .. " is a 6to4 address, which carries an IPv4 address the relay " ..
      "does not decode" .. remedy
  end
  if begins(bytes, { 0x20, 0x01, 0x00, 0x00 }) then
    return false, address .. " is a Teredo address, which carries IPv4 addresses the relay " ..
      "does not decode" .. remedy
  end
  return true, ""
end

--- The first of `answers` the relay may connect to on `port`, which is the
--- only one it connects to. Nil and every answer's reason when none is
--- allowed, so the refusal says why each was; an empty list is refused
--- with its own reason.
--- @param answers {Answer} Every answer for a name, in the order received
--- @param port integer The port the program asked for
--- @param grants {string} The policy's `connect` targets (`host:port`)
--- @param own {string} The host's own addresses, numeric
--- @return Answer|nil The first allowed answer
--- @return string Why none is allowed, "" when one is
function relay_address.select(answers: {relay_address.Answer}, port: integer,
                              grants: {string}, own: {string}): relay_address.Answer | nil, string
  if #answers == 0 then return nil, "the name has no addresses" end
  local why: {string} = {}
  for _, answer in ipairs(answers) do
    local ok, reason = relay_address.check(answer.address, port, grants, own)
    if ok then return answer, "" end
    why[#why + 1] = reason
  end
  return nil, "no address of the name is allowed: " .. table.concat(why, "; ")
end

-- TODO: the relay needs the host's own addresses for `own`, and the core has
-- no binding that lists them (no getifaddrs in core/ or cosmic.sys): add one
-- and have the relay pass its addresses here, once cosmic.sys carries getifaddrs.

return relay_address
