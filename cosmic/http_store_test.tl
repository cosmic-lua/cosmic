--- cosmic.http's tests of the CA roots the binary's own database
--- carries, apart from cosmic/http_test.tl's so those stand while the
--- tree moves.

local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")

--- `store`: the carried roots are read through [`Store.databases()`].
Test.policy{ grants = { { path = "o/cosmic.db", letters = "r" } } }

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
  return (assert(Codec.unhex(rows[1]:text(1))))
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
    local ok, why = Http.check_certificate(row:blob(1))
    assert(ok and why == "", row:text(2) .. ": " .. tostring(why))
  end
  for _, der in ipairs({ "", "\x30\x03abc", "not der" }) do
    local ok, why = Http.check_certificate(der)
    assert(not ok and why ~= "", Codec.hex(der))
  end
end

--- What a request whose server presents `der` makes of it, trusting
--- what `opts` chooses: "trusted" when only the name is wrong (the
--- certificate stands for no host), else the failure.
local function verdict(der: string, opts: Http.Options): string
  local response, why = Http.open("https://cosmic.test/",
    { script = { first_flight(der) }, roots = opts.roots, ca = opts.ca, pin = opts.pin })
  assert(response == nil, "a canned first flight completes no handshake")
  if why:find("Common Name", 1, true) ~= nil and why:find("not correctly signed", 1, true) == nil then
    return "trusted"
  end
  return why
end

