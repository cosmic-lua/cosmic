--- Worked examples for [`cosmic.cbor`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Cbor = require("cosmic.cbor")
local Codec = require("cosmic.codec")

local record Example
end

--- A COSE key (RFC 9052), the map of integer labels a passkey's public
--- key travels in, written and read back.
function Example.map()
  local key = Cbor.map({
    { Cbor.integer(1), Cbor.integer(2) },
    { Cbor.integer(3), Cbor.integer(-7) },
    { Cbor.integer(-1), Cbor.integer(1) },
    { Cbor.integer(-2), Cbor.bytes(("\1"):rep(32)) },
  })
  local text = Cbor.encode(key, { sort = true })
  local read = assert(Cbor.decode(text))
  print(Codec.hex(text:sub(1, 7)), assert(Cbor.get(read, 3)).integer)
  assert(assert(Cbor.get(read, 3)).integer == -7)
end

--- One item at the front of more bytes, as WebAuthn's authenticator
--- data holds a COSE key followed by extensions.
function Example.decode_first()
  local first = assert(Cbor.decode_first("\x82\x01\x02rest"))
  print(#assert(first.item.items), first.next)
  assert(first.next == 4)
end

--- Values of each kind, and what is no CBOR.
function Example.decode()
  local item = assert(Cbor.decode((assert(Codec.unhex("83f563616263f93e00")))))
  for _, each in ipairs(assert(item.items)) do print(each.kind) end
  local refused, why = Cbor.decode("\x61\xff")
  print(refused == nil, why)
  assert(refused == nil and Cbor.encode(Cbor.array({ Cbor.boolean(true), Cbor.text("abc"), Cbor.float(1.5) })) ==
      assert(Codec.unhex("83f563616263f93e00")))
end

return Example
