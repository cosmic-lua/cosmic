--- Mozilla's OneCRL changeset as the rows of `ca_revoked`
--- ([`build.onecrl`]), and the tree's own snapshot of it.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local onecrl = require("build.onecrl")
local schema = require("build.schema")

--- The tree's snapshot.
Test.policy{ grants = { { path = "vendor/onecrl/onecrl.json", letters = "r" } } }

--- An empty database of the shipped shape.
local function database(): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  return db
end

--- A changeset holding `changes`, each a JSON object's text, as the feed
--- writes one.
local function changeset(changes: {string}): string
  return '{"metadata":{"sort":"-last_modified","bucket":"security-state"},"timestamp":1792622041776,' ..
    '"changes":[' .. table.concat(changes, ",") .. ']}'
end

--- Base64 of `text`.
local function b64(text: string): string
  return Codec.base64(text)
end

--- A change by issuer and serial number, by subject and key, and one
--- disabled: the first two revoke, as their decoded bytes, and the last
--- nothing; the timestamp is the state's.
local function test_a_changeset_gives_what_it_revokes()
  local hash = string.rep("\7", 32)
  local text = changeset({
    '{"id":"a","enabled":true,"issuerName":"' .. b64("an issuer") .. '","serialNumber":"' .. b64("\0\1") .. '"}',
    '{"id":"b","subject":"' .. b64("a subject") .. '","pubKeyHash":"' .. b64(hash) .. '","enabled":true}',
    '{"id":"c","enabled":false,"issuerName":"' .. b64("gone") .. '","serialNumber":"' .. b64("\2") .. '"}',
  })
  local found = assert(onecrl.parse(text))
  assert(#found == 2, tostring(#found))
  local serial, key = assert(found[1]), assert(found[2])
  assert(serial.kind == "serial" and serial.name == "an issuer" and serial.value == "\0\1")
  assert(key.kind == "key" and key.name == "a subject" and key.value == hash)
  assert(onecrl.timestamp(text) == "1792622041776")
end

--- A change that names neither pair whole, or a key hash that is not a
--- SHA-256, or text that is no changeset, is refused, saying why.
local function test_a_changeset_it_cannot_mean_is_refused()
  local cases: {string:string} = {
    [changeset({ '{"issuerName":"' .. b64("x") .. '"}' })] = "change 1 names neither",
    [changeset({ '{"subject":"' .. b64("x") .. '","pubKeyHash":"' .. b64("short") .. '"}' })] = "change 1 names neither",
    ["[]"] = "not a OneCRL changeset",
    -- a field of another kind is refused, not read as missing: the feed would otherwise revoke less without a word
    [changeset({ '{"issuerName":5,"serialNumber":"AA=="}' })] = "$.changes[0].issuerName: want string, got integer",
    [changeset({ '{"enabled":"false","issuerName":"AA==","serialNumber":"AA=="}' })] =
      "$.changes[0].enabled: want boolean, got string",
    [changeset({ '5' })] = "$.changes[0]: json: expected a JSON object, got number",
  }
  for text, want in pairs(cases) do
    local found, why = onecrl.parse(text)
    assert(found == nil and why:find(want, 1, true) ~= nil, want .. ": " .. tostring(why))
  end
end

--- Each distinct entry is one row, in the order of its bytes, so the same
--- entries make the same table.
local function test_entries_become_rows_once_each_in_order()
  local db = database()
  assert(onecrl.put(db, "", {
    { kind = "serial", name = "b", value = "\1" },
    { kind = "key", name = "a", value = string.rep("\7", 32) },
    { kind = "serial", name = "b", value = "\1" },
  }))
  local rows = assert(Sqlite.text_rows(db, "SELECT kind, hex(name), hex(value) FROM ca_revoked ORDER BY rowid"))
  assert(db:close())
  assert(#rows == 2, tostring(#rows))
  assert(assert(rows[1]):text(1) == "key" and assert(rows[2]):text(1) == "serial")
end

--- The tree's snapshot revokes EM DV TLS CA - G3B, the eMudhra
--- intermediate whose misissuance had Mozilla remove the emSign roots in
--- 2026, by its subject and key: every copy, the one Comodo's AAA
--- Certificate Services cross-signed too.
local function test_the_snapshot_revokes_the_emsign_intermediate()
  local text = assert(Fs.read("vendor/onecrl/onecrl.json"))
  local found = assert(onecrl.parse(text))
  assert(#found > 1000, tostring(#found))
  local subject = assert(Codec.unbase64(
    "MD8xCzAJBgNVBAYTAk5MMRMwEQYDVQQKDAplTXVkaHJhIEJWMRswGQYDVQQDDBJFTSBEViBUTFMgQ0EgLSBHM0I="))
  local hash = assert(Codec.unbase64("6+1kdcLC2A/LGZ8/6N1uazzmC3frFdTkLD3sDG9bUQU="))
  local met = false
  for _, one in ipairs(found) do
    if one.kind == "key" and one.name == subject and one.value == hash then
      met = true
    end
  end
  assert(met, "G3B is not among what the snapshot revokes")
end
