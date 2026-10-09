--- Which destination addresses the sandbox's network relay
--- ([`cosmic.relay`]) may connect to: the pure half of its address checks.
--- A granted name is resolved once; [`relay_address.permitted`] classifies
--- every answer and keeps the allowed ones in order, so a name
--- whose answers mix allowed and forbidden addresses is connected to at an
--- allowed one, never a forbidden one.
---
--- An address is refused unless a literal grant names exactly it: a
--- `connect` target whose host is that numeric address and whose port is
--- the one asked for, or "*". The grant's grammar is [`cosmic.relay.grant`]'s, which
--- [`cosmic.sandbox`] validates `connect` by: an IPv6 host is in brackets
--- (`[::1]:80`) and any spelling of it opens the one address, and a name
--- or a "*" host opens no address. The classes refused:
---
--- - loopback (127/8, ::1) and unspecified (0.0.0.0/8, ::);
--- - link-local (169.254/16, fe80::/10);
--- - multicast (224/4, ff00::/8), broadcast (255.255.255.255) and the
---   rest of the reserved 240/4;
--- - private (10/8, 172.16/12, 192.168/16, fc00::/7, and the deprecated
---   site-local fec0::/10);
--- - carrier-grade NAT (100.64/10);
--- - cloud metadata services: 169.254.169.254, 168.63.129.16 (Azure's
---   wireserver), fd00:ec2::254 and 100.100.100.200, named though a range
---   may hold each, so the refusal says what it is;
--- - documentation and benchmarking ranges (192.0.2/24, 198.51.100/24,
---   203.0.113/24, 198.18/15, 2001:db8::/32, 3fff::/20, 2001:2::/48). Nothing
---   legitimate answers there, and some networks route them to something
---   internal (198.18/15 is a common fake-IP range of local proxies), so a
---   name that resolves to one is refused rather than trusted;
--- - IETF protocol assignments and other special ranges nothing public
---   answers on: 192.0.0.0/24 (Oracle's metadata 192.0.0.192 and the NAT64
---   discovery addresses), the deprecated 6to4 relay anycast 192.88.99/24,
---   100::/64 (discard), 5f00::/16 (SRv6 segment ids) and 2001::/23, which
---   holds the ORCHID ranges 2001:10::/28 and 2001:20::/28;
--- - the host's own addresses, which the caller lists
---   ([`relay_address.own_addresses`]);
--- - every IPv6 address outside 2000::/3, the global unicast range.
---
--- An IPv6 address that carries an IPv4 one is refused outright, each form
--- with a reason of its own, never decoded: IPv4-mapped ::ffff:0:0/96, the
--- well-known NAT64 prefix 64:ff9b::/96, IPv4-compatible ::/96, the SIIT
--- form 0:0:0:0:ffff:0::/96, 6to4 (2002::/16), Teredo (2001::/32), and the
--- local-use NAT64 prefix 64:ff9b:1::/48 (RFC 8215), which an operator may
--- carve at any RFC 6052 length -- a /96 gateway sends
--- 64:ff9b:1:808:0:0:a9fe:a9fe to 169.254.169.254 -- so no one decoding
--- is right. A literal grant of the carrier opens only the carrier's own
--- spelling; a grant of the IPv4 address it carries does not.
---
--- The classes above are data, [`relay_address.deny_cidrs`]: the native
--- connector ([`cosmic.net`]'s public mode) judges an address by the same
--- list in its own process, so a prefix is added in one place.
---
--- Addresses are in the strict grammar [`cosmic.net`]'s numeric hosts take:
--- IPv4 as four decimal octets
--- with no leading zeros, IPv6 in hex groups of one to four digits with at
--- most one "::" and an IPv4 tail, no zone. Anything else is refused as
--- not numeric: an answer is untrusted bytes from DNS.

local Grant = require("cosmic.relay.grant")

local record relay_address
  --- One answer of a name, as [`Net.resolve`] returns it.
  record Answer
    --- The numeric address text.
    address: string
    --- Its family, kept with the answer and not consulted: the address's
    --- own text decides how it is read.
    family: string
  end
end

--- One refused prefix.
local record Deny
  --- The prefix as "address/bits", the address numeric (IPv4 or IPv6).
  cidr: string
  --- The class it is refused as, which names its reason in a refusal.
  class: string
end

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
  special = "a special-purpose address",
  discard = "a discard-only address",
  mapped = "an IPv4-mapped address, which the relay does not decode",
  nat64 = "a NAT64 address, which the relay does not decode",
  nonglobal = "an IPv6 address outside 2000::/3, the global unicast range",
  compatible = "an IPv4-compatible address, which the relay does not decode",
  translated = "an IPv4-translated (SIIT) address, which the relay does not decode",
  ["6to4"] = "a 6to4 address, which carries an IPv4 address the relay does not decode",
  teredo = "a Teredo address, which carries IPv4 addresses the relay does not decode",
  nat64local = "a local-use NAT64 address, whose prefix length, and so the IPv4 address it " ..
    "carries, the relay cannot know",
}

