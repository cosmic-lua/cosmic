--- The certificates Mozilla revokes by OneCRL
--- ([`vendor/onecrl/onecrl.json`], a snapshot of its remote settings
--- feed): intermediates of CAs it still trusts, named by issuer and
--- serial number, or by subject and public key so that every certificate
--- of one name and key -- a cross-signed copy too -- is caught. One row
--- each in the shipped `ca_revoked` table, which [`core/http.c`] reads
--- as it verifies a chain and refuses one holding any of them.
---
--- The writer fills the table in cosmic's own projection alone, as it
--- does the CA roots ([`build.roots`]); `carried` copies it into the tool
--- and `cosmic build` into every executable.
---
--- A binary refuses what the snapshot it was built from names: `cosmic
--- refresh` writes a copy of that binary, or of cosmic itself, holding
--- the feed's newest state, as it does Mozilla's newest roots. The
--- snapshot here moves when `bin/vendor onecrl` takes the feed's newest
--- into vendor/onecrl, for a pull request.
---
--- TODO: verify a changeset's content signature (its `metadata`'s
--- `signature`, under Mozilla's content-signing root) before reading it,
--- once cosmic can verify a P-384 ECDSA signature and a chain to that
--- root; until then a snapshot, vendored or refreshed, is trusted as the
--- TLS connection it came over.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local bind = require("build.bind")

local record onecrl
  --- One certificate OneCRL revokes.
  record Entry
    --- "serial": `name` is its issuer's DER Name and `value` its serial
    --- number's bytes, as the certificate encodes them. "key": `name` is
    --- its subject's DER Name and `value` the SHA-256 of its
    --- SubjectPublicKeyInfo's DER.
    kind: string
    name: string
    value: string
  end
end

--- Where cosmic's own tree keeps the snapshot.
local snapshot <const> = "vendor/onecrl/onecrl.json"

--- Where [`onecrl.fill`] reads the snapshot of the tree at `root`.
function onecrl.source(root: string): string
  return root .. "/" .. snapshot
end

--- A remote settings changeset, as far as this reads one.
local record Feed
  record Change
    issuerName?: string
    serialNumber?: string
    subject?: string
    pubKeyHash?: string
    enabled?: boolean
  end
  changes: {Change}
end

-- Written out, not [`Shape.record_of`]: a boot loads this module, and
-- has no build to resolve one.
local FEED <const> = Shape.record({
  changes = Shape.list(Shape.record({
    issuerName = Shape.optional(Shape.string),
    serialNumber = Shape.optional(Shape.string),
    subject = Shape.optional(Shape.string),
    pubKeyHash = Shape.optional(Shape.string),
    enabled = Shape.optional(Shape.boolean),
  })),
})

--- `text`'s base64 as bytes, or nil when it is none, or empty.
local function bytes(text: string | nil): string | nil
  if text == nil or text == "" then
    return nil
  end
  local decoded, _ = Codec.unbase64(text)
  if decoded == nil or decoded == "" then
    return nil
  end
  return decoded
end

--- The timestamp of the state the changeset `text` is of, as its JSON
--- writes it, or nil when it names none.
function onecrl.timestamp(text: string): string | nil
  return text:match('"timestamp"%s*:%s*(%d+)%s*,%s*"changes"')
end

--- Every certificate the changeset `text` revokes, in its order: a
--- change of an issuer and a serial number, or of a subject and a key's
--- hash. A change marked `enabled: false` revokes nothing. Nil and why
--- when `text` is no changeset, or a change names neither pair whole.
function onecrl.parse(text: string): {onecrl.Entry} | nil, string
  local feed, trouble: Feed | nil, string = Shape.decode_into(text, FEED)
  if feed == nil then
    return nil, "not a OneCRL changeset: " .. trouble
  end
  local found: {onecrl.Entry} = {}
  for i, change in ipairs(feed.changes) do
    if change.enabled ~= false then
      local issuer, serial = bytes(change.issuerName), bytes(change.serialNumber)
      local subject, hash = bytes(change.subject), bytes(change.pubKeyHash)
      if issuer ~= nil and serial ~= nil then
        found[#found + 1] = { kind = "serial", name = issuer, value = serial }
      elseif subject ~= nil and hash ~= nil and #hash == 32 then
        found[#found + 1] = { kind = "key", name = subject, value = hash }
      else
        return nil, ("change %d names neither an issuer and a serial number nor a subject " ..
          "and a key's SHA-256, in base64"):format(i)
      end
    end
  end
  return found, ""
end

--- Writes `found` into the `ca_revoked` table of the database `db` holds
--- as `qualifier`, which must hold no rows yet: one row per distinct
--- entry, in the order of their bytes, so the same entries make the
--- same table. `cosmic refresh` writes a snapshot it fetched through
--- this too.
function onecrl.put(db: Sqlite.Handle, qualifier: string, found: {onecrl.Entry}): boolean, string
  -- SQLite orders and dedupes them: the new checker types no `table.sort` call.
  local made, made_trouble = Sqlite.run(db, "CREATE TEMP TABLE onecrl_put (kind TEXT, name BLOB, value BLOB)", {})
  if not made then
    return false, made_trouble
  end
  for _, one in ipairs(found) do
    local put, put_trouble = Sqlite.run(db,
      "INSERT INTO temp.onecrl_put (kind, name, value) VALUES (?1, ?2, ?3)",
      { bind.text(one.kind), bind.blob(one.name), bind.blob(one.value) })
    if not put then
      return false, put_trouble
    end
  end
  for _, sql in ipairs({
      "INSERT INTO " .. qualifier .. "ca_revoked (kind, name, value) SELECT DISTINCT kind, name, value " ..
        "FROM temp.onecrl_put ORDER BY kind, name, value",
      "DROP TABLE temp.onecrl_put",
  }) do
    local done, trouble = Sqlite.run(db, sql, {})
    if not done then
      return false, trouble
    end
  end
  return true, ""
end

--- Writes the snapshot under `root` into the `ca_revoked` table of the
--- database `db` holds as `qualifier` (`"out."`, say). A tree with no
--- snapshot writes none.
function onecrl.fill(db: Sqlite.Handle, root: string, qualifier: string): boolean, string
  local path = root .. "/" .. snapshot
  local exists, trouble = Fs.exists(path)
  if exists == nil then
    return false, trouble
  end
  if not exists then
    return true, ""
  end
  local text, read_trouble = Fs.read(path)
  if text == nil then
    return false, read_trouble
  end
  local found, parse_trouble = onecrl.parse(text)
  if found == nil then
    return false, path .. ": " .. parse_trouble
  end
  return onecrl.put(db, qualifier, found)
end

return onecrl
