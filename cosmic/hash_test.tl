--- Proves the digests and HMAC the core exposes against published
--- test vectors, in Teal and in SQL alike, and that an algorithm
--- nobody has heard of is refused rather than answered.

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
    assert(Hash.hex(Hash.digest(algorithm, v[2])) == v[3], v[1])
  end
  assert(Hash.hex_sha256("abc") == vectors[4][3])
end

local function test_hmac_matches_published_vectors()
  for _, v in ipairs(macs) do
    local algorithm = v[1] as Hash.Algorithm
    assert(Hash.hex(Hash.hmac(algorithm, "key", fox)) == v[2], v[1])
  end
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

local function test_hasher_refuses_an_unknown_algorithm()
  local hasher, trouble = Hash.hasher("sha0" as Hash.Algorithm)
  assert(hasher == nil and trouble:find("no such digest algorithm", 1, true) ~= nil)
end
