--- Worked examples for [`cosmic.srp`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Hash = require("cosmic.hash")
local Rand = require("cosmic.rand")
local Srp = require("cosmic.srp")

local record Example end

local parameters: Srp.Parameters = { group = Srp.group_3072, hash = "sha512", rules = "rfc5054" }

--- Setting a password: the server draws a salt and keeps it with the
--- verifier, and never sees the password again. The verifier is a
--- number at the width of the group's prime.
function Example.verifier()
  local salt = assert(Rand.entropy(16))
  local verifier = Srp.verifier(parameters, "alice", "password123", salt)
  print(#verifier)
  assert(#verifier == #Srp.group_3072.prime)
  assert(verifier == Srp.verifier(parameters, "alice", "password123", salt))
  assert(verifier ~= Srp.verifier(parameters, "alice", "password124", salt))
end

--- A login, message by message. The two sides end with one key, which
--- neither sent, and each has seen the other prove it.
function Example.client()
  local salt = assert(Rand.entropy(16))
  local verifier = Srp.verifier(parameters, "alice", "password123", salt)

  -- 1. The client sends its identity and its public value.
  local client = Srp.client(parameters, "alice", "password123")
  -- 2. The server looks the identity up, and sends its salt and a public value.
  local server = Srp.server(parameters, "alice", salt, verifier)
  -- 3. The client sends its proof.
  local login = assert(client:prove(salt, server.public))
  -- 4. The server checks it, and sends its own.
  local accepted = assert(server:verify(client.public, login.proof))
  local genuine = client:verify(accepted.proof)

  print(genuine, Hash.equal(login.key, accepted.key), #login.key)
  assert(genuine and login.key == accepted.key)
end

--- A wrong password. The server learns only that the proof is wrong,
--- and answers with nothing the client could try other passwords
--- against. The next attempt gets a new server side.
function Example.server()
  local salt = assert(Rand.entropy(16))
  local verifier = Srp.verifier(parameters, "alice", "password123", salt)

  local server = Srp.server(parameters, "alice", salt, verifier)
  local client = Srp.client(parameters, "alice", "password124")
  local login = assert(client:prove(salt, server.public))
  local accepted, why = server:verify(client.public, login.proof)
  print(accepted, why)
  assert(accepted == nil)

  local again = Srp.server(parameters, "alice", salt, verifier)
  local retry = Srp.client(parameters, "alice", "password123")
  assert(again:verify(retry.public, assert(retry:prove(salt, again.public)).proof))
end

--- The parameters are an agreement: a client under one hash or rule
--- set is, to a server under another, a client with the wrong password. The two rule sets part only where a digest leads with a
--- zero byte, as the SHA-256 of this identity does, so a mismatch can
--- pass every other test.
function Example.Rules()
  local rfc: Srp.Parameters = { group = Srp.group_2048, hash = "sha256", rules = "rfc5054" }
  local srptools: Srp.Parameters = { ...rfc, rules = "srptools" }
  local identity = "user159"
  assert(Hash.digest("sha256", identity):byte(1) == 0)
  local salt = assert(Rand.entropy(16))
  local verifier = Srp.verifier(rfc, identity, "password123", salt)
  assert(verifier == Srp.verifier(srptools, identity, "password123", salt))

  local server = Srp.server(rfc, identity, salt, verifier)
  local client = Srp.client(srptools, identity, "password123")
  local accepted, why = server:verify(client.public, assert(client:prove(salt, server.public)).proof)
  print(accepted, why)
  assert(accepted == nil)

  local matching = Srp.client(rfc, identity, "password123")
  assert(server:verify(matching.public, assert(matching:prove(salt, server.public)).proof))
end

--- A hash [`cosmic.hash`] has no name for, given as a function: here
--- SHA-256 of SHA-256. Both sides pass the same function.
function Example.Digest()
  local function twice(data: string): string
    return Hash.sha256(Hash.sha256(data))
  end
  local doubled: Srp.Parameters = { group = Srp.group_2048, hash = twice, rules = "rfc5054" }
  local salt = assert(Rand.entropy(16))
  local server = Srp.server(doubled, "alice", salt, Srp.verifier(doubled, "alice", "password123", salt))
  local client = Srp.client(doubled, "alice", "password123")
  local login = assert(client:prove(salt, server.public))
  local accepted = assert(server:verify(client.public, login.proof))
  print(#login.key, client:verify(accepted.proof))
  assert(login.key == accepted.key)
end

--- The seven groups of RFC 5054. A wider prime costs an attacker who
--- holds a verifier more, and each login more time: a public value is
--- as many bytes as the prime, and both sides raise numbers of that
--- width to a power.
function Example.Group()
  local groups: {Srp.Group} = {
    Srp.group_1024, Srp.group_1536, Srp.group_2048, Srp.group_3072, Srp.group_4096, Srp.group_6144, Srp.group_8192,
  }
  for _, group in ipairs(groups) do
    local client = Srp.client({ group = group, hash = "sha256", rules = "rfc5054" }, "alice", "password123")
    print(#group.prime * 8, group.generator:byte(), #client.public)
    assert(#client.public == #group.prime)
  end
end

return Example
