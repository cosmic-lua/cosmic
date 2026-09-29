--- cosmic.http's tests that need the program itself, apart from
--- cosmic/http_test.tl's so those stand while the tree moves:
--- $SSL_CERT_FILE, which only a fresh process started from the program
--- reads. The CA roots the binary's own database carries are read in
--- cosmic/http_store_test.tl.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- Requests to a closed local port, which a loopback alone answers:
--- the worker runs offline, and is keyed. And the program itself, which
--- its tests start.
Test.needs{ network = { "127.0.0.1" }, tool = true }

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
--- nothing: a request fails as it would without it. Reading a directory
--- by the size that seeking to its end gives would ask for more memory
--- than there is, and opening a pipe without O_NONBLOCK would wait for a
--- writer forever.
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
