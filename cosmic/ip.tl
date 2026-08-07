--- IP address parsing, formatting, and classification utilities.
--- The typed Addr is the only address currency in public signatures
--- (api-review-2): parse and resolve return Addr, sockets accept
--- and return Addr, and classification lives on Addr methods. The
--- implementation is IPv4-only — IPv6 strings are rejected with an
--- explicit error — but the shape is ready for IPv6 as a value
--- extension: a later "inet6" family is a new Addr value, not a new
--- API. Addr:int() exposes the raw v4 integer for the C boundary.
--- The format halves are method-form: Addr:format() and Cidr:format()
--- (or tostring()) invert parse and parse_cidr.
local cosmo = require("cosmo")

--- Category of an IPv4 address, as reported by categorize().
--- LOOPBACK/PRIVATE/TESTNET/MULTICAST are special-use ranges; the rest
--- name the registry or organization the block is delegated to.
local type Category = cosmo.IpCategory

--- Address family. IPv4 only today; IPv6 (whilp/cosmopolitan#144) adds
--- "inet6" as a value, leaving every Addr-taking signature unchanged.
local enum Family
  "inet"
end

--- A typed IP address: the one address type in public signatures.
--- Compares by value (two Addrs are == when they hold the same
--- address) and formats with tostring().
local record Addr
  _n: integer
  --- Address family; "inet" for IPv4.
  family: Family
  --- Get the raw integer representation (the IPv4 payload).
  --- Use this at the C boundary or for arithmetic on the raw value.
  --- @return integer The IP address as an integer
  int: function(Addr): integer
  --- Format as a dotted-quad string (e.g., "192.168.1.1").
  --- @return string The formatted IP address
  format: function(Addr): string
  --- Categorize the address (e.g., "LOOPBACK", "PRIVATE", "ARIN").
  --- @return Category The category name
  categorize: function(Addr): Category
  --- Check if this is a loopback address (127.x.x.x).
  --- @return boolean True if loopback
  is_loopback: function(Addr): boolean
  --- Check if this is a private address (10.x, 172.16-31.x, 192.168.x).
  --- @return boolean True if private
  is_private: function(Addr): boolean
  --- Check if this is a public/routable address.
  --- @return boolean True if public
  is_public: function(Addr): boolean
end

local function addr_int(self: Addr): integer
  return self._n
end

local function addr_format(self: Addr): string
  return cosmo.FormatIp(self._n)
end

local function addr_categorize(self: Addr): Category
  return cosmo.CategorizeIp(self._n)
end

local function addr_is_loopback(self: Addr): boolean
  return cosmo.IsLoopbackIp(self._n)
end

local function addr_is_private(self: Addr): boolean
  return cosmo.IsPrivateIp(self._n)
end

local function addr_is_public(self: Addr): boolean
  return cosmo.IsPublicIp(self._n)
end

-- Methods and the family constant live on the shared metatable (
-- precedent), so make_addr allocates one two-field table and nothing else.
local Addr_mt: metatable < Addr > = {
  __index = {
    family = "inet",
    int = addr_int,
    format = addr_format,
    categorize = addr_categorize,
    is_loopback = addr_is_loopback,
    is_private = addr_is_private,
    is_public = addr_is_public,
  } as Addr, -- cast: __index method table as record
  __tostring = function(self: Addr): string
    return cosmo.FormatIp(self._n)
  end,
  __eq = function(a: Addr, b: Addr): boolean
    return a._n == b._n
  end,
}

local function make_addr(n: integer): Addr
  return setmetatable({_n = n} as Addr, Addr_mt) -- cast: partial table into record
end

--- Wrap a raw integer as a typed Addr.
--- This is the explicit int-to-Addr constructor for the C boundary
--- (e.g. values from cosmo bindings); everything else should already
--- hold an Addr.
--- @param n integer The IP address as an integer
--- @return Addr The typed IP address
local function from_int(n: integer): Addr
  return make_addr(n)
end

--- Parse an IPv4 address string into a typed Addr.
--- Strict dotted quad only: exactly four decimal octets 0-255, no
--- leading zeros ("127.1", "1.2.3.4.5", "01.2.3.4" are all errors).
--- IPv6 is rejected with an explicit error.
--- @param str string The IP address string (e.g., "192.168.1.1")
--- @return Addr | nil The typed IP address, or nil on error
--- @return string Error message if parsing failed
local function parse(str: string): Addr | nil, string
  if not str or str == "" then
    return nil, "empty IP address"
  end
  if str:find(":", 1, true) then
    return nil, "IPv6 not supported: " .. str
  end
  local a, b, c, d = str:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return nil, "invalid IPv4 address (want dotted quad): " .. str
  end
  local n: integer = 0
  for _, octet in ipairs({a, b, c, d}) do
    -- no leading zeros: "0" is fine, "01" reads as octal in other parsers
    if #octet > 3 or (#octet > 1 and octet:sub(1, 1) == "0") then
      return nil, "invalid IPv4 octet '" .. octet .. "' in: " .. str
    end
    local v = math.tointeger(tonumber(octet))
    if v > 255 then
      return nil, "invalid IPv4 octet '" .. octet .. "' in: " .. str
    end
    n = n * 256 + v
  end
  return make_addr(n)
end

--- Look up a hostname and return a typed Addr.
--- Returns nil and an error message on failure.
--- @param hostname string The hostname to look up
--- @return Addr? The resolved IP address, or nil on error
--- @return string? Error message on failure
local function resolve(hostname: string): Addr | nil, string
  local raw, err = cosmo.ResolveIp(hostname)
  if not raw then
    return nil, "dns: lookup failed for " .. hostname .. ": " .. tostring(err)
  end
  return make_addr(raw)
end

--- A parsed IPv4 CIDR block (e.g. "10.0.0.0/8"). Compares by value
--- and formats with tostring(). Construct with parse_cidr().
local record Cidr
  _n: integer
  _bits: integer
  --- Prefix length (0-32).
  bits: function(Cidr): integer
  --- First address of the block (the network address).
  --- @return Addr The network address
  network: function(Cidr): Addr
  --- The netmask (e.g. 255.255.255.0 for /24).
  --- @return Addr The netmask
  netmask: function(Cidr): Addr
  --- Last address of the block (the broadcast address).
  --- @return Addr The broadcast address
  broadcast: function(Cidr): Addr
  --- Number of addresses in the block (including network/broadcast).
  --- @return integer The block size
  size: function(Cidr): integer
  --- Check whether the block contains an address. Takes the typed
  --- Addr only: a raw string would make an unparseable input
  --- indistinguishable from a non-member — the fail-open direction
  --- for an allowlist check. Parse first and handle the error there.
  --- @param a Addr The address
  --- @return boolean True when contained
  contains: function(Cidr, Addr): boolean
  --- Format as "addr/bits" (same as tostring()).
  --- @return string The CIDR notation
  format: function(Cidr): string
end

--- Netmask integer for a prefix length (0 -> 0, 24 -> 0xFFFFFF00).
local function cidr_mask(bits: integer): integer
  if bits == 0 then
    return 0
  end
  return (~ ((1 << (32 - bits)) - 1)) & 0xFFFFFFFF
end

local function cidr_bits(self: Cidr): integer
  return self._bits
end

local function cidr_network(self: Cidr): Addr
  return make_addr(self._n)
end

local function cidr_netmask(self: Cidr): Addr
  return make_addr(cidr_mask(self._bits))
end

local function cidr_broadcast(self: Cidr): Addr
  return make_addr(self._n | (~ cidr_mask(self._bits) & 0xFFFFFFFF))
end

local function cidr_size(self: Cidr): integer
  return 1 << (32 - self._bits)
end

local function cidr_contains(self: Cidr, a: Addr): boolean
  return (a:int() & cidr_mask(self._bits)) == self._n
end

local function cidr_format(self: Cidr): string
  return cosmo.FormatIp(self._n) .. "/" .. self._bits
end

local Cidr_mt: metatable < Cidr > = {
  __index = {
    bits = cidr_bits,
    network = cidr_network,
    netmask = cidr_netmask,
    broadcast = cidr_broadcast,
    size = cidr_size,
    contains = cidr_contains,
    format = cidr_format,
  } as Cidr, -- cast: __index method table as record
  __tostring = cidr_format,
  __eq = function(a: Cidr, b: Cidr): boolean
    return a._n == b._n and a._bits == b._bits
  end,
}

local function make_cidr(n: integer, bits: integer): Cidr
  -- cast: partial table into record
  return setmetatable({_n = n, _bits = bits} as Cidr, Cidr_mt)
end

--- Parse an IPv4 CIDR block ("addr/prefix", e.g. "192.168.0.0/16").
--- The address part follows parse()'s strict dotted-quad rules; the
--- prefix must be a decimal 0-32 without leading zeros. Host bits set
--- below the prefix are masked away (like Go's ParseCIDR):
--- parse_cidr("10.1.2.3/8") is the 10.0.0.0/8 block.
--- @param str string The CIDR string to parse
--- @return Cidr | nil The parsed block, or nil on error
--- @return string Error message if parsing failed
local function parse_cidr(str: string): Cidr | nil, string
  local addr_part, bits_part = str:match("^([^/]*)/(%d+)$")
  if not addr_part then
    return nil, "invalid CIDR (want addr/prefix): " .. str
  end
  local base, err = parse(addr_part)
  if not base then
    return nil, err
  end
  local bp = bits_part
  if #bp > 2 or (#bp > 1 and bp:sub(1, 1) == "0") then
    return nil, "invalid CIDR prefix '" .. bp .. "' in: " .. str
  end
  local bits = math.tointeger(tonumber(bp))
  if not bits or bits > 32 then
    return nil, "invalid CIDR prefix '" .. bp .. "' in: " .. str
  end
  local b = bits
  local n = base:int() & cidr_mask(b)
  return make_cidr(n, b)
end

local record IpModule
  type Addr = Addr
  type Category = Category
  type Family = Family
  type Cidr = Cidr
  from_int: function(n: integer): Addr
  parse: function(str: string): Addr | nil, string
  parse_cidr: function(str: string): Cidr | nil, string
  resolve: function(hostname: string): Addr | nil, string
end

local M: IpModule = {
  from_int = from_int,
  parse = parse,
  parse_cidr = parse_cidr,
  resolve = resolve,
}

return M
