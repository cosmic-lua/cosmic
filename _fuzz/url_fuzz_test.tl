--- Fuzz properties for cosmic.url.
--- Four laws, each run through _fuzz.driver so a failure reports the seed,
--- the iteration and the failing input in base64:
---   parse is total over arbitrary bytes,
---   format reaches a fixpoint after one parse/format round,
---   unescape_param inverts escape_param,
---   parse_query inverts format_query.
--- The table-valued property still generates a string — the driver's input
--- is what the failure message carries, so the query tables are encoded as
--- length-prefixed bytes and decoded inside the check.
--- env: FUZZ_SEED FUZZ_ITERS

local check = require("cosmic.check")
local deep = require("cosmic.deep")
local driver = require("_fuzz.driver")
local url = require("cosmic.url")

--- Draw one element of a list uniformly.
--- @param list {string} The choices
--- @return string The chosen element
local function pick(list: {string}): string
  return list[math.random(1, #list)]
end

--- Draw a run of lowercase letters, the shape of a scheme or a host label.
--- @param max_len integer The longest run to produce
--- @return string The letters
local function letters(max_len: integer): string
  local out: {string} = {}
  for i = 1, math.random(1, max_len) do
    out[i] = string.char(math.random(97, 122))
  end
  return table.concat(out)
end

-- Characters that make a URL component interesting: delimiters, percent
-- escapes (valid and bare), and a multi-byte UTF-8 sequence.
local SPECIALS = {
  "%20", "%2F", "%3F", "%26", "%3D", "%25", "%zz",
  " ", "?", "&", "=", "%", "#", "@", ":", "/", "+", "~", ".", "..",
  "[", "]", "\226\152\131",
}

--- Draw a URL component: mostly letters, sometimes a delimiter or escape.
--- @param max_parts integer The most pieces to concatenate
--- @return string The component
local function component(max_parts: integer): string
  local out: {string} = {}
  for i = 1, math.random(1, max_parts) do
    if math.random(1, 4) == 1 then
      out[i] = pick(SPECIALS)
    else
      out[i] = letters(4)
    end
  end
  return table.concat(out)
end

--- Draw a host: a dotted name, an IPv4 literal, or a bracketed IPv6-ish
--- literal.
--- @return string The host
local function host(): string
  local kind = math.random(1, 10)
  if kind == 1 then
    return "[" .. letters(4) .. "::" .. tostring(math.random(0, 9)) .. "]"
  end
  if kind == 2 then
    return string.format("%d.%d.%d.%d", math.random(0, 255), math.random(0, 255),
      math.random(0, 255), math.random(0, 255))
  end
  local labels: {string} = {}
  for i = 1, math.random(1, 3) do
    labels[i] = letters(6)
  end
  return table.concat(labels, ".")
end

--- Assemble a plausible URL from random parts: an optional
--- scheme/userinfo/host/port authority, path segments, a query and a
--- fragment, with unescaped and escaped characters throughout.
--- @return string The URL
local function plausible_url(): string
  local out: {string} = {}
  if math.random(1, 6) > 1 then
    out[#out + 1] = letters(6) .. "://"
    if math.random(1, 6) == 1 then
      out[#out + 1] = component(2) .. ":" .. component(2) .. "@"
    end
    out[#out + 1] = host()
    if math.random(1, 3) == 1 then
      out[#out + 1] = ":" .. tostring(math.random(1, 65535))
    end
  end
  for _ = 1, math.random(0, 3) do
    out[#out + 1] = "/" .. component(4)
  end
  if math.random(1, 2) == 1 then
    local params: {string} = {}
    for i = 1, math.random(1, 3) do
      params[i] = component(2) .. "=" .. component(2)
    end
    out[#out + 1] = "?" .. table.concat(params, "&")
  end
  if math.random(1, 3) == 1 then
    out[#out + 1] = "#" .. component(3)
  end
  return table.concat(out)
end

--- Encode a query map as length-prefixed bytes, so the driver can carry
--- it as its input string and report it in base64.
--- Shape: `<n>:<bytes>` per string, a key followed by its value count
--- followed by its values.
--- @param params {string:{string}} The map to encode
--- @return string The encoded map
local function encode_params(params: {string: {string}}): string
  local out: {string} = {}
  local function put(s: string)
    out[#out + 1] = tostring(#s) .. ":" .. s
  end
  for key, values in pairs(params) do
    put(key)
    put(tostring(#values))
    for _, value in ipairs(values) do
      put(value)
    end
  end
  return table.concat(out)
end

--- Decode what encode_params wrote.
--- @param blob string The encoded map
--- @return {string:{string}} | nil The map, or nil when the bytes are malformed
--- @return string? What was malformed
local function decode_params(blob: string): {string: {string}} | nil, string
  local pos = 1
  local function take(): string | nil, string
    local colon = blob:find(":", pos, true)
    if not colon then
      return nil, "no length prefix at " .. tostring(pos)
    end
    local size = math.tointeger(tonumber(blob:sub(pos, colon - 1)))
    if not size then
      return nil, "bad length at " .. tostring(pos)
    end
    local value = blob:sub(colon + 1, colon + size)
    if #value ~= size then
      return nil, "short read at " .. tostring(pos)
    end
    pos = colon + 1 + size
    return value
  end
  local params: {string: {string}} = {}
  while pos <= #blob do
    local key, key_err = take()
    if not key then
      return nil, key_err
    end
    local count_text, count_err = take()
    if not count_text then
      return nil, count_err
    end
    local count = math.tointeger(tonumber(count_text))
    if not count then
      return nil, "bad value count: " .. count_text
    end
    local values: {string} = {}
    for i = 1, count do
      local value, value_err = take()
      if not value then
        return nil, value_err
      end
      values[i] = value
    end
    params[key] = values
  end
  return params
end

--- Draw a query map: at most eight keys, each with one to three values,
--- all of them arbitrary bytes.
--- @return {string:{string}} The map
local function query_map(): {string: {string}}
  local params: {string: {string}} = {}
  for _ = 1, math.random(0, 8) do
    local values: {string} = {}
    for i = 1, math.random(1, 3) do
      values[i] = driver.bytes(12)
    end
    params[driver.bytes(12)] = values
  end
  return params
end

-- parse answers every byte string: a Url, or nil with a reason. It never
-- throws, and it never returns nil without saying why.
local function test_parse_totality()
  local ok, message = driver.run({
      name = "parse_totality",
      gen = function(): string
        return driver.bytes(256)
      end,
      check = function(input: string): boolean, string
        local parsed, err = url.parse(input)
        if parsed then
          return true
        end
        if not err or err == "" then
          return false, "returned nil without an error message"
        end
        return true
      end,
    })
  check.truthy(ok, message)
end
test_parse_totality()

-- format reaches a normal form in one round and then stays there: for any
-- URL that parses, format(parse(s)) reparses and formats to itself.
local function test_format_fixpoint()
  local ok, message = driver.run({
      name = "format_fixpoint",
      gen = plausible_url,
      check = function(input: string): boolean, string
        local parsed = url.parse(input)
        if not parsed then
          return true
        end
        local once = url.format(parsed)
        local reparsed, err = url.parse(once)
        if not reparsed then
          return false, string.format("format output did not reparse: %q: %s",
            once, tostring(err))
        end
        local twice = url.format(reparsed)
        if twice ~= once then
          return false, string.format("not a fixpoint: once=%q twice=%q", once, twice)
        end
        return true
      end,
    })
  check.truthy(ok, message)
end
test_format_fixpoint()

-- unescape_param inverts escape_param over arbitrary bytes.
local function test_escape_inverse()
  local ok, message = driver.run({
      name = "escape_inverse",
      gen = function(): string
        return driver.bytes(128)
      end,
      check = function(input: string): boolean, string
        local escaped = url.escape_param(input)
        local decoded, err = url.unescape_param(escaped)
        if not decoded then
          return false, string.format("unescape_param rejected %q: %s", escaped,
            tostring(err))
        end
        if decoded ~= input then
          return false, string.format("round trip changed the bytes: escaped=%q got=%q",
            escaped, decoded)
        end
        return true
      end,
    })
  check.truthy(ok, message)
end
test_escape_inverse()

-- parse_query inverts format_query: keys, values and their order survive.
local function test_query_round_trip()
  local ok, message = driver.run({
      name = "query_round_trip",
      gen = function(): string
        return encode_params(query_map())
      end,
      check = function(input: string): boolean, string
        local params, decode_err = decode_params(input)
        if not params then
          return false, "the generated input did not decode: " .. tostring(decode_err)
        end
        local round_tripped = url.parse_query(url.format_query(params))
        if not deep.equal(params, round_tripped) then
          return false, "parse_query(format_query(t)) differed from t"
        end
        return true
      end,
    })
  check.truthy(ok, message)
end
test_query_round_trip()
