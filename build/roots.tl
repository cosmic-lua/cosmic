--- The CA roots a cosmic binary trusts: those Mozilla's root store
--- ([`vendor/cacert/certdata.txt`], NSS's certdata.txt) trusts to issue
--- server certificates, one row per certificate in the shipped
--- `ca_roots` table, each the certificate's DER bytes under its SHA-256,
--- the label the store gives it, and the date after which Mozilla trusts
--- it for no server certificate issued (`distrust_after`), which
--- [`core/http.c`] enforces as it verifies a chain. A PEM bundle (curl's
--- cacert.pem, a file `cosmic refresh --cacert` is given) is read too,
--- and names no such date.
---
--- The database carries the bundle once, as DER, for every core the
--- artifact holds, rather than as PEM text in each core. [`core/http.c`]
--- reads the rows out of the binary's own database the first time a
--- request needs them and hands mbedtls the chain it parsed, for every
--- TLS connection and every proxy's alike. A project's database, though
--- searched ahead of the binary's, never adds a root.
---
--- The writer fills the table in cosmic's own projection alone, as it
--- does the bill of materials ([`build.bom`]); `carried` copies it into
--- the tool and `cosmic build` into every executable.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local bind = require("build.bind")

local record roots
  --- One certificate of the bundle.
  record Root
    label: string
    der: string
    --- `YYYYMMDDHHMMSS`, in UTC: a server certificate this root issued
    --- with a later notBefore is not trusted. "" when there is none.
    distrust_after: string
  end
end

--- Where cosmic's own tree keeps the bundle.
local bundle <const> = "vendor/cacert/certdata.txt"

--- Where [`roots.fill`] reads the bundle of the tree at `root`.
function roots.source(root: string): string
  return root .. "/" .. bundle
end

--- Every certificate a PEM bundle holds, in its order, each under the
--- label the line above its `====` underline gives it (empty when the
--- bundle names none). Nil and why when a certificate block is not
--- closed, or its body is not base64.
local function parse_pem(pem: string): {roots.Root}?, string
  local found: mut {roots.Root} = {}
  local label = ""
  local previous = ""
  local body: mut {string}? = nil
  local number = 0
  for line in String.lines((pem:gsub("\r\n", "\n"))) do
    number = number + 1
    if body ~= nil then
      if line == "-----END CERTIFICATE-----" then
        local der, why = Codec.unbase64(table.concat(body))
        if der == nil then
          return nil, "line " .. tostring(number) .. ": the certificate above is not base64: " .. why
        end
        if der == "" then
          return nil, "line " .. tostring(number) .. ": the certificate above is empty"
        end
        found[#found + 1] = { label = label, der = der, distrust_after = "" }
        body = nil
        label = ""
      elseif line:find("-----", 1, true) then
        return nil, "line " .. tostring(number) .. ": a certificate is not closed before " .. line
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

--- The bytes a `MULTILINE_OCTAL` value's lines spell (`\060\202...`),
--- or nil when a line holds anything else.
local function octal(lines: {string}): string?
  local bytes: mut {string} = {}
  for _, line in ipairs(lines) do
    if line:find("^[\\0-7]*$") == nil then
      return nil
    end
    for digits in line:gmatch("\\([0-7][0-7][0-7])") do
      bytes[#bytes + 1] = string.char(math.tointeger(tonumber(digits, 8)) or 0)
    end
  end
  return table.concat(bytes)
end

--- One object of certdata.txt: each attribute's value, by name. A
--- `MULTILINE_OCTAL` value is its bytes; any other, the text after its
--- type (`CKO_CERTIFICATE`, `"a label"`, `CK_FALSE`).
local type Object = {string:string}

--- `CKA_NSS_SERVER_DISTRUST_AFTER`'s value as [`Root.distrust_after`]: an
--- ASN.1 UTCTime `YYMMDDHHMMSSZ`, its year 19YY from 50 up (RFC 5280
--- 4.1.2.5.1); "" for `CK_FALSE`. Nil for anything else.
local function distrust_after(value: string?): string?
  if value == nil or value == "CK_FALSE" then
    return ""
  end
  local year, rest = value:match("^(%d%d)(%d%d%d%d%d%d%d%d%d%d)Z$")
  if year == nil or rest == nil then
    return nil
  end
  local century = "20"
  if (math.tointeger(tonumber(year)) or 0) >= 50 then
    century = "19"
  end
  return century .. year .. rest
end

--- The roots NSS's certdata.txt trusts to issue server certificates
--- (a trust object of the same issuer and serial number whose
--- `CKA_TRUST_SERVER_AUTH` is `CKT_NSS_TRUSTED_DELEGATOR`), in the
--- file's order, each with its label and server distrust date. Nil and
--- why for an object or value the file cannot mean, or a trusted root
--- with no certificate.
local function parse_certdata(text: string): {roots.Root}?, string
  local objects: mut {Object} = {}
  local object: Object = {}
  local name = ""
  local value_lines: {string}? = nil
  local number = 0
  local begun = false
  for line in String.lines((text:gsub("\r\n", "\n"))) do
    number = number + 1
    local open = value_lines
    if open ~= nil then
      if line == "END" then
        local bytes = octal(open)
        if bytes == nil then
          return nil, "line " .. tostring(number) .. ": " .. name .. " holds what is no octal"
        end
        object[name] = bytes
        value_lines = nil
      else
        open[#open + 1] = line
      end
    elseif line == "BEGINDATA" then
      begun = true
    elseif begun and line ~= "" and line:sub(1, 1) ~= "#" then
      local attribute, kind, rest = line:match("^(CKA_[%w_]+) ([%w_]+)%s*(.*)$")
      if attribute == nil or kind == nil or rest == nil then
        return nil, "line " .. tostring(number) .. ": not an attribute: " .. line:sub(1, 80)
      end
      if attribute == "CKA_CLASS" then
        object = {}
        objects[#objects + 1] = object
      end
      if kind == "MULTILINE_OCTAL" then
        name = attribute
        value_lines = {}
      elseif kind == "UTF8" then
        object[attribute] = rest:match('^"(.*)"$') or rest
      else
        object[attribute] = rest
      end
    end
  end
  if value_lines ~= nil then
    return nil, name .. " is not closed by END"
  end
  if not begun then
    return nil, "holds no BEGINDATA"
  end
  local trusted: mut {string:boolean} = {}
  for _, one in ipairs(objects) do
    if one["CKA_CLASS"] == "CKO_NSS_TRUST" and one["CKA_TRUST_SERVER_AUTH"] == "CKT_NSS_TRUSTED_DELEGATOR" then
      trusted[(one["CKA_ISSUER"] or "") .. "\0" .. (one["CKA_SERIAL_NUMBER"] or "")] = true
    end
  end
  local found: mut {roots.Root} = {}
  for _, one in ipairs(objects) do
    local key = (one["CKA_ISSUER"] or "") .. "\0" .. (one["CKA_SERIAL_NUMBER"] or "")
    if one["CKA_CLASS"] == "CKO_CERTIFICATE" and trusted[key] == true then
      local label = one["CKA_LABEL"] or ""
      local der = one["CKA_VALUE"]
      if der == nil or der == "" then
        return nil, label .. ": a trusted root with no certificate"
      end
      local after = distrust_after(one["CKA_NSS_SERVER_DISTRUST_AFTER"])
      if after == nil then
        return nil, label .. ": its server distrust date is no UTCTime"
      end
      trusted[key] = false
      found[#found + 1] = { label = label, der = der, distrust_after = after }
    end
  end
  for _, unmet in pairs(trusted) do
    if unmet then
      return nil, "a server trust names no certificate in the file"
    end
  end
  return found, ""
end

--- Every root `text` holds: NSS's certdata.txt when it has a
--- `BEGINDATA` line (only those it trusts to issue server
--- certificates, with their distrust dates), else a PEM bundle (each
--- certificate, with none). Nil and why when it cannot be read as the
--- one it is.
function roots.parse(text: string): {roots.Root}?, string
  if text:find("\nBEGINDATA\r?\n") ~= nil then
    return parse_certdata(text)
  end
  return parse_pem(text)
end

--- Writes `found` into the `ca_roots` table of the database `db` holds
--- as `qualifier`, which must hold no rows yet: one row per distinct
--- certificate, in digest order. `ca_roots` is a rowid table, so the
--- order rows go in is the order of the file's bytes. `cosmic refresh`
--- writes a bundle it fetched through this too, so the same roots make
--- the same table either way.
function roots.put(db: Sqlite.Handle, qualifier: string, found: {roots.Root}): boolean, string
  local by_digest: mut {string:roots.Root} = {}
  local digests: mut {string} = {}
  for _, one in ipairs(found) do
    local digest = Hash.sha256(one.der)
    if by_digest[digest] == nil then
      by_digest[digest] = one
      digests[#digests + 1] = digest
    end
  end
  table.sort(digests)
  for _, digest in ipairs(digests) do
    local one = assert(by_digest[digest])
    local put, put_trouble = Sqlite.run(db,
      "INSERT INTO " .. qualifier .. "ca_roots (sha256, label, der, distrust_after) VALUES (?1, ?2, ?3, ?4)",
      { bind.blob(digest), bind.text(one.label), bind.blob(one.der), bind.text(one.distrust_after) })
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
--- TODO: hold the tree's bundle to [`Http.check_certificate`] as
--- `cosmic refresh` holds a fetched one, refusing a root the TLS stack
--- cannot read rather than shipping one [`core/http.c`] drops; the
--- fixtures build/roots_test.tl fills from are bytes that are no
--- certificate, and would need real ones first.
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