--- The bytes of the numeric address `address`, most significant first: 4
--- for an IPv4 one, 16 for an IPv6 one. Nil for anything else, which
--- never raises.
--- @param address string The text to read
--- @return {integer}|nil The bytes
function relay_address.parse(address: string): {integer} | nil
  return Grant.address(address)
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

--- Every refused prefix, in the order a refusal names its class: the
--- first to hold an address wins, which makes `::` and `::1` unspecified
--- and loopback rather than IPv4-compatible, and a metadata address the
--- metadata one rather than its range's.
local DENY <const>: {Deny} = {
  { cidr = "169.254.169.254/32", class = "metadata" },
  { cidr = "100.100.100.200/32", class = "metadata" },
  { cidr = "168.63.129.16/32", class = "metadata" },
  { cidr = "fd00:ec2::254/128", class = "metadata" },
  { cidr = "0.0.0.0/8", class = "unspecified" },
  { cidr = "192.0.0.0/24", class = "special" },
  { cidr = "192.88.99.0/24", class = "special" },
  { cidr = "10.0.0.0/8", class = "private" },
  { cidr = "100.64.0.0/10", class = "cgnat" },
  { cidr = "127.0.0.0/8", class = "loopback" },
  { cidr = "169.254.0.0/16", class = "link-local" },
  { cidr = "172.16.0.0/12", class = "private" },
  { cidr = "192.168.0.0/16", class = "private" },
  { cidr = "192.0.2.0/24", class = "documentation" },
  { cidr = "198.18.0.0/15", class = "benchmark" },
  { cidr = "198.51.100.0/24", class = "documentation" },
  { cidr = "203.0.113.0/24", class = "documentation" },
  { cidr = "224.0.0.0/4", class = "multicast" },
  { cidr = "255.255.255.255/32", class = "broadcast" },
  { cidr = "240.0.0.0/4", class = "reserved" },
  { cidr = "::/128", class = "unspecified" },
  { cidr = "::1/128", class = "loopback" },
  { cidr = "::/96", class = "compatible" },
  { cidr = "::ffff:0:0/96", class = "mapped" },
  { cidr = "0:0:0:0:ffff:0::/96", class = "translated" },
  { cidr = "64:ff9b::/96", class = "nat64" },
  { cidr = "64:ff9b:1::/48", class = "nat64local" },
  { cidr = "fe80::/10", class = "link-local" },
  { cidr = "fec0::/10", class = "private" },
  { cidr = "fc00::/7", class = "private" },
  { cidr = "ff00::/8", class = "multicast" },
  { cidr = "100::/64", class = "discard" },
  { cidr = "5f00::/16", class = "special" },
  { cidr = "2002::/16", class = "6to4" },
  { cidr = "2001::/32", class = "teredo" },
  { cidr = "2001:db8::/32", class = "documentation" },
  { cidr = "3fff::/20", class = "documentation" },
  { cidr = "2001:2::/48", class = "benchmark" },
  -- 2001::/23, past the Teredo and benchmarking prefixes named above.
  { cidr = "2001::/23", class = "special" },
}

