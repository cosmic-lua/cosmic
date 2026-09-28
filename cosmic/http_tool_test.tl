--- cosmic.http's tests that need the program itself, apart from
--- cosmic/http_test.tl's so those stand while the tree moves: the CA
--- roots the binary's own database carries, read through
--- `Store.databases()`, and $SSL_CERT_FILE, which only a fresh process
--- started from the program reads.

local Child = require("cosmic.child")
local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local this_program = require("build.this_program")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- Requests to a closed local port, which a loopback alone answers:
--- the worker runs offline, and is keyed. And the program itself, which
--- its tests start, and whose own database holds the roots they read.
Test.needs{ network = { "127.0.0.1" }, tool = true }

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

--- What a fresh process, $SSL_CERT_FILE naming `cert_file`, is told
--- when it opens a closed local port: the roots, that file's included,
--- are loaded once per process, at its first request.
local function refused_with_cert_file(tmp: string, cert_file: string): string
  local script = tmp .. "/open.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local _, trouble = Http.open("http://127.0.0.1:1/", { connect_timeout_ms = 2000 })
Fs.put(Fs.stdout, trouble or "")
]]))
  local started = this_program.program({ "--standalone", script },
    { env = { SSL_CERT_FILE = cert_file, XDG_CACHE_HOME = tmp .. "/cache" },
      stdout = "capture", stderr = "capture", timeout_ms = 30000 })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, tostring(result.stderr))
  return result.stdout or ""
end

--- $SSL_CERT_FILE naming what holds no certificates -- a directory, a
--- named pipe, or a file of anything else -- adds none and refuses
--- nothing: a request fails as it would without it. A directory's size,
--- as seeking to its end tells it, once asked for more memory than there
--- was, refusing every request; a pipe, opened without O_NONBLOCK, waited
--- for a writer forever.
local function test_a_cert_file_holding_no_certificates_is_passed_over(tmp: string)
  local junk = tmp .. "/junk.pem"
  assert(Fs.write(junk, "no certificate here\n"))
  local pipe = tmp .. "/pipe.pem"
  assert(sys.mkfifo(pipe))
  for _, cert_file in ipairs({ tmp, junk, pipe, tmp .. "/missing.pem" }) do
    local trouble = refused_with_cert_file(tmp, cert_file)
    assert(not trouble:find("SSL_CERT_FILE", 1, true), cert_file .. ": " .. trouble)
    assert(trouble:lower():find("connect", 1, true) ~= nil, cert_file .. ": " .. trouble)
  end
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
