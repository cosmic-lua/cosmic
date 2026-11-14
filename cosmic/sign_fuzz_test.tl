--- Fuzz properties for [`cosmic.sign`]: what a seed signs verifies under
--- its public key, and [`Sign.ed25519_verify`] is total and exact -- it
--- answers for whatever bytes it is handed, never raises, and takes a
--- key, message and signature only as they were signed. `FUZZ_SEED` and
--- `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Sign = require("cosmic.sign")

local seed <const> = string.rep("s", 32)
local message <const> = "the message that was signed"
--- A key, the signature under it and the message, as one input.
local signed <const> = Sign.ed25519_public(seed) .. Sign.ed25519(seed, message) .. message

local function test_what_a_seed_signs_verifies(tmp: string)
  Fuzz.run({
    name = "sign then verify",
    dir = tmp,
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

local function test_verify_is_total_and_takes_only_what_was_signed(tmp: string)
  Fuzz.run({
    name = "verify a changed key, signature or message",
    dir = tmp,
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
