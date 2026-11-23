--- Keys: keys that sign and keys that check signatures, and keys that
--- agree on a shared secret, one model for every module that takes one.
--- [`cosmic.acme`] signs its requests with a [`Key.Secret`], and
--- [`cosmic.jose`] signs tokens with one. Four algorithms are here,
--- each named as an argument:
---
--- - "ed25519": Ed25519 (RFC 8032), which JOSE calls EdDSA. It is pure
---   Ed25519, over the message itself; the prehashed and context
---   variants (Ed25519ph, Ed25519ctx) are not here.
--- - "p256": ECDSA over the NIST curve P-256 with SHA-256, which JOSE
---   calls ES256 and X.509 ecdsa-with-SHA256, for a certificate
---   authority or an ACME server that takes no Ed25519.
--- - "rsa": RSA PKCS #1 v1.5 with SHA-256 (RFC 8017), which JOSE calls
---   RS256 and X.509 sha256WithRSAEncryption, for a peer that takes RSA
---   alone. It is much slower than the others: prefer P-256 where the
---   peer takes it.
--- - "x25519": X25519 (RFC 7748), which signs nothing: two parties
---   [`Secret.agree`] on a secret from each one's key and the other's
---   public key.
---
---     local key = Key.generate("ed25519")
---     local signature = key:sign("message")
---     assert(key.public:verify("message", signature))
---
--- - [`Key.generate`] draws a new secret key.
--- - [`Key.read`] reads one from PEM, as [`Secret.pem`] writes it or
---   as OpenSSL does.
--- - [`Key.secret`] makes one of its secret's bytes.
--- - [`Key.public`] makes a public key of bytes from anyone.
---
--- A secret key is the whole secret: draw it here, never from a
--- password or a seeded generator; keep its PEM in a file only its owner
--- reads, and never log or print it whole. `tostring` of a key shows its
--- algorithm alone.
---
--- Signing is deterministic under each algorithm: a key and a message
--- always give the same signature (RFC 6979 for P-256).

local Codec = require("cosmic.codec")
local Der = require("cosmic.internal.der")
local Failure = require("cosmic.failure")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Rand = require("cosmic.rand")
-- The raw modules behind every function here live under the reserved
-- `cosmic.internal.` namespace -- see cosmic/store.tl for why they are
-- off the public surface.
local raw_cipher = require("cosmic.internal.cipher")
local raw_sign = require("cosmic.internal.sign")

--- The algorithm of a key.
local enum Alg
  "ed25519"
  "p256"
  "rsa"
  "x25519"
end

local OID_ED25519 <const> = "1.3.101.112"
local OID_X25519 <const> = "1.3.101.110"
local OID_EC_PUBLIC_KEY <const> = "1.2.840.10045.2.1"
local OID_P256 <const> = "1.2.840.10045.3.1.7"
local OID_RSA_ENCRYPTION <const> = "1.2.840.113549.1.1.1"

--- The numbers of an RSA public key, each unsigned big-endian with no
--- leading zero.
local record RsaNumbers
  n: string
  e: string
end

--- The modulus n and the exponent e of the DER RSAPublicKey `public`, or
--- nil.
local function rsa_numbers(public: string): RsaNumbers?
  local numbers = Der.sequence_of(public)
  local n = if numbers == nil then nil else numbers[1] end
  local e = if numbers == nil then nil else numbers[2] end
  if numbers == nil or #numbers ~= 2 or n == nil or e == nil or n.tag ~= 0x02 or e.tag ~= 0x02 then
    return nil
  end
  return { n = (n.content:gsub("^\0+", "")), e = (e.content:gsub("^\0+", "")) }
end

