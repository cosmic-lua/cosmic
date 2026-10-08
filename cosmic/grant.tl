--- A policy's `connect` target, read once: the one grammar [`cosmic.sandbox`]
--- validates a `connect` entry by, the sandbox's starter plans the relay
--- from, and the relay matches a request against. A target is `host:port`;
--- the host is one of
---
--- - a DNS name: labels of letters, digits and inner hyphens, 63 bytes at
---   most and 253 in all, with no final label an `inet_aton` would read as a
---   number. It is lower-cased and loses a trailing dot, so `API.Example.com.`
---   and `api.example.com` are one grant;
--- - an IPv4 address of four decimal octets with no leading zero;
--- - an IPv6 address in brackets (`[::1]`), in any spelling the strict
---   grammar reads, canonical in RFC 5952's form;
--- - `*`, which grants every name (never an address, private or numeric:
---   those need a grant that names them).
---
--- and the port is a decimal number from 1 to 65535 with no leading zero,
--- or `*` for any. A pattern such as `*.example.com` is none of these: the
--- relay matches whole names, so a grant of it would open nothing, and it is
--- refused. Every host a target accepts, but `*`, is one the relay's CONNECT
--- and SOCKS readers ([`cosmic.relay.wire`]) can carry as a request's.
---
--- The numeric and name grammars are this module's alone: the relay's
--- readers and its address checks read through it, so a host the policy
--- accepts is read the same way wherever it is met. Everything here is a
--- pure function of its argument and never raises.
---
---     local target = assert(Grant.parse("API.Example.com.:443"))
---     print(target.kind, target.text) -- name  api.example.com:443

local record Grant
  --- What a target's host is.
  enum Kind
    "any"
    "name"
    "ipv4"
    "ipv6"
  end

  --- One `connect` target, read.
  record Target
    --- What the host is.
    kind: Kind
    --- The host in its canonical form: "*" for `any`, a name lower-cased
    --- without a trailing dot, four decimal octets, or an IPv6 address in
    --- RFC 5952's form without brackets.
    host: string
    --- For an address, its bytes (4 or 16); nil otherwise.
    bytes: {integer}
    --- The port, 0 for any.
    port: integer
    --- The target in its canonical text: `host:port` with an IPv6 host in
    --- brackets and "*" for a port of any.
    text: string
  end
end

--- The longest text of an IPv6 address, "ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255".
local MAX_ADDRESS <const> = 45

--- The longest DNS name, and its longest label, in bytes.
local MAX_NAME <const> = 253
local MAX_LABEL <const> = 63

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
  if text:find("[^%x:%.]") or text:find(":::", 1, true) then return nil end
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

--- The bytes of the numeric address `text`, most significant first: 4 for
--- an IPv4 address (four decimal octets, none with a leading zero), 16 for
--- an IPv6 one (hex groups of one to four digits, at most one "::", an
--- IPv4 tail, no brackets or zone). Nil for anything else.
--- @param text string The text to read
--- @return {integer}|nil The bytes
function Grant.address(text: string): {integer} | nil
  if type(text) ~= "string" or text == "" or #text > MAX_ADDRESS then
    return nil
  end
  if text:find(":", 1, true) then return parse6(text) end
  return parse4(text)
end

