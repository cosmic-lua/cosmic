--- DER (X.690), as much of it as [`cosmic.key`] and [`cosmic.acme`] need:
--- the encoding of the elements of a key, a certificate signing request
--- and a certificate, a reader of a certificate's or a key's elements,
--- and PEM (RFC 7468) around them.

local Codec = require("cosmic.codec")

local record Der
  --- One element: its tag and its content.
  record Element
    tag: integer
    content: string
    --- The index after the element in what it was read from.
    after: integer
  end

  --- The content of an ASN.1 NULL, with its tag.
  NULL: string
end

Der.NULL = "\5\0"

local function length(n: integer): string
  if n < 0x80 then return string.char(n) end
  local bytes: mut {string} = {}
  while n > 0 do
    table.insert(bytes, 1, string.char(n & 0xff))
    n = n >> 8
  end
  return string.char(0x80 | #bytes) .. table.concat(bytes)
end

--- The element of `tag` around `content`.
function Der.element(tag: integer, content: string): string
  return string.char(tag) .. length(#content) .. content
end

--- The SEQUENCE of the elements given, in order.
function Der.sequence(...: string): string
  return Der.element(0x30, table.concat({ ... }))
end

--- The INTEGER of the unsigned big-endian `bytes`.
function Der.unsigned(bytes: string): string
  local first = bytes:find("[^\0]")
  local trimmed = if first == nil then "\0" else bytes:sub(first) end
  if (trimmed:byte(1) or 0) >= 0x80 then trimmed = "\0" .. trimmed end
  return Der.element(0x02, trimmed)
end

--- The OBJECT IDENTIFIER of the dotted `oid`, such as "1.2.840.10045.2.1".
function Der.oid(dotted: string): string
  local arcs: mut {integer} = {}
  for arc in dotted:gmatch("%d+") do arcs[#arcs + 1] = math.tointeger(tonumber(arc)) or 0 end
  local out: mut {string} = { string.char(40 * (arcs[1] or 0) + (arcs[2] or 0)) }
  for i = 3, #arcs do
    local arc = arcs[i] or 0
    local digits: mut {string} = { string.char(arc & 0x7f) }
    arc = arc >> 7
    while arc > 0 do
      table.insert(digits, 1, string.char(0x80 | (arc & 0x7f)))
      arc = arc >> 7
    end
    out[#out + 1] = table.concat(digits)
  end
  return Der.element(0x06, table.concat(out))
end

--- The BIT STRING of the whole bytes `bytes`.
function Der.bits(bytes: string): string
  return Der.element(0x03, "\0" .. bytes)
end

--- The element at `at` of `bytes`, or nil where it is cut short or its
--- length is indefinite or of more than four bytes. It reads BER's
--- longer spellings of a length too, and a tag of one byte alone.
function Der.read(bytes: string, at: integer): Der.Element?
  local tag, first = bytes:byte(at, at + 1)
  if tag == nil or first == nil or first == 0x80 or first > 0x84 then return nil end
  local size, start = first, at + 2
  if first > 0x80 then
    size = 0
    for i = 1, first & 0x7f do size = (size << 8) | (bytes:byte(at + 1 + i) or 0) end
    start = at + 2 + (first & 0x7f)
  end
  if start + size - 1 > #bytes then return nil end
  return { tag = tag, content = bytes:sub(start, start + size - 1), after = start + size }
end

--- The elements of the constructed content `content`, or nil where one
--- is cut short.
function Der.elements(content: string): {Der.Element}?
  local out: mut {Der.Element} = {}
  local at = 1
  while at <= #content do
    local element = Der.read(content, at)
    if element == nil then return nil end
    out[#out + 1] = element
    at = element.after
  end
  return out
end

--- The elements of the SEQUENCE that is the whole of `bytes`, or nil.
function Der.sequence_of(bytes: string): {Der.Element}?
  local element = Der.read(bytes, 1)
  if element == nil or element.tag ~= 0x30 or element.after ~= #bytes + 1 then return nil end
  return Der.elements(element.content)
end

--- The PEM of `bytes` under `label`: base64 in lines of 64 characters
--- between the BEGIN and END lines.
function Der.pem(label: string, bytes: string): string
  local text = Codec.base64(bytes)
  local lines: mut {string} = { "-----BEGIN " .. label .. "-----" }
  for i = 1, #text, 64 do lines[#lines + 1] = text:sub(i, i + 63) end
  lines[#lines + 1] = "-----END " .. label .. "-----"
  return table.concat(lines, "\n") .. "\n"
end

return Der
