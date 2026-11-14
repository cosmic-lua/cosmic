--- SRP-6a, the Secure Remote Password protocol: a client proves that it
--- knows a password to a server that holds only a verifier of it, and
--- both arrive at a key nobody listening can compute. The password never
--- crosses the wire, and what does cross gives a listener nothing to
--- try guesses against.
---
--- - [`Srp.verifier`] is what a server stores for an identity, in place
---   of the password.
--- - [`Srp.client`] is the client's side of one login and [`Srp.server`]
---   the server's. Each has a public value to send, and proves the key
---   to the other.
--- - [`Srp.Parameters`] names the group, the hash and the hashing
---   [`Srp.Rules`]. Both sides must use the same three: nothing in the
---   protocol negotiates them.
---
---     local parameters: Srp.Parameters = { group = Srp.group_3072, hash = "sha512", rules = "rfc5054" }
---     local client = Srp.client(parameters, "alice", "password123")
---     local server = Srp.server(parameters, "alice", salt, verifier)
---     local login = assert(client:prove(salt, server.public))
---     local accepted = assert(server:verify(client.public, login.proof))
---     assert(client:verify(accepted.proof) and login.key == accepted.key)
---
--- A login is four messages. The client sends its identity and
--- `client.public`. The server sends the identity's salt and
--- `server.public`. The client sends its proof, and the server, once it
--- has checked that, sends its own.
---
--- Numbers (a prime, a public value, a verifier) are big-endian byte
--- strings, as in [`cosmic.bigint`]. One that a function here answers is
--- as wide as the group's prime, zero bytes on the left. One that a peer
--- sent may have any number of leading zero bytes. An identity, a
--- password and a salt are bytes, hashed as given: a caller that takes
--- text from a person settles its encoding and normal form first.
---
--- What a correct program can meet answers nil and why: a peer's public
--- value that is not a number from 1 to the prime less 1, a scrambling
--- value of zero, a proof that is wrong. An argument that is the caller's own mistake (a
--- group whose prime is even, a secret of no bytes) raises, and so does
--- the system's entropy source failing.
---
--- Secrets and time. The secret exponents go through
--- [`Bigint.powmod`] at a fixed width, which hides an exponent's value
--- and nothing else ([`cosmic.bigint`]'s doc says what shows). The
--- arithmetic around it is not constant in time: the client's exponent
--- is a sum and a product of secrets, both sides reduce a product with
--- the verifier, and the shared number is hashed without its leading
--- zero bytes, so its length shows. Whoever can time one side's
--- arithmetic that closely may learn something of the verifier or of
--- the password's hash. Proofs are compared with [`Hash.equal`]. Nothing
--- wipes a password, a secret or a key: they are ordinary strings.

local Bigint = require("cosmic.bigint")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Rand = require("cosmic.rand")
local String = require("cosmic.string")

local record Srp
  --- The numbers a login computes with: a prime `N` and a generator `g`
  --- of the integers modulo it, big-endian. Use one of the constants
  --- unless a peer dictates another. The prime of a group made elsewhere
  --- must be a safe prime (`(N - 1) / 2` is prime too) and `g` a
  --- generator modulo it: nothing here checks either.
  record Group
    --- `N`.
    prime: string
    --- `g`, from 2 to `N` less 1.
    generator: string
  end

  --- A hash function: the digest of `data`, always of one length, from
  --- 1 to 255 bytes.
  type Digest = function(data: string): string

  --- How numbers become bytes where they are hashed, which
  --- implementations do not agree on. In both rule sets, with `H` the
  --- hash, `|` joining bytes, `PAD(n)` the number `n` at the width of
  --- `N` and a bare number its shortest form, with no leading zero byte:
  ---
  --- - `k = H(N | PAD(g))`, `u = H(PAD(A) | PAD(B))` and
  ---   `x = H(salt | H(identity | ":" | password))`;
  --- - the verifier is `g^x`, `A = g^a` and `B = k*v + g^b`, all modulo
  ---   `N`;
  --- - the shared number `S` is `(B - k*g^x)^(a + u*x)` to the client
  ---   and `(A * v^u)^b` to the server, and the key is `K = H(S)`;
  --- - the client's proof is
  ---   `M1 = H(HN xor Hg | HI | salt | A | B | K)`, where `HN = H(N)`,
  ---   `Hg = H(g)` and `HI = H(identity)`, and the server's is
  ---   `M2 = H(A | M1 | K)`.
  ---
  --- So only `g` in `k`, and `A` and `B` in `u`, are padded, as RFC 5054
  --- section 2.1 has it: a number is its shortest form unless `PAD` is
  --- written. A salt is hashed as its bytes, leading zeros included. The
  --- two rule sets differ in `M1` alone, in whether the digests `HN xor
  --- Hg` and `HI` are bytes, kept whole, or numbers.
  enum Rules
    --- RFC 5054's `k`, `u` and `x` with RFC 2945's two proofs, over SRP-6's key (`H(S)`, `S` in its shortest
    --- form) and not that RFC's interleaved SHA-1. `HN xor Hg` and `HI` are hashed as a digest's whole bytes.
    "rfc5054"
    --- What the Python library `srptools` 2.0 computes: as `rfc5054`, but in `M1` the digests `HN xor Hg` and `HI`
    --- are read as numbers, and so lose their leading zero bytes.
    "srptools"
  end

  --- What both sides of a login agree on beforehand. A verifier belongs
  --- to the parameters it was made under.
  record Parameters
    --- One of the constants ([`Srp.group_3072`]), or a peer's own.
    group: Group
    --- A name of [`Hash.Algorithm`], or a function for a hash that
    --- [`cosmic.hash`] does not carry.
    hash: Hash.Algorithm | Digest
    --- Which of the two ways of hashing the peer follows.
    rules: Rules
  end

  --- What a side holds once it has computed the shared key.
  record Session
    --- The key `K`, a digest's length of bytes. It is not yet proved to
    --- be shared: a client uses it once [`Client`]'s `verify` answers
    --- true, and a server gets a session only from a proof that was
    --- right.
    key: string
    --- This side's proof, to send to the other: `M1` from a client, `M2`
    --- from a server.
    proof: string
  end

  --- The client's side of one login, from [`Srp.client`].
  record Client
    --- `A`, to send to the server.
    public: string

    --- The session, given the salt and public value the server sent,
    --- and "". nil and why when `server_public` is not a number from 1
    --- to the prime less 1, or when the scrambling value `u` is zero.
    --- A public value of zero modulo the prime, or a `u` of zero, would
    --- let a server that does not know the verifier choose the key, and
    --- no honest server sends a number that is not below the prime.
    --- Give up the login then: `verify` answers for no earlier session.
    prove: function(self: Client, salt: string, server_public: string): Session?, string

    --- Whether `server_proof` is the proof of the session `prove`
    --- answered, which only a server holding the verifier can send.
    --- Raises when `prove` has answered no session.
    verify: function(self: Client, server_proof: string): boolean
  end

  --- The server's side of one login, from [`Srp.server`].
  record Server
    --- `B`, to send to the client with the salt.
    public: string

    --- The session, given the public value and the proof the client
    --- sent, and "": its `proof` is the answer that shows the client
    --- the server holds the verifier. nil and why when `client_proof`
    --- is wrong, which is what a wrong password looks like, when
    --- `client_public` is not a number from 1 to the prime less 1, or
    --- when `u` is zero. A client that failed is answered with nothing
    --- computed from the key, or it could try passwords against the
    --- answer at leisure. Each proof tests one guess at the password:
    --- the caller limits how many an identity gets.
    verify: function(self: Server, client_public: string, client_proof: string): Session?, string
  end

  --- The 1024-bit group of RFC 5054, appendix A. Its generator is 2.
  group_1024: Group
  --- The 1536-bit group of RFC 5054, appendix A. Its generator is 2.
  group_1536: Group
  --- The 2048-bit group of RFC 5054, appendix A. Its generator is 2.
  group_2048: Group
  --- The 3072-bit group of RFC 5054, appendix A. Its generator is 5.
  group_3072: Group
  --- The 4096-bit group of RFC 5054, appendix A. Its generator is 5.
  group_4096: Group
  --- The 6144-bit group of RFC 5054, appendix A. Its generator is 5.
  group_6144: Group
  --- The 8192-bit group of RFC 5054, appendix A. Its generator is 19.
  group_8192: Group
