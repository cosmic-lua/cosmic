--- `cosmic acme` (build/acme.tl), run in this process against the fake
--- ACME server of build/acme_fixture.tl, with its files, hooks and
--- output stood in for: the keys it writes, the challenges it completes
--- and what it refuses.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Key = require("cosmic.key")
local rsa_fixture = require("build.rsa_fixture")
local acme = require("build.acme")
local acme_fixture = require("build.acme_fixture")

local DIRECTORY <const> = acme_fixture.BASE .. "/directory"

local record Ran
  mut code: integer
  mut out: string
  mut err: string
end

--- A stand-in for the files, hooks and network a run reaches.
local record World
  files: mut {string: string}
  modes: mut {string: integer}
  --- Each file present wrote, in order, and each removed.
  written: mut {string}
  removed: mut {string}
  --- Each hook command line, joined by spaces.
  hooks: mut {string}
  mut hook_fails: boolean
  --- Paths whose write fails.
  write_fails: mut {string: boolean}
  mut server: acme_fixture.Server
end

local function new_world(): World
  return { files = {}, modes = {}, written = {}, removed = {}, hooks = {}, hook_fails = false,
    write_fails = {}, server = acme_fixture.new_server() }
end

local function run(world: World, words: {string}): Ran
  local argv: mut {string} = { "acme" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = acme.run(argv, {
    out = function(text: string): boolean, string
      ran.out = ran.out .. text
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    read = function(path: string): string?, string
      local data = world.files[path]
      if data == nil then return nil, path .. ": no such file" end
      return data, ""
    end,
    write = function(path: string, data: string, mode: integer): boolean, string
      if world.write_fails[path] == true then return false, path .. ": read-only file system" end
      world.files[path] = data
      world.modes[path] = mode
      table.insert(world.written, path)
      return true, ""
    end,
    create = function(path: string, data: string, mode: integer): boolean, string
      if world.files[path] ~= nil then return false, path .. ": there already; name a new file" end
      world.files[path] = data
      world.modes[path] = mode
      table.insert(world.written, path)
      return true, ""
    end,
    mkdirs = function(_path: string): boolean, string return true, "" end,
    remove = function(path: string): boolean, string
      world.files[path] = nil
      table.insert(world.removed, path)
      return true, ""
    end,
    run = function(hook: {string}): boolean, string
      table.insert(world.hooks, table.concat(hook, " "))
      if world.hook_fails then return false, (hook[1] or "") .. " exited 1" end
      return true, ""
    end,
    request = world.server.request,
    pause = acme_fixture.no_pause,
  })
  return ran
end

--- A world with an account key and a certificate key in files.
local function keyed(): World
  local world = new_world()
  world.files["account.pem"] = Key.generate("p256"):pem()
  world.files["site.pem"] = Key.generate("p256"):pem()
  return world
end

local function test_key_writes_a_p256_key_only_its_owner_reads()
  local world = new_world()
  local ran = run(world, { "key", "account.pem" })
  assert(ran.code == 0 and ran.out == "" and ran.err == "", ran.err)
  local pem = assert(world.files["account.pem"])
  assert(world.modes["account.pem"] == 0x180, "mode 0600")
  local key = assert(Key.read(pem))
  assert(key.alg == "p256")
end

local function test_key_rsa_prints_an_rsa_key_to_standard_output()
  local world = new_world()
  local ran = run(world, { "key", "--rsa", "-" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  local key = assert(Key.read(ran.out))
  assert(key.alg == "rsa" and #(assert(key.public:jwk()["n"])) == 342, "a 2048-bit modulus")
end

local function test_key_refuses_a_file_that_is_there_and_options_it_does_not_take()
  local world = new_world()
  world.files["account.pem"] = "kept"
  local cases: {{string}} = {
    { "key account.pem", "there already" },
    { "key", "key takes one file, not 0" },
    { "key a.pem b.pem", "key takes one file, not 2" },
    { "key --bits 3072 a.pem", "--bits is for --rsa" },
    { "key --rsa --bits 1024 a.pem", "--bits is 2048, 3072 or 4096, not 1024" },
    { "key --rsa --bits 2048.0 a.pem", "--bits is 2048, 3072 or 4096, not 2048.0" },
    { "key --webroot /var/www a.pem", "--webroot is not an option of key" },
    { "renew a.pem", "no subcommand renew" },
    { "", "name key or issue" },
  }
  for _, case in ipairs(cases) do
    local line, expected = assert(case[1]), assert(case[2])
    local words: mut {string} = {}
    for word in line:gmatch("%S+") do words[#words + 1] = word end
    local ran = run(world, words)
    assert(ran.code == 2 and ran.err:find(expected, 1, true) ~= nil, line .. ": " .. ran.err)
  end
  assert(world.files["account.pem"] == "kept", "the file there is left as it was")
end

local function test_issue_answers_http_01_from_the_webroot_and_writes_the_chain()
  local world = keyed()
  local ran = run(world, { "issue", "--account", "account.pem", "--key", "site.pem", "--directory", DIRECTORY,
    "--webroot", "/var/www", "--agree-tos", "--contact", "mailto:ops@example.com", "--out", "chain.pem",
    "example.com", "www.example.com" })
  assert(ran.code == 0 and ran.out == "" and ran.err == "", ran.err)
  local chain = assert(world.files["chain.pem"])
  assert(chain:find("BEGIN CERTIFICATE", 1, true) ~= nil and world.modes["chain.pem"] == 0x1a4)
  local responses = 0
  for _, path in ipairs(world.written) do
    if path:find("^/var/www/%.well%-known/acme%-challenge/") ~= nil then
      responses = responses + 1
    end
  end
  assert(responses == 2, "a response for each name")
  assert(#world.removed == 2, "and each taken away after")
  local made = assert(world.server.accounts[1])
  assert(made["termsOfServiceAgreed"] == true)
  local csr = acme_fixture.read_csr(world.server.csr)
  local site = assert(Key.read(assert(world.files["site.pem"])))
  local x = assert(Codec.unbase64url(assert(site.public:jwk()["x"])))
  assert(csr.verified and csr.public:sub(2, 33) == x, "the request carries the certificate key")
end

local function test_issue_answers_dns_01_through_the_hook_and_prints_the_chain()
  local world = keyed()
  local ran = run(world, { "issue", "--account", "account.pem", "--key", "site.pem", "--directory", DIRECTORY,
    "--dns-hook", "/usr/local/bin/dns", "*.example.com" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out:find("BEGIN CERTIFICATE", 1, true) ~= nil)
  assert(#world.hooks == 2, table.concat(world.hooks, "\n"))
  local present, cleanup = assert(world.hooks[1]), assert(world.hooks[2])
  assert(present:find("^/usr/local/bin/dns present _acme%-challenge%.example%.com %S+$") ~= nil, present)
  assert(cleanup == (present:gsub(" present ", " cleanup ", 1)), cleanup)
end

local function test_a_hook_that_fails_stops_the_issue_with_exit_1()
  local world = keyed()
  world.hook_fails = true
  local ran = run(world, { "issue", "--account", "account.pem", "--key", "site.pem", "--directory", DIRECTORY,
    "--dns-hook", "/usr/local/bin/dns", "example.com" })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err:find("^cosmic: acme: ") ~= nil and ran.err:find("exited 1", 1, true) ~= nil, ran.err)
end

local function test_issue_refuses_a_line_or_a_key_it_cannot_use()
  local world = keyed()
  world.files["broken.pem"] = "not a key"
  world.files["ed25519.pem"] = Key.generate("ed25519"):pem()
  world.files["other.pem"] = assert(world.files["site.pem"])
  local base = "issue --account account.pem --key site.pem --directory " .. DIRECTORY
  local cases: {{string}} = {
    { base .. " --webroot /w", "issue names the certificate's DNS names" },
    { base .. " example.com", "one of --webroot (http-01) and --dns-hook (dns-01)" },
    { base .. " --webroot /w --dns-hook /h example.com", "one of --webroot" },
    { "issue --key site.pem --webroot /w example.com", "--account names a key file" },
    { "issue --account account.pem --key missing.pem --webroot /w example.com", "missing.pem: no such file" },
    { "issue --account broken.pem --key site.pem --webroot /w example.com", "broken.pem: no private key" },
    { "issue --account ed25519.pem --key site.pem --webroot /w example.com", "ed25519.pem: an Ed25519 key" },
    { "issue --account account.pem --key ed25519.pem --webroot /w example.com", "ed25519.pem: an Ed25519 key" },
    { "issue --account account.pem --key account.pem --webroot /w example.com", "--key is the account's key" },
    { "issue --account account.pem --key site.pem --staging --directory " .. DIRECTORY .. " --webroot /w x.com",
      "--staging names a directory" },
    { base .. " --rsa --webroot /w example.com", "--rsa is not an option of issue" },
    { base .. " --dns-hook dns example.com", "--dns-hook is a path to the program, such as ./dns" },
    { base .. " --webroot /w --out account.pem example.com", "--out names a key file" },
    { base .. " --webroot /w --out site.pem example.com", "--out names a key file" },
    { base .. " --webroot /w --out other.pem example.com", "other.pem: holds a private key" },
    { base .. " --webroot /w example.com bad..com", "\"bad..com\" is not a DNS name" },
  }
  for _, case in ipairs(cases) do
    local line, expected = assert(case[1]), assert(case[2])
    local words: mut {string} = {}
    for word in line:gmatch("%S+") do words[#words + 1] = word end
    local ran = run(world, words)
    assert(ran.code == 2 and ran.err:find(expected, 1, true) ~= nil, line .. ": " .. ran.err)
  end
  assert(#world.server.log == 0, "nothing is sent for a line refused")
end

local function test_an_rsa_certificate_key_is_taken()
  local world = keyed()
  world.files["rsa.pem"] = assert(Key.secret("rsa", rsa_fixture.FIRST)):pem()
  local ran = run(world, { "issue", "--account", "account.pem", "--key", "rsa.pem", "--directory", DIRECTORY,
    "--webroot", "/w", "example.com" })
  assert(ran.code == 0, ran.err)
  assert(acme_fixture.read_csr(world.server.csr).verified)
end

local function test_names_are_asked_for_once_each()
  local world = keyed()
  local ran = run(world, { "issue", "--account", "account.pem", "--key", "site.pem", "--directory", DIRECTORY,
    "--webroot", "/w", "example.com", "example.com" })
  assert(ran.code == 0, ran.err)
  local responses = 0
  for _, path in ipairs(world.written) do
    if path:find("^/w/%.well%-known/acme%-challenge/") ~= nil then responses = responses + 1 end
  end
  assert(responses == 1, "one authorization for the name given twice")
end

local function test_out_dash_prints_the_chain()
  local world = keyed()
  local ran = run(world, { "issue", "--account", "account.pem", "--key", "site.pem", "--directory", DIRECTORY,
    "--webroot", "/w", "--out", "-", "example.com" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.out:find("BEGIN CERTIFICATE", 1, true) ~= nil and world.files["-"] == nil)
end

local function test_a_chain_that_cannot_be_written_is_printed_instead()
  local world = keyed()
  world.write_fails["chain.pem"] = true
  local ran = run(world, { "issue", "--account", "account.pem", "--key", "site.pem", "--directory", DIRECTORY,
    "--webroot", "/w", "--out", "chain.pem", "example.com" })
  assert(ran.code == 2, ran.err)
  assert(ran.err:find("chain.pem: read-only file system; the chain follows on standard output instead", 1, true) ~=
      nil, ran.err)
  assert(ran.out:find("BEGIN CERTIFICATE", 1, true) ~= nil, "the chain is not lost")
end

--- The process's own files: the exclusive create, its mode, and its
--- refusal of a file there (here one made first, as another process
--- could at any moment).
local function test_key_creates_its_file_exclusively(tmp: string)
  local path = tmp .. "/account.pem"
  assert(acme.run({ "acme", "key", path }) == 0)
  local made = assert(Fs.read(path))
  assert(Key.read(made))
  assert((assert(Fs.stat(path)).mode & 0x1ff) == 0x180)
  assert(acme.run({ "acme", "key", path }) == 2)
  assert(assert(Fs.read(path)) == made, "a key there was written over")
  local link = tmp .. "/link.pem"
  assert(Fs.symlink(tmp .. "/elsewhere.pem", link))
  assert(acme.run({ "acme", "key", link }) == 2)
  assert(not assert(Fs.status(tmp .. "/elsewhere.pem")).exists, "a link was written through")
end

local function test_issue_refuses_a_directory_that_is_not_https()
  local world = keyed()
  local ran = run(world, { "issue", "--account", "account.pem", "--key", "site.pem", "--directory",
    "http://acme.test/directory", "--webroot", "/w", "example.com" })
  assert(ran.code == 2 and ran.err:find("--directory is an https URL", 1, true) ~= nil, ran.err)
  assert(#world.server.log == 0, "nothing is sent")
end

local function test_a_hook_is_never_run_for_a_name_not_asked_for()
  local world = keyed()
  world.server.shown = function(_domain: string, wildcard: boolean): acme_fixture.Identifier
    return { type = "dns", value = "evil.example", wildcard = wildcard }
  end
  local ran = run(world, { "issue", "--account", "account.pem", "--key", "site.pem", "--directory", DIRECTORY,
    "--dns-hook", "/usr/local/bin/dns", "example.com" })
  assert(ran.code == 1 and ran.err:find("evil.example, which was not asked for", 1, true) ~= nil, ran.err)
  assert(#world.hooks == 0, table.concat(world.hooks, "\n"))
end

local function test_a_chain_for_another_key_is_never_written_over_out()
  local world = keyed()
  world.files["chain.pem"] = "the chain served now"
  world.server.leaf_spki = Key.generate("p256").public:spki()
  local ran = run(world, { "issue", "--account", "account.pem", "--key", "site.pem", "--directory", DIRECTORY,
    "--webroot", "/w", "--out", "chain.pem", "example.com" })
  assert(ran.code == 1 and ran.err:find("not for the certificate's key", 1, true) ~= nil, ran.err)
  assert(world.files["chain.pem"] == "the chain served now" and ran.out == "", ran.out)
end
