--- Proves which strings [`Srp.server`] takes as a verifier, at each
--- length a verifier can be written in: the check reads a secret, so it
--- goes by another path than a public value's does.

local Bigint = require("cosmic.bigint")
local Srp = require("cosmic.srp")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

local parameters: Srp.Parameters = { group = Srp.group_1024, hash = "sha256", rules = "rfc5054" }
local prime = Srp.group_1024.prime
local secret = string.rep("b", 32)

--- The public value of a server holding `verifier`.
local function public_of(verifier: string): string
  return Srp.server(parameters, "alice", "salt", verifier, secret).public
end

local function test_a_verifier_is_the_same_number_at_every_length()
  local verifier = Srp.verifier(parameters, "alice", "password123", "salt")
  local expected = public_of(verifier)
  for _, zeros in ipairs{ 1, 5, 3000, 5000 } do
    assert(public_of(string.rep("\0", zeros) .. verifier) == expected, tostring(zeros))
  end
  -- A small verifier, shorter than the prime and longer than it.
  local small = public_of("\7")
  assert(small ~= expected)
  assert(public_of("\0\0\7") == small)
  assert(public_of(string.rep("\0", #prime + 3) .. "\7") == small)
end

local function test_the_largest_verifier_is_the_prime_less_one()
  local last = assert(Bigint.sub(prime, "\1"))
  assert(#public_of(last) == #prime)
  assert(public_of(string.rep("\0", 9) .. last) == public_of(last))
end

local function test_a_long_string_that_is_no_verifier_raises()
  local refused = "the verifier is not from 1 to the prime less 1"
  local verifier = Srp.verifier(parameters, "alice", "password123", "salt")
  Test.raises(function() public_of("\1" .. verifier) end, refused)
  Test.raises(function() public_of("\1" .. string.rep("\0", 3000) .. verifier) end, refused)
  Test.raises(function() public_of(string.rep("\0", 3000) .. prime) end, refused)
  Test.raises(function() public_of(string.rep("\0", 3000)) end, refused)
  Test.raises(function() public_of(string.rep("\0", #prime)) end, refused)
  Test.raises(function() public_of(Bigint.add(prime, "\1")) end, refused)
end
