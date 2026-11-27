--- `cosmic tailscale` (build/tailscale.tl), run in this process against a
--- stand-in tailscaled: a [`Server.serve`] on a socket of the test's own
--- that responds to the LocalAPI paths with the JSON the daemon writes.
--- The verb runs in a task of the stand-in's own run, as a call of
--- [`cosmic.tailscale`] waits as one, with its output and files stood in
--- for.

local Array = require("cosmic.array")
local type Failure = require("cosmic.failure")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Tailscale = require("cosmic.tailscale")
local Test = require("cosmic.test")
local tailscale = require("build.tailscale")

Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, requires = { "unix_socket" } }

local WHOIS <const> = [[{
  "Node": {"ID": 7, "StableID": "nABC1CNTRL", "Name": "laptop.tail1234.ts.net.", "User": 42,
    "Addresses": ["100.64.0.2/32", "fd7a:115c:a1e0::2/128"], "Tags": null,
    "Hostinfo": {"Hostname": "laptop", "OS": "macOS"}},
  "UserProfile": {"ID": 42, "LoginName": "will@example.com", "DisplayName": "Will"},
  "CapMap": {"example.com/cap/read": null, "example.com/cap/admin": [{"level": "all"}]}
}]]

local TAGGED <const> = [[{
  "Node": {"ID": 8, "StableID": "nDEF2CNTRL", "Name": "db.tail1234.ts.net.", "User": 9,
    "Addresses": ["100.64.0.3/32"], "Tags": ["tag:db", "tag:prod"]},
  "UserProfile": {"ID": 9, "LoginName": "tagged-devices", "DisplayName": "Tagged Devices"}
}]]

local STATUS <const> = [[{
  "Version": "1.90.0", "BackendState": "Running", "TailscaleIPs": ["100.64.0.1"],
  "Self": {"ID": "nSELF", "HostName": "box", "DNSName": "box.tail1234.ts.net.", "OS": "linux",
    "UserID": 42, "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"], "Online": true, "Active": false,
    "ExitNode": false, "ExitNodeOption": false, "Relay": "", "CurAddr": ""},
  "Health": ["Tailscale can't reach the configured DNS servers."], "MagicDNSSuffix": "tail1234.ts.net",
  "CurrentTailnet": {"Name": "example.com", "MagicDNSSuffix": "tail1234.ts.net", "MagicDNSEnabled": true},
  "CertDomains": ["box.tail1234.ts.net"],
  "Peer": {
    "nodekey:bb": {"ID": "nZ", "HostName": "zed", "DNSName": "zed.tail1234.ts.net.", "OS": "linux",
      "UserID": 9, "TailscaleIPs": ["100.64.0.9"], "Tags": ["tag:db"], "Online": false, "Active": false,
      "ExitNode": false, "ExitNodeOption": true, "Relay": "fra", "CurAddr": "",
      "LastSeen": "2026-11-20T10:00:00Z"},
    "nodekey:cc": {"ID": "nM", "HostName": "mid", "DNSName": "mid.tail1234.ts.net.", "OS": "windows",
      "UserID": 77, "TailscaleIPs": ["100.64.0.5"], "Online": true, "Active": true,
      "ExitNode": false, "ExitNodeOption": false, "Relay": "nyc", "CurAddr": ""},
    "nodekey:dd": {"ID": "nS", "HostName": "six", "DNSName": "", "OS": "",
      "UserID": 42, "TailscaleIPs": ["fd7a:115c:a1e0::6"], "Online": true, "Active": false,
      "ExitNode": false, "ExitNodeOption": false, "Relay": "", "CurAddr": ""},
    "nodekey:aa": {"ID": "nA", "HostName": "alpha", "DNSName": "alpha.tail1234.ts.net.", "OS": "macOS",
      "UserID": 42, "TailscaleIPs": ["100.64.0.2"], "Online": true, "Active": true,
      "ExitNode": false, "ExitNodeOption": false, "Relay": "fra", "CurAddr": "192.0.2.1:41641"}
  },
  "User": {"42": {"ID": 42, "LoginName": "will@example.com", "DisplayName": "Will"},
    "9": {"ID": 9, "LoginName": "tagged-devices", "DisplayName": "Tagged Devices"}}
}]]

