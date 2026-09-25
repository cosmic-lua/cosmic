--- The CA roots a cosmic binary trusts: Mozilla's bundle
--- (`vendor/cacert/cacert.pem`), one row per certificate in the shipped
--- `ca_roots` table, each the certificate's DER bytes under its SHA-256
--- and the label the bundle gives it.
---
--- The core once carried the bundle's PEM text in each of its cores;
--- the database carries it once, as DER, for every core the artifact
--- holds. `core/http.c` reads the rows out of the binary's own database
--- the first time a request needs them and hands mbedtls the chain it
--- parsed, for every TLS connection and every proxy's alike, so a
--- project's database, searched ahead of the binary's, never adds a
--- root.
---
--- The writer fills the table in cosmic's own projection alone, as it
--- does the bill of materials (`build.bom`); `carried` copies it into
--- the tool and `cosmic build` into every executable.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local bind = require("build.bind")

local record roots
  --- One certificate of the bundle.
  record Root
    label: string
    der: string
  end
end

--- Where cosmic's own tree keeps the bundle.
local bundle <const> = "vendor/cacert/cacert.pem"

--- Every certificate a PEM bundle holds, in its order, each under the
--- label the line above its `====` underline gives it (empty when the
--- bundle names none). Nil and why when a certificate block is not
--- closed, or its body is not base64.
function roots.parse(pem: string): {roots.Root} | nil, string
  local found: {roots.Root} = {}
  local label = ""
  local previous = ""
  local body: {string} | nil = nil
  local number = 0
  for line in (pem:gsub("\r\n", "\n") .. "\n"):gmatch("([^\n]*)\n") do
    number = number + 1
    if body ~= nil then
      if line == "-----END CERTIFICATE-----" then
        local der, why = Codec.unbase64(table.concat(body))
        if der == nil then
          return nil, "line " .. number .. ": the certificate above is not base64: " .. why
        end
        if der == "" then
          return nil, "line " .. number .. ": the certificate above is empty"
        end
        found[#found + 1] = { label = label, der = der }
        body = nil
        label = ""
      elseif line:find("-----", 1, true) then
        return nil, "line " .. number .. ": a certificate is not closed before " .. line
      else
        body[#body + 1] = line
      end
    elseif line == "-----BEGIN CERTIFICATE-----" then
      body = {}
    elseif line:match("^=+$") and previous ~= "" then
      label = previous
    end
    previous = line
  end
  if body ~= nil then
    return nil, "the last certificate is not closed"
  end
  return found
end

--- Writes `found` into the `ca_roots` table of the database `db` holds
--- as `qualifier`, which holds none yet: one row per certificate, a
--- bundle listing one twice trusting it once, in digest order --
--- `ca_roots` is a rowid table, so the order rows go in is the order of
--- the file's bytes. `cosmic refresh` writes a bundle it fetched this
--- way too, so the same bundle makes the same table either way.
function roots.put(db: Sqlite.Handle, qualifier: string, found: {roots.Root}): boolean, string
  local by_digest: {string:roots.Root} = {}
  local digests: {string} = {}
  for _, one in ipairs(found) do
    local digest = Hash.sha256(one.der)
    if by_digest[digest] == nil then
      by_digest[digest] = one
      digests[#digests + 1] = digest
    end
  end
  table.sort(digests)
  for _, digest in ipairs(digests) do
    local one = by_digest[digest]
    local put, put_trouble = Sqlite.run(db,
      "INSERT INTO " .. qualifier .. "ca_roots (sha256, label, der) VALUES (?1, ?2, ?3)",
      { bind.blob(digest), bind.text(one.label), bind.blob(one.der) })
    if not put then
      return false, put_trouble
    end
  end
  return true, ""
end

--- Writes the bundle under `root` into the `ca_roots` table of the
--- database `db` holds as `qualifier` (`"out."`, say). A tree with no
--- bundle writes none; one whose bundle holds no certificate fails, so
--- a binary never ships trusting nothing by accident.
function roots.fill(db: Sqlite.Handle, root: string, qualifier: string): boolean, string
  local path = root .. "/" .. bundle
  local exists, trouble = Fs.exists(path)
  if exists == nil then
    return false, trouble
  end
  if not exists then
    return true, ""
  end
  local pem, read_trouble = Fs.read(path)
  if pem == nil then
    return false, read_trouble
  end
  local found, parse_trouble = roots.parse(pem)
  if found == nil then
    return false, path .. ": " .. parse_trouble
  end
  if #found == 0 then
    return false, path .. ": holds no certificate"
  end
  return roots.put(db, qualifier, found)
end

return roots