end

--- How many bytes a secret exponent drawn here is: 512 bits, twice the
--- 256 that RFC 5054 asks for at least.
local secret_length <const> = 64

--- The most bytes of a secret a caller passes, so that the client's
--- exponent `a + u*x` stays an exponent [`Bigint.powmod`] takes.
local secret_most <const> = 512

--- `number` with no leading zero byte, and one zero byte for zero.
local function shortest(number: string): string
  local first = number:find("[^\0]")
  if first == nil then return "\0" end
  return number:sub(first)
end

local function group(generator: string, hex: string): Srp.Group
  return { prime = assert(Codec.unhex(hex)), generator = generator }
end

Srp.group_1024 = group("\2",
  "eeaf0ab9adb38dd69c33f80afa8fc5e86072618775ff3c0b9ea2314c9c256576d674df7496ea81d3383b4813d692c6e0" ..
    "e0d5d8e250b98be48e495c1d6089dad15dc7d7b46154d6b6ce8ef4ad69b15d4982559b297bcf1885c529f566660e57ec" ..
    "68edbc3c05726cc02fd4cbf4976eaa9afd5138fe8376435b9fc61d2fc0eb06e3")

Srp.group_1536 = group("\2",
  "9def3cafb939277ab1f12a8617a47bbbdba51df499ac4c80beeea9614b19cc4d5f4f5f556e27cbde51c6a94be4607a29" ..
    "1558903ba0d0f84380b655bb9a22e8dcdf028a7cec67f0d08134b1c8b97989149b609e0be3bab63d47548381dbc5b1fc" ..
    "764e3f4b53dd9da1158bfd3e2b9c8cf56edf019539349627db2fd53d24b7c48665772e437d6c7f8ce442734af7ccb7ae" ..
    "837c264ae3a9beb87f8a2fe9b8b5292e5a021fff5e91479e8ce7a28c2442c6f315180f93499a234dcf76e3fed135f9bb")

