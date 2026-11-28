--- Fuzz properties for [`cosmic.jose`]: [`Jose.verify_jwt`] and
--- [`Jose.key`] are total, handling whatever text they are handed
--- and never raising, and a token is taken only as it was signed.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (cosmic/fuzz.tl).

local Fuzz = require("cosmic.fuzz")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local Key = require("cosmic.key")

local signer <const> = Key.generate("p256")
local signed <const> = Jose.sign(signer, { iss = "i", aud = "a", sub = "s", exp = 2000000000 }, { kid = "k" })
local published <const> = Jose.jwk(signer.public, "k")
local keys <const> = { assert(Jose.key(published)) }
local OPTS: Jose.JwtOptions = { issuer = "i", audience = "a", now = 1700000000 }

local function fuzz_verify_is_total_and_takes_only_what_was_signed(): Fuzz.Target
  return Fuzz.target({
    name = "verify a changed token",
    requires = { "changed" },
    gen = function(src: Fuzz.Source): string
      if src:int(0, 7) == 0 then return Fuzz.bytes(src, 300) end
      return Fuzz.mutate(src, signed, 4)
    end,
    check = function(input: string): boolean, string
      if input ~= signed then Fuzz.label("changed") end
      local claims, _ = Jose.verify_jwt(input, keys, OPTS)
      if (claims ~= nil) ~= (input == signed) then
        return false, "verify_jwt answered " .. tostring(claims ~= nil)
      end
      return true, ""
    end,
  })
end

local function fuzz_key_is_total(): Fuzz.Target
  local jwk <const> = assert(Json.encode(published))
  return Fuzz.target({
    name = "read a changed JWK",
    gen = function(src: Fuzz.Source): string
      return Fuzz.mutate(src, jwk, 4)
    end,
    check = function(input: string): boolean, string
      local object, _ = Json.decode_object(input)
      if object ~= nil then
        local key, why = Jose.key(object)
        if key == nil and tostring(why) == "" then return false, "a refusal with no reason" end
      end
      return true, ""
    end,
  })
end