--- The refused prefixes as "address/bits" text, the list the native
--- connector takes as its `deny` ([`cosmic.net`]'s [`Net.connector`]). An
--- IPv6 address outside 2000::/3 is refused besides, by a rule of its own
--- and not a prefix here.
--- @return {string} The prefixes, in the order a refusal names them
function relay_address.deny_cidrs(): {string}
  local out: {string} = {}
  for i, entry in ipairs(DENY) do out[i] = entry.cidr end
  return out
end

local record Prefix
  bytes: {integer}
  bits: integer
  class: string
end

local PREFIXES <const>: {Prefix} = (function(): {Prefix}
  local out: {Prefix} = {}
  for _, entry in ipairs(DENY) do
    local address, bits = entry.cidr:match("^(.-)/(%d+)$")
    out[#out + 1] = { bytes = assert(relay_address.parse(address)), bits = math.tointeger(tonumber(bits)),
      class = entry.class }
  end
  return out
end)()

--- Whether `b` is in `prefix`.
local function within(b: {integer}, prefix: Prefix): boolean
  if #b ~= #prefix.bytes then return false end
  local whole = prefix.bits // 8
  for i = 1, whole do
    if b[i] ~= prefix.bytes[i] then return false end
  end
  local rest = prefix.bits % 8
  if rest == 0 then return true end
  local mask = (0xff << (8 - rest)) & 0xff
  return b[whole + 1] & mask == prefix.bytes[whole + 1] & mask
end

--- The class an address is refused as, or nil. `own` holds the host's
--- addresses as bytes.
local function classify(b: {integer}, own: {{integer}}): string | nil
  for _, prefix in ipairs(PREFIXES) do
    if prefix.class == "metadata" and within(b, prefix) then return "metadata" end
  end
  for _, o in ipairs(own) do
    if same(b, o) then return "own" end
  end
  for _, prefix in ipairs(PREFIXES) do
    if prefix.class ~= "metadata" and within(b, prefix) then return prefix.class end
  end
  if #b == 16 and b[1] & 0xe0 ~= 0x20 then return "nonglobal" end
  return nil
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
    local parsed, _ = Grant.parse(grant)
    if parsed ~= nil and parsed.bytes ~= nil and same(parsed.bytes, bytes) and
        (parsed.port == 0 or parsed.port == port) then
      return true
    end
  end
  return false
end

--- Whether a `connect` target in `grants` literally names `address` for
--- `port`, by the grammar this module's header gives: the relay asks it of
--- a request that carries an IP address, which no grant of a name or of "*"
--- opens. Text that is no numeric address is not granted.
--- @param address string The numeric address text
--- @param port integer The port asked for
--- @param grants {string} The policy's `connect` targets (`host:port`)
--- @return boolean Whether a grant names exactly this address and port
function relay_address.granted(address: string, port: integer, grants: {string}): boolean
  local bytes = relay_address.parse(address)
  return bytes ~= nil and granted(bytes, port, grants)
end

--- The host's own addresses `own`, numeric text, as the bytes [`check`] and
--- [`permitted`] take, which they would otherwise read again for every answer.
--- An IPv4-mapped entry is reduced to the IPv4 address it carries, so an
--- own address is refused however an answer spells it. Raises for an entry
--- that is no numeric address: a list of the host's own addresses is the
--- caller's, never untrusted: the relay's starter lists them.
--- @param own {string} The addresses, as text
--- @return {{integer}} Each one's bytes
function relay_address.own_addresses(own: {string}): {{integer}}
  local out: {{integer}} = {}
  for _, text in ipairs(own) do
    local bytes = relay_address.parse(text)
    if bytes == nil then error("own address \"" .. tostring(text) .. "\" is not numeric", 2) end
    if #bytes == 16 and begins(bytes, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }) then
      bytes = { bytes[13], bytes[14], bytes[15], bytes[16] }
    end
    out[#out + 1] = bytes
  end
  return out
end

--- The most bytes of an answer a refusal repeats.
local SHOWN <const> = 64

--- Whether the relay may connect to the numeric `address` on `port`.
--- Allowed answers `true` and "". Refused answers `false` and a reason
--- that names the class and the remedy, a literal grant:
--- "169.254.169.254 is a metadata address: grant it literally with
--- --connect 169.254.169.254:80". Text that is no numeric address is
--- refused too, shown cut to 64 bytes with its control and non-ASCII bytes
--- as "?".
--- @param address string The numeric address text, as an answer holds it
--- @param port integer The port the program asked for
--- @param grants {string} The policy's `connect` targets (`host:port`)
--- @param own {{integer}} The host's own addresses, from [`own_addresses`]
--- @return boolean Whether the connection is allowed
--- @return string The reason it is refused, "" when it is allowed
function relay_address.check(address: string, port: integer, grants: {string},
                             own: {{integer}}): boolean, string
  local bytes = relay_address.parse(address)
  if bytes == nil then
    local shown = tostring(address):sub(1, SHOWN):gsub("[%c\128-\255]", "?")
    if #tostring(address) > SHOWN then shown = shown .. "..." end
    return false, "\"" .. shown .. "\" is not a numeric address"
  end
  if granted(bytes, port, grants) then return true, "" end
  local class = classify(bytes, own)
  if class then
    return false, address .. " is " .. PHRASES[class] .. ": grant it literally with --connect " ..
      target(address, port)
  end
  return true, ""
end

--- Every one of `answers` the relay may connect to on `port`, in the order
--- received: the candidates it tries one after another, and never an
--- address outside them. Nil and every answer's reason when none is
--- allowed, so the refusal says why each was; an empty list is refused
--- with its own reason.
--- @param answers {Answer} Every answer for a name, in the order received
--- @param port integer The port the program asked for
--- @param grants {string} The policy's `connect` targets (`host:port`)
--- @param own {{integer}} The host's own addresses, from [`own_addresses`]
--- @return {Answer}|nil The allowed answers, at least one
--- @return string Why none is allowed, "" when one is
function relay_address.permitted(answers: {relay_address.Answer}, port: integer,
                                 grants: {string}, own: {{integer}}): {relay_address.Answer} | nil, string
  if #answers == 0 then return nil, "the name has no addresses" end
  local why: {string} = {}
  local allowed: {relay_address.Answer} = {}
  for _, answer in ipairs(answers) do
    local ok, reason = relay_address.check(answer.address, port, grants, own)
    if ok then
      allowed[#allowed + 1] = answer
    else
      why[#why + 1] = reason
    end
  end
  if #allowed > 0 then return allowed, "" end
  return nil, "no address of the name is allowed: " .. table.concat(why, "; ")
end

return relay_address