Srp.group_2048 = group("\2",
  "ac6bdb41324a9a9bf166de5e1389582faf72b6651987ee07fc3192943db56050a37329cbb4a099ed8193e0757767a13d" ..
    "d52312ab4b03310dcd7f48a9da04fd50e8083969edb767b0cf6095179a163ab3661a05fbd5faaae82918a9962f0b93b8" ..
    "55f97993ec975eeaa80d740adbf4ff747359d041d5c33ea71d281e446b14773bca97b43a23fb801676bd207a436c6481" ..
    "f1d2b9078717461a5b9d32e688f87748544523b524b0d57d5ea77a2775d2ecfa032cfbdbf52fb3786160279004e57ae6" ..
    "af874e7303ce53299ccc041c7bc308d82a5698f3a8d0c38271ae35f8e9dbfbb694b5c803d89f7ae435de236d525f5475" ..
    "9b65e372fcd68ef20fa7111f9e4aff73")

Srp.group_3072 = group("\5",
  "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd" ..
    "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" ..
    "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f" ..
    "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ..
    "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510" ..
    "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7" ..
    "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c" ..
    "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a93ad2caffffffffffffffff")

Srp.group_4096 = group("\5",
  "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd" ..
    "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" ..
    "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f" ..
    "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ..
    "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510" ..
    "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7" ..
    "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c" ..
    "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d7" ..
    "88719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8dbbbc2db04de8ef92e8efc141fbecaa6" ..
    "287c59474e6bc05d99b2964fa090c3a2233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa9" ..
    "93b4ea988d8fddc186ffb7dc90a6c08f4df435c934063199ffffffffffffffff")

Srp.group_6144 = group("\5",
  "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd" ..
    "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" ..
    "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f" ..
    "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ..
    "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510" ..
    "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7" ..
    "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c" ..
    "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d7" ..
    "88719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8dbbbc2db04de8ef92e8efc141fbecaa6" ..
    "287c59474e6bc05d99b2964fa090c3a2233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa9" ..
    "93b4ea988d8fddc186ffb7dc90a6c08f4df435c93402849236c3fab4d27c7026c1d4dcb2602646dec9751e763dba37bd" ..
    "f8ff9406ad9e530ee5db382f413001aeb06a53ed9027d831179727b0865a8918da3edbebcf9b14ed44ce6cbaced4bb1b" ..
    "db7f1447e6cc254b332051512bd7af426fb8f401378cd2bf5983ca01c64b92ecf032ea15d1721d03f482d7ce6e74fef6" ..
    "d55e702f46980c82b5a84031900b1c9e59e7c97fbec7e8f323a97a7e36cc88be0f1d45b7ff585ac54bd407b22b4154aa" ..
    "cc8f6d7ebf48e1d814cc5ed20f8037e0a79715eef29be32806a1d58bb7c5da76f550aa3d8a1fbff0eb19ccb1a313d55c" ..
    "da56c9ec2ef29632387fe8d76e3c0468043e8f663f4860ee12bf2d5b0b7474d6e694f91e6dcc4024ffffffffffffffff")

