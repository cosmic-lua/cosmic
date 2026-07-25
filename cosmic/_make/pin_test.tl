#!/usr/bin/env cosmic
-- Tests for pins and the `fetch` verb.
--
-- The extractor gets adversarial cases rather than happy ones: a pin is
-- data, and the value of that claim is entirely in what it REFUSES. If
-- a pin could call a function, "a build runs only bytes you pinned"
-- would be a comment rather than a property.
--
-- The fetch half runs against a forked loopback server, so verification
-- (the digest matching, and the digest NOT matching) is exercised for
-- real without reaching the network.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local mfetch = require("cosmic._make.fetch")
local mk = require("cosmic._make")
local net = require("cosmic.net")
local pin = require("cosmic._make.pin")
local proc = require("cosmic.proc")
local project = require("cosmic._make.project")
local signal = require("cosmic.signal")
local cenv = require("cosmic.env")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Extract a pin from source text, for the grammar tests.
local function ext(source: string): {string: any} | nil, string
  return pin.extract(source, "p.pin.tl")
end

-- The shape a pin is allowed to have: one `return` of a table of
-- literals, nesting included.
local function test_extracts_a_literal()
  local got = check.must(ext([[
return {
  url = "https://example.test/x-{version}.tar.gz",
  version = "1.2.3",
  sha256 = "abc123",
  strip_components = 1,
  verified = true,
  platforms = {["*"] = {sha = "deadbeef"}},
}
]]))
  assert(got.url == "https://example.test/x-{version}.tar.gz", "string")
  assert(got.version == "1.2.3", "string")
  assert(got.strip_components == 1, "number")
  assert(got.verified == true, "boolean")
  local plat = got.platforms as {string: any} -- cast: from any
  local star = plat["*"] as {string: any} -- cast: from any
  assert(star.sha == "deadbeef", "nested table and bracket key")
end
test_extracts_a_literal()

-- Everything a pin may NOT be. Each of these is a way for a file that
-- looks like data to do something, and each is refused by name.
local function refused(source: string, needle: string, why: string)
  local got, err = ext(source)
  assert(not got, why .. ": should be refused, got a value")
  assert(err:find(needle, 1, true),
    why .. ": message should mention " .. needle .. ", got: " .. tostring(err))
end

local function test_a_pin_cannot_be_code()
  refused('return { url = os.getenv("URL") }', "literals only",
    "a function call")
  refused('return { url = "a" .. "b" }', "literals only",
    "concatenation")
  refused('return { url = BASE }', "literals only", "a variable")
  refused('local x = 1\nreturn { url = "u" }', "exactly `return",
    "a statement before the return")
  refused('return { url = "u" }\nprint("side effect")', "ends after its table",
    "anything after the table")
  refused('return "just a string"', "must return a table literal",
    "a non-table return")
  refused('print("hi")', "exactly `return", "no return at all")
  refused('return { "positional" }', "name = <literal>",
    "an array entry with no key")
end
test_a_pin_cannot_be_code()

--- Write a pin file and read it.
local function read_pin(name: string, body: string): pin.Pin | nil, string
  local dir = fs.join(tmpdir, "pin-" .. name)
  assert(fs.makedirs(dir))
  local path = fs.join(dir, name .. ".pin.tl")
  assert(fs.write(path, body))
  return pin.read(path)
end

-- A pin without a digest is a download. The distinction is the entire
-- point, so it is an error rather than a warning.
local function test_a_pin_needs_a_digest()
  local got, err = read_pin("nodigest", 'return { url = "https://x.test/a" }\n')
  assert(not got, "a pin without sha256 must be refused")
  assert(err:find("needs a sha256", 1, true), "got: " .. tostring(err))

  local nourl, uerr = read_pin("nourl", 'return { sha256 = "abcd1234" }\n')
  assert(not nourl, "a pin without a url must be refused")
  assert(uerr:find("needs a url", 1, true), "got: " .. tostring(uerr))
end
test_a_pin_needs_a_digest()

-- `{version}` substitution is the one templating the grammar allows,
-- which is what makes a version bump a one-line diff.
local function test_version_substitution()
  local p = check.must(read_pin("versioned",
      'return {\n  url = "https://x.test/{version}/a.tar.gz",\n' ..
      '  version = "9.9",\n  sha256 = "abcd1234",\n}\n'))
  assert(p.url == "https://x.test/9.9/a.tar.gz", "got: " .. p.url)
  -- P3 in the design's Units investigation: the output name comes from
  -- the URL, NOT from the pin's position in the tree.
  assert(p.output:find("a.tar.gz", 1, true),
    "the output is named by the asset, got: " .. p.output)
end
test_version_substitution()

--- Fork a loopback server answering one request with `body`.
local function serve(body: string): integer, integer
  local srv, port = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local pid = proc.fork()
  if pid == 0 then
    signal.setitimer({
        which = signal.ITIMER_REAL,
        valuesec = 30,
        valuens = 0,
        intervalsec = 0,
        intervalns = 0,
      })
    local conn = s:accept()
    if conn then
      local c = conn as net.Socket -- cast: record union after guard
      local buf = ""
      while not buf:find("\r\n\r\n", 1, true) do
        local data = c:recv(4096)
        if not data or #data == 0 then break end
        buf = buf .. data
      end
      c:send("HTTP/1.1 200 OK\r\nContent-Length: " .. #body ..
        "\r\nConnection: close\r\n\r\n" .. body)
      c:close()
    end
    os.exit(0)
  end
  s:close()
  return math.tointeger(port), pid
