--- Proves the digests and HMAC the core exposes against published
--- test vectors, in Teal and in SQL alike, and that an algorithm
--- nobody has heard of is refused rather than answered.

local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")

local fox = "The quick brown fox jumps over the lazy dog"

local record Holder
  h: Hash.Hasher
end

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

local function test_equal_compares_every_byte()
  local mac = Hash.hmac("sha256", "key", fox)
  assert(Hash.equal(mac, mac))
  assert(Hash.equal(mac, Hash.hmac("sha256", "key", fox)))
  assert(Hash.equal("", ""))
  assert(Hash.equal("a\0b", "a\0b"))
  assert(not Hash.equal("a\0b", "a\0c"))
  -- Each byte position decides: a flip at the first, a middle and the
  -- last byte, and in the high bit, is unequal.
  for _, at in ipairs({ 1, 16, 32 }) do
    for _, flip in ipairs({ 1, 0x80, 0xff }) do
      local bytes = { mac:byte(1, -1) }
      bytes[at] = bytes[at] ~ flip
      assert(not Hash.equal(mac, string.char(table.unpack(bytes))),
        "byte " .. at .. " flipped by " .. flip)
    end
  end
end

local function test_equal_refuses_a_length_mismatch()
  assert(not Hash.equal("abc", "ab"))
  assert(not Hash.equal("ab", "abc"))
  assert(not Hash.equal("", "a"))
  assert(not Hash.equal("a\0", "a"))
end

local function test_equal_raises_on_a_non_string()
  local equal = Hash.equal as function(any, any): boolean
  local ok = pcall(equal, {}, "1")
  assert(not ok)
  ok = pcall(equal, "1", nil)
  assert(not ok)
  -- A number converts to a string in Lua; a MAC is never one.
  ok = pcall(equal, 123, "123")
  assert(not ok)
  ok = pcall(equal, "123", 123)
  assert(not ok)
end

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

--- The raw HMAC of `message` fed to [`Hash.hmac_hasher`] in pieces of `step` bytes.
local function chunked_hmac(algorithm: Hash.Algorithm, key: string, message: string, step: integer): string
  local mac = assert(Hash.hmac_hasher(algorithm, key))
  local at = 1
  while at <= #message do
    mac:update(message:sub(at, at + step - 1))
    at = at + step
  end
  return (assert(mac:digest()))
end

