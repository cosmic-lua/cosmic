--- `cosmic acme`: a certificate from an ACME certificate authority such
--- as Let's Encrypt, from the command line. [`cosmic.acme`] runs the
--- protocol; this reads the command line, the key files and the
--- challenge's means, and writes what came back.
---
--- `cosmic acme key [--rsa] [--bits N] <file|->` writes a new private key
--- as PEM: P-256 by default, or RSA of 2048, 3072 or 4096 bits. A file
--- gets mode 0600, and one that is there already is refused, since a key
--- written over is an account or a certificate lost.
---
--- `cosmic acme issue --account <file> --key <file> (--webroot <dir> |
--- --dns-hook <program>) [options] <name>...` asks for a certificate for
--- the names and prints the chain as PEM, or writes it to `--out` (`-`:
--- standard output), once its leaf is found to certify `--key` for
--- exactly the names. `--out` is written over, for a renewal, unless it
--- is a key file or holds a private key. When the write fails, the chain,
--- issued already, is printed instead. Each
--- key file is PEM as `key` writes it, or as OpenSSL does
--- ([`Key.read`]), P-256 or RSA. The account is made on the first issue
--- (`--agree-tos` accepts the server's terms; `--contact` names a
--- `mailto:` URL) and found by its key after.
---
--- `--webroot <dir>` answers http-01: the response goes in
--- `<dir>/.well-known/acme-challenge/<token>`, which the web server for
--- each name serves on port 80, and is removed after. `--dns-hook
--- <program>` answers dns-01, the only challenge a wildcard takes: the
--- program runs as `<program> present <record> <value>` before the
--- check and `<program> cleanup <record> <value>` after, with its
--- output on standard error. It puts the TXT record `<record>` with the
--- value `<value>` in the zone, and exits 0 only once the zone's servers
--- answer it. The program is a path (`./hook`), not searched for. A
--- `present` that fails stops the issue, and its `cleanup` does not run.
---
--- The response file and its directories get the process's umask: one
--- of 077 hides them from a web server that runs as another user.
---
--- The directory is Let's Encrypt's production one; `--staging` takes
--- its staging one (untrusted certificates, higher limits), and
--- `--directory <url>` any other, an https URL. Every URL the server
--- hands back is held to https too, and no redirect is followed.
---
--- Like `cosmic json` it prints no summary. Exit 0 is ok, 1 an issue the
--- server or a challenge refused, or a request that failed, 2 a command
--- line or a key file it refuses, 5 a write that failed. Complaints go to standard
--- error as `cosmic: acme: ...`. Its `spec` (build/verb_spec.tl) is
--- `bare`.

local Acme = require("cosmic.acme")
local Child = require("cosmic.child")
local Verb = require("cosmic.cli.acme")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Key = require("cosmic.key")
local sys = require("cosmic.sys")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")

--- The `cosmic acme` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  mut spec: verb_spec.Spec
  --- Where `run` reads and writes and what it sends: what a test stands
  --- in for.
  record Io
    --- Writes to standard output, as given. False and why when the bytes
    --- did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- Reads a file whole: [`Fs.read`].
    read: function(path: string): string?, string
    --- Writes a file whole with a mode: [`Fs.write`].
    write: function(path: string, data: string, mode: integer): boolean, string
    --- Writes a new file whole with a mode, refusing one that is there
    --- (O_EXCL) with the why `<path>` .. [`THERE_ALREADY`].
    create: function(path: string, data: string, mode: integer): boolean, string
    --- Makes a directory and those above it: [`Fs.mkdirs`].
    mkdirs: function(path: string): boolean, string
    --- Removes a file: [`Fs.remove`].
    remove: function(path: string): boolean, string
    --- Runs a hook's command line, its output to standard error: true, or
    --- false and why it did not exit 0.
    run: function(argv: {string}): boolean, string
    --- Sends a request to the ACME server: [`Http.request`].
    request: Acme.Request
    --- Pauses between polls, for nanoseconds: [`Clock.sleep`] when nil.
    pause?: function(ns: integer): boolean, string
  end
end

--- The subcommands, each with the options it takes, as [`cosmic.cli.acme`] describes them.
local subcommands = Verb.subcommands or {}

--- The usage line of the subcommand `sub`, which a refusal ends with; the verb's own where it names none.
local function usage(sub: string): string
  return Flags.usage(Verb, "cosmic acme", { sub })
end

--- Mode 0600: a key file only its owner reads.
local OWNER_ONLY <const> = 0x180
--- Mode 0644: a certificate chain anyone reads.
local READABLE <const> = 0x1a4

local function default_run(argv: {string}): boolean, string
  local result, why = Child.run(argv, { timeout_ns = Child.FOREVER, stdout = 2 })
  if result == nil then return false, tostring(why) end
  if not result.ok then
    local how = if result.code ~= nil then "exited " .. tostring(result.code)
      else "was ended by signal " .. tostring(result.signal or 0) end
    return false, (argv[1] or "") .. " " .. how
  end
  return true, ""
end

--- Why a key file is not written: one is there.
local THERE_ALREADY <const> = ": there already; a key written over is lost, so name a new file"