end

--- A project holding one pin pointing at `url`.
local function pinned(name: string, url: string, sha: string): string
  local root = fs.join(tmpdir, "fetch-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(fs.join(root, "3p")))
  assert(fs.write(fs.join(root, "main.tl"), "print('x')\n"))
  assert(fs.write(fs.join(root, "3p/blob.pin.tl"),
      'return {\n  url = "' .. url .. '",\n  sha256 = "' .. sha .. '",\n}\n'))
  return root
end

--- Run a verb in process against a named root.
local function run(root: string, ...: string): integer
  local cwd = check.must(fs.getcwd())
  cenv.set("COSMIC_MAKE_ROOT", root)
  local argv: {string} = {}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local code = mk.run(argv)
  cenv.unset("COSMIC_MAKE_ROOT")
  assert(fs.chdir(cwd))
  return code
end

-- The happy path, verified: the bytes arrive, they hash to the pin, and
-- they land at the pin's output.
local function test_fetch_verifies_and_writes()
  local body = "pinned bytes\n"
  local port, pid = serve(body)
  local root = pinned("ok", "http://127.0.0.1:" .. port .. "/blob.bin",
    hash.sha256_hex(body))
  local code = run(root, "fetch")
  proc.wait(pid)
  assert(code == 0, "a matching digest should succeed")
  local got = check.must(fs.read(fs.join(root, "3p/blob.bin")))
  assert(got == body, "the fetched bytes should land at the pin's output")
end
test_fetch_verifies_and_writes()

-- Bytes that do not hash to the pin are never written. Not "written
-- then checked" -- a build either runs on the bytes you named or does
-- not run.
local function test_a_mismatch_is_never_written()
  local port, pid = serve("something else entirely\n")
  local root = pinned("mismatch", "http://127.0.0.1:" .. port .. "/blob.bin",
    hash.sha256_hex("pinned bytes\n"))
  local code = run(root, "fetch")
  proc.wait(pid)
  assert(code == 1, "a digest mismatch must fail")
  assert(not fs.exists(fs.join(root, "3p/blob.bin")),
    "mismatched bytes must never land on disk")
end
test_a_mismatch_is_never_written()

-- A satisfied pin needs no network at all: the check is on the bytes,
-- so the second run is a hash and nothing else. The URL here points at
-- a port nobody is listening on, which is the assertion.
local function test_a_satisfied_pin_does_not_fetch()
  local body = "already here\n"
  local root = pinned("satisfied", "http://127.0.0.1:1/blob.bin",
    hash.sha256_hex(body))
  assert(fs.write(fs.join(root, "3p/blob.bin"), body))
  local code = run(root, "fetch")
  assert(code == 0,
    "a pin whose output already hashes correctly must not need the network")
end
test_a_satisfied_pin_does_not_fetch()

-- The posture, asserted structurally: `fetch` is the only part of
-- --make that can open a socket at all. This is a stronger claim than
-- "one build did not fetch" -- it covers every verb, including the ones
-- later slices add -- and it needs neither a network nor a build. The
-- end-to-end half (a project whose pin points at a dead port still
-- builds) lives in build_test.tl, which already drives a real make.
--
-- Tests are excluded: the claim is about the modules. A test may
-- legitimately reach the network to prove something about fetching,
-- and this file is the proof of that.
local function test_only_fetch_can_open_a_socket()
  local networked: {string} = {}
  local found, cerr = fs.collect("cosmic/_make", "*.tl")
  assert(found, "cannot scan cosmic/_make: " .. tostring(cerr))
  for _, path in ipairs(found as {string}) do -- cast: record union after the guard
    if not path:find("_test%.tl$") then
      local src = check.must(fs.read(path))
      if src:find('require("cosmic.fetch")', 1, true) then
        networked[#networked + 1] = fs.basename(path)
      end
    end
  end
  table.sort(networked)
  assert(table.concat(networked, ",") == "fetch.tl",
    "only the fetch verb may reach the network, but these do: " ..
    table.concat(networked, ", "))
end
test_only_fetch_can_open_a_socket()

-- A pin that is not a pin fails the verb rather than being skipped.
local function test_a_broken_pin_fails_fetch()
  local root = pinned("broken", "http://127.0.0.1:1/x", "abcd1234")
  assert(fs.write(fs.join(root, "3p/blob.pin.tl"),
      'return { url = os.getenv("X") }\n'))
  assert(run(root, "fetch") == 1, "a pin that is code must fail the verb")
end
test_a_broken_pin_fails_fetch()

-- Selection works here too, and an empty selection is an error.
local function test_selection()
  local root = pinned("selected", "http://127.0.0.1:1/x", "abcd1234")
  assert(run(root, "fetch", "nope") == 1, "an empty selection must fail")
end
test_selection()

-- The pin unit's scope is the pin file itself: `resolve` reads nothing
-- else, which is why fetch needs no compiled tree.
local function test_resolve_reads_only_the_pin()
  local root = pinned("scope", "https://x.test/a.bin", "abcd1234")
  local cwd = check.must(fs.getcwd())
  assert(fs.chdir(root))
  local proj = check.must(project.scan("."))
  local pins = check.must(mfetch.resolve(project.of_kind(proj, {"pin"})))
  assert(fs.chdir(cwd))
  assert(#pins == 1, "one pin")
  assert(pins[1].url == "https://x.test/a.bin", "got: " .. pins[1].url)
end
test_resolve_reads_only_the_pin()

print("all pin tests passed")