--- The 16 `bytes` of an IPv6 address in RFC 5952's form: lower-case hex
--- groups without leading zeros, the longest run of two or more zero groups
--- (the first, on a tie) as "::".
--- @param bytes {integer} The sixteen bytes
--- @return string The address text, without brackets
function Grant.ipv6_text(bytes: {integer}): string
  local all: {integer} = {}
  for i = 1, 16, 2 do all[#all + 1] = bytes[i] << 8 | bytes[i + 1] end
  local best_at, best_len, at = 0, 1, 1
  while at <= 8 do
    if all[at] == 0 then
      local stop = at
      while stop < 8 and all[stop + 1] == 0 do stop = stop + 1 end
      if stop - at + 1 > best_len then best_at, best_len = at, stop - at + 1 end
      at = stop + 1
    else
      at = at + 1
    end
  end
  local parts: {string} = {}
  local i = 1
  while i <= 8 do
    if i == best_at then
      if best_len == 8 then return "::" end
      parts[#parts + 1] = ""
      if i == 1 or i + best_len > 8 then parts[#parts + 1] = "" end
      i = i + best_len
    else
      parts[#parts + 1] = ("%x"):format(all[i])
      i = i + 1
    end
  end
  return table.concat(parts, ":")
end

--- Whether `label`, the last of a name's, is one a resolver may read as a
--- number: all digits, or `0x` and hex digits (`inet_aton`'s forms).
local function numeric(label: string): boolean
  return label:find("^%d+$") ~= nil or label:find("^0x%x*$") ~= nil
end

--- `text` as a DNS name in canonical form (lower-case, a trailing dot
--- removed), or nil and why. A name is labels of letters, digits and inner
--- hyphens, 63 bytes at most each and 253 in all, whose last is no number.
--- @param text string The name
--- @return string|nil The canonical name
--- @return string Why there is none, "" otherwise
function Grant.name(text: string): string | nil, string
  if text:sub(-1) == "." then
    text = text:sub(1, -2)
  end
  if text == "" then
    return nil, "empty host name"
  end
  if #text > MAX_NAME then
    return nil, "host name longer than 253 bytes"
  end
  text = text:gsub("%u", string.lower)
  local last = ""
  for label in (text .. "."):gmatch("([^.]*)%.") do
    if label == "" then
      return nil, "host name with an empty label"
    end
    if #label > MAX_LABEL then
      return nil, "host name label longer than 63 bytes"
    end
    if not label:find("^[a-z0-9][a-z0-9-]*$") or label:sub(-1) == "-" then
      return nil, "host name label that is not letters, digits and inner hyphens"
    end
    last = label
  end
  if numeric(last) then
    return nil, "host name whose last label is a number (write an IPv4 address in four parts)"
  end
  return text, ""
end

--- A decimal port from 1 to 65535 with no leading zero, or nil and why.
--- @param text string The port's text
--- @return integer|nil The port
--- @return string Why there is none, "" otherwise
function Grant.port(text: string): integer | nil, string
  local why = "port is not a decimal number from 1 to 65535 without leading zeros"
  if not text:find("^[1-9]%d*$") or #text > 5 then
    return nil, why
  end
  local port = math.tointeger(tonumber(text))
  if port == nil or port > 65535 then
    return nil, why
  end
  return port, ""
end

--- `host:port` in its canonical text.
local function text_of(kind: Grant.Kind, host: string, port: integer): string
  if kind == "ipv6" then host = "[" .. host .. "]" end
  return host .. ":" .. (port == 0 and "*" or tostring(port))
end

--- A `connect` target `text` read, or nil and why: the host a name, an
--- IPv4 address, an IPv6 address in brackets or "*", then ":" and a port or
--- "*" (see the module's header). The why names the first thing wrong,
--- without the target.
--- @param text string The target, `host:port`
--- @return Grant.Target|nil The target
--- @return string Why there is none, "" otherwise
function Grant.parse(text: string): Grant.Target | nil, string
  if type(text) ~= "string" then return nil, "a target is text" end
  local host, at = text:match("^(.+):([^:]+)$")
  if host == nil or at == nil then return nil, "not host:port" end
  local port = 0
  if at ~= "*" then
    local number, why = Grant.port(at)
    if number == nil then return nil, why end
    port = number
  end
  local inner = host:match("^%[(.*)%]$")
  if inner ~= nil then
    local bytes = inner:find(":", 1, true) and Grant.address(inner) or nil
    if bytes == nil or #bytes ~= 16 then
      return nil, "brackets hold an IPv6 address and nothing else"
    end
    local canonical = Grant.ipv6_text(bytes)
    return { kind = "ipv6", host = canonical, bytes = bytes, port = port,
      text = text_of("ipv6", canonical, port) }, ""
  end
  if host:find(":", 1, true) then
    return nil, "an IPv6 host is written in brackets"
  end
  if host == "*" then
    return { kind = "any", host = "*", port = port, text = text_of("any", "*", port) }, ""
  end
  if host:find("*", 1, true) then
    return nil, "a host is a whole name or \"*\", not a pattern"
  end
  if host:find("[%[%]]") then
    return nil, "brackets hold an IPv6 address and nothing else"
  end
  local bytes = Grant.address(host)
  if bytes ~= nil then
    return { kind = "ipv4", host = host, bytes = bytes, port = port,
      text = text_of("ipv4", host, port) }, ""
  end
  local name, why = Grant.name(host)
  if name == nil then return nil, why end
  return { kind = "name", host = name, port = port, text = text_of("name", name, port) }, ""
end

return Grant