--- Writes `data` to the new file `path` with `mode`: created with
--- O_EXCL, so a file made there since it was looked for, a link
--- included, is never written through. A write that fails takes the
--- file away again.
local function create(path: string, data: string, mode: integer): boolean, string
  -- TODO: write to a temporary file and link(2) it to `path`, so a crash
  -- mid-write leaves no cut key there, once cosmic.sys carries link.
  local fd, trouble, number = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, mode)
  if fd == nil then
    return false, path .. (if number == sys.EEXIST then THERE_ALREADY else ": " .. trouble end)
  end
  local wrote, why = Fs.put(fd, data)
  local closed, unclosed = Fs.close(fd)
  if not wrote or not closed then
    local _, _ = Fs.remove(path)
    return false, path .. ": " .. tostring(if wrote then unclosed else why end)
  end
  return true, ""
end

local standard: verb.Io = {
  out = bare.out,
  err = bare.err,
  read = function(path: string): string?, string
    local text, why = Fs.read(path)
    if text == nil then return nil, tostring(why) end
    return text, ""
  end,
  write = function(path: string, data: string, mode: integer): boolean, string
    local wrote, written_why = Fs.write(path, data, mode)
    if not wrote then return false, tostring(written_why) end
    return true, ""
  end,
  create = create,
  mkdirs = function(path: string): boolean, string
    local made, why = Fs.mkdirs(path)
    if not made then return false, tostring(why) end
    return true, ""
  end,
  remove = function(path: string): boolean, string
    local removed, why = Fs.remove(path)
    if not removed then return false, tostring(why) end
    return true, ""
  end,
  run = default_run,
  request = function(method: string, url: string, opts: Http.Options): Http.Body?, string
    return Http.request(method, url, opts)
  end,
}