Srp.group_8192 = group("\19",
  "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b139b22514a08798e3404dd" ..
    "ef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7ed" ..
    "ee386bfb5a899fa5ae9f24117c4b1fe649286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f" ..
    "83655d23dca3ad961c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca18217c32905e462e36ce3b" ..
    "e39e772c180e86039b2783a2ec07a28fb5c55df06f4c52c9de2bcbf6955817183995497cea956ae515d2261898fa0510" ..
    "15728e5a8aaac42dad33170d04507a33a85521abdf1cba64ecfb850458dbef0a8aea71575d060c7db3970f85a6e1e4c7" ..
    "abf5ae8cdb0933d71e8c94e04a25619dcee3d2261ad2ee6bf12ffa06d98a0864d87602733ec86a64521f2b18177b200c" ..
    "bbe117577a615d6c770988c0bad946e208e24fa074e5ab3143db5bfce0fd108e4b82d120a92108011a723c12a787e6d7" ..
    "88719a10bdba5b2699c327186af4e23c1a946834b6150bda2583e9ca2ad44ce8dbbbc2db04de8ef92e8efc141fbecaa6" ..
    "287c59474e6bc05d99b2964fa090c3a2233ba186515be7ed1f612970cee2d7afb81bdd762170481cd0069127d5b05aa9" ..
    "93b4ea988d8fddc186ffb7dc90a6c08f4df435c93402849236c3fab4d27c7026c1d4dcb2602646dec9751e763dba37bd" ..
    "f8ff9406ad9e530ee5db382f413001aeb06a53ed9027d831179727b0865a8918da3edbebcf9b14ed44ce6cbaced4bb1b" ..
    "db7f1447e6cc254b332051512bd7af426fb8f401378cd2bf5983ca01c64b92ecf032ea15d1721d03f482d7ce6e74fef6" ..
    "d55e702f46980c82b5a84031900b1c9e59e7c97fbec7e8f323a97a7e36cc88be0f1d45b7ff585ac54bd407b22b4154aa" ..
    "cc8f6d7ebf48e1d814cc5ed20f8037e0a79715eef29be32806a1d58bb7c5da76f550aa3d8a1fbff0eb19ccb1a313d55c" ..
    "da56c9ec2ef29632387fe8d76e3c0468043e8f663f4860ee12bf2d5b0b7474d6e694f91e6dbe115974a3926f12fee5e4" ..
    "38777cb6a932df8cd8bec4d073b931ba3bc832b68d9dd300741fa7bf8afc47ed2576f6936ba424663aab639c5ae4f568" ..
    "3423b4742bf1c978238f16cbe39d652de3fdb8befc848ad922222e04a4037c0713eb57a81a23f0c73473fc646cea306b" ..
    "4bcbc8862f8385ddfa9d4b7fa2c087e879683303ed5bdd3a062b3cf5b3a278a66d2a13f83f44f82ddf310ee074ab6a36" ..
    "4597e899a0255dc164f31cc50846851df9ab48195ded7ea1b1d510bd7ee74d73faf36bc31ecfa268359046f4eb879f92" ..
    "4009438b481c6cd7889a002ed5ee382bc9190da6fc026e479558e4475677e9aa9e3050e2765694dfc81f56e880b96e71" ..
    "60c980dd98edd3dfffffffffffffffff")

--- [`Srp.Parameters`] checked and made ready to compute with.
local record Suite
  prime: string
  generator: string
  --- How many bytes the prime is.
  width: integer
  digest: Srp.Digest
  --- The multiplier `k`.
  multiplier: string
  --- Whether `HN xor Hg` and `HI` lose their leading zero bytes.
  strips: boolean
end

--- `number`, which is below the prime, at the prime's width.
local function padded(suite: Suite, number: string): string
  return (assert(Bigint.pad(number, suite.width)))
end

