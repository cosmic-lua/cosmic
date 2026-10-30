--- Proves SHA-256 and SHA-512 against digests from outside the library,
--- on the message lengths where padding changes the block count (55, 56,
--- 63, 64, 119, 120, 127 and 128 bytes) and where input is fed in
--- pieces. SHA-256 runs on the processor's SHA instructions where it has
--- them (x86 SHA-NI, Armv8 SHA2) and on the portable code elsewhere, and
--- a wrong round, schedule word or state shuffle in one path changes
--- every digest it makes: the vectors and the independent Lua SHA-256
--- below hold both paths to the same answers. The processor features
--- [`sys.cpu_features`] answers key the verdict (build/declared_key.tl), so
--- each kind of processor runs this on its own path.

local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")

--- The bytes of the test messages: byte `i` of a message is `i % 251`,
--- so a message is not periodic in any block size.
local function message(length: integer): string
  local pieces: mut {string} = {}
  for first = 0, length - 1, 4096 do
    local bytes: mut {integer} = {}
    for i = first, math.min(first + 4095, length - 1) do bytes[#bytes + 1] = i % 251 end
    pieces[#pieces + 1] = string.char(table.unpack(bytes))
  end
  return table.concat(pieces)
end

--- Length, SHA-256 and SHA-512 (hex) of `message(length)`, from Python's hashlib.
local record Vector
  length: integer
  sha256: string
  sha512: string
end

local vectors: {Vector} = {
  { length = 0,
    sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    sha512 = "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce" ..
      "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e" },
  { length = 1,
    sha256 = "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d",
    sha512 = "b8244d028981d693af7b456af8efa4cad63d282e19ff14942c246e50d9351d22" ..
      "704a802a71c3580b6370de4ceb293c324a8423342557d4e5c38438f0e36910ee" },
  { length = 55,
    sha256 = "463eb28e72f82e0a96c0a4cc53690c571281131f672aa229e0d45ae59b598b59",
    sha512 = "6856647f269c2ee3d8128f0b25427659d880641ef343300dd3cd4679168f58d6" ..
      "527fda70b4ebc854e2065e172b7d58c1536992c0810599259ba84a2b40c65414" },
  { length = 56,
    sha256 = "da2ae4d6b36748f2a318f23e7ab1dfdf45acdc9d049bd80e59de82a60895f562",
    sha512 = "8b12b2f6fe400a51d29656e2b8c42a1bbfe6fcf3e425da430db05d1a2dda1479" ..
      "0dee20fa8b22d8762afffe4988a5c98a4430d22a17e41e23d90fa61ab75671a9" },
  { length = 63,
    sha256 = "29af2686fd53374a36b0846694cc342177e428d1647515f078784d69cdb9e488",
    sha512 = "9dc9c5598e55dc42955695320839788e353f1d7f6ba74df74c80a8a52f463c06" ..
      "97f57f68835d1418f4ce9b6530cd79bd0f4c6f7e13c93feb1218c0b65c2c0561" },
  { length = 64,
    sha256 = "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108",
    sha512 = "ee4320ebaf3fdb4f2c832b137200c08e235e0fa7bbd0eb1740c7063ba8a0d151" ..
      "da77e003398e1714a955d475b05e3e950b639503b452ec185de4229bc4873949" },
  { length = 65,
    sha256 = "4bfd2c8b6f1eec7a2afeb48b934ee4b2694182027e6d0fc075074f2fabb31781",
    sha512 = "02856cef735f9acec6b9e33f0fbc8f9804d2aa54187f382b8ae842e5d3696c07" ..
      "459aad2a5aed25ea5e117eb1c7ba35da6a7a8adce9e6afe3ad79e9fa42d5bba8" },
  { length = 111,
    sha256 = "60780e9451bdc43cf4530ffc95cbb0c4eb24dae2c39f55f334d679e076c08065",
    sha512 = "a1a111449b198d9b1f538bad7f3fc1022b3a5b1a5e90a0bc860de8512746cbc3" ..
      "1599e6c834de3a3235327af0b51ff57bf7acf1974a73014d9c3953812edc7c8d" },
  { length = 112,
    sha256 = "09373f127d34e61dbbaa8bc4499c87074f2ddb10e1b465f506d7d70a15011979",
    sha512 = "c5fbd731d19d2ae1180f001be72c2c1aaba1d7b094b3748880e24593b8e117a7" ..
      "50e11c1bd867cc2f96dace8c8b74abd2d5c4f236be444e77d30d1916174070b9" },
  { length = 119,
    sha256 = "da18797ed7c3a777f0847f429724a2d8cd5138e6ed2895c3fa1a6d39d18f7ec6",
    sha512 = "43e497279c2ce805903a33b54b746ea92d607f7c4807986c849823b81097a909" ..
      "9b5896ac7cc66df3a93edc8a91b6f3971d6c7f5688daf635737760bd080e27b3" },
  { length = 120,
    sha256 = "f52b23db1fbb6ded89ef42a23ce0c8922c45f25c50b568a93bf1c075420bbb7c",
    sha512 = "9636708964c5ff6600510319e07bf3fcfcb1f4058fec278efb677964ba1e140c" ..
      "1632505452f802e99bcf09da3d456dc3868d149a0788a730e49d239ce7415145" },
  { length = 127,
    sha256 = "92ca0fa6651ee2f97b884b7246a562fa71250fedefe5ebf270d31c546bfea976",
    sha512 = "eab89674feaa34e27aebeeff3c0a4d70070bb872d5e9f186cf1dbbdee517b6e3" ..
      "5724d629ff025a5b07185e911ada7e3c8acf830aa0e4f71777bd2d44f504f7f0" },
  { length = 128,
    sha256 = "471fb943aa23c511f6f72f8d1652d9c880cfa392ad80503120547703e56a2be5",
    sha512 = "1dffd5e3adb71d45d2245939665521ae001a317a03720a45732ba1900ca3b835" ..
      "1fc5c9b4ca513eba6f80bc7b1d1fdad4abd13491cb824d61b08d8c0e1561b3f7" },
  { length = 129,
    sha256 = "5099c6a56203f9687f7d33f4bfdf576d31dc91f6b695ecea38b2770c87631135",
    sha512 = "1d9da57fbbdab09afb3506ab2d223d06109d65c1c8ad197f50138f714bc4c3f2" ..
      "fe5787922639c680acad1c651f955990425954ce2cba0c5cc83f2667d878eb0f" },
  { length = 1000,
    sha256 = "4e4c294b331f7a2099a379bec34b9f9fc03dc46ab465d998f4d683da53487e6d",
    sha512 = "5096498d96f50f9a137c4db5b8b0cd38383ad55350fb5a98805fedc31fa1262f" ..
      "1f0cf4d6f12d7ecd8dedd933a4c9126344fe22e937a8ad35fdeae1e876ae698b" },
}

local function test_sha2_matches_digests_computed_outside_the_library()
  for _, v in ipairs(vectors) do
    local text = message(v.length)
    assert(Codec.hex(Hash.digest("sha256", text)) == v.sha256, "sha256 of " .. tostring(v.length))
    assert(Codec.hex(Hash.digest("sha512", text)) == v.sha512, "sha512 of " .. tostring(v.length))
  end
end

--- FIPS 180-4's two-block messages and the million-a message, which is
--- 15,625 blocks through one long run of the block function.
local function test_sha2_matches_the_published_multi_block_vectors()
  assert(Hash.hex_sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
  assert(Codec.hex(Hash.digest("sha512", "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn" ..
      "hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")) ==
      "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018" ..
      "501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")
  local million = string.rep("a", 1000000)
  assert(Hash.hex_sha256(million) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  assert(Codec.hex(Hash.digest("sha512", million)) ==
      "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973eb" ..
      "de0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b")
end

--- SHA-224 shares SHA-256's block function and differs in initial state
--- and truncation; SHA-384 likewise with SHA-512.
local function test_sha224_and_sha384_match_the_published_vectors()
  assert(Codec.hex(Hash.digest("sha224", "abc")) ==
      "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7")
  assert(Codec.hex(Hash.digest("sha224", "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) ==
      "75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525")
  assert(Codec.hex(Hash.digest("sha384", "abc")) ==
      "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed" ..
      "8086072ba1e7cc2358baeca134c825a7")
end

--- Input split at awkward offsets: the buffered tail, a block that
--- straddles two updates, whole blocks fed with a partial one pending
--- (the library hands those to the block function in one run) and a
--- split next to the padding's length field.
local function test_pieces_at_odd_offsets_make_the_same_digest()
  local text = message(1000)
  local splits: {{integer}} = {
    { 1 }, { 63 }, { 64 }, { 65 }, { 3, 61 }, { 1, 64, 65 }, { 55, 56, 57 }, { 127, 129 },
    { 7, 100, 333, 334 }, { 999 }, { 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13 },
  }
  local algorithms: {Hash.Algorithm} = { "sha256", "sha512", "sha224", "sha384" }
  for _, algorithm in ipairs(algorithms) do
    local want = Hash.digest(algorithm, text)
    for _, cuts in ipairs(splits) do
      local hasher = assert(Hash.hasher(algorithm))
      local at = 1
      for _, cut in ipairs(cuts) do
        hasher:update(text:sub(at, at + cut - 1))
        at = at + cut
      end
      hasher:update(text:sub(at))
      assert(assert(hasher:digest()) == want, algorithm .. " split " .. table.concat(cuts, ","))
    end
  end
end

local K <const>: {integer} = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

--- Element `i` of `list`, which the caller knows is there.
local function at(list: {integer}, i: integer): integer
  return assert(list[i])
end

local function rotr(x: integer, n: integer): integer
  return ((x >> n) | (x << (32 - n))) & 0xffffffff
end

--- SHA-256 straight from FIPS 180-4, one block at a time, sharing no
--- code or tables with the library.
local function reference_sha256(text: string): string
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local padded = text .. "\128" .. string.rep("\0", (55 - #text) % 64) .. string.pack(">I8", #text * 8)
  assert(#padded % 64 == 0)
  for block = 1, #padded, 64 do
    local w: mut {integer} = {}
    for t = 0, 15 do
      local word = string.unpack(">I4", padded, block + 4 * t)
      w[#w + 1] = word
    end
    for t = 17, 64 do
      local x, y = at(w, t - 15), at(w, t - 2)
      local s0 = rotr(x, 7) ~ rotr(x, 18) ~ (x >> 3)
      local s1 = rotr(y, 17) ~ rotr(y, 19) ~ (y >> 10)
      local word = (at(w, t - 16) + s0 + at(w, t - 7) + s1) & 0xffffffff
      w[#w + 1] = word
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for t = 1, 64 do
      local big1 = rotr(e, 6) ~ rotr(e, 11) ~ rotr(e, 25)
      local choose = (e & f) ~ (~e & 0xffffffff & g)
      local t1 = (h + big1 + choose + at(K, t) + at(w, t)) & 0xffffffff
      local big0 = rotr(a, 2) ~ rotr(a, 13) ~ rotr(a, 22)
      local majority = (a & b) ~ (a & c) ~ (b & c)
      local t2 = (big0 + majority) & 0xffffffff
      h, g, f, e, d, c, b, a = g, f, e, (d + t1) & 0xffffffff, c, b, a, (t1 + t2) & 0xffffffff
    end
    h0, h1, h2, h3 = (h0 + a) & 0xffffffff, (h1 + b) & 0xffffffff, (h2 + c) & 0xffffffff,
      (h3 + d) & 0xffffffff
    h4, h5, h6, h7 = (h4 + e) & 0xffffffff, (h5 + f) & 0xffffffff, (h6 + g) & 0xffffffff,
      (h7 + h) & 0xffffffff
  end
  return string.pack(">I4I4I4I4I4I4I4I4", h0, h1, h2, h3, h4, h5, h6, h7)
end

local function test_the_reference_sha256_is_right()
  assert(Codec.hex(reference_sha256("abc")) ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  for _, v in ipairs(vectors) do
    assert(Codec.hex(reference_sha256(message(v.length))) == v.sha256, tostring(v.length))
  end
end

--- Pseudo-random bytes of every length from 0 to 135 (every padding
--- shape of one and two blocks) and a few longer ones, hashed in one
--- call and in two pieces.
local function test_sha256_agrees_with_the_reference_on_pseudo_random_data()
  local state = 0x2545F4914F6CDD1D
  local function random_bytes(length: integer): string
    local bytes: mut {string} = {}
    for i = 1, length do
      state = state ~ (state << 13)
      state = state ~ (state >> 7)
      state = state ~ (state << 17)
      bytes[i] = string.char((state >> 24) & 0xff)
    end
    return table.concat(bytes)
  end
  local lengths: mut {integer} = {}
  for length = 0, 135 do lengths[#lengths + 1] = length end
  for _, length in ipairs({ 191, 192, 193, 1024, 1025 }) do lengths[#lengths + 1] = length end
  for _, length in ipairs(lengths) do
    local text = random_bytes(length)
    local want = reference_sha256(text)
    assert(Hash.sha256(text) == want, "one call, length " .. tostring(length))
    local hasher = assert(Hash.hasher("sha256"))
    local cut = (length * 7) % (length + 1)
    hasher:update(text:sub(1, cut))
    hasher:update(text:sub(cut + 1))
    assert(assert(hasher:digest()) == want, "two pieces, length " .. tostring(length))
  end
end