--- `cosmic acme key`: writes a new key to the one word, "-" for standard
--- output.
local function make_key(to: verb.Io, complain: function(line: string), parsed: Flags.Parsed): integer
  if #parsed.words ~= 1 then
    complain(("key takes one file, not %d; %s"):format(#parsed.words, usage("key")))
    return bare.refused
  end
  local file = assert(parsed.words[1])
  if file == "" then
    complain(bare.empty_file .. "; " .. usage("key"))
    return bare.refused
  end
  local bits_word = parsed.values["--bits"]
  local rsa = parsed.set["--rsa"] == true
  if bits_word ~= nil and not rsa then
    complain("--bits is for --rsa; " .. usage("key"))
    return bare.refused
  end
  -- The option's choices, which Flags.parse holds it to, are whole numbers.
  local bits = assert(math.tointeger(tonumber(bits_word or "2048")), "--bits takes only its choices")
  -- No look for a file there first: the exclusive create alone refuses
  -- one, made however lately.
  local key = if rsa then Key.generate("rsa", { bits = bits }) else Key.generate("p256") end
  local pem = key:pem()
  if file == "-" then return bare.written(complain, to.out(pem)) end
  local ok, why = to.create(file, pem, OWNER_ONLY)
  if not ok then
    complain(why)
    return bare.refused
  end
  return bare.ok
end

--- The key in the file the option `name` names, or nil after a complaint.
local function read_key(to: verb.Io, complain: function(line: string), parsed: Flags.Parsed,
                        name: string): Key.Secret?
  local file = parsed.values[name]
  if file == nil or file == "" then
    complain(name .. " names a key file (`cosmic acme key <file>` makes one); " .. usage("issue"))
    return nil
  end
  local text, why = to.read(file)
  if text == nil then
    complain(why)
    return nil
  end
  local key, trouble = Key.read(text)
  if key == nil then
    complain(file .. ": " .. (trouble.message:gsub("^key: ", "")))
    return nil
  end
  if key.alg == "ed25519" then
    complain(file .. ": an Ed25519 key, which ACME servers take none of: make a P-256 or RSA key with `cosmic acme key`")
    return nil
  end
  return key
end

--- `cosmic acme issue`: asks for a certificate for the words, and
--- prints or writes its chain.
local function issue(to: verb.Io, complain: function(line: string), parsed: Flags.Parsed): integer
  local function refuse(line: string): integer
    complain(line .. "; " .. usage("issue"))
    return bare.refused
  end
  if #parsed.words == 0 then return refuse("issue names the certificate's DNS names") end
  local webroot, hook = parsed.values["--webroot"], parsed.values["--dns-hook"]
  if (webroot == nil) == (hook == nil) then
    return refuse("issue takes one of --webroot (http-01) and --dns-hook (dns-01)")
  end
  if webroot == "" or hook == "" then return refuse(bare.empty_file) end
  if hook ~= nil and hook:find("/", 1, true) == nil then
    return refuse("--dns-hook is a path to the program, such as ./" .. hook .. ", which is not searched for")
  end
  local staging, directory = parsed.set["--staging"] == true, parsed.values["--directory"]
  if staging and directory ~= nil then
    return refuse("--staging names a directory, as --directory does")
  end
  -- The client refuses one too, but only once it is asked for something.
  if directory ~= nil and directory:sub(1, 8):lower() ~= "https://" then
    return refuse("--directory is an https URL")
  end
  local out = parsed.values["--out"]
  if out == "" then return refuse(bare.empty_file) end
  if out == "-" then out = nil end
  if out ~= nil and (out == parsed.values["--account"] or out == parsed.values["--key"]) then
    return refuse("--out names a key file, which the chain would write over")
  end
  if out ~= nil then
    -- A file there that holds a private key, by another name for it, is not written over either.
    local there, _ = to.read(out)
    if there ~= nil and there:find("PRIVATE KEY-----", 1, true) ~= nil then
      complain(out .. ": holds a private key, which the chain would write over")
      return bare.refused
    end
  end
  -- Each name once, and each one a DNS name, before anything is sent.
  local names: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, name in ipairs(parsed.words) do
    if seen[name] ~= true then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  local account_key = read_key(to, complain, parsed, "--account")
  if account_key == nil then return bare.refused end
  local key = read_key(to, complain, parsed, "--key")
  if key == nil then return bare.refused end
  if key.public:spki() == account_key.public:spki() then
    complain("--key is the account's key; a certificate takes a key of its own")
    return bare.refused
  end
  local request, invalid = Acme.csr(key, names)
  if request == nil then return refuse((invalid:gsub("^acme: ", ""))) end
  local client = Acme.client({
    directory = directory or (if staging then Acme.LETS_ENCRYPT_STAGING else Acme.LETS_ENCRYPT end),
    key = account_key,
    request = to.request,
    pause = to.pause,
  })
  local agreed = parsed.set["--agree-tos"] == true
  local made, why = client:account({ contact = parsed.all["--contact"], terms_agreed = agreed })
  if made == nil then
    local listed, _ = client:directory()
    local terms = if listed == nil then nil else listed["terms"] end
    if not agreed and terms ~= nil then
      why = why .. " (--agree-tos accepts the terms at " .. terms .. ")"
    end
    complain((why:gsub("^acme: ", "")))
    return bare.failed
  end
  local present: function(c: Acme.Challenge): boolean, string
  local cleanup: function(c: Acme.Challenge)
  local challenge: Acme.ChallengeType = "http-01"
  if webroot ~= nil then
    present = function(c: Acme.Challenge): boolean, string
      local path = webroot .. c.path
      local dir = path:match("^(.*)/[^/]*$") or webroot
      local ok, trouble = to.mkdirs(dir)
      if not ok then return false, trouble end
      return to.write(path, c.key_authorization, READABLE)
    end
    cleanup = function(c: Acme.Challenge)
      local _, _ = to.remove(webroot .. c.path)
    end
  else
    local program = assert(hook)
    challenge = "dns-01"
    present = function(c: Acme.Challenge): boolean, string
      return to.run({ program, "present", c.dns_name, c.dns_value })
    end
    cleanup = function(c: Acme.Challenge)
      local _, _ = to.run({ program, "cleanup", c.dns_name, c.dns_value })
    end
  end
  local chain, trouble = client:issue(names, {
    key = key, challenge = challenge, present = present, cleanup = cleanup,
  })
  if chain == nil then
    complain((trouble:gsub("^acme: ", "")))
    return bare.failed
  end
  if out == nil then return bare.written(complain, to.out(chain)) end
  local ok, write_why = to.write(out, chain, READABLE)
  if not ok then
    -- The certificate is issued, and a server limits how often: print it rather than lose it.
    complain(write_why .. "; the chain follows on standard output instead")
    local _, _ = to.out(chain)
    return bare.refused
  end
  return bare.ok
end

--- `cosmic acme <key|issue> ...`: makes a key, or a certificate, and
--- returns the exit code: 0 ok, 1 an issue that failed, 2 a command
--- line or a file it refuses, 5 a write that failed.
--- @param argv the command line, `acme` at slot 1
--- @param io where files are read and written and requests sent; the process's own when nil
function verb.run(argv: {string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("acme", to.err)
  local sub = argv[2]
  local described = if sub ~= nil then subcommands[sub] else nil end
  if sub == nil or described == nil then
    complain((if sub == nil then "name key or issue" else "no subcommand " .. sub end) .. "; " .. usage(sub or ""))
    return bare.refused
  end
  local none: {string:boolean | Flags.Option} = {}
  local got, trouble = Flags.parse(argv, 3, described.spec or none)
  if got == nil then
    complain(sub .. ": " .. trouble .. "; " .. usage(sub))
    return bare.refused
  end
  local parsed: Flags.Parsed = got
  if sub == "key" then return make_key(to, complain, parsed) end
  return issue(to, complain, parsed)
end

--- The `acme` verb as [`build/verb_list.tl`] lists it. It reads no tree,
--- so it is never stale-checked.
verb.spec = {
  name = "acme",
  guide = "more quick tools",
  tests = { "build.acme_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "key or issue, its options and the names",
  exits = "`acme` prints a key or a chain when no file is named, and nothing after; it exits 1 when the server or a challenge refused an issue or a request failed, 2 when it refuses its command line or a key file, 5 when a write failed.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/acme_test.tl)",
}

return verb
