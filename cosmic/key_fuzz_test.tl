--- Fuzz properties for [`cosmic.key`]: what a seed signs verifies under
--- its public key, and an Ed25519 key's verify is total and exact -- it
--- handles whatever bytes it is handed, never raises, and takes a
--- key, message and signature only as they were signed. `FUZZ_SEED` and
--- `FUZZ_ITERS` pick the inputs (cosmic/fuzz.tl).

local Fuzz = require("cosmic.fuzz")
local Key = require("cosmic.key")

--- The operations of each signing algorithm on bytes, through
--- [`cosmic.key`]: the shape the vectors are written in. A secret that
--- [`Key.secret`] refuses raises its Failure; a public key that
--- [`Key.public`] refuses verifies nothing.
local record Sign
end

local function secret_key(alg: Key.Alg, bytes: string): Key.Secret
  return assert(Key.secret(alg, bytes))
end

local function verify(alg: Key.Alg, public: string, message: string, signature: string): boolean
  local key, _ = Key.public(alg, public)
  return key ~= nil and key:verify(message, signature)
end

function Sign.ed25519_public(seed: string): string
  return secret_key("ed25519", seed).public.bytes
end
function Sign.ed25519(seed: string, message: string): string
  return secret_key("ed25519", seed):sign(message)
end
function Sign.ed25519_verify(public: string, message: string, signature: string): boolean
  return verify("ed25519", public, message, signature)
end
function Sign.p256_secret(): string return Key.generate("p256").secret end
function Sign.p256_public(s: string): string return secret_key("p256", s).public.bytes end
function Sign.p256(s: string, message: string): string
  return secret_key("p256", s):sign(message)
end
function Sign.p256_verify(public: string, message: string, signature: string): boolean
  return verify("p256", public, message, signature)
end
function Sign.rsa_secret(bits?: integer): string
  return Key.generate("rsa", { bits = bits }).secret
end
function Sign.rsa_public(s: string): string return secret_key("rsa", s).public.bytes end
function Sign.rsa(s: string, message: string): string return secret_key("rsa", s):sign(message) end
function Sign.rsa_verify(public: string, message: string, signature: string): boolean
  return verify("rsa", public, message, signature)
end

local seed <const> = string.rep("s", 32)
local message <const> = "the message that was signed"
--- A key, the signature under it and the message, as one input.
local signed <const> = Sign.ed25519_public(seed) .. Sign.ed25519(seed, message) .. message

local function fuzz_what_a_seed_signs_verifies(): Fuzz.Target
  return Fuzz.target({
    name = "sign then verify",
    gen = function(src: Fuzz.Source): string
      local drawn: mut {string} = {}
      for i = 1, 32 do drawn[i] = string.char(src:int(0, 255)) end
      return table.concat(drawn) .. Fuzz.bytes(src, 300)
    end,
    check = function(input: string): boolean, string
      local secret, text = input:sub(1, 32), input:sub(33)
      local public, signature = Sign.ed25519_public(secret), Sign.ed25519(secret, text)
      if #public ~= 32 or #signature ~= 64 then
        return false, "a key or signature of the wrong length"
      end
      if not Sign.ed25519_verify(public, text, signature) then
        return false, "its own signature is refused"
      end
      if Sign.ed25519_verify(public, text .. "\0", signature) then
        return false, "a longer message is taken"
      end
      return true, ""
    end,
  })
end

local function fuzz_verify_is_total_and_takes_only_what_was_signed(): Fuzz.Target
  return Fuzz.target({
    name = "verify a changed key, signature or message",
    requires = { "changed", "short" },
    gen = function(src: Fuzz.Source): string
      if src:int(0, 7) == 0 then return Fuzz.bytes(src, 200) end
      return Fuzz.mutate(src, signed, 4)
    end,
    check = function(input: string): boolean, string
      if #input < 96 then Fuzz.label("short") end
      if input ~= signed then Fuzz.label("changed") end
      local verified = Sign.ed25519_verify(input:sub(1, 32), input:sub(97), input:sub(33, 96))
      if verified ~= (input == signed) then
        return false, "verify answered " .. tostring(verified)
      end
      return true, ""
    end,
  })
end