local function test_incremental_hmac_matches_published_vectors()
  local ones = string.rep("\x0b", 20)
  local long_key = string.rep("\xaa", 131)
  local text = "Test Using Larger Than Block-Size Key - Hash Key First"
  -- RFC 4231 cases 1, 2 and 6 (SHA-256), RFC 2202 cases 1, 2 and 6 (MD5, SHA-1).
  local cases: {{string}} = {
    { "sha256", ones, "Hi There", "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7" },
    { "sha256", "Jefe", "what do ya want for nothing?",
      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" },
    { "sha256", long_key, text, "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54" },
    { "md5", string.rep("\x0b", 16), "Hi There", "9294727a3638bb1c13f48ef8158bfc9d" },
    { "md5", "Jefe", "what do ya want for nothing?", "750c783e6ab0b503eaa86e310a5db738" },
    { "md5", string.rep("\xaa", 80), text, "6b1ab7fe4bd7bf8f0b62e6ce61b9d0cd" },
    { "sha1", string.rep("\x0b", 20), "Hi There", "b617318655057264e28bc0b6fb378c8ef146be00" },
    { "sha1", "Jefe", "what do ya want for nothing?", "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79" },
    { "sha1", string.rep("\xaa", 80), text, "aa4ae5e15272d00e95705637ce8a3b55ed402112" },
  }
  for _, case in ipairs(cases) do
    local algorithm = case[1] as Hash.Algorithm
    for _, step in ipairs({ 1, 3, 64, 1000 }) do
      assert(Codec.hex(chunked_hmac(algorithm, case[2], case[3], step)) == case[4],
        case[1] .. " in chunks of " .. step)
    end
  end
end

--- What an HMAC key is padded to, per algorithm (the rate of a SHA-3 sponge).
local blocks: {Hash.Algorithm:integer} = {
  ["md5"] = 64, ["sha1"] = 64, ["sha224"] = 64, ["sha256"] = 64, ["sha384"] = 128, ["sha512"] = 128,
  ["sha3-224"] = 144, ["sha3-256"] = 136, ["sha3-384"] = 104, ["sha3-512"] = 72,
}

local function test_incremental_hmac_agrees_with_hmac_for_every_algorithm()
  local message = string.rep("0123456789abcdef", 40)
  for algorithm, block in pairs(blocks) do
    -- Each algorithm's own block boundary, besides the lengths every one meets.
    for _, length in ipairs({ 0, 1, 64, 71, 72, 73, 104, 136, 144, 145, 300, block - 1, block, block + 1 }) do
      local key = string.rep("k", length)
      local want = Hash.hmac(algorithm, key, message)
      for _, step in ipairs({ 1, 7, 128, #message }) do
        assert(chunked_hmac(algorithm, key, message, step) == want,
          algorithm .. " key " .. length .. " chunks of " .. step)
      end
      -- An empty message: no update at all, and one empty update.
      local none = assert(Hash.hmac_hasher(algorithm, key))
      assert(none:digest() == Hash.hmac(algorithm, key, ""))
      local empty = assert(Hash.hmac_hasher(algorithm, key))
      empty:update("")
      assert(empty:digest() == Hash.hmac(algorithm, key, ""))
    end
  end
end

--- Starting an HMAC imports its key into one of the crypto library's
--- 32 slots (MBEDTLS_PSA_KEY_SLOT_COUNT); the operation keeps a copy,
--- so the slot must be released at once. A slot left behind would make
--- the thirty-third live hasher fail to start.
local function test_many_unfinished_incremental_hmacs_can_be_live_at_once()
  local live: {Hash.Hasher} = {}
  for i = 1, 100 do
    local mac, trouble = Hash.hmac_hasher("sha256", "key" .. i)
    assert(mac ~= nil, "hasher " .. i .. ": " .. trouble)
    mac:update("message " .. i)
    live[i] = mac
  end
  for i, mac in ipairs(live) do
    assert(mac:digest() == Hash.hmac("sha256", "key" .. i, "message " .. i), "hasher " .. i)
  end
end

local function test_incremental_hmac_is_finished_by_digest()
  local mac = assert(Hash.hmac_hasher("sha256", "key"))
  mac:update("abc")
  assert(mac:digest() == Hash.hmac("sha256", "key", "abc"))
  assert(not pcall(mac.update, mac, "more"))
  assert(not pcall(mac.digest, mac))
  assert(not pcall(Hash.hmac_hasher, "nonesuch" as Hash.Algorithm, "key"))
  do local _abandoned <close> = assert(Hash.hmac_hasher("sha256", "key")) end
end

local function test_incremental_hmac_throws_naming_the_finished_hasher()
  local mac = assert(Hash.hmac_hasher("sha256", "key"))
  assert(mac:digest())
  local ok, trouble = pcall(function(): string, string
    return mac:digest()
  end)
  assert(not ok and tostring(trouble):find("hash: the hasher is finished", 1, true), tostring(trouble))
  local updated = pcall(mac.update, mac, "more")
  assert(not updated)
  local _, why = pcall(function(): any
    mac:update("more")
    return nil
  end)
  assert(tostring(why):find("hash: the hasher is finished", 1, true), tostring(why))
end

local function test_incremental_hmac_raises_on_an_unknown_algorithm()
  local ok, trouble = pcall(Hash.hmac_hasher, "sha0" as Hash.Algorithm, "key")
  assert(not ok)
  assert(tostring(trouble):find("hash: no such digest algorithm", 1, true), tostring(trouble))
end

local function test_incremental_hmac_answers_an_empty_error()
  local mac, trouble = Hash.hmac_hasher("sha256", "key")
  assert(mac ~= nil and trouble == "", trouble)
  mac:update(fox)
  local code, dtrouble = mac:digest()
  assert(code == Hash.hmac("sha256", "key", fox) and dtrouble == "", dtrouble)
end

local function test_a_closed_incremental_hmac_is_finished()
  local kept: Hash.Hasher
  do
    local mac <close> = assert(Hash.hmac_hasher("sha512", "key"))
    mac:update("abc")
    kept = mac
  end
  assert(not pcall(kept.update, kept, "more"))
  assert(not pcall(kept.digest, kept))
  -- Closing a finished one is harmless too.
  do
    local mac <close> = assert(Hash.hmac_hasher("sha3-256", "key"))
    assert(mac:digest())
  end
end

local function test_an_incremental_hmac_revived_by_a_finalizer_is_finished()
  local saved: Hash.Hasher
  local holder: Holder = setmetatable({} as Holder, {
    __gc = function(self: Holder) saved = self.h end,
  } as metatable<Holder>)
  holder.h = assert(Hash.hmac_hasher("sha256", "key"))
  holder = nil
  collectgarbage()
  collectgarbage()
  assert(saved ~= nil, "the finalizer ran")
  assert(not pcall(saved.update, saved, "abc"))
  assert(not pcall(saved.digest, saved))
end

--- Two incremental HMACs under different keys, fed alternately, do not
--- share state: each answers what a one-shot HMAC under its own key does.
local function test_incremental_hmacs_are_independent()
  local one = assert(Hash.hmac_hasher("sha256", "one"))
  local two = assert(Hash.hmac_hasher("sha256", "two"))
  one:update("a")
  two:update("x")
  one:update("b")
  two:update("y")
  assert(one:digest() == Hash.hmac("sha256", "one", "ab"))
  assert(two:digest() == Hash.hmac("sha256", "two", "xy"))
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
  assert(tostring(trouble):find("hash: no such digest algorithm", 1, true) ~= nil,
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
  assert(tostring(trouble):find("hash: no such digest algorithm", 1, true) ~= nil,
    tostring(trouble))
end

local function test_hasher_and_digest_carry_an_empty_error()
  local hasher, trouble = Hash.hasher("sha256")
  assert(hasher ~= nil and trouble == "", trouble)
  hasher:update("abc")
  local digest, dtrouble = hasher:digest()
  assert(digest == Hash.digest("sha256", "abc") and dtrouble == "", dtrouble)
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

--- SipHash under the key 00 01 .. 0f, of the first n bytes of 00 01 ..
--- (wrapping past ff): the reference vectors' scheme, with the tags
--- zig's std.crypto.auth.siphash computes (the first of SipHash-2-4's,
--- 310e0edd47db6f72, is the paper's own). The lengths reach a word's
--- tail of 0, 1, 3 and 7 bytes, and past 255, where the length byte the
--- last word carries wraps.
local siphash_lengths: {integer} = { 0, 1, 3, 7, 8, 15, 16, 63, 257 }
local siphash_vectors: {{any}} = {
  { {}, { "310e0edd47db6f72", "fd67dc93c539f874", "2d7efbd796666785", "37d1018bf50002ab",
    "6224939a79f5f593", "e545be4961ca29a1", "db9bc2577fcc2a3f", "724506eb4c328a95", "4897b2558d7b818a" } },
  { { size = 16 }, { "a3817f04ba25a8e66df67214c7550293",
    "da87c1d86b99af44347659119b22fc45", "9c70b60c5267a94e5f33b6b02985ed51",
    "a1f1ebbed8dbc153c0b84aa61ff08239",
    "3b62a9ba6258f5610f83e264f31497b4", "5493e99933b0a8117e08ec0f97cfc3d9",
    "6ee2a4ca67b054bbfd3315bf85230577", "5150d1772f50834a503e069a973fbd7c", "1b25fee1ef6fbb23179c26056c2995fc" } },
  { { compression = 1, finalization = 3, size = 16 }, { "e77ebcb22788a5befd62db6add303001",
    "fc6f370460d3eda85e0573cc2b2ff063", "6bc5ccfa1edcf79f4823187712ebd743",
    "1084b923f2aae0c3a62f2ec80848ab77",
    "aa12fee1d5e3dab4724f16ab35f9c799", "c17e5505b2bd526c2921cdec1e7e0109",
    "d0a8d95715518eebb513b0f83d9e1793", "4c5800e34efe426f079f6b0aa75260ad", "13749065b1571a858bd8b998656046a7" } },
  { { compression = 1, finalization = 3 }, { "dcc40f055801acab", "93ca577df39bf4c9", "fbf7dde7b80af88b",
    "4011b19b987d92d3", "8e9a298d11959036", "5699512a6dd820d3", "668b907d1add4fcc",
    "a8b3bbb76290199d", "b8733c21a6fc8f5d" } },
}

local function test_siphash_matches_reference_vectors()
  local key, message = "", ""
  for i = 0, 15 do key = key .. string.char(i) end
  for i = 0, 299 do message = message .. string.char(i % 256) end
  for _, case in ipairs(siphash_vectors) do
    local options = case[1] as Hash.SipHashOptions
    local tags = case[2] as {string}
    for i, n in ipairs(siphash_lengths) do
      local got = Codec.hex(Hash.siphash(key, message:sub(1, n), options))
      assert(got == tags[i], n .. " bytes: " .. got .. " ~= " .. tags[i])
    end
  end
end

local function test_siphash_refuses_a_bad_key_or_variant()
  local key = string.rep("k", 16)
  assert(not pcall(Hash.siphash, string.rep("k", 15), "m"))
  assert(not pcall(Hash.siphash, string.rep("k", 17), "m"))
  assert(not pcall(Hash.siphash, key, "m", { size = 12 }))
  assert(not pcall(Hash.siphash, key, "m", { compression = 0 }))
  assert(not pcall(Hash.siphash, key, "m", { finalization = 65 }))
  assert(Hash.siphash(key, "m", {}) == Hash.siphash(key, "m",
    { compression = 2, finalization = 4, size = 8 }))
end
