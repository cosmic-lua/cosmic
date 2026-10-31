--- cosmic.http's TLS stack reads a certificate's basicConstraints
--- strictly: a `SEQUENCE { INTEGER n }` there is refused rather than read
--- as cA = (n != 0), which mbedtls 4.1.0 and before did (CVE-2026-49300),
--- so a certificate another X.509 implementation reads as an end entity
--- is never taken for a CA.

local Codec = require("cosmic.codec")
local Http = require("cosmic.http")

--- A DER element: `tag`, the length of `body`, then `body`.
local function der(tag: integer, body: string): string
  local n = #body
  local length: string
  if n < 128 then
    length = string.char(n)
  else
    assert(n < 65536)
    length = "\x82" .. string.pack(">I2", n)
  end
  return string.char(tag) .. length .. body
end

--- The SubjectPublicKeyInfo of a P-256 key (nobody holds the private
--- half of this one; reading a certificate checks no signature).
local KEY <const> = assert(Codec.unhex(
  "3059301306072a8648ce3d020106082a8648ce3d0301070342000449cf490741561655d5ae7fa7ca1110739" ..
    "c168f17b8dd1e0c6118c35f31040aba1e351c18ec838368915d47282d5b2e3a04da0d9551dd5c0968c35984" ..
    "53026e8d"))

--- A v3 certificate for the name "t" whose only extension is
--- basicConstraints holding `value`, and a signature that is no
--- signature at all.
local function certificate(value: string): string
  local ecdsa_sha256 = der(0x30, "\x06\x08\x2a\x86\x48\xce\x3d\x04\x03\x02")
  local name = der(0x30, der(0x31, der(0x30, "\x06\x03\x55\x04\x03" .. der(0x0c, "t"))))
  local validity = der(0x30, der(0x17, "250101000000Z") .. der(0x17, "350101000000Z"))
  local basic_constraints = der(0x30, "\x06\x03\x55\x1d\x13" .. "\x01\x01\xff" .. der(0x04, value))
  local tbs = der(0x30,
    der(0xa0, der(0x02, "\2")) ..
      der(0x02, "\1") ..
      ecdsa_sha256 .. name .. validity .. name .. KEY ..
      der(0xa3, der(0x30, basic_constraints)))
  return der(0x30, tbs .. ecdsa_sha256 .. der(0x03, "\0" .. der(0x30, der(0x02, "\1") .. der(0x02, "\1"))))
end

--- A basicConstraints of `cA TRUE` is read; one of `SEQUENCE { INTEGER 1 }`
--- (RFC 5280's pathLenConstraint with no cA, which mbedtls 4.1.0 read as
--- cA TRUE), `INTEGER 0`, an empty SEQUENCE followed by a `cA TRUE` it
--- does not hold (which 4.1.0 also read as cA TRUE), and one with bytes
--- after its SEQUENCE are not.
local function test_a_basic_constraints_that_starts_with_an_integer_is_refused()
  local ok, why = Http.check_certificate(certificate("\x30\x03\x01\x01\xff"))
  assert(ok and why == "", "the control certificate is unreadable: " .. tostring(why))
  ok, why = Http.check_certificate(certificate("\x30\x00"))
  assert(ok and why == "", "an empty basicConstraints is unreadable: " .. tostring(why))
  local refused: {string: string} = {
    ["INTEGER 1"] = "\x30\x03\x02\x01\x01",
    ["INTEGER 0"] = "\x30\x03\x02\x01\x00",
    ["INTEGER 1 then a path length"] = "\x30\x06\x02\x01\x01\x02\x01\x00",
    ["cA TRUE after an empty SEQUENCE"] = "\x30\x00\x01\x01\xff",
    ["bytes after the SEQUENCE"] = "\x30\x03\x01\x01\xff\x05\x00",
  }
  for label, value in pairs(refused) do
    ok, why = Http.check_certificate(certificate(value))
    assert(not ok and why ~= "", label .. " is read as a certificate")
  end
end
