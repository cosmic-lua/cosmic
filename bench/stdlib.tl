--- Run-time microbenchmarks of the stdlib beyond bench/runtime.tl: `bin/cosmic bench/stdlib.tl [name...]`.
--- JSON's walks and layouts, hashing, compression, the AEAD cipher, CBOR, big numbers and hex. Each case is one
--- line on [`bench.harness`], which takes `--json`, `--rounds` and `--against <old-binary>`. It measures; it gates
--- nothing, and no test reads its numbers.
local Bench = require("bench.harness")
local Bigint = require("cosmic.bigint")
local Cbor = require("cosmic.cbor")
local Cipher = require("cosmic.cipher")
local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Rand = require("cosmic.rand")

local bench = Bench.new("stdlib")
local case = bench.case

local function decoded(text: string, opts?: Json.DecodeOptions): Json.Value
  local value, why = Json.decode(text, opts)
  if value == nil then error(tostring(why)) end
  return value
end

local MIB <const> = 1024 * 1024
local bytes = Rand.new(2026):bytes(MIB)

-- JSON: a tweet-like record (41 top-level keys and a nested object), walked, laid out and diffed.
local parts: mut {string} = {}
for i = 1, 40 do parts[#parts + 1] = ('"k%d":{"a":%d,"b":"x"}'):format(i, i) end
local tweet_text = "{" .. table.concat(parts, ",") ..
    ',"user":{"id":1,"name":"n","x":2,"y":3,"z":4,"w":5,"tags":["a","b","c"]}}'
local tweet = decoded(tweet_text)
local tweet_again = decoded(tweet_text)
local members_of = assert(Json.to_object(tweet))
local rows: mut {string} = {}
for i = 1, 1000 do
  rows[i] = ('{"id":%d,"name":"user%d","score":%d.5,"at":{"x":%d,"y":%d},"tags":["a","b"]}'):format(i, i, i, i, -i)
end
local table_text = "[" .. table.concat(rows, ",") .. "]"

case("json.get shallow", function(n: integer)
  for _ = 1, n do
    local v, why = Json.get(tweet, { "k7" })
    if v == nil then error(tostring(why)) end
  end
end)
case("json.get user.name", function(n: integer)
  for _ = 1, n do
    local v, why = Json.get(tweet, { "user", "name" })
    if v == nil then error(tostring(why)) end
  end
end)
case("json.get user.tags[3]", function(n: integer)
  for _ = 1, n do
    local v, why = Json.get(tweet, { "user", "tags", 3 })
    if v == nil then error(tostring(why)) end
  end
end)
case("json.members 41 keys", function(n: integer)
  for _ = 1, n do local _ = Json.members(members_of) end
end)
case("json.layout 41 keys", function(n: integer)
  for _ = 1, n do local _ = Json.layout(members_of) end
end)
case("json.diff equal 41 keys", function(n: integer)
  for _ = 1, n do local _ = Json.diff(tweet, tweet_again) end
end)
case("json.decode only 2 fields", function(n: integer)
  local opts: Json.DecodeOptions = { only = { { "user", "name" }, { "k7", "a" } } }
  for _ = 1, n do local _ = decoded(tweet_text, opts) end
end, { bytes = #tweet_text })
case("json.format expanded 1000 rows", function(n: integer)
  for _ = 1, n do local _ = Json.format(table_text, { layout = "expanded" })! end
end, { bytes = #table_text })
case("json.format fractured 1000 rows", function(n: integer)
  for _ = 1, n do local _ = Json.format(table_text, { layout = "fractured" })! end
end, { bytes = #table_text })

-- Hashing, 1 MiB: bytes per operation give GB/s.
local algorithms: {Hash.Algorithm} = { "sha256", "sha512", "sha3-256", "md5" }
for _, algorithm in ipairs(algorithms) do
  case("hash." .. algorithm .. " 1 MiB", function(n: integer)
    for _ = 1, n do local _ = Hash.digest(algorithm, bytes) end
  end, { bytes = MIB })
end
case("hash.hmac sha256 1 MiB", function(n: integer)
  for _ = 1, n do local _ = Hash.hmac("sha256", "key", bytes) end
end, { bytes = MIB })
case("hash.siphash 1 MiB", function(n: integer)
  for _ = 1, n do local _ = Hash.siphash(string.rep("k", 16), bytes) end
end, { bytes = MIB })

local formats: {Compress.Format} = { "gzip", "zstd", "xz" }
-- Compression: text that repeats (a 1 MiB table of rows), each format both ways.
local text = string.rep(table_text, 1 + MIB // #table_text):sub(1, MIB)
for _, format in ipairs(formats) do
  local packed = assert(Compress.encode(format, text))
  case("compress.encode " .. format .. " 1 MiB", function(n: integer)
    for _ = 1, n do local _ = Compress.encode(format, text)! end
  end, { bytes = MIB })
  case("compress.decode " .. format .. " 1 MiB", function(n: integer)
    for _ = 1, n do local _ = Compress.decode(format, packed)! end
  end, { bytes = MIB })
end

-- The AEAD cipher: seal and open 1 MiB.
local key, nonce = string.rep("k", 32), string.rep("n", 12)
local sealed = Cipher.seal("chacha20-poly1305", key, nonce, bytes)
case("cipher.seal chacha20 1 MiB", function(n: integer)
  for _ = 1, n do local _ = Cipher.seal("chacha20-poly1305", key, nonce, bytes) end
end, { bytes = MIB })
case("cipher.open chacha20 1 MiB", function(n: integer)
  for _ = 1, n do local _ = Cipher.open("chacha20-poly1305", key, nonce, sealed)! end
end, { bytes = MIB })

-- CBOR: the same rows as an array of maps.
local items: mut {Cbor.Item} = {}
for i = 1, 1000 do
  items[i] = Cbor.map({ { Cbor.text("id"), Cbor.integer(i) }, { Cbor.text("name"), Cbor.text("user" .. tostring(i)) },
    { Cbor.text("score"), Cbor.float(i + 0.5) }, { Cbor.text("tags"), Cbor.array({ Cbor.text("a"), Cbor.text("b") }) } })
end
local cbor_item = Cbor.array(items)
local cbor_text = Cbor.encode(cbor_item)
case("cbor.encode 1000 rows", function(n: integer)
  for _ = 1, n do local _ = Cbor.encode(cbor_item) end
end, { bytes = #cbor_text })
case("cbor.decode 1000 rows", function(n: integer)
  for _ = 1, n do local _ = Cbor.decode(cbor_text)! end
end, { bytes = #cbor_text })

-- Big numbers: a 2048-bit modular exponentiation and a 2048-bit product.
local modulus = "0x" .. "ff" .. string.rep("ab", 255) .. "f1"
local base = "0x" .. string.rep("3c", 256)
case("bigint.powmod 2048-bit", function(n: integer)
  for _ = 1, n do local _ = Bigint.powmod(base, "0x10001", modulus) end
end)
case("bigint.mul 2048-bit", function(n: integer)
  for _ = 1, n do local _ = Bigint.mul(base, modulus) end
end)

-- Hex, 1 MiB.
local hex = Codec.hex(bytes)
case("codec.hex 1 MiB", function(n: integer)
  for _ = 1, n do local _ = Codec.hex(bytes) end
end, { bytes = MIB })
case("codec.unhex 1 MiB", function(n: integer)
  for _ = 1, n do local _ = Codec.unhex(hex)! end
end, { bytes = #hex })

return function(argv: {string}): integer return bench.main(argv) end
