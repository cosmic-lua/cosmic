--- Proves the digests and HMAC the core exposes against published
--- test vectors, in Teal and in SQL alike, and that an algorithm
--- nobody has heard of is refused rather than answered.

local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")

local fox = "The quick brown fox jumps over the lazy dog"

local vectors: {{string}} = {
  { "md5", "", "d41d8cd98f00b204e9800998ecf8427e" },
  { "sha1", "abc", "a9993e364706816aba3e25717850c26c9cd0d89d" },
  { "sha224", "abc", "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7" },
  { "sha256", "abc",
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
  { "sha384", "abc",
    "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed" ..
    "8086072ba1e7cc2358baeca134c825a7" },
  { "sha512", "abc",
    "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" ..
    "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f" },
  { "sha3-256", "abc",
    "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532" },
  { "sha3-512", "abc",
    "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e" ..
    "10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0" },
}

local macs: {{string}} = {
  { "md5", "80070713463e7749b90c2dc24911e275" },
  { "sha256", "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8" },
  { "sha512",
    "b42af09057bac1e2d41708e48a902e09b5ff7f12ab428a4fe86653c73dd248fb" ..
    "82f948a549f7b791a5b41915ee4d1ec3935357e4e2317250d0372afa2ebeeb3a" },
}

local function test_digests_match_published_vectors()
  for _, v in ipairs(vectors) do
    local algorithm = v[1] as Hash.Algorithm
    assert(Codec.hex(Hash.digest(algorithm, v[2])) == v[3], v[1])
  end
  assert(Hash.hex_sha256("abc") == vectors[4][3])
end

local function test_hmac_matches_published_vectors()
  for _, v in ipairs(macs) do
    local algorithm = v[1] as Hash.Algorithm
    assert(Codec.hex(Hash.hmac(algorithm, "key", fox)) == v[2], v[1])
  end
end

--- HMAC takes a key of any length (RFC 2104): an empty one, and one
--- longer than the block -- RFC 4231's case 6 at 131 bytes, and keys
--- past the 8 KiB the crypto library imports -- as well as ones exactly
--- a block long, which are used as they are.
local function test_hmac_takes_a_key_of_any_length()
  local rfc4231 = "Test Using Larger Than Block-Size Key - Hash Key First"
  local cases: {{string}} = {
    { "sha256", "", fox,
      "fb011e6154a19b9a4c767373c305275a5a69e8b68b0b4c9200c383dced19a416" },
    { "sha256", string.rep("\xaa", 131), rfc4231,
      "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54" },
    { "sha256", string.rep("k", 64), fox,
      "bbbf90167fe46c7a3fa5b549325ad6428715eae339737730860fcea2c3f43d5c" },
    { "sha256", string.rep("k", 200), fox,
      "86522d64cfd7d3d21199f47288e74cdc22a6395aff54f0270c7feef1d0fa61bf" },
    { "sha256", string.rep("k", 10000), fox,
      "ec6e8734d2a5ac3ffe12eb18377f17850fbd8999a7e77a9882c7385da477055f" },
    { "sha512", "", fox,
      "1de78322e11d7f8f1035c12740f2b902353f6f4ac4233ae455baccdf9f377915" ..
      "66e790d5c7682aad5d3ceca2feff4d3f3fdfd9a140c82a66324e9442b8af71b6" },
    { "sha512", string.rep("\xaa", 131), rfc4231,
      "80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f352" ..
      "6b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598" },
    { "sha512", string.rep("k", 128), fox,
      "d4835efaf497c0d1fe88eb16df0e805fd68ae5adb623d08b5cea86fd57d7df59" ..
      "cdfe1c7092c4c3629d5a63c0d13a6e1b25cd24c937b10013dd059f05e7a639f9" },
    { "sha512", string.rep("k", 200), fox,
      "2ec850d56a434619da67d65f350b4a2caad666d274cf844ee9ac03f73e14d201" ..
      "2bc00387fc44ee2404aa91155181ae98ee75b0497788ca045997ef2462e82f91" },
    { "sha512", string.rep("k", 10000), fox,
      "2acc5c34c7fc0fa0b8e483f1155219f42af8a7d6448e51d520f30d1a48d100da" ..
      "1929cd07ba7629453a50c03a915ea3bae7d0aa41ffdf3922a04f1c9614b3f5eb" },
  }
  local db = assert(Sqlite.memory())
  for _, case in ipairs(cases) do
    local algorithm = case[1] as Hash.Algorithm
    local label = case[1] .. " with a " .. #case[2] .. "-byte key"
    assert(Codec.hex(Hash.hmac(algorithm, case[2], case[3])) == case[4], label)
    local rows = assert(Sqlite.text_rows(db, "SELECT lower(hex(hmac(?1, ?2, ?3)))",
      { { text = case[1] }, { blob = case[2] }, { text = case[3] } }))
    assert(rows[1][1] == case[4], "SQL, " .. label)
  end
  db:close()
end

local function test_an_unknown_algorithm_raises()
  local ok, trouble = pcall(Hash.digest, "sha0" as Hash.Algorithm, "abc")
  assert(not ok)
  assert(tostring(trouble):find("no such digest algorithm", 1, true) ~= nil,
    tostring(trouble))
end

local function test_sql_knows_the_same_digests()
  local db = assert(Sqlite.memory())
  for _, v in ipairs(vectors) do
    local rows = assert(Sqlite.text_rows(db,
      "SELECT lower(hex(digest(?1, ?2)))", { { text = v[1] }, { text = v[2] } }))
    assert(rows[1][1] == v[3], v[1])
  end
  for _, v in ipairs(macs) do
    local rows = assert(Sqlite.text_rows(db,
      "SELECT lower(hex(hmac(?1, 'key', ?2)))", { { text = v[1] }, { text = fox } }))
    assert(rows[1][1] == v[2], v[1])
  end
  local same = assert(Sqlite.text_rows(db, "SELECT sha256('abc') = digest('sha256', 'abc')"))
  assert(same[1][1] == "1")
  local nulls = assert(Sqlite.text_rows(db,
    "SELECT digest(NULL, 'abc') IS NULL, hmac('sha256', NULL, 'abc') IS NULL"))
  assert(nulls[1][1] == "1" and nulls[1][2] == "1")
  local rows, trouble = Sqlite.text_rows(db, "SELECT digest('sha0', 'abc')")
  assert(rows == nil)
  assert(trouble:find("no such digest algorithm", 1, true) ~= nil, trouble)
  db:close()
end

local function test_hasher_matches_digest_for_chunked_input()
  local algorithms: {Hash.Algorithm} = { "sha1", "sha256", "sha512", "md5" }
  for _, algorithm in ipairs(algorithms) do
    local whole = string.rep(fox, 37)
    local hasher = assert(Hash.hasher(algorithm))
    local pos = 1
    local sizes = { 1, 2, 3, 5, 8, 13, 4096 }
    local size_i = 1
    while pos <= #whole do
      local size = sizes[(size_i - 1) % #sizes + 1]
      size_i = size_i + 1
      local piece = whole:sub(pos, pos + size - 1)
      hasher:update(piece)
      pos = pos + #piece
    end
    local digest = assert(hasher:digest())
    assert(digest == Hash.digest(algorithm, whole), algorithm)
  end
end

local function test_hasher_throws_after_digest()
  local hasher = assert(Hash.hasher("sha256"))
  hasher:update("abc")
  assert(hasher:digest())
  local ok, trouble = pcall(function(): string, string
    return hasher:update("more")
  end)
  assert(not ok and tostring(trouble):find("finished", 1, true) ~= nil)
  local ok2 = pcall(function(): string, string
    return hasher:digest()
  end)
  assert(not ok2)
end

local function test_hasher_raises_on_an_unknown_algorithm()
  local ok, trouble = pcall(Hash.hasher, "sha0" as Hash.Algorithm)
  assert(not ok)
  assert(tostring(trouble):find("no such digest algorithm", 1, true) ~= nil,
    tostring(trouble))
end

local function test_hasher_and_digest_carry_an_empty_error()
  local hasher, trouble = Hash.hasher("sha256")
  assert(hasher ~= nil and trouble == "", trouble)
  hasher:update("abc")
  local digest, dtrouble = hasher:digest()
  assert(digest == Hash.digest("sha256", "abc") and dtrouble == "", dtrouble)
end

local record Holder
  h: Hash.Hasher
end

local function test_a_hasher_revived_by_a_finalizer_is_finished()
  local saved: Hash.Hasher
  local holder: Holder = setmetatable({} as Holder, {
    __gc = function(self: Holder) saved = self.h end,
  } as metatable<Holder>)
  holder.h = assert(Hash.hasher("sha256"))
  holder = nil
  collectgarbage()
  collectgarbage()
  assert(saved ~= nil, "the finalizer ran")
  local ok, why = pcall(function(): any
    saved:update("abc")
    return nil
  end)
  assert(not ok and tostring(why):find("finished", 1, true), tostring(why))
  assert(not pcall(saved.digest, saved))
end

local function test_a_closed_hasher_is_finished()
  local kept: Hash.Hasher
  do
    local hasher <close> = assert(Hash.hasher("sha256"))
    hasher:update("abc")
    kept = hasher
  end
  assert(not pcall(kept.update, kept, "more"))
  assert(not pcall(kept.digest, kept))
  -- Closing a digested hasher is harmless too.
  do
    local hasher <close> = assert(Hash.hasher("md5"))
    assert(hasher:digest())
  end
end

local function test_byte_sum_adds_unsigned_bytes_over_a_range()
  assert(Hash.byte_sum("") == 0)
  assert(Hash.byte_sum("\0\1\2\255") == 258)
  assert(Hash.byte_sum("abc", 2) == 98 + 99)
  assert(Hash.byte_sum("abc", 1, 2) == 97 + 98)
  assert(Hash.byte_sum("abc", 2, 2) == 98)
  assert(Hash.byte_sum("abc", 3, 2) == 0)
  assert(Hash.byte_sum("abc", 4) == 0)
  -- A tar header's checksum: every byte, with the checksum field's own
  -- eight counted as spaces.
  local block = ("x"):rep(148) .. ("\255"):rep(8) .. ("\0"):rep(356)
  assert(Hash.byte_sum(block, 1, 148) + 8 * 32 + Hash.byte_sum(block, 157, 512) ==
    148 * 120 + 8 * 32)
  assert(Hash.byte_sum(block) == 148 * 120 + 8 * 255)
end

local function test_byte_sum_raises_on_a_range_outside_the_string()
  assert(not pcall(Hash.byte_sum, "abc", 0))
  assert(not pcall(Hash.byte_sum, "abc", 1, 4))
  assert(not pcall(Hash.byte_sum, "abc", 1, -1))
  assert(not pcall(Hash.byte_sum, "abc", 5))
  assert(not pcall(Hash.byte_sum, "abc", 3, 1))
end
