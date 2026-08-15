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
local czip = require("cosmic.zip")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local mfetch = require("_make.fetch")
local mk = require("_make")
local net = require("cosmic.net")
local pin = require("_make.pin")
local proc = require("cosmic.proc")
local project = require("_make.project")
local sys = require("cosmic.sys")
local signal = require("cosmic.signal")
local cenv = require("cosmic.env")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Extract a pin from source text, for the grammar tests.
local function ext(source: string): {string: any} | nil, string
  return pin.extract(source, "p_pin.tl")
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
  assert(fs.make_dirs(dir))
  local path = fs.join(dir, name .. "_pin.tl")
  assert(fs.write(path, body))
  return pin.read(path)
end

-- A pin without a digest is a download. The distinction is the entire
-- point, so it is an error rather than a warning.
local function test_a_pin_needs_a_digest()
  local got, err = read_pin("nodigest", 'return { url = "https://x.test/a" }\n')
  assert(not got, "a pin without sha256 must be refused")
  assert(err:find("needs a sha256", 1, true), "got: " .. tostring(err))

  local nourl, uerr = read_pin("nourl",
    'return { sha256 = "abababababababababababababababababababababababababababababababab" }\n')
  assert(not nourl, "a pin without a url must be refused")
  assert(uerr:find("needs a url", 1, true), "got: " .. tostring(uerr))
end
test_a_pin_needs_a_digest()

-- `{version}` substitution is the one templating the grammar allows,
-- which is what makes a version bump a one-line diff.
local function test_version_substitution()
  local p = check.must(read_pin("versioned",
      'return {\n  url = "https://x.test/{version}/a.tar.gz",\n' ..
      '  version = "9.9",\n  sha256 = "abababababababababababababababababababababababababababababababab",\n}\n'))
  assert(p.url == "https://x.test/9.9/a.tar.gz", "got: " .. p.url)
  -- The output name comes from the URL, NOT from the pin's position in
  -- the tree.
  assert(p.output:find("a.tar.gz", 1, true),
    "the output is named by the asset, got: " .. p.output)
end
test_version_substitution()