--- A peer whose names, OS and tags carry escape sequences and control
--- bytes, each its own choice: a title change (OSC 0), a clear screen, a
--- C1 CSI, a right-to-left override, a carriage return and a newline.
local HOSTILE <const> = [[{
  "Version": "1.90.0", "BackendState": "Running", "TailscaleIPs": ["100.64.0.1"], "MagicDNSSuffix": "ts.net",
  "Peer": {
    "nodekey:ee": {"ID": "nE", "HostName": "evil", "DNSName": "evil\u001b]0;owned\u0007.ts.net.",
      "OS": "linux\u001b[2J\u202e", "UserID": 66, "TailscaleIPs": ["100.64.0.66"], "Tags": ["tag:x\u009b31m"],
      "Online": true, "Active": false, "ExitNode": false, "ExitNodeOption": false, "Relay": "", "CurAddr": ""}
  },
  "User": {}
}]]

local HOSTILE_WHOIS <const> = [[{
  "Node": {"ID": 66, "StableID": "nEVIL", "Name": "evil\u001b[31m.ts.net.", "User": 66,
    "Addresses": ["100.64.0.66/32"], "Hostinfo": {"Hostname": "evil", "OS": "linux\r\nos  forged"}},
  "UserProfile": {"ID": 66, "LoginName": "mallory\u001b[8m@example.com", "DisplayName": "Mal\u009d0;x\u009c"}
}]]

local NO_HTTPS <const> = [[{"Version": "1.90.0", "BackendState": "NeedsLogin",
  "AuthURL": "https://login.tailscale.com/a/x", "MagicDNSSuffix": ""}]]

local PAIR <const> = "-----BEGIN EC PRIVATE KEY-----\nKEY\n-----END EC PRIVATE KEY-----\n" ..
  "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n"

--- What a run printed and wrote, and what the stand-in was asked.
local record Ran
  mut code: integer
  mut out: string
  mut err: string
  files: mut {string: string}
  modes: mut {string: integer}
  seen: mut {string}
  --- Each file renamed into place, in order.
  renamed: mut {string}
  --- The files the stand-in holds for Taildrop, by name.
  waiting: mut {string: string}
  --- The files put to it, by `target/name`.
  put: mut {string: string}
  --- What standard input holds, where it is not a terminal.
  mut stdin?: string
end

local TARGETS <const> = [=[[
  {"Node": {"ID": 2, "StableID": "nALPHA", "Name": "alpha.tail1234.ts.net.", "User": 42,
    "Addresses": ["100.64.0.2/32"], "Hostinfo": {"Hostname": "alpha", "OS": "macOS"}},
   "PeerAPIURL": "http://100.64.0.2:41000"},
  {"Node": {"ID": 9, "StableID": "nZED", "Name": "zed.tail1234.ts.net.", "User": 42,
    "Addresses": ["100.64.0.9/32"]}, "PeerAPIURL": "http://100.64.0.9:41000"}
]]=]