--- The suite of `parameters`. `level` is where a refusal is raised, as
--- [`error`] counts it from this function's caller.
local function suite_of(parameters: Srp.Parameters, level: integer): Suite
  local prime = shortest(parameters.group.prime)
  local generator = shortest(parameters.group.generator)
  if #prime > Bigint.modulus_bytes then
    error("srp: the group's prime is longer than " .. String.counted(Bigint.modulus_bytes, "byte"), level + 1)
  end
  if assert(prime:byte(-1)) % 2 == 0 then error("srp: the group's prime is even", level + 1) end
  if Bigint.compare(generator, "\1") <= 0 or #generator > #prime or Bigint.compare(generator, prime) >= 0 then
    error("srp: the group's generator must be from 2 to the prime less 1", level + 1)
  end
  local hash = parameters.hash
  local digest: Srp.Digest
  if hash is Hash.Algorithm then
    digest = function(data: string): string return Hash.digest(hash, data) end
  else
    digest = hash
  end
  local multiplier = digest(prime .. assert(Bigint.pad(generator, #prime)))
  if #multiplier < 1 or #multiplier > 255 then
    error("srp: the hash must answer a digest of 1 to 255 bytes", level + 1)
  end
  return {
    prime = prime,
    generator = generator,
    width = #prime,
    digest = digest,
    multiplier = multiplier,
    strips = parameters.rules == "srptools",
  }
end

--- The private key `x` of an identity, a digest's length of bytes.
local function private_key(suite: Suite, identity: string, password: string, salt: string): string
  return suite.digest(salt .. suite.digest(identity .. ":" .. password))
end

--- `secret` as given, or `secret_length` bytes of entropy. `level` is
--- as [`suite_of`]'s.
local function exponent_of(secret: string?, level: integer): string
  if secret == nil then return (assert(Rand.entropy(secret_length))) end
  if #secret < 1 or #secret > secret_most then
    error("srp: a secret must be from 1 to " .. String.counted(secret_most, "byte"), level + 1)
  end
  if shortest(secret) == "\0" then error("srp: a secret must not be zero", level + 1) end
  return secret
end

--- `public` as a peer sent it, in its shortest form, when it is a number
--- from 1 to the prime less 1.
local function accepted(suite: Suite, public: string): string?
  local number = shortest(public)
  if number == "\0" or #number > suite.width or Bigint.compare(number, suite.prime) >= 0 then
    return nil
  end
  return number
end

--- The scrambling value `u` of the two public values, or nil when it is
--- zero.
local function scrambler(suite: Suite, client_public: string, server_public: string): string?
  local u = suite.digest(padded(suite, client_public) .. padded(suite, server_public))
  if shortest(u) == "\0" then return nil end
  return u
end

local function xor(a: string, b: string): string
  local bytes: mut {string} = {}
  for i = 1, #a do
    bytes[#bytes + 1] = string.char(assert(a:byte(i)) ~ assert(b:byte(i)))
  end
  return table.concat(bytes)
end

--- The key and the two proofs of a login whose shared number is
--- `shared`. The public values are in their shortest form.
local function proofs(suite: Suite, identity: string, salt: string, client_public: string, server_public: string,
                      shared: string): string, string, string
  local digest = suite.digest
  local key = digest(shared)
  local group_part = xor(digest(suite.prime), digest(suite.generator))
  local identity_part = digest(identity)
  if suite.strips then
    group_part, identity_part = shortest(group_part), shortest(identity_part)
  end
  local client_proof = digest(group_part .. identity_part .. salt .. client_public .. server_public .. key)
  return key, client_proof, digest(client_public .. client_proof .. key)
end

--- The verifier `v` of a password: what a server stores for `identity`,
--- beside `salt`, when the password is set. It is not the password, but
--- whoever reads it can try guesses against it at the speed of two
--- hashes and an exponentiation, so keep it as a password hash is kept.
--- `salt` is bytes drawn for this identity, `Rand.entropy(16)` of
--- [`cosmic.rand`]. Raises on a group it cannot compute with.
---
---     local salt = assert(Rand.entropy(16))
---     local verifier = Srp.verifier(parameters, "alice", "password123", salt)
function Srp.verifier(parameters: Srp.Parameters, identity: string, password: string, salt: string): string
  local suite = suite_of(parameters, 2)
  return padded(suite, Bigint.powmod(suite.generator, private_key(suite, identity, password, salt), suite.prime))
end

--- The client's side of one login as `identity`. `secret` is the
--- private exponent `a`, for a test that must replay: absent, it is 64
--- bytes from [`Rand.entropy`], fresh for each login, which is what a
--- program wants. Raises on a group it cannot compute with, and on a
--- `secret` that is zero, of no bytes or of more than 512.
function Srp.client(parameters: Srp.Parameters, identity: string, password: string, secret?: string): Srp.Client
  local suite = suite_of(parameters, 2)
  local exponent = exponent_of(secret, 2)
  local public = Bigint.powmod(suite.generator, exponent, suite.prime)
  local expected: string? = nil

  return {
    public = padded(suite, public),
    prove = function(_self: Srp.Client, salt: string, server_public: string): Srp.Session?, string
      expected = nil
      local theirs = accepted(suite, server_public)
      if theirs == nil then
        return nil, "srp: the server's public value is not from 1 to the prime less 1"
      end
      local u = scrambler(suite, public, theirs)
      if u == nil then return nil, "srp: the scrambling value is zero" end
      local x = private_key(suite, identity, password, salt)
      local verifier = Bigint.powmod(suite.generator, x, suite.prime)
      -- TODO: the products and sums here, and the server's, take a time that depends on the verifier and on
      -- `x`: compute them in constant time once cosmic.bigint carries a multiplication, an addition and a
      -- reduction that are.
      local masked = Bigint.mod(Bigint.mul(suite.multiplier, verifier), suite.prime)
      local base = Bigint.mod(assert(Bigint.sub(Bigint.add(theirs, suite.prime), masked)), suite.prime)
      -- One width for every login, as powmod asks of a secret exponent:
      -- the sum is below 256 to the power of this.
      local width = math.max(#exponent, #u + #x) + 1
      local power = assert(Bigint.pad(Bigint.add(exponent, Bigint.mul(u, x)), width))
      local shared = Bigint.powmod(base, power, suite.prime)
      local key, proof, server_proof = proofs(suite, identity, salt, public, theirs, shared)
      expected = server_proof
      return { key = key, proof = proof }, ""
    end,
    verify = function(_self: Srp.Client, server_proof: string): boolean
      local want = expected
      if want == nil then error("srp: verify comes after prove has answered a session", 2) end
      return Hash.equal(server_proof, want)
    end,
  }
end

--- The server's side of one login as `identity`, whose stored `salt`
--- and `verifier` ([`Srp.verifier`]) it is given. `secret` is the
--- private exponent `b`, for a test that must replay, as
--- [`Srp.client`]'s is. Raises on a group it cannot compute with, on a
--- `verifier` that is not a number from 1 to the prime less 1, and on a
--- `secret` as [`Srp.client`] does or one whose public value would be
--- zero.
function Srp.server(parameters: Srp.Parameters, identity: string, salt: string, verifier: string,
                    secret?: string): Srp.Server
  local suite = suite_of(parameters, 2)
  local v = accepted(suite, verifier)
  if v == nil then error("srp: the verifier is not from 1 to the prime less 1", 2) end
  local masked = Bigint.mod(Bigint.mul(suite.multiplier, v), suite.prime)
  local exponent, public: string, string
  repeat
    exponent = exponent_of(secret, 2)
    public = Bigint.mod(Bigint.add(masked, Bigint.powmod(suite.generator, exponent, suite.prime)), suite.prime)
    if public == "\0" and secret ~= nil then
      error("srp: the secret makes a public value of zero", 2)
    end
  until public ~= "\0"

  return {
    public = padded(suite, public),
    verify = function(_self: Srp.Server, client_public: string, client_proof: string): Srp.Session?, string
      local theirs = accepted(suite, client_public)
      if theirs == nil then
        return nil, "srp: the client's public value is not from 1 to the prime less 1"
      end
      local u = scrambler(suite, theirs, public)
      if u == nil then return nil, "srp: the scrambling value is zero" end
      local base = Bigint.mod(Bigint.mul(theirs, Bigint.powmod(v, u, suite.prime)), suite.prime)
      local shared = Bigint.powmod(base, exponent, suite.prime)
      local key, expected, proof = proofs(suite, identity, salt, theirs, public, shared)
      if not Hash.equal(client_proof, expected) then
        return nil, "srp: the client's proof is wrong"
      end
      return { key = key, proof = proof }, ""
    end,
  }
end

return Srp
