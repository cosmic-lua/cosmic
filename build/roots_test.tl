local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local roots = require("build.roots")
local schema = require("build.schema")

--- The tree's CA bundle.
Test.policy{ grants = { { path = "vendor/cacert/certdata.txt", letters = "r" } } }

--- An empty database of the shipped shape.
local function database(): Sqlite.Handle
  local db = assert(Sqlite.memory())
  for _, statement in ipairs(schema.create("")) do
    assert(db:exec(statement))
  end
  return db
end

--- A PEM block holding `bytes`, wrapped at 64 columns.
local function block(bytes: string): string
  local encoded = Codec.base64(bytes)
  local lines: mut {string} = { "-----BEGIN CERTIFICATE-----" }
  for at = 1, #encoded, 64 do
    lines[#lines + 1] = encoded:sub(at, at + 63)
  end
  lines[#lines + 1] = "-----END CERTIFICATE-----"
  return table.concat(lines, "\n")
end

local bundle <const> = "vendor/cacert/certdata.txt"

--- Fills a fresh database from `pem`, written as the bundle under
--- `tmp`: the rows, as `label` and hex DER in digest order, or nil and
--- why.
local function filled(tmp: string, pem: string): Sqlite.Rows?, string
  assert(Fs.mkdirs(tmp .. "/vendor/cacert"))
  assert(Fs.write(tmp .. "/" .. bundle, pem))
  local db = database()
  local ok, trouble = roots.fill(db, tmp, "main.")
  if not ok then
    assert(db:close())
    return nil, trouble
  end
  local rows = assert(Sqlite.text_rows(db, "SELECT label, hex(der) FROM ca_roots ORDER BY rowid"))
  assert(db:close())
  return rows, ""
end

local function test_each_certificate_is_its_der_under_its_label(tmp: string)
  local rows = assert(filled(tmp, table.concat({
    "##",
    "## Bundle of CA Root Certificates",
    "##",
    "",
    "First Root",
    "==========",
    block(string.rep("\1", 100)),
    "",
    block("\2\3"),
    "",
    "Third Root",
    "==========",
    "# Fingerprint (SHA-256): 04:04",
    block("\4"),
    "",
  }, "\n")))
  local by_der: mut {string:string} = {}
  for _, row in ipairs(rows) do
    by_der[row:text(2)] = row:text(1)
  end
  assert(#rows == 3)
  assert(by_der[string.rep("01", 100)] == "First Root")
  assert(by_der["0203"] == "", "a block with no label has none")
  assert(by_der["04"] == "Third Root", "a comment after the underline is no label")
end

local function test_a_broken_bundle_is_refused(tmp: string)
  local _, open = filled(tmp, "-----BEGIN CERTIFICATE-----\nAAAA\n")
  assert(open:find("the last certificate is not closed", 1, true), open)
  local _, nested = filled(tmp, "-----BEGIN CERTIFICATE-----\nAAAA\n" ..
      "-----BEGIN CERTIFICATE-----\n")
  assert(nested:find("not closed", 1, true), nested)
  local _, garbled = filled(tmp, "-----BEGIN CERTIFICATE-----\n!!!!\n" ..
      "-----END CERTIFICATE-----\n")
  assert(garbled:find("not base64", 1, true), garbled)
end

local function test_fill_writes_one_row_per_distinct_certificate(tmp: string)
  assert(Fs.mkdirs(tmp .. "/vendor/cacert"))
  assert(Fs.write(tmp .. "/" .. bundle, "A\n=\n" .. block("\5\6") .. "\n" ..
      "B\n=\n" .. block("\7") .. "\n" .. "A again\n=\n" .. block("\5\6") .. "\n"))
  local db = database()
  assert(roots.fill(db, tmp, "main."))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT hex(sha256), label, hex(der) FROM ca_roots ORDER BY rowid"))
  assert(db:close())
  assert(#rows == 2, "a certificate listed twice is one root")
  local first, second = Hash.sha256("\5\6"), Hash.sha256("\7")
  local low = if first < second then "0506" else "07" end
  assert(rows[1]:text(3) == low, "rows go in in digest order")
  for _, row in ipairs(rows) do
    local der = if row:text(3) == "0506" then "\5\6" else "\7" end
    assert(row:text(1) == Codec.hex(Hash.sha256(der)):upper(), "a row is keyed by its digest")
    assert(row:text(2) == (if der == "\7" then "B" else "A" end), "the first label a certificate has is kept")
  end
end

local function test_a_tree_without_a_bundle_has_no_roots_but_an_empty_one_fails(tmp: string)
  local db = database()
  assert(roots.fill(db, tmp, "main."))
  assert(Fs.mkdirs(tmp .. "/vendor/cacert"))
  assert(Fs.write(tmp .. "/" .. bundle, "## nothing here\n"))
  local ok, trouble = roots.fill(db, tmp, "main.")
  assert(not ok and trouble:find("holds no certificate", 1, true), trouble)
  assert(db:close())
end

--- The tree's own root store: one row per root it trusts to issue
--- server certificates, each labelled, with nothing left over.
local function test_the_tree_s_bundle_becomes_a_row_per_certificate()
  local root = assert(Fs.absolute("."))
  local text = assert(Fs.read(root .. "/" .. bundle))
  local _, blocks = text:gsub("\nCKA_TRUST_SERVER_AUTH CK_TRUST CKT_NSS_TRUSTED_DELEGATOR\n", "")
  local db = database()
  assert(roots.fill(db, root, "main."))
  local counted = assert(Sqlite.text_rows(db,
    "SELECT count(*), count(*) FILTER (WHERE label = ''), " ..
      "count(*) FILTER (WHERE sha256 <> sha256(der)) FROM ca_roots"))
  assert(db:close())
  assert(tonumber(counted[1]:text(1)) == blocks, counted[1]:text(1) .. " rows for " .. tostring(blocks))
  assert(counted[1]:text(2) == "0", "every root of the bundle is labelled")
  assert(counted[1]:text(3) == "0", "each row is keyed by its certificate's digest")
end

--- `bytes` as certdata.txt writes a `MULTILINE_OCTAL` value: `\ooo`
--- per byte, sixteen to a line, then END.
local function octal(bytes: string): string
  local lines: mut {string} = {}
  for at = 1, #bytes, 16 do
    local line: mut {string} = {}
    for i = at, math.min(at + 15, #bytes) do
      line[#line + 1] = ("\\%03o"):format(bytes:byte(i) or 0)
    end
    lines[#lines + 1] = table.concat(line)
  end
  lines[#lines + 1] = "END"
  return table.concat(lines, "\n")
end

--- One root of a certdata.txt fixture: its certificate object (unless
--- `trust_only`) and its trust object.
local record Entry
  label: string
  der: string
  serial: string
  --- `CKA_TRUST_SERVER_AUTH`'s value.
  server: string
  --- A UTCTime, or nil for `CK_FALSE`.
  distrust?: string
  trust_only?: boolean
end

--- A certdata.txt holding `entries`, laid out as NSS's is.
local function certdata(entries: {Entry}): string
  local lines: mut {string} = { "# This Source Code Form is subject to the terms of the Mozilla Public", "#",
    "BEGINDATA", "CKA_CLASS CK_OBJECT_CLASS CKO_NSS_BUILTIN_ROOT_LIST", "CKA_TOKEN CK_BBOOL CK_TRUE",
    'CKA_LABEL UTF8 "Mozilla Builtin Roots"' }
  local issuer = octal("an issuer")
  for _, entry in ipairs(entries) do
    if entry.trust_only ~= true then
      lines[#lines + 1] = ""
      lines[#lines + 1] = '# Certificate "' .. entry.label .. '"'
      lines[#lines + 1] = "CKA_CLASS CK_OBJECT_CLASS CKO_CERTIFICATE"
      lines[#lines + 1] = 'CKA_LABEL UTF8 "' .. entry.label .. '"'
      lines[#lines + 1] = "CKA_ISSUER MULTILINE_OCTAL\n" .. issuer
      lines[#lines + 1] = "CKA_SERIAL_NUMBER MULTILINE_OCTAL\n" .. octal(entry.serial)
      lines[#lines + 1] = "CKA_VALUE MULTILINE_OCTAL\n" .. octal(entry.der)
      local distrust = entry.distrust
      if distrust == nil then
        lines[#lines + 1] = "CKA_NSS_SERVER_DISTRUST_AFTER CK_BBOOL CK_FALSE"
      else
        lines[#lines + 1] = "CKA_NSS_SERVER_DISTRUST_AFTER MULTILINE_OCTAL\n" .. octal(distrust)
      end
      lines[#lines + 1] = "CKA_NSS_EMAIL_DISTRUST_AFTER CK_BBOOL CK_FALSE"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = '# Trust for "' .. entry.label .. '"'
    lines[#lines + 1] = "CKA_CLASS CK_OBJECT_CLASS CKO_NSS_TRUST"
    lines[#lines + 1] = 'CKA_LABEL UTF8 "' .. entry.label .. '"'
    lines[#lines + 1] = "CKA_ISSUER MULTILINE_OCTAL\n" .. issuer
    lines[#lines + 1] = "CKA_SERIAL_NUMBER MULTILINE_OCTAL\n" .. octal(entry.serial)
    lines[#lines + 1] = "CKA_TRUST_SERVER_AUTH CK_TRUST " .. entry.server
    lines[#lines + 1] = "CKA_TRUST_EMAIL_PROTECTION CK_TRUST CKT_NSS_TRUSTED_DELEGATOR"
  end
  return table.concat(lines, "\n") .. "\n"
end

--- certdata.txt gives the roots it trusts to issue server certificates
--- and no others -- not one trusted for e-mail alone, nor a distrusted
--- certificate with no object of its own -- each with its label and its
--- server distrust date, a year of 50 or more in the 1900s.
local function test_certdata_gives_the_server_roots_and_their_dates()
  local found = assert(roots.parse(certdata({
    { label = "Plain Root", der = string.rep("\1", 40), serial = "\1", server = "CKT_NSS_TRUSTED_DELEGATOR" },
    { label = "Dated Root", der = "\2\3", serial = "\2", server = "CKT_NSS_TRUSTED_DELEGATOR",
      distrust = "260415235959Z" },
    { label = "Old Date", der = "\5", serial = "\5", server = "CKT_NSS_TRUSTED_DELEGATOR",
      distrust = "991231000000Z" },
    { label = "Mail Root", der = "\3", serial = "\3", server = "CKT_NSS_MUST_VERIFY_TRUST" },
    { label = "Gone", der = "\4", serial = "\4", server = "CKT_NSS_NOT_TRUSTED", trust_only = true },
  })))
  assert(#found == 3, tostring(#found))
  local plain, dated, old = assert(found[1]), assert(found[2]), assert(found[3])
  assert(plain.label == "Plain Root" and plain.der == string.rep("\1", 40) and plain.distrust_after == "")
  assert(dated.label == "Dated Root" and dated.der == "\2\3" and dated.distrust_after == "20260415235959",
    dated.distrust_after)
  assert(old.distrust_after == "19991231000000", old.distrust_after)
end

--- A certdata.txt the build cannot mean is refused, saying why, rather
--- than read as fewer roots.
local function test_a_certdata_it_cannot_mean_is_refused()
  local trusted: Entry = { label = "A Root", der = "\1", serial = "\1", server = "CKT_NSS_TRUSTED_DELEGATOR" }
  local good = certdata({ trusted })
  local cases: {string:string} = {
    [(good:gsub("\nEND\n", "\n", 1))] = "is no octal",
    [good .. "CKA_VALUE MULTILINE_OCTAL\n\\001\n"] = "is not closed by END",
    [good .. "not an attribute\n"] = "not an attribute",
    [certdata({ { label = "Lost", der = "\1", serial = "\1", server = "CKT_NSS_TRUSTED_DELEGATOR",
      trust_only = true } })] = "names no certificate",
    [certdata({ { label = "Bad Date", der = "\1", serial = "\1", server = "CKT_NSS_TRUSTED_DELEGATOR",
      distrust = "2026-04-15" } })] = "Bad Date: its server distrust date is no UTCTime",
  }
  for text, want in pairs(cases) do
    local found, why = roots.parse(text)
    assert(found == nil and why:find(want, 1, true) ~= nil, want .. ": " .. tostring(why))
  end
end

--- A dated root's date goes into its row, and an undated one's is "".
local function test_a_distrust_date_is_carried_in_the_row(tmp: string)
  assert(Fs.mkdirs(tmp .. "/vendor/cacert"))
  assert(Fs.write(tmp .. "/" .. bundle, certdata({
    { label = "Plain Root", der = "\1", serial = "\1", server = "CKT_NSS_TRUSTED_DELEGATOR" },
    { label = "Dated Root", der = "\2", serial = "\2", server = "CKT_NSS_TRUSTED_DELEGATOR",
      distrust = "260415235959Z" },
  })))
  local db = database()
  assert(roots.fill(db, tmp, "main."))
  local rows = assert(Sqlite.text_rows(db, "SELECT label, distrust_after FROM ca_roots ORDER BY label"))
  assert(db:close())
  assert(#rows == 2)
  local dated, plain = assert(rows[1]), assert(rows[2])
  assert(dated:text(1) == "Dated Root" and dated:text(2) == "20260415235959", dated:text(2))
  assert(plain:text(1) == "Plain Root" and plain:text(2) == "", plain:text(2))
end