--- A file a run writes, kept in `ran.files` once it is closed.
local class Sink is Stream.Writer
  ran: Ran
  path: string
  parts: mut {string}

  function write(self, chunk: string): (true) | (nil, Failure)
    self.parts[#self.parts + 1] = chunk
    return true
  end

  function close(self): (true) | (nil, Failure)
    self.ran.files[self.path] = table.concat(self.parts)
    return true
  end

  function abort(self): (true) | (nil, Failure)
    return true
  end
end

--- The stand-in's response to a Taildrop path, or nil for another.
local function file_answer(ran: Ran, req: Server.Request): Server.Reply?
  local target = req.target
  if target == "/localapi/v0/file-targets" then return { status = 200, body = TARGETS } end
  local to, name = target:match("^/localapi/v0/file%-put/([^/]+)/(.+)$")
  if to ~= nil then
    ran.put[to .. "/" .. assert(name)] = assert(Stream.read_all(req.body))
    return { status = 200, body = "{}\n" }
  end
  if target == "/localapi/v0/files/" or target:match("^/localapi/v0/files/%?") ~= nil then
    local names: mut {string} = {}
    for file in pairs(ran.waiting) do names[#names + 1] = file end
    table.sort(names)
    local items: mut {string} = {}
    for _, file in ipairs(names) do
      items[#items + 1] = ('{"Name": "%s", "Size": %d}'):format(file, #assert(ran.waiting[file]))
    end
    return { status = 200, body = "[" .. table.concat(items, ",") .. "]" }
  end
  local file = target:match("^/localapi/v0/files/(.+)$")
  if file == nil then return nil end
  local plain = file:gsub("%%(%x%x)", function(hex: string): string
    return string.char(assert(math.tointeger(tonumber(hex, 16))))
  end)
  local data = ran.waiting[plain]
  if data == nil then return { status = 404, body = "file not found\n" } end
  if req.method == "DELETE" then
    ran.waiting[plain] = nil
    return { status = 204 }
  end
  return { status = 200, body = data }
end

--- The stand-in's response to `target`; `status` is the status reply.
local function answer(target: string, status: string): Server.Reply
  if target == "/localapi/v0/status" or target == "/localapi/v0/status?peers=false" then
    return { status = 200, body = status }
  end
  if target == "/localapi/v0/whois?addr=100.64.0.2" then return { status = 200, body = WHOIS } end
  if target == "/localapi/v0/whois?addr=100.64.0.3" then return { status = 200, body = TAGGED } end
  if target == "/localapi/v0/whois?addr=100.64.0.66" then
    return { status = 200, body = HOSTILE_WHOIS }
  end
  if target:match("^/localapi/v0/whois%?") ~= nil then
    return { status = 404, body = "no match for IP:port\n" }
  end
  if target:match("^/localapi/v0/cert/box%.tail1234%.ts%.net%?type=pair") ~= nil then
    return { status = 200, body = PAIR }
  end
  if target:match("^/localapi/v0/cert/") ~= nil then
    return { status = 403, body = "cert access denied\n" }
  end
  if target == "/localapi/v0/ping?ip=100.64.0.2&type=disco" then
    return { status = 200, body = '{"LatencySeconds": 0.0125, "Endpoint": "192.0.2.1:41641"}' }
  end
  if target == "/localapi/v0/ping?ip=100.64.0.9&type=TSMP" then
    return { status = 200, body = '{"LatencySeconds": 0.08, "DERPRegionCode": "fra"}' }
  end
  return { status = 404, body = "404 page not found\n" }
end

--- How many runs this process made: each takes a socket of its own.
local runs = 0

--- `cosmic tailscale <words>` against the stand-in at a socket under
--- `tmp`, which responds with `status` for the status (STATUS by
--- default). With `no_socket` the command line names none, and the
--- run's connect is handed the stand-in's anyway.
local function run(tmp: string, words: {string}, status?: string, no_socket?: boolean, setup?: function(Ran)): Ran
  local ran: Ran = { code = -1, out = "", err = "", files = {}, modes = {}, seen = {}, renamed = {},
    waiting = {}, put = {} }
  if setup ~= nil then setup(ran) end
  runs = runs + 1
  local socket = tmp .. "/ts" .. tostring(runs) .. ".sock"
  assert(Server.serve{
    listeners = { Net.unix(socket) },
    on_stop = function(_: Net.Server) end,
    handle = function(req: Server.Request): Server.Reply
      ran.seen[#ran.seen + 1] = req.method .. " " .. req.target
      local filed = file_answer(ran, req)
      if filed ~= nil then return filed end
      return answer(req.target, status or STATUS)
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local path = assert(Array.at(addresses, 1).path)
      local argv: mut {string} = { "tailscale" }
      for _, word in ipairs(words) do argv[#argv + 1] = word end
      if no_socket ~= true then
        argv[#argv + 1] = "--socket"
        argv[#argv + 1] = path
      end
      ran.code = tailscale.run(argv, {
        out = function(text: string): boolean, string
          ran.out = ran.out .. text
          return true, ""
        end,
        err = function(line: string) ran.err = ran.err .. line .. "\n" end,
        write = function(file: string, data: string, mode: integer): boolean, string
          if file:match("^/ro/") ~= nil then return false, file .. ": read-only file system" end
          ran.files[file] = data
          ran.modes[file] = mode
          return true, ""
        end,
        rename = function(from: string, into: string): boolean, string
          local data = ran.files[from]
          if data == nil then return false, from .. ": no such file" end
          ran.files[into], ran.modes[into] = data, assert(ran.modes[from])
          ran.files[from], ran.modes[from] = nil, nil
          ran.renamed[#ran.renamed + 1] = into
          return true, ""
        end,
        open = function(file: string): tailscale.Opened?, string
          local data = ran.files[file]
          if data == nil then return nil, file .. ": No such file or directory" end
          return { reader = Stream.from_string(data), size = #data }, ""
        end,
        stdin = function(): string?, string
          local text = ran.stdin
          if text == nil then return nil, "standard input is a terminal" end
          return text, ""
        end,
        create = function(file: string): Stream.Writer?, string
          if file:match("^/ro/") ~= nil then return nil, file .. ": read-only file system" end
          local sink: Sink = { ran = ran, path = file, parts = {} }
          return sink, ""
        end,
        exists = function(file: string): boolean?, string return ran.files[file] ~= nil, "" end,
        is_dir = function(file: string): boolean
          return file == "/in" or file == "/" or file:match("^/ro") ~= nil
        end,
        connect = function(opts: Tailscale.Daemon): Tailscale.Client?, string
          local client, why = Tailscale.connect({ socket = opts.socket or path })
          if client == nil then return nil, tostring(why) end
          return client, ""
        end,
      })
      server:stop()
    end,
  })
  return ran
end

--- Status lists this node first, then each peer by name, their columns
--- lined up: owner or tags, OS, and how traffic reaches it.
local function test_status_lists_the_node_and_its_peers_in_columns(tmp: string)
  local ran = run(tmp, { "status" })
  assert(ran.code == 0, ran.err)
  assert(ran.out == table.concat({
    "100.64.0.1         box.tail1234.ts.net    will@example.com  linux    this node",
    "fd7a:115c:a1e0::6  -                      will@example.com  -        -",
    "100.64.0.2         alpha.tail1234.ts.net  will@example.com  macOS    active; direct 192.0.2.1:41641",
    '100.64.0.5         mid.tail1234.ts.net    user 77           windows  active; relay "nyc"',
    "100.64.0.9         zed.tail1234.ts.net    tag:db            linux    offline, last seen 2026-11-20T10:00:00Z",
    "health: Tailscale can't reach the configured DNS servers.",
    "",
  }, "\n"), ran.out)
end

--- A node that is not running says so first, with where to log in, and
--- exits 1, as `tailscale status` does.
local function test_status_of_a_node_that_needs_login_says_where_to_log_in(tmp: string)
  local ran = run(tmp, { "status" }, NO_HTTPS)
  assert(ran.code == 1, ran.err)
  assert(ran.out == "NeedsLogin: log in at https://login.tailscale.com/a/x\n", ran.out)
end

--- What a peer names itself reaches the terminal escaped, so it can
--- neither move the cursor, clear the screen, retitle the window nor
--- start a line that looks like the daemon's; `--json` escapes it as
--- JSON does.
local function test_status_escapes_what_a_peer_named_itself(tmp: string)
  local ran = run(tmp, { "status" }, HOSTILE)
  assert(ran.code == 0, ran.err)
  assert(ran.out == "Running\n100.64.0.66  evil\\x1B]0;owned\\x07.ts.net  tag:x\\xC2\\x9B31m  linux\\x1B[2J\\xE2\\x80\\xAE  -\n",
    ran.out)
  local json = run(tmp, { "status", "--json" }, HOSTILE)
  assert(json.code == 0, json.err)
  assert(json.out:find("[\0-\9\11-\31\127]") == nil, json.out)
  assert(json.out:find('"os":"linux\\u001b[2J\\u202e"', 1, true) ~= nil, json.out)
  assert(json.out:find('"tag:x\\u009b31m"', 1, true) ~= nil, json.out)
  assert(json.out:find("[\128-\255]") == nil, json.out)
end

local function test_whois_escapes_what_a_peer_named_itself(tmp: string)
  local ran = run(tmp, { "whois", "100.64.0.66" })
  assert(ran.code == 0, ran.err)
  assert(ran.out == table.concat({
    "node       evil\\x1B[31m.ts.net (nEVIL)",
    "addresses  100.64.0.66",
    "user       mallory\\x1B[8m@example.com (Mal\\xC2\\x9D0;x\\xC2\\x9C)",
    "os         linux\\x0D\\x0Aos  forged",
    "",
  }, "\n"), ran.out)
end

--- A file a peer sent is listed, taken and complained of with the C1
--- control or bidi override in its name escaped, the directory given
--- as it was typed.
local function test_file_names_a_peer_chose_are_escaped(tmp: string)
  local function two(ran: Ran)
    ran.waiting["a\xC2\x9B.txt"] = "x"
    ran.waiting["b\xE2\x80\xAEfdp.exe"] = "MZ"
  end
  local listed = run(tmp, { "file", "list" }, nil, false, two)
  assert(listed.code == 0, listed.err)
  assert(listed.out == "1  a\\xC2\\x9B.txt\n2  b\\xE2\\x80\\xAEfdp.exe\n", listed.out)
  local json = run(tmp, { "file", "list", "--json" }, nil, false, two)
  assert(json.out:find('"a\\u009b.txt"', 1, true) ~= nil and json.out:find('"b\\u202efdp.exe"', 1, true) ~= nil,
    json.out)
  local got = run(tmp, { "file", "get", "/in" }, nil, false, function(ran: Ran)
    two(ran)
    ran.files["/in/a\xC2\x9B.txt"] = "old"
  end)
  assert(got.code == 1, got.err)
  assert(got.err == "cosmic: tailscale: /in/a\\xC2\\x9B.txt: there already, so a\\xC2\\x9B.txt waits on " ..
      "(--conflict overwrite or rename takes it)\n", got.err)
  assert(got.out == "/in/b\\xE2\\x80\\xAEfdp.exe\n", got.out)
  assert(got.files["/in/b\xE2\x80\xAEfdp.exe"] == "MZ")
end

--- `--json` prints the module's record, the users keyed by id as text.
local function test_status_json_is_the_records_fields(tmp: string)
  local ran = run(tmp, { "status", "--json" })
  assert(ran.code == 0, ran.err)
  local Json = require("cosmic.json")
  local got = assert(Json.decode_object(ran.out))
  assert(got["backend_state"] == "Running", ran.out)
  local users = assert(Json.to_object(got["users"]))
  local will = assert(Json.to_object(users["42"]))
  assert(will["login_name"] == "will@example.com", ran.out)
  local peers = assert(Json.to_array(got["peers"]))
  assert(#peers == 4, ran.out)
  local first = assert(Json.to_object(peers[1]))
  assert(first["host_name"] == "six", ran.out)
  local empty = run(tmp, { "status", "--json" }, NO_HTTPS)
  assert(empty.code == 1, empty.err)
  assert(empty.out:find('"peers":[]', 1, true) ~= nil and empty.out:find('"users":{}', 1, true) ~= nil and
      empty.out:find('"cert_domains":[]', 1, true) ~= nil, empty.out)
end

--- Whois names the node and its user, or a tagged node's tags, and each
--- capability in order, with the values a grant attached.
local function test_whois_prints_the_node_its_user_and_its_capabilities(tmp: string)
  local ran = run(tmp, { "whois", "100.64.0.2" })
  assert(ran.code == 0, ran.err)
  assert(ran.out == table.concat({
    "node       laptop.tail1234.ts.net (nABC1CNTRL)",
    "addresses  100.64.0.2 fd7a:115c:a1e0::2",
    "user       will@example.com (Will)",
    "os         macOS",
    'cap        example.com/cap/admin [{"level":"all"}]',
    "cap        example.com/cap/read",
    "",
  }, "\n"), ran.out)
  local by_name = run(tmp, { "whois", "alpha" })
  assert(by_name.code == 0 and by_name.out == ran.out, by_name.out)
  local tagged = run(tmp, { "whois", "100.64.0.3" })
  assert(tagged.code == 0, tagged.err)
  assert(tagged.out == "node       db.tail1234.ts.net (nDEF2CNTRL)\naddresses  100.64.0.3\n" ..
      "tags       tag:db tag:prod\n", tagged.out)
  local json = run(tmp, { "whois", "--json", "100.64.0.3" })
  assert(json.out:find('"tagged":true', 1, true) ~= nil, json.out)
  assert(json.out:find('"tags":["tag:db","tag:prod"]', 1, true) ~= nil, json.out)
  local caps = run(tmp, { "whois", "--json", "100.64.0.2" })
  assert(caps.out:find('"example.com/cap/read":[]', 1, true) ~= nil, caps.out)
  assert(caps.out:find('"own":false', 1, true) ~= nil, caps.out)
  assert(caps.out:find('"example.com/cap/admin":[{"level":"all"}]', 1, true) ~= nil, caps.out)
end

--- An address no node has exits 1, naming it.
local function test_whois_of_a_stranger_exits_1(tmp: string)
  local ran = run(tmp, { "whois", "192.0.2.7" })
  assert(ran.code == 1, tostring(ran.code))
  assert(ran.err == "cosmic: tailscale: no node has the address 192.0.2.7\n", ran.err)
  assert(ran.out == "", ran.out)
end

--- Cert takes the node's first name when given none and writes the key,
--- only its owner may read, and the chain, where `tailscale cert` does.
local function test_cert_writes_the_key_and_the_chain_of_the_nodes_name(tmp: string)
  local ran = run(tmp, { "cert", "--min-validity", "30d" })
  assert(ran.code == 0, ran.err)
  assert(ran.files["box.tail1234.ts.net.key"] == "-----BEGIN EC PRIVATE KEY-----\nKEY\n-----END EC PRIVATE KEY-----\n")
  assert(ran.files["box.tail1234.ts.net.crt"] == "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n")
  assert(ran.modes["box.tail1234.ts.net.key"] == 0x180, tostring(ran.modes["box.tail1234.ts.net.key"]))
  assert(ran.modes["box.tail1234.ts.net.crt"] == 0x1a4)
  -- 30 days in seconds, as the daemon's Go duration reads it.
  assert(ran.seen[2] == "GET /localapi/v0/cert/box.tail1234.ts.net?type=pair&min_validity=2592000s",
    table.concat(ran.seen, "\n"))
  assert(ran.renamed[1] == "box.tail1234.ts.net.key" and ran.renamed[2] == "box.tail1234.ts.net.crt")
  assert(ran.files["box.tail1234.ts.net.key.new"] == nil)
  -- A name with its final dot names the same files.
  local out = run(tmp, { "cert", "--cert-file", "-", "--key-file", "/tmp/k.pem", "box.tail1234.ts.net." })
  assert(out.code == 0, out.err)
  assert(out.out == "-----BEGIN CERTIFICATE-----\nLEAF\n-----END CERTIFICATE-----\n", out.out)
  assert(out.files["/tmp/k.pem"] ~= nil and out.modes["/tmp/k.pem"] == 0x180)
  assert(#out.seen == 1, table.concat(out.seen, "\n"))
  local both = run(tmp, { "cert", "--cert-file", "-", "--key-file", "-" })
  assert(both.out == PAIR, both.out)
end

--- A refused certificate, a node with no name, a write that fails and a
--- bad duration each say why, and a write that fails writes no chain.
local function test_cert_says_why_it_wrote_nothing(tmp: string)
  local refused = run(tmp, { "cert", "other.tail1234.ts.net" })
  assert(refused.code == 1 and refused.err == "cosmic: tailscale: /localapi/v0/cert/other.tail1234.ts.net: cert access denied\n",
    refused.err)
  local nameless = run(tmp, { "cert" }, NO_HTTPS)
  assert(nameless.code == 1 and nameless.err == "cosmic: tailscale: the node is NeedsLogin: log in at " ..
      "https://login.tailscale.com/a/x, so it has no name to get a certificate for\n", nameless.err)
  -- The chain's write fails after the key's: neither is renamed into place.
  local ro = run(tmp, { "cert", "--key-file", "/tmp/k", "--cert-file", "/ro/c" })
  assert(ro.code == 2 and ro.err == "cosmic: tailscale: /ro/c.new: read-only file system; nothing was written over\n",
    ro.err)
  assert(#ro.renamed == 0 and ro.files["/tmp/k"] == nil, table.concat(ro.renamed, " "))
  local odd = run(tmp, { "cert", "box/../status" })
  assert(odd.code == 2 and odd.err:find('no such domain "box/../status"', 1, true) ~= nil, odd.err)
  assert(#odd.seen == 0, table.concat(odd.seen, "\n"))
  local huge = run(tmp, { "cert", "--min-validity", "999999999d" })
  assert(huge.code == 2 and huge.err:find("too long", 1, true) ~= nil, huge.err)
  local bad = run(tmp, { "cert", "--min-validity", "1y" })
  assert(bad.code == 2 and bad.err:find("not years or months", 1, true) ~= nil, bad.err)
  assert(#bad.seen == 0, table.concat(bad.seen, "\n"))
  local same = run(tmp, { "cert", "--cert-file", "x", "--key-file", "x" })
  assert(same.code == 2 and same.err:find("name one file", 1, true) ~= nil, same.err)
end

--- Ping prints the round trip and the path the reply came by.
local function test_ping_prints_the_round_trip_and_its_path(tmp: string)
  local direct = run(tmp, { "ping", "100.64.0.2" })
  assert(direct.code == 0, direct.err)
  assert(direct.out == "pong from 100.64.0.2 via direct 192.0.2.1:41641 in 12.5ms\n", direct.out)
  local relayed = run(tmp, { "ping", "--kind", "TSMP", "100.64.0.9" })
  assert(relayed.out == "pong from 100.64.0.9 via DERP fra in 80.0ms\n", relayed.out)
  local json = run(tmp, { "ping", "--json", "100.64.0.2" })
  assert(json.out:find('"latency_ns":12500000', 1, true) ~= nil, json.out)
  local named = run(tmp, { "ping", "alpha" })
  assert(named.out == "pong from 100.64.0.2 via direct 192.0.2.1:41641 in 12.5ms\n", named.out)
  local full = run(tmp, { "ping", "ALPHA.tail1234.ts.net." })
  assert(full.code == 0, full.err)
  local nobody = run(tmp, { "ping", "nobody" })
  assert(nobody.code == 1 and nobody.err == "cosmic: tailscale: no node of the tailnet is named nobody\n", nobody.err)
  local refused = run(tmp, { "ping", "100.64.0.7" })
  assert(refused.code == 1 and refused.err:find("^cosmic: tailscale: /localapi/v0/ping: ") ~= nil, refused.err)
  local bad = run(tmp, { "ping", "--kind", "udp", "100.64.0.2" })
  assert(bad.code == 2 and bad.err:find("ping: --kind takes disco, ICMP, TSMP or peerapi, not udp", 1, true) ~= nil, bad.err)
end

--- A command line it cannot run is refused before the daemon is asked.
local function test_a_command_line_it_cannot_run_is_refused(tmp: string)
  -- Each line, and the usage its refusal ends with: the subcommand's own, or the verb's where it names none.
  local lines: {{string}} = { {}, { "up" }, { "status", "--kind", "disco" }, { "whois" }, { "status", "x" },
    { "cert", "a", "b" }, { "file", "get" }, { "file", "list", "x" } }
  local usages: {string} = { "<cert|file|ping|status|whois> ...", "<cert|file|ping|status|whois> ...",
    "status [options]", "whois [--json] <address|name>", "status [options]", "cert [options] [domain]",
    "file get [options] <dir>", "file list [options]" }
  for i, words in ipairs(lines) do
    local ran = run(tmp, words)
    assert(ran.code == 2, table.concat(words, " ") .. ": " .. tostring(ran.code))
    local usage = "; usage: cosmic tailscale " .. assert(usages[i]) .. "\n"
    assert(ran.err:sub(-#usage) == usage, ran.err)
    assert(#ran.seen == 0, table.concat(ran.seen, "\n"))
  end
end

--- A daemon that is not there fails the call, exit 1, naming the socket.
local function test_a_daemon_that_is_not_there_exits_1(tmp: string)
  local ran = run(tmp, { "status", "--socket", tmp .. "/none.sock" }, nil, true)
  assert(ran.code == 1, tostring(ran.code))
  assert(ran.err:find("^cosmic: tailscale: ") ~= nil, ran.err)
end

--- The targets list by name, and a file goes to one named by its first
--- label, under its own name or --name, from a file or standard input.
local function test_file_send_names_a_target_and_streams_the_file(tmp: string)
  local listed = run(tmp, { "file", "targets" })
  assert(listed.code == 0, listed.err)
  assert(listed.out == "alpha.tail1234.ts.net  nALPHA  100.64.0.2  macOS\n" ..
      "zed.tail1234.ts.net    nZED    100.64.0.9  -\n", listed.out)
  local sent = run(tmp, { "file", "send", "/data/a report.txt", "zed" }, nil, false, function(ran: Ran)
    ran.files["/data/a report.txt"] = "hello zed"
  end)
  assert(sent.code == 0, sent.err)
  assert(sent.put["nZED/a%20report.txt"] == "hello zed", tostring(sent.put["nZED/a%20report.txt"]))
  local piped = run(tmp, { "file", "send", "--name", "notes.md", "-", "100.64.0.2" }, nil, false, function(ran: Ran)
    ran.stdin = "# notes"
  end)
  assert(piped.code == 0 and piped.put["nALPHA/notes.md"] == "# notes", piped.err)
  local nameless = run(tmp, { "file", "send", "-", "zed" })
  assert(nameless.code == 2 and nameless.err:find("needs --name", 1, true) ~= nil, nameless.err)
  local nobody = run(tmp, { "file", "send", "/data/x", "box" }, nil, false, function(ran: Ran)
    ran.files["/data/x"] = "x"
  end)
  assert(nobody.code == 1 and nobody.err:find("no node takes files as box", 1, true) ~= nil, nobody.err)
  local odd = run(tmp, { "file", "send", "--name", "a/b", "/data/x", "zed" })
  assert(odd.code == 2 and odd.err:find('no file may go as "a/b"', 1, true) ~= nil and #odd.seen == 0, odd.err)
  local missing = run(tmp, { "file", "send", "/data/none", "zed" })
  assert(missing.code == 2 and #missing.seen == 0, missing.err)
end

--- Get writes each waiting file into the directory, prints its path and
--- drops it from the daemon; a name taken already is skipped and waits
--- on, or renamed, and --keep leaves the file waiting.
local function test_file_get_writes_each_waiting_file_and_drops_it(tmp: string)
  local function two(ran: Ran)
    ran.waiting["a.txt"] = "alpha"
    ran.waiting["b c.pdf"] = "%PDF"
  end
  local got = run(tmp, { "file", "get", "/in/" }, nil, false, two)
  assert(got.code == 0, got.err)
  assert(got.out == "/in/a.txt\n/in/b c.pdf\n", got.out)
  assert(got.files["/in/a.txt"] == "alpha" and got.files["/in/b c.pdf"] == "%PDF")
  assert(next(got.waiting) == nil)
  local listed = run(tmp, { "file", "list" }, nil, false, two)
  assert(listed.out == "5  a.txt\n4  b c.pdf\n", listed.out)
  local taken = run(tmp, { "file", "get", "/in" }, nil, false, function(ran: Ran)
    two(ran)
    ran.files["/in/a.txt"] = "old"
  end)
  assert(taken.code == 1 and taken.err:find("/in/a.txt: there already", 1, true) ~= nil, taken.err)
  assert(taken.files["/in/a.txt"] == "old" and taken.waiting["a.txt"] == "alpha")
  assert(taken.out == "/in/b c.pdf\n", taken.out)
  local renamed = run(tmp, { "file", "get", "--conflict", "rename", "--keep", "/in" }, nil, false, function(ran: Ran)
    two(ran)
    ran.files["/in/a.txt"] = "old"
    ran.files["/in/a (1).txt"] = "older"
  end)
  assert(renamed.code == 0, renamed.err)
  assert(renamed.files["/in/a (2).txt"] == "alpha", renamed.out)
  assert(renamed.waiting["a.txt"] == "alpha", "--keep leaves it")
  local over = run(tmp, { "file", "get", "--conflict", "overwrite", "/in" }, nil, false, function(ran: Ran)
    two(ran)
    ran.files["/in/a.txt"] = "old"
  end)
  assert(over.code == 0 and over.files["/in/a.txt"] == "alpha", over.err)
  local ro = run(tmp, { "file", "get", "/ro" }, nil, false, two)
  assert(ro.code == 1 and ro.err:find("a.txt: /ro/a.txt: read-only file system", 1, true) ~= nil, ro.err)
  assert(ro.waiting["a.txt"] == "alpha")
  local nodir = run(tmp, { "file", "get", "/nowhere" })
  assert(nodir.code == 2 and nodir.err:find("not a directory", 1, true) ~= nil, nodir.err)
end