--- `der` as PEM.
local function pem(der: string): string
  local encoded = Codec.base64(der)
  local lines: {string} = { "-----BEGIN CERTIFICATE-----" }
  for at = 1, #encoded, 64 do
    lines[#lines + 1] = encoded:sub(at, at + 63)
  end
  lines[#lines + 1] = "-----END CERTIFICATE-----"
  return table.concat(lines, "\n") .. "\n"
end

--- A root the binary carries that `minimal` leaves out.
local OUTSIDE <const> = "Telia RSA TLS Root CA v3"

--- `roots = "minimal"` trusts the roots of [`Http.minimal_roots`] and not
--- the rest the binary carries, which the default, and "mozilla",
--- still trust; a refusal names the request's own choice of roots, not
--- the binary's staleness.
local function test_minimal_roots_trust_only_their_own()
  local listed = carried_root("ISRG Root X1")
  local outside = carried_root(OUTSIDE)
  assert(verdict(listed, { roots = "minimal" }) == "trusted")
  local refused = verdict(outside, { roots = "minimal" })
  assert(refused:find("not correctly signed by the trusted CA", 1, true), refused)
  assert(refused:find("opts.roots", 1, true), refused)
  assert(not refused:find("cosmic refresh", 1, true), refused)
  assert(verdict(outside, {}) == "trusted")
  assert(verdict(outside, { roots = "mozilla" }) == "trusted")
end

--- A list of digests trusts exactly the carried roots it names, in
--- either case and with or without the colons Mozilla's bundle prints.
local function test_roots_by_digest_trust_only_those()
  local outside = carried_root(OUTSIDE)
  local hex = Codec.hex(Hash.sha256(outside))
  local colons = hex:upper():gsub("(%x%x)", "%1:"):sub(1, -2)
  assert(verdict(outside, { roots = { hex } }) == "trusted")
  assert(verdict(outside, { roots = { colons } }) == "trusted")
  local refused = verdict(carried_root("ISRG Root X1"), { roots = { hex } })
  assert(refused:find("not correctly signed", 1, true), refused)
end

--- `ca` is trusted besides the roots, and alone with `roots = "none"`,
--- as PEM or as DER; "none" with nothing besides trusts nothing, and
--- says so before connecting.
local function test_ca_pins_a_certificate_in_code()
  local outside = carried_root(OUTSIDE)
  local listed = carried_root("ISRG Root X1")
  assert(verdict(outside, { roots = "none", ca = pem(outside) }) == "trusted")
  assert(verdict(outside, { roots = "none", ca = outside }) == "trusted")
  assert(verdict(outside, { roots = "minimal", ca = pem(outside) }) == "trusted")
  local refused = verdict(listed, { roots = "none", ca = pem(outside) })
  assert(refused:find("not correctly signed", 1, true), refused)
  local _, nothing = Http.open("https://cosmic.test/", { roots = "none" })
  assert(nothing:find("no CA roots to trust", 1, true), nothing)
  -- An empty list trusts none of the carried roots ($SSL_CERT_FILE's
  -- may still be trusted, or nothing at all).
  local none_listed: {string} = {}
  assert(verdict(outside, { roots = none_listed }) ~= "trusted")
end

--- A `ca` the TLS stack cannot read fails the request, naming which.
local function test_an_unreadable_ca_fails_the_request()
  local outside = carried_root(OUTSIDE)
  local cases: {string:string} = {
    ["not a certificate"] = "opts.ca: not an X.509 certificate",
    ["-----BEGIN CERTIFICATE-----\n!!!!\n-----END CERTIFICATE-----\n"] = "certificate 1 is not base64",
    [pem(outside) .. "-----BEGIN CERTIFICATE-----\nAAAA\n"] = "certificate 2 is not closed",
    ["-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n"] = "holds no certificate",
  }
  for ca, want in pairs(cases) do
    local response, why = Http.open("https://cosmic.test/", { ca = ca, script = { "" } })
    assert(response == nil and why:find(want, 1, true) ~= nil, want .. ": " .. tostring(why))
  end
end

--- Options of the wrong shape raise, naming the option.
local function test_trust_options_of_the_wrong_shape_raise()
  local function raised(opts: Http.Options): string
    local ok, err = pcall(Http.open, "https://cosmic.test/", opts)
    assert(not ok, "no raise")
    return tostring(err)
  end
  assert(raised({ roots = "everything" }):find("opts.roots must be", 1, true))
  assert(raised({ roots = { "abc" } }):find("opts.roots[1]", 1, true))
  assert(raised({ roots = { string.rep("g", 64) } }):find("opts.roots[1]", 1, true))
  assert(raised({ pin = "sha256//short=" }):find("opts.pin[1]", 1, true))
  local no_pins: {string} = {}
  assert(raised({ pin = no_pins }):find("opts.pin must hold a pin", 1, true))
end

--- A public key pin is the base64 SHA-256 of the certificate's
--- SubjectPublicKeyInfo: ISRG Root X1's is the one Let's Encrypt
--- publishes, from its DER or its PEM, and a well-formed pin is taken.
local function test_public_key_pin_is_the_spki_hash()
  local root = carried_root("ISRG Root X1")
  local want = "sha256//C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M="
  assert(Http.public_key_pin(root) == want)
  assert(Http.public_key_pin(pem(root)) == want)
  local none, why = Http.public_key_pin("not a certificate")
  assert(none == nil and why:find("not an X.509 certificate", 1, true) ~= nil, why)
  local two, both = Http.public_key_pin(pem(root) .. pem(carried_root(OUTSIDE)))
  assert(two == nil and both == "more than one certificate", both)
  -- Taken: what fails here is the canned handshake, not the pin's shape.
  -- TODO: show a pin the server's key does not hash to failing the
  -- request, once a test can complete a TLS handshake: a canned first
  -- flight stops before curl checks the pin, and cosmic serves no TLS.
  assert(verdict(root, { pin = { want, want } }) == "trusted")
end

--- Each of [`Http.minimal_roots`] is a root this binary carries, named
--- once: a bundle that drops one fails here, for whoever moves the
--- bundle to decide what replaces it.
local function test_minimal_roots_are_carried()
  local databases = Store.databases()
  local seen: {string:boolean} = {}
  local own = assert(databases[#databases])
  for _, hex in ipairs(Http.minimal_roots()) do
    assert(hex:match("^%x+$") ~= nil and #hex == 64 and hex == hex:lower(), hex)
    assert(seen[hex] == nil, hex .. " is listed twice")
    seen[hex] = true
    local rows = assert(Sqlite.text_rows(own,
      "SELECT label FROM ca_roots WHERE sha256 = unhex(?1)", { { text = hex } }))
    assert(#rows == 1, hex .. " is not among the binary's CA roots")
  end
  local mine = Http.minimal_roots()
  mine[1] = "changed"
  assert(Http.minimal_roots()[1] ~= "changed", "the list is a copy")
end