--- A public key: one that checks signatures, or for X25519 the half a
--- party sends the other. Every argument of [`verify`] may come from
--- anyone.
local class Public
  --- Its algorithm.
  alg: Alg
  --- The key's bytes: the 32 bytes of an Ed25519 or X25519 key, the
  --- 65-byte uncompressed point of a P-256 key as SEC 1 spells it (the
  --- byte 0x04, then X and Y as 32 big-endian bytes each), the DER
  --- RSAPublicKey of an RSA key (RFC 8017 appendix A.1.1: the SEQUENCE of
  --- the modulus n and the exponent e).
  bytes: string

  --- Whether `signature` is one of `message` under this key, as
  --- [`Secret.sign`] makes it. Bytes that do not verify answer false and
  --- nothing raises, a signature of the wrong size included; an X25519
  --- key verifies nothing.
  ---
  --- - Ed25519 takes the equation RFC 8032 section 5.1.7 gives first:
  ---   8(S·B - h·A - R) is the neutral point. An S of the group order L
  ---   or more is refused, so adding L to a valid S makes no second
  ---   signature; a key or an R that is no point of the curve is
  ---   refused; a point's encoding RFC 8032 refuses to decode (a y of
  ---   2^255 - 19 or more, or an x of 0 with the sign bit set) is read as
  ---   the point it reduces to; and a key of small order, in any of its
  ---   encodings, is refused, since under the neutral point the
  ---   signature of R neutral and S 0 would verify every message.
  --- - P-256 refuses a point off the curve and an R or S of 0 or n or
  ---   more. Both S and n - S verify, as ECDSA has it: a signature is not
  ---   unique to its message, so do not take one as an identifier of what
  ---   was signed.
  --- - RSA refuses a key of fewer than 2048 bits or more than 4096, and a
  ---   signature not as long as the modulus.
  ---
  ---     local ok = key.public:verify("message", signature)
  function verify(self, message: string, signature: string): boolean
    if self.alg == "ed25519" then return raw_sign.ed25519_verify(self.bytes, message, signature) end
    if self.alg == "p256" then return raw_sign.p256_verify(self.bytes, message, signature) end
    if self.alg == "rsa" then return raw_sign.rsa_verify(self.bytes, message, signature) end
    return false
  end

  --- The members of its JSON Web Key (RFC 7517) that RFC 7638 takes a
  --- thumbprint over, base64url: `crv`, `kty` and `x` for Ed25519 and
  --- X25519 (RFC 8037); `crv`, `kty`, `x` and `y` for P-256; `e`, `kty`
  --- and `n` for RSA.
  ---
  ---     local jwk = key.public:jwk()
  ---     assert(jwk["kty"] == "EC" and jwk["crv"] == "P-256")
  function jwk(self): {string: string}
    if self.alg == "ed25519" then
      return { crv = "Ed25519", kty = "OKP", x = Codec.base64url(self.bytes) }
    end
    if self.alg == "x25519" then
      return { crv = "X25519", kty = "OKP", x = Codec.base64url(self.bytes) }
    end
    if self.alg == "p256" then
      return {
        crv = "P-256",
        kty = "EC",
        x = Codec.base64url(self.bytes:sub(2, 33)),
        y = Codec.base64url(self.bytes:sub(34, 65)),
      }
    end
    local numbers = assert(rsa_numbers(self.bytes))
    return { e = Codec.base64url(numbers.e), kty = "RSA", n = Codec.base64url(numbers.n) }
  end

  --- The RFC 7638 thumbprint of its JWK: the base64url SHA-256 of
  --- [`jwk`]'s members in the order of their names, as JSON with no
  --- space. 43 characters.
  ---
  ---     assert(#key.public:thumbprint() == 43)
  function thumbprint(self): string
    local members: mut {string} = {}
    for name, value in pairs(self:jwk()) do
      members[#members + 1] = Json.quote(name) .. ":" .. Json.quote(value)
    end
    table.sort(members)
    return Codec.base64url(Hash.sha256("{" .. table.concat(members, ",") .. "}"))
  end

  --- Its DER SubjectPublicKeyInfo (RFC 5280, RFC 8410 for Ed25519 and
  --- X25519): the form a certificate and a certificate signing request
  --- name it in.
  function spki(self): string
    local algorithm =
      if self.alg == "ed25519" then Der.sequence(Der.oid(OID_ED25519))
        elseif self.alg == "x25519" then Der.sequence(Der.oid(OID_X25519))
        elseif self.alg == "p256" then Der.sequence(Der.oid(OID_EC_PUBLIC_KEY), Der.oid(OID_P256))
        else Der.sequence(Der.oid(OID_RSA_ENCRYPTION), Der.NULL) end
    return Der.sequence(algorithm, Der.bits(self.bytes))
  end

  --- Its algorithm and not its bytes: `Key.Public (p256)`.
  function __tostring(self): string
    return "Key.Public (" .. self.alg .. ")"
  end
end

--- A secret key: what [`Key.generate`], [`Key.read`] and [`Key.secret`]
--- answer.
local class Secret
  --- Its algorithm.
  alg: Alg
  --- Its public key.
  public: Public
  --- Internal: the secret's bytes, as [`Key.secret`] takes them. Read
  --- them through [`pem`].
  secret: string

  --- The signature of `message`, of any length: 64 bytes for Ed25519;
  --- for P-256, the ECDSA signature of the SHA-256 of `message` as R
  --- then S, 32 big-endian bytes each, the form JWS ES256 takes (RFC 7518
  --- section 3.4; a DER signature, as X.509 takes one, is the same two
  --- integers in an ASN.1 SEQUENCE); for RSA, the RSASSA-PKCS1-v1_5
  --- signature of its SHA-256 (RFC 8017 section 8.2), as many bytes as
  --- the modulus. Raises for an X25519 key, which signs nothing, and when
  --- the system's entropy source fails: mbedtls blinds its work on a
  --- P-256 or RSA secret with random values.
  ---
  ---     local signature = key:sign("message")
  function sign(self, message: string): string
    if self.alg == "ed25519" then return raw_sign.ed25519(self.secret, message) end
    if self.alg == "p256" then return raw_sign.p256(self.secret, message) end
    if self.alg == "rsa" then return raw_sign.rsa(self.secret, message) end
    error("key: an X25519 key signs nothing: it agrees on a secret with another", 2)
  end

  --- The 32-byte secret this X25519 key and `peer`, the other party's
  --- public key, share: the peer computes the same bytes from its own key
  --- and this key's public key, and nobody who saw only the public keys
  --- can. A Failure when `peer` is a point of low order, which makes the
  --- secret all zero bytes whatever this key is: a peer that sends one
  --- is choosing the secret, not agreeing on it. Raises unless both keys
  --- are X25519, and when the system's entropy source fails.
  ---
  --- The secret is not a key yet. Pass it through a key derivation
  --- ([`Hash.hkdf`]), together with both public keys, and use what that
  --- answers as [`Cipher.seal`]'s key. Public keys are not authenticated
  --- here: a party that must know who the peer is checks the peer's
  --- public key against one it already trusts.
  ---
  ---     local mine, theirs = Key.generate("x25519"), Key.generate("x25519")
  ---     assert(assert(mine:agree(theirs.public)) == assert(theirs:agree(mine.public)))
  function agree(self, peer: Public): (string) | (nil, Failure)
    if self.alg ~= "x25519" or peer.alg ~= "x25519" then
      error(("key: agree takes two X25519 keys, not %s and %s"):format(self.alg, peer.alg), 2)
    end
    local shared, why = raw_cipher.x25519(self.secret, peer.bytes)
    if shared == nil then return nil, Failure.new("key: " .. (why:gsub("^cipher: ", ""))) end
    return shared
  end

  --- The key as PEM, the form [`Key.read`] reads back and a web server
  --- reads a certificate's key in: "EC PRIVATE KEY" (SEC 1) for P-256,
  --- "RSA PRIVATE KEY" (PKCS #1) for RSA, "PRIVATE KEY" (PKCS #8, RFC
  --- 8410) for Ed25519 and X25519. It holds the secret.
  ---
  ---     assert(Fs.write("key.pem", key:pem(), tonumber("600", 8)))
  function pem(self): string
    if self.alg == "ed25519" or self.alg == "x25519" then
      local oid = if self.alg == "ed25519" then OID_ED25519 else OID_X25519 end
      return Der.pem("PRIVATE KEY", Der.sequence(Der.unsigned("\0"), Der.sequence(Der.oid(oid)),
        Der.element(0x04, Der.element(0x04, self.secret))))
    end
    if self.alg == "p256" then
      return Der.pem("EC PRIVATE KEY", Der.sequence(Der.unsigned("\1"), Der.element(0x04, self.secret),
        Der.element(0xa0, Der.oid(OID_P256)), Der.element(0xa1, Der.bits(self.public.bytes))))
    end
    return Der.pem("RSA PRIVATE KEY", self.secret)
  end

  --- Its algorithm and not its secret, so a key printed or logged by
  --- mistake shows nothing: `Key.Secret (p256)`.
  function __tostring(self): string
    return "Key.Secret (" .. self.alg .. ")"
  end
end

local record Key
  type Alg = Alg
  type Public = Public
  type Secret = Secret

  --- What [`Key.generate`] takes.
  record GenerateOptions
    --- The size of an RSA key: 2048 (the default), 3072 or 4096.
    bits?: integer
  end
end

--- A failure the raw modules raise, as `sign: why` or `cipher: why`, as
--- this module's.
local function refusal(raised: any): string
  local message = tostring(raised)
  return "key: " .. (message:match("sign: (.*)$") or message:match("cipher: (.*)$") or message)
end

--- The public bytes of the secret `secret` of `alg`, or nil and why it
--- is refused.
local function public_of(alg: Alg, secret: string): string?, string
  local ok, value = pcall(function(): string
    if alg == "ed25519" then return raw_sign.ed25519_public(secret) end
    if alg == "x25519" then return raw_cipher.x25519_public(secret) end
    if alg == "p256" then return raw_sign.p256_public(secret) end
    return raw_sign.rsa_public(secret)
  end)
  if not ok then return nil, refusal(value) end
  return value, ""
end

--- The key of the secret `secret`, whose public bytes are `public`.
local function make(alg: Alg, secret: string, public: string): Key.Secret
  local key: Secret = { alg = alg, secret = secret, public = { alg = alg, bytes = public } }
  return key
end

--- Raises unless `alg` is an algorithm of [`Key.Alg`].
local function check_alg(alg: Alg)
  if alg ~= "ed25519" and alg ~= "p256" and alg ~= "rsa" and alg ~= "x25519" then
    error(("key: the algorithm is \"ed25519\", \"p256\", \"rsa\" or \"x25519\", not %q"):format(tostring(alg)), 3)
  end
end

--- A new key of `alg`, drawn from the system's entropy. An RSA key is
--- of `opts.bits`, and drawing one takes a while, up to seconds for 4096
--- bits. Raises on an algorithm or bits not listed, and when the entropy
--- source fails.
---
---     local key = Key.generate("ed25519")
---     local big = Key.generate("rsa", { bits = 4096 })
function Key.generate(alg: Key.Alg, opts?: Key.GenerateOptions): Key.Secret
  check_alg(alg)
  local bits = if opts == nil then nil else opts.bits end
  if bits ~= nil and alg ~= "rsa" then
    error(("key: bits is the size of an RSA key, not of a %s key"):format(alg), 2)
  end
  local secret: string
  if alg == "ed25519" or alg == "x25519" then
    -- Any 32 bytes are a key of either: X25519 clamps its scalar (RFC
    -- 7748 section 5), and an Ed25519 seed is hashed.
    secret = assert(Rand.entropy(32))
  elseif alg == "p256" then
    -- A scalar from 1 to n - 1: 32 bytes of entropy fall outside that
    -- range about once in 2^32.
    secret = raw_sign.p256_secret()
  else
    local ok, drawn = pcall(raw_sign.rsa_secret, bits)
    if not ok then error(refusal(drawn), 2) end
    secret = drawn
  end
  return make(alg, secret, (assert(public_of(alg, secret))))
end

--- The key of `alg` over `bytes`, its secret: a 32-byte Ed25519 seed
--- (RFC 8032's private key), 32 bytes of X25519 (RFC 7748), a 32-byte
--- big-endian P-256 scalar from 1 to n - 1, or a DER RSAPrivateKey (PKCS
--- #1, the form `openssl genrsa -traditional` writes) of 2048 to 4096
--- bits. Any 32 bytes are an X25519 key: RFC 7748 clamps the bits it
--- does not use. A Failure where the bytes are none of these, or when
--- the system's entropy source fails: mbedtls blinds its work on a
--- P-256 or RSA secret with random values. Raises on an algorithm not
--- listed.
---
---     local key = assert(Key.secret("ed25519", (assert(Rand.entropy(32)))))
function Key.secret(alg: Key.Alg, bytes: string): (Key.Secret) | (nil, Failure)
  check_alg(alg)
  local public, why = public_of(alg, bytes)
  if public == nil then return nil, Failure.new(why) end
  return make(alg, bytes, public)
end

--- The public key of `alg` over `bytes`, which may come from anyone, as
--- [`Public.bytes`] says: 32 bytes for Ed25519 and X25519, a 65-byte
--- point that starts with 0x04 for P-256, a DER RSAPublicKey for RSA. A Failure on
--- bytes of another size or shape. A P-256 point off the curve, or an
--- RSA modulus of the wrong size, is read here and refused by
--- [`Public.verify`]. Raises on an algorithm not listed.
---
---     local public = assert(Key.public("ed25519", bytes))
function Key.public(alg: Key.Alg, bytes: string): (Key.Public) | (nil, Failure)
  check_alg(alg)
  if (alg == "ed25519" or alg == "x25519") and #bytes ~= 32 then
    local name = if alg == "ed25519" then "Ed25519" else "X25519" end
    return nil, Failure.new(("key: an %s public key is 32 bytes, not %d"):format(name, #bytes))
  end
  if alg == "p256" and (#bytes ~= 65 or bytes:byte(1) ~= 0x04) then
    return nil, Failure.new("key: a P-256 public key is 65 bytes that start with 0x04")
  end
  if alg == "rsa" and rsa_numbers(bytes) == nil then
    return nil, Failure.new("key: an RSA public key is a DER RSAPublicKey: a SEQUENCE of n and e")
  end
  local key: Public = { alg = alg, bytes = bytes }
  return key
end

--- The key of the secret `secret` of `alg`, or nil and why.
local function secret_of(alg: Alg, secret: string): Key.Secret?, string
  local public, why = public_of(alg, secret)
  if public == nil then return nil, why end
  return make(alg, secret, public), ""
end

--- The P-256 secret of the DER ECPrivateKey `der_bytes` (SEC 1 section
--- C.4) whose curve, where it or `curve` names one, is P-256, or nil and
--- why.
local function sec1_secret(der_bytes: string, curve?: string): string?, string
  local parts = Der.sequence_of(der_bytes)
  local version = if parts == nil then nil else parts[1] end
  local secret = if parts == nil then nil else parts[2] end
  if parts == nil or version == nil or version.tag ~= 0x02 or version.content ~= "\1" or
      secret == nil or secret.tag ~= 0x04 or #secret.content == 0 then
    return nil, "key: not an EC private key: no SEC 1 ECPrivateKey"
  end
  local named = curve
  for i = 3, #parts do
    local part = assert(parts[i])
    if part.tag == 0xa0 then named = part.content end
  end
  if named ~= nil and named ~= Der.oid(OID_P256) then
    return nil, "key: an EC key is on P-256, not another curve"
  end
  if #secret.content > 32 then return nil, "key: a P-256 secret is 32 bytes at most" end
  return string.rep("\0", 32 - #secret.content) .. secret.content, ""
end

--- The key of the DER PrivateKeyInfo `der_bytes` (RFC 5208), Ed25519,
--- P-256 or RSA, or nil and why.
local function pkcs8_key(der_bytes: string): Key.Secret?, string
  local parts = Der.sequence_of(der_bytes)
  local version = if parts == nil then nil else parts[1] end
  local algorithm = if parts == nil then nil else parts[2] end
  local inner = if parts == nil then nil else parts[3] end
  if version == nil or version.tag ~= 0x02 or (version.content ~= "\0" and version.content ~= "\1") or
      algorithm == nil or algorithm.tag ~= 0x30 or
      inner == nil or inner.tag ~= 0x04 then
    return nil, "key: not a private key: no PKCS #8 PrivateKeyInfo"
  end
  local identifiers = Der.elements(algorithm.content)
  local oid = if identifiers == nil then nil else identifiers[1] end
  local parameters = if identifiers == nil then nil else identifiers[2] end
  local oid_der = if oid == nil then "" else Der.element(oid.tag, oid.content) end
  if oid_der == Der.oid(OID_RSA_ENCRYPTION) then return secret_of("rsa", inner.content) end
  if oid_der == Der.oid(OID_EC_PUBLIC_KEY) then
    local curve = if parameters == nil then nil else Der.element(parameters.tag, parameters.content) end
    local secret, why = sec1_secret(inner.content, curve)
    if secret == nil then return nil, why end
    return secret_of("p256", secret)
  end
  if oid_der == Der.oid(OID_ED25519) or oid_der == Der.oid(OID_X25519) then
    local alg: Alg = if oid_der == Der.oid(OID_ED25519) then "ed25519" else "x25519" end
    -- RFC 8410's CurvePrivateKey: the secret, an OCTET STRING inside the
    -- PrivateKeyInfo's own.
    local seed = Der.read(inner.content, 1)
    if seed == nil or seed.tag ~= 0x04 or seed.after ~= #inner.content + 1 then
      return nil, ("key: an %s private key is an OCTET STRING of its secret"):format(alg)
    end
    return secret_of(alg, seed.content)
  end
  return nil, "key: a private key is Ed25519, X25519, P-256 or RSA, not another algorithm"
end

--- The labels of the PEM blocks [`Key.read`] reads.
local KEY_LABELS <const>: {string: boolean} = {
  ["EC PRIVATE KEY"] = true, ["RSA PRIVATE KEY"] = true, ["PRIVATE KEY"] = true,
}

--- The key of the PEM `text`, or nil and why.
local function read_text(text: string): Key.Secret?, string
  for label, body in text:gmatch("%-%-%-%-%-BEGIN ([%u ]+)%-%-%-%-%-(.-)%-%-%-%-%-END %1%-%-%-%-%-") do
    if label == "ENCRYPTED PRIVATE KEY" then
      return nil, "key: the key is encrypted: decrypt it first"
    end
    if KEY_LABELS[label] == true then
      if body:find("Proc-Type:", 1, true) ~= nil then
        return nil, "key: the key is encrypted: decrypt it first"
      end
      local der_bytes, undecoded = Codec.unbase64((body:gsub("%s", "")))
      if der_bytes == nil then
        return nil, "key: the " .. label .. " block is not base64: " .. undecoded
      end
      if label == "PRIVATE KEY" then return pkcs8_key(der_bytes) end
      if label == "RSA PRIVATE KEY" then return secret_of("rsa", der_bytes) end
      local secret, why = sec1_secret(der_bytes)
      if secret == nil then return nil, why end
      return secret_of("p256", secret)
    end
  end
  return nil, "key: no private key in the text: no EC, RSA or PKCS #8 PRIVATE KEY block"
end

--- The key in the PEM `text`, as [`Secret.pem`] writes it or as
--- OpenSSL does: "EC PRIVATE KEY" (SEC 1) on P-256, "RSA PRIVATE KEY"
--- (PKCS #1), or "PRIVATE KEY" (PKCS #8) holding any of the four. Text
--- around the block is skipped, an "EC PARAMETERS" block in front
--- included; the first key block decides. A Failure for text with no
--- such block, a block whose base64 or DER is broken, a key on another
--- curve or of another algorithm, a P-256 secret out of range, or an
--- RSA key of fewer than 2048 bits or more than 4096. An encrypted key
--- ("ENCRYPTED PRIVATE KEY", or a block with a `Proc-Type` header) is
--- not read: decrypt it first (`openssl pkey -in key.pem -out
--- plain.pem`).
---
---     local key = assert(Key.read(assert(Fs.read("account.pem"))))
function Key.read(text: string): (Key.Secret) | (nil, Failure)
  local key, why = read_text(text)
  if key == nil then return nil, Failure.new(why) end
  return key
end

return Key
