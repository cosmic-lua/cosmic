--- cosmic.http's tests of the CA roots the binary's own database
--- carries, apart from cosmic/http_test.tl's so those stand while the
--- tree moves.

local Codec = require("cosmic.codec")
local Http = require("cosmic.http")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")

--- `store`: the carried roots are read through [`Store.databases()`].
Test.needs{ store = true }

--- A TLS 1.2 server's first flight, as a script can send it: a
--- ServerHello choosing ECDHE-RSA with AES-128-GCM, then its
--- Certificate message holding `der` alone. The client verifies the
--- certificate the moment it reads the message, so nothing more of the
--- handshake is needed to see what it made of it.
local function first_flight(der: string): string
  local function message(kind: integer, body: string): string
    return string.char(kind) .. string.pack(">I3", #body) .. body
  end
  local hello = message(2, "\3\3" .. string.rep("B", 32) .. "\0" .. "\192\47" .. "\0")
  local certificate = message(11, string.pack(">I3", #der + 3) .. string.pack(">I3", #der) .. der)
  local records = hello .. certificate
  return "\22\3\3" .. string.pack(">I2", #records) .. records
end

--- A root the binary's own database carries (`ca_roots`), as DER.
local function carried_root(label: string): string
  local databases = Store.databases()
  local rows = assert(Sqlite.text_rows(databases[#databases],
    "SELECT hex(der) FROM ca_roots WHERE label = ?1", { { text = label } }))
  assert(#rows == 1, label .. " is not among the binary's CA roots")
  return (assert(Codec.unhex(rows[1][1])))
end

--- An https connection is verified against the CA roots the binary's
--- own database carries (core/http.c's `use_roots`): a server
--- presenting one of them is trusted -- and refused only because the
--- root names another host -- while the same certificate with its
--- signature broken is not.
local function test_an_https_peer_is_verified_against_the_carried_roots()
  local root = carried_root("ISRG Root X1")
  local _, trusted = Http.open("https://cosmic.test/", { script = { first_flight(root) } })
  assert(trusted:find("Common Name", 1, true), trusted)
  assert(not trusted:find("not correctly signed", 1, true),
    "a carried root is not trusted: " .. trusted)
  local broken = root:sub(1, -2) .. string.char(root:byte(-1) ~ 1)
  local _, refused = Http.open("https://cosmic.test/", { script = { first_flight(broken) } })
  assert(refused:find("not correctly signed by the trusted CA", 1, true), refused)
  -- The carried roots may be what is stale: the failure says how to get
  -- newer ones.
  assert(refused:find("`cosmic refresh cacert --binary <this program> -o <copy>`", 1, true), refused)
  assert(not trusted:find("cosmic refresh", 1, true), trusted)
end

--- Every root this binary carries reads as a certificate; a DER
--- sequence that is none, and bytes that are no DER at all, do not,
--- and say why.
local function test_check_certificate_reads_what_the_binary_trusts()
  local databases = Store.databases()
  local roots = assert(Sqlite.rows(databases[#databases], "SELECT der, label FROM ca_roots"))
  assert(#roots > 0)
  for _, row in ipairs(roots) do
    local ok, why = Http.check_certificate(row[1].blob)
    assert(ok and why == "", row[2].text .. ": " .. why)
  end
  for _, der in ipairs({ "", "\x30\x03abc", "not der" }) do
    local ok, why = Http.check_certificate(der)
    assert(not ok and why ~= "", Codec.hex(der))
  end
end
