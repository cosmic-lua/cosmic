--- build.digest hashes as cosmic.hash does, byte for byte: the raw
--- SHA-256, its hexadecimal and a digest fed in chunks, so that a key
--- computed with either is the same; and each answers the published
--- SHA-256 vectors.

local Hash = require("cosmic.hash")
local digest = require("build.digest")

--- The empty string, every byte alone, strings of every length to 130
--- over a spread of bytes (across SHA-256's 64-byte block and its
--- padding's edge at 55 and 56), every byte in order, and a megabyte.
local function samples(): {string}
  local out: {string} = { "" }
  for byte = 0, 255 do out[#out + 1] = string.char(byte) end
  for length = 1, 130 do
    local bytes: {string} = {}
    for i = 1, length do bytes[i] = string.char((i * 37 + length * 11) % 256) end
    out[#out + 1] = table.concat(bytes)
  end
  local all: {string} = {}
  for byte = 0, 255 do all[#all + 1] = string.char(byte) end
  out[#out + 1] = table.concat(all)
  out[#out + 1] = table.concat(all):rep(4096)
  return out
end

--- `data` fed to a fresh hasher in chunks of `size` bytes, and its raw
--- digest.
local function chunked(data: string, size: integer): string
  local hasher = assert(digest.sha256_hasher())
  for at = 1, #data, size do hasher:update(data:sub(at, at + size - 1)) end
  return (assert(hasher:digest()))
end

local function test_every_digest_is_cosmic_hash_s()
  for _, sample in ipairs(samples()) do
    local raw = digest.sha256(sample)
    assert(#raw == 32 and raw == Hash.sha256(sample), #sample)
    assert(digest.hex_sha256(sample) == Hash.hex_sha256(sample), #sample)
    assert(chunked(sample, 1 + #sample // 3) == raw, #sample)
    local reference = assert(Hash.hasher("sha256"))
    reference:update(sample)
    assert(chunked(sample, 7) == assert(reference:digest()), #sample)
  end
end

--- FIPS 180-2's examples, and the empty string's.
local function test_the_published_vectors()
  local vectors: {{string}} = {
    { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
    { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
    { "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
    { ("a"):rep(1000000),
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0" },
  }
  for _, vector in ipairs(vectors) do
    local data, expected = vector[1], vector[2]
    assert(digest.hex_sha256(data) == expected, expected)
    assert(chunked(data, 1000) == digest.sha256(data), expected)
  end
end

--- A finished hasher refuses more, as cosmic.hash's does: the same
--- table's.
local function test_a_finished_hasher_refuses_more()
  local hasher = assert(digest.sha256_hasher())
  hasher:update("x")
  assert(hasher:digest() == digest.sha256("x"))
  assert(not pcall(function() hasher:update("y") end))
  assert(not pcall(function() local _, _ = hasher:digest() end))
end
