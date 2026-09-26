local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local roots = require("build.roots")
local schema = require("build.schema")
local type Declared = require("build.inputs").Declared

--- The tree's CA bundle.
local _inputs: Declared = { reads = { "vendor/cacert/cacert.pem" } }

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
  local lines: {string} = { "-----BEGIN CERTIFICATE-----" }
  for at = 1, #encoded, 64 do
    lines[#lines + 1] = encoded:sub(at, at + 63)
  end
  lines[#lines + 1] = "-----END CERTIFICATE-----"
  return table.concat(lines, "\n")
end

local bundle <const> = "vendor/cacert/cacert.pem"

--- Fills a fresh database from `pem`, written as the bundle under
--- `tmp`: the rows, as `label` and hex DER in digest order, or nil and
--- why.
local function filled(tmp: string, pem: string): {{string}} | nil, string
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
    block("\4"),
    "",
  }, "\n")))
  local by_der: {string:string} = {}
  for _, row in ipairs(rows) do
    by_der[row[2]] = row[1]
  end
  assert(#rows == 3)
  assert(by_der[string.rep("01", 100)] == "First Root")
  assert(by_der["0203"] == "", "a block with no label has none")
  assert(by_der["04"] == "Third Root")
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
  local low = first < second and "0506" or "07"
  assert(rows[1][3] == low, "rows go in in digest order")
  for _, row in ipairs(rows) do
    local der = row[3] == "0506" and "\5\6" or "\7"
    assert(row[1] == Codec.hex(Hash.sha256(der)):upper(), "a row is keyed by its digest")
    assert(row[2] == (der == "\7" and "B" or "A"), "the first label a certificate has is kept")
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

--- The tree's own bundle: one row per certificate it holds, each
--- labelled, with nothing left over.
local function test_the_tree_s_bundle_becomes_a_row_per_certificate()
  local root = assert(Fs.absolute("."))
  local pem = assert(Fs.read(root .. "/" .. bundle))
  local _, blocks = pem:gsub("-----BEGIN CERTIFICATE-----", "")
  local db = database()
  assert(roots.fill(db, root, "main."))
  local counted = assert(Sqlite.text_rows(db,
    "SELECT count(*), count(*) FILTER (WHERE label = ''), " ..
    "count(*) FILTER (WHERE sha256 <> sha256(der)) FROM ca_roots"))
  assert(db:close())
  assert(tonumber(counted[1][1]) == blocks, counted[1][1] .. " rows for " .. blocks)
  assert(counted[1][2] == "0", "every root of the bundle is labelled")
  assert(counted[1][3] == "0", "each row is keyed by its certificate's digest")
end