--- Fork a loopback server answering one request with `body`, under
--- `status` (default 200).
local function serve(body: string, status?: integer): integer, integer
  local srv = net.listen_tcp("127.0.0.1", 0)
  local s = check.must(srv, "listen_tcp failed")
  local port = check.must(s:local_endpoint()).port
  local pid = proc.fork()
  if pid == 0 then
    assert(signal.setitimer({
          which = signal.ITIMER_REAL,
          value_ms = 30000,
          interval_ms = 0,
        }))
    local conn = s:accept()
    if conn then
      local c = conn
      local buf = ""
      while not buf:find("\r\n\r\n", 1, true) do
        local data = c:recv(4096)
        if not data or #data == 0 then break end
        buf = buf .. data
      end
      local code = status or 200
      assert(c:send("HTTP/1.1 " .. code .. " " ..
          (code == 200 and "OK" or "Not Found") .. "\r\nContent-Length: " ..
          #body .. "\r\nConnection: close\r\n\r\n" .. body))
      assert(c:close())
    end
    os.exit(0)
  end
  assert(s:close())
  return math.tointeger(port), pid
end

--- A project holding one pin pointing at `url`.
local function pinned(name: string, url: string, sha: string): string
  local root = fs.join(tmpdir, "fetch-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(fs.join(root, "3p")))
  assert(fs.write(fs.join(root, "main.tl"), "print('x')\n"))
  assert(fs.write(fs.join(root, "3p/blob_pin.tl"),
      'return {\n  url = "' .. url .. '",\n  sha256 = "' .. sha .. '",\n}\n'))
  return root
end

--- Run a verb in process against a named root.
local function run(root: string, ...: string): integer
  local cwd = check.must(fs.cwd())
  assert(cenv.set("COSMIC_MAKE_ROOT", root))
  local argv: {string} = {}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local code = mk.run(argv)
  assert(cenv.unset("COSMIC_MAKE_ROOT"))
  assert(fs.set_cwd(cwd))
  return code
end

--- Run a verb, returning its exit code and what it wrote to stderr.
---
--- Diagnostics are the assertion for some of these -- "which failure
--- was this" is the whole point -- and `mk.run` reports only a code.
--- Swapping the handle is the pattern envd_test already uses.
local function run_out(root: string, ...: string): integer, string
  local path = fs.join(tmpdir, "pin-stderr.txt")
  local real = io.stderr
  io.stderr = assert(io.open(path, "w"))
  local code = run(root, ...)
  io.stderr:close()
  io.stderr = real
  return code, fs.read(path) or ""
end

-- The happy path, verified: the bytes arrive, they hash to the pin, and
-- they land at the pin's output.
local function test_fetch_verifies_and_writes()
  local body = "pinned bytes\n"
  local port, pid = serve(body)
  local root = pinned("ok", "http://127.0.0.1:" .. port .. "/blob.bin",
    hash.sha256_hex(body))
  local code = run(root, "fetch")
  assert(proc.wait(pid))
  assert(code == 0, "a matching digest should succeed")
  -- Under the build directory, mirroring the pin's position: a fetched
  -- archive is generated content, and beside its pin it would be a file
  -- `check` sees, `lint` scans, and a clean checkout does not have.
  local got = check.must(fs.read(fs.join(root, "o/3p/blob.bin")))
  assert(got == body, "the fetched bytes should land under o/")
  assert(not fs.is_present(fs.join(root, "3p/blob.bin")),
    "and never beside the pin, in the tree")
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
  assert(proc.wait(pid))
  assert(code == 1, "a digest mismatch must fail")
  -- The LANDING path, under `o/`, not the pin's own directory: asserting
  -- against the pin's own directory would check a path nothing writes
  -- to and pass vacuously, leaving the security property unasserted.
  assert(not fs.is_present(fs.join(root, "o/3p/blob.bin")),
    "mismatched bytes must never land on disk")
  assert(not fs.is_present(fs.join(root, "o/3p/blob.bin.tmp")),
    "and no partial file may survive either")
end
test_a_mismatch_is_never_written()

-- A satisfied pin needs no network at all: the check is on the bytes,
-- so the second run is a hash and nothing else. The URL here points at
-- a port nobody is listening on, which is the assertion.
local function test_a_satisfied_pin_does_not_fetch()
  local body = "already here\n"
  local root = pinned("satisfied", "http://127.0.0.1:1/blob.bin",
    hash.sha256_hex(body))
  assert(fs.make_dirs(fs.join(root, "o/3p")))
  assert(fs.write(fs.join(root, "o/3p/blob.bin"), body))
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
  local found, cerr = fs.find("_make", {glob = "*.tl"})
  assert(found, "cannot scan _make: " .. tostring(cerr))
  for _, path in ipairs(found) do
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
  local root = pinned("broken", "http://127.0.0.1:1/x", "abababababababababababababababababababababababababababababababab")
  assert(fs.write(fs.join(root, "3p/blob_pin.tl"),
      'return { url = os.getenv("X") }\n'))
  assert(run(root, "fetch") == 1, "a pin that is code must fail the verb")
end
test_a_broken_pin_fails_fetch()

-- Selection works here too, and an empty selection is an error.
local function test_selection()
  local root = pinned("selected", "http://127.0.0.1:1/x", "abababababababababababababababababababababababababababababababab")
  assert(run(root, "fetch", "nope") == 1, "an empty selection must fail")
end
test_selection()

-- The pin unit's scope is the pin file itself: `resolve` reads nothing
-- else, which is why fetch needs no compiled tree.
local function test_resolve_reads_only_the_pin()
  local root = pinned("scope", "https://x.test/a.bin", "abababababababababababababababababababababababababababababababab")
  local cwd = check.must(fs.cwd())
  assert(fs.set_cwd(root))
  local proj = check.must(project.scan("."))
  local pins = check.must(mfetch.resolve(project.of_kind(proj, {"pin"})))
  assert(fs.set_cwd(cwd))
  assert(#pins == 1, "one pin")
  assert(pins[1].url == "https://x.test/a.bin", "got: " .. pins[1].url)
end
test_resolve_reads_only_the_pin()

print("all pin tests passed")

-- A pin that declares a format is unpacked beside the archive it
-- verified. That ordering is the property, not an implementation
-- detail: an archive is a program for a decompressor, so it is only
-- ever run on bytes whose digest already matched.
local function test_a_declared_format_is_unpacked()
  -- A zip built here, so the test needs no fixture on disk: one file
  -- under a wrapper directory, which is what strip_components exists
  -- for (a release tarball names its wrapper after the tag).
  local archive = fs.join(tmpdir, "payload.zip")
  local w = check.must(czip.open(archive, {mode = "write"}))
  assert(w:add("wrapper-1.0/tl.lua", "return 'teal'\n"))
  assert(w:add("wrapper-1.0/deep/other.txt", "x\n"))
  assert(w:close())
  local body = check.must(fs.read(archive))

  local port, pid = serve(body)
  local root = pinned("unpacked", "http://127.0.0.1:" .. port .. "/payload.zip",
    hash.sha256_hex(body))
  -- Rewrite the pin with a format and a wrapper to strip.
  assert(fs.write(fs.join(root, "3p/blob_pin.tl"),
      'return {\n  url = "http://127.0.0.1:' .. port .. '/payload.zip",\n' ..
      '  sha256 = "' .. hash.sha256_hex(body) .. '",\n' ..
      '  format = "zip",\n  strip_components = 1,\n}\n'))
  local code = run(root, "fetch")
  assert(proc.wait(pid))
  assert(code == 0, "a pin with a format should fetch and unpack")

  local got = check.must(fs.read(fs.join(root, "o/3p/tl.lua")))
  assert(got == "return 'teal'\n", "the wrapper directory is stripped away")
  assert(fs.is_file(fs.join(root, "o/3p/deep/other.txt")),
    "and the rest of the tree keeps its shape")
  assert(fs.is_file(fs.join(root, "o/3p/payload.zip")),
    "the verified archive stays beside what came out of it")
  assert(not fs.is_present(fs.join(root, "o/3p/.unpack")),
    "and the staging directory does not survive")
end
test_a_declared_format_is_unpacked()

-- A pin may name its digest per platform, because some artifacts
-- differ per host. Both spellings exist because this reader and the
-- older `_build` fetcher read the same committed files, and a pin that
-- had to be written twice is a pin that can disagree with itself.
local function test_a_pin_may_name_its_digest_per_platform()
  local sha = string.rep("ab", 32)
  local shared = check.must(read_pin("anyplat",
      'return {\n  url = "https://x.test/a-{version}.zip",\n' ..
      '  version = "1.0",\n  format = "zip",\n' ..
      '  platforms = {["*"] = {sha = "' .. sha .. '"}},\n}\n'))
  assert(shared.sha256 == sha, "the '*' row answers for every host")
  assert(shared.platform == "*", "and says so")
  assert(shared.format == "zip", "a top-level format still applies")
  assert(shared.url == "https://x.test/a-1.0.zip", "{version} still substitutes")

  local host = sys.platform()
  local exact = check.must(read_pin("hostplat",
      'return {\n  url = "https://x.test/{platform}/a.bin",\n' ..
      '  platforms = {\n' ..
      '    ["' .. host .. '"] = {sha = "' .. sha .. '", format = "gz"},\n' ..
      '    ["*"] = {sha = "' .. string.rep("cd", 32) .. '"},\n  },\n}\n'))
  assert(exact.sha256 == sha, "the host's own row wins over '*'")
  assert(exact.platform == host, "and names the tag it matched")
  assert(exact.format == "gz", "a row may carry the format too")
  assert(exact.url == "https://x.test/" .. host .. "/a.bin",
    "{platform} substitutes the tag that matched")

  local none, nerr = read_pin("noplat",
    'return {\n  url = "https://x.test/a",\n' ..
    '  platforms = {["nosuch-arch"] = {sha = "' .. sha .. '"}},\n}\n')
  assert(not none, "a platforms table with no matching row is refused")
  assert(nerr:find("no platform row", 1, true), "got: " .. tostring(nerr))
end
test_a_pin_may_name_its_digest_per_platform()

-- A pin that unpacks has TWO outputs, and only one is
-- content-addressed. Hashing the archive alone answered "did the bytes
-- arrive", never "did they come out": an unpack that failed once left
-- a correctly-hashing archive that made every later fetch report PASS
-- over a missing tree.
local function test_a_missing_unpack_is_redone()
  local archive = fs.join(tmpdir, "redo.zip")
  local w = check.must(czip.open(archive, {mode = "write"}))
  assert(w:add("tl.lua", "return 'teal'\n"))
  assert(w:close())
  local body = check.must(fs.read(archive))

  local port, pid = serve(body)
  local root = pinned("redo", "http://127.0.0.1:" .. port .. "/redo.zip",
    hash.sha256_hex(body))
  assert(fs.write(fs.join(root, "3p/blob_pin.tl"),
      'return {\n  url = "http://127.0.0.1:' .. port .. '/redo.zip",\n' ..
      '  sha256 = "' .. hash.sha256_hex(body) .. '",\n  format = "zip",\n}\n'))
  assert(run(root, "fetch") == 0, "the first fetch should unpack")
  assert(proc.wait(pid))
  local out = fs.join(root, "o/3p/tl.lua")
  assert(fs.is_file(out), "unpack produced the tree")

  -- Delete the unpacked tree, keep the archive: the exact poisoned
  -- state a failed unpack leaves behind. No server is listening now,
  -- so a re-download would fail -- repairing from the verified archive
  -- is the assertion.
  assert(fs.remove_all(out))
  assert(run(root, "fetch") == 0, "the second fetch should repair, not refetch")
  assert(fs.is_file(out), "the unpacked tree is restored")
end
test_a_missing_unpack_is_redone()

-- `Result.ok` is transport-level, so an unchecked 404 error page
-- reaches the digest check and fails as a sha256 mismatch -- the wrong
-- diagnosis for the commonest cause, a typo'd version in the url.
local function test_a_non_2xx_names_the_status()
  local port, pid = serve("<html>not found</html>\n", 404)
  local root = pinned("status", "http://127.0.0.1:" .. port .. "/blob.bin",
    hash.sha256_hex("pinned bytes\n"))
  local code, out = run_out(root, "fetch")
  assert(proc.wait(pid))
  assert(code == 1, "a 404 must fail")
  assert(out:find("HTTP 404", 1, true),
    "the message names the status, got: " .. out)
  assert(not out:find("mismatch", 1, true),
    "and does not blame the digest, got: " .. out)
end
test_a_non_2xx_names_the_status()

-- A truncated digest is a copy-paste slip. Accepting one (any run of
-- eight or more hex characters) defers it to fetch time as a mismatch,
-- pointing the reader at the url instead of the pin.
local function test_a_short_digest_is_refused()
  local short, err = read_pin("shortsha",
    'return { url = "https://x.test/a", sha256 = "abcd1234" }\n')
  assert(not short, "an 8-hex digest must be refused")
  assert(err:find("64 hex", 1, true), "got: " .. tostring(err))

  -- The landing path is derived from the url's last segment, so that
  -- segment reaches `fs.join` and has to be a file name and nothing
  -- else. `..` would climb out of the pin's mirrored position.
  local dots, derr = read_pin("dotsname",
    'return {\n  url = "https://x.test/a/..",\n' ..
    '  sha256 = "' .. string.rep("ab", 32) .. '",\n}\n')
  assert(not dots, "a url whose tail is '..' must be refused")
  assert(derr:find("usable file name", 1, true), "got: " .. tostring(derr))

  local query, qerr = read_pin("queryname",
    'return {\n  url = "https://x.test/a.zip?token=secret",\n' ..
    '  sha256 = "' .. string.rep("ab", 32) .. '",\n}\n')
  assert(not query, "a url with a query string must be refused")
  assert(qerr:find("usable file name", 1, true), "got: " .. tostring(qerr))
end
test_a_short_digest_is_refused()
