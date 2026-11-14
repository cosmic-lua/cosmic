--- Fuzz properties for [`cosmic.bigint`]: the functions for secrets
--- compute what the plain ones do, at the widths their arguments fix,
--- for drawn operands and moduli of every length that crosses a limb.
--- They prove the numbers and nothing of the time taken, which no test
--- measures. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Bigint = require("cosmic.bigint")
local Fuzz = require("build.fuzz")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

--- The most bytes of a drawn modulus, and of a drawn operand: four
--- limbs, and operands up to twice that.
local modulus_most <const> = 32
local operand_most <const> = 64

--- A number of at most `most` bytes, one time in four all 0xff or all
--- zero bytes, where a carry runs the whole length or nothing is added.
local function operand(src: Fuzz.Source, most: integer): string
  local kind = src:int(0, 7)
  if kind == 0 then return string.rep("\255", src:int(0, most)) end
  if kind == 1 then return string.rep("\0", src:int(0, most)) end
  return Fuzz.bytes(src, most)
end

--- `number` in exactly `width` bytes.
local function wide(number: string, width: integer): string
  return (assert(Bigint.pad(number, width)))
end

local function test_arithmetic_for_secrets_agrees_with_the_plain_functions(tmp: string)
  Fuzz.run({
    name = "bigint secrets agree",
    dir = tmp,
    requires = { "odd modulus", "even modulus", "operand above the modulus", "wrapped difference" },
    -- A modulus and two operands, each behind a byte of its length.
    gen = function(src: Fuzz.Source): string
      local parts: mut {string} = {}
      for _, most in ipairs{ modulus_most, operand_most, operand_most } do
        local part = operand(src, most)
        parts[#parts + 1] = string.char(#part) .. part
      end
      return table.concat(parts)
    end,
    check = function(input: string): boolean, string
      local parts: mut {string} = {}
      local at = 1
      for i = 1, 3 do
        local length = input:byte(at)
        if length == nil then return true, "" end
        parts[i] = input:sub(at + 1, at + length)
        at = at + 1 + length
      end
      local modulus, a, b = assert(parts[1]), assert(parts[2]), assert(parts[3])
      local product, sum = Bigint.product(a, b), Bigint.sum(a, b)
      if product ~= wide(Bigint.mul(a, b), #a + #b) then
        return false, "product is not mul's number"
      end
      if sum ~= wide(Bigint.add(a, b), math.max(#a, #b) + 1) then
        return false, "sum is not add's number"
      end
      if Bigint.compare(modulus, "") == 0 then return true, "" end
      local width = #modulus
      if Bigint.compare(a, modulus) >= 0 then Fuzz.label("operand above the modulus") end
      if Bigint.reduce(a, modulus) ~= wide(Bigint.mod(a, modulus), width) then
        return false, "reduce is not mod's number"
      end
      if Bigint.addmod(a, b, modulus) ~= wide(Bigint.mod(Bigint.add(a, b), modulus), width) then
        return false, "addmod is not the sum reduced"
      end
      local left, right = Bigint.mod(a, modulus), Bigint.mod(b, modulus)
      if Bigint.compare(left, right) < 0 then Fuzz.label("wrapped difference") end
      local difference = Bigint.mod(assert(Bigint.sub(Bigint.add(left, modulus), right)), modulus)
      if Bigint.submod(a, b, modulus) ~= wide(difference, width) then
        return false, "submod is not the difference reduced"
      end
      if assert(modulus:byte(-1)) % 2 == 0 then
        Fuzz.label("even modulus")
        return true, ""
      end
      Fuzz.label("odd modulus")
      if Bigint.mulmod(a, b, modulus) ~= wide(Bigint.mod(Bigint.mul(a, b), modulus), width) then
        return false, "mulmod is not the product reduced"
      end
      return true, ""
    end,
  })
end
