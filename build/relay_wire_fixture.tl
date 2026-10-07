--- Builders for the tests of [`cosmic.relay_wire`]: the bytes a program
--- sends the relay, whole or damaged by a test.

local record relay_wire_fixture
  --- What a synthetic ClientHello holds.
  record HelloOptions
    --- The host name its server_name extension carries, none when nil.
    name: string
    --- Length of the session id, 0 to 255.
    session: integer
    --- Cipher suites, each two bytes; 1 when nil.
    suites: integer
    --- Extensions written after the server_name one, whole, in order.
    extra: {string}
    --- The server_name extension's data in place of one built from `name`.
    server_name: string
    --- Bytes the hello's body is to hold, made up with a padding extension
    --- last; nil for no padding.
    size: integer
  end
end

--- The bytes the hex digits of `text` spell.
function relay_wire_fixture.bytes(text: string): string
  return (text:gsub("%x%x", function(pair: string): string
    return string.char(math.tointeger(tonumber(pair, 16)))
  end))
end

--- A big-endian integer of `width` bytes.
function relay_wire_fixture.be(value: integer, width: integer): string
  local out: {string} = {}
  for i = width - 1, 0, -1 do
    out[#out + 1] = string.char((value >> (8 * i)) & 255)
  end
  return table.concat(out)
end

--- One extension of `kind` holding `data`.
function relay_wire_fixture.extension(kind: integer, data: string): string
  return relay_wire_fixture.be(kind, 2) .. relay_wire_fixture.be(#data, 2) .. data
end

--- The data of a server_name extension naming `name`.
function relay_wire_fixture.server_name(name: string): string
  local be = relay_wire_fixture.be
  local entry = "\0" .. be(#name, 2) .. name
  return be(#entry, 2) .. entry
end

--- A ClientHello handshake message (its four-byte header and body).
function relay_wire_fixture.hello(opts?: relay_wire_fixture.HelloOptions): string
  local be = relay_wire_fixture.be
  opts = opts or {}
  local suites = opts.suites or 1
  local exts: {string} = {}
  if opts.server_name ~= nil then
    exts[#exts + 1] = relay_wire_fixture.extension(0, opts.server_name)
  elseif opts.name ~= nil then
    exts[#exts + 1] = relay_wire_fixture.extension(0, relay_wire_fixture.server_name(opts.name))
  end
  for _, extra in ipairs(opts.extra or {}) do
    exts[#exts + 1] = extra
  end
  local fixed = "\3\3" .. ("r"):rep(32) .. be(opts.session or 0, 1) .. ("s"):rep(opts.session or 0) ..
    be(2 * suites, 2) .. ("\0\47"):rep(suites) .. "\1\0"
  local joined = table.concat(exts)
  if opts.size ~= nil then
    local pad = opts.size - (#fixed + 2 + #joined + 4)
    if pad < 0 then
      error("hello: size is smaller than the hello's own fields", 2)
    end
    joined = joined .. relay_wire_fixture.extension(21, ("\0"):rep(pad))
  end
  local body = fixed
  if joined ~= "" then
    body = fixed .. be(#joined, 2) .. joined
  end
  return "\1" .. be(#body, 3) .. body
end

--- `message` as handshake records: the first holds `sizes[1]` bytes of it,
--- the next `sizes[2]`, and the last all that is left. `version` is the
--- records' legacy version, 0x0301 when nil.
function relay_wire_fixture.records(message: string, sizes?: {integer}, version?: integer): string
  local out: {string} = {}
  local at = 1
  local function record(payload: string)
    out[#out + 1] = "\22" .. relay_wire_fixture.be(version or 0x0301, 2) .. relay_wire_fixture.be(#payload, 2) .. payload
  end
  for _, size in ipairs(sizes or {}) do
    if at > #message then
      break
    end
    record(message:sub(at, at + size - 1))
    at = at + size
  end
  if at <= #message or #out == 0 then
    record(message:sub(at))
  end
  return table.concat(out)
end

--- A CONNECT request for `target`, with `headers` (whole lines, no CRLF).
function relay_wire_fixture.connect(target: string, headers?: {string}, version?: string): string
  local lines = { "CONNECT " .. target .. " " .. (version or "HTTP/1.1") }
  for _, header in ipairs(headers or {}) do
    lines[#lines + 1] = header
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n"
end

--- The sixteen bytes of the IPv6 address `text`, which is in the form
--- [`cosmic.relay_wire`] writes (lower case, `::` at most once).
function relay_wire_fixture.ipv6_bytes(text: string): string
  local function side(part: string): {integer}
    local out: {integer} = {}
    for piece in part:gmatch("[^:]+") do
      out[#out + 1] = math.tointeger(tonumber(piece, 16))
    end
    return out
  end
  local gap = text:find("::", 1, true)
  local left = side(gap and text:sub(1, gap - 1) or text)
  local right = gap and side(text:sub(gap + 2)) or {}
  local all: {integer} = {}
  for _, g in ipairs(left) do
    all[#all + 1] = g
  end
  for _ = 1, 8 - #left - #right do
    all[#all + 1] = 0
  end
  for _, g in ipairs(right) do
    all[#all + 1] = g
  end
  local out: {string} = {}
  for _, g in ipairs(all) do
    out[#out + 1] = relay_wire_fixture.be(g, 2)
  end
  return table.concat(out)
end

--- A SOCKS5 request: version 5, `command`, reserved 0, `atyp`, `address`
--- (its bytes, with a domain's length in front) and `port`.
function relay_wire_fixture.socks_request(command: integer, atyp: integer, address: string, port: integer): string
  return "\5" .. string.char(command) .. "\0" .. string.char(atyp) .. address .. relay_wire_fixture.be(port, 2)
end

return relay_wire_fixture
