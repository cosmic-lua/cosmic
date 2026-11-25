--- Taildrop through [`cosmic.tailscale`] against a stand-in tailscaled: a
--- [`Server.serve`] that responds at the LocalAPI's file paths as the
--- daemon does. Each client call runs in a task of the stand-in's own
--- run, as a call waits as one.

local Array = require("cosmic.array")
local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Tailscale = require("cosmic.tailscale")
local Test = require("cosmic.test")

Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" }, requires = { "unix_socket" } }

local TARGETS <const> = [=[[
  {"Node": {"ID": 9, "StableID": "nZED", "Name": "zed.tail1234.ts.net.", "User": 42,
    "Addresses": ["100.64.0.9/32"], "Hostinfo": {"Hostname": "zed", "OS": "linux"}},
   "PeerAPIURL": "http://100.64.0.9:41000"},
  {"Node": {"ID": 2, "StableID": "nALPHA", "Name": "alpha.tail1234.ts.net.", "User": 42,
    "Addresses": ["100.64.0.2/32"]}, "PeerAPIURL": "http://100.64.0.2:41000"}
]]=]

--- What the stand-in holds and saw.
local record Daemon
  --- Each request, as `method target`.
  seen: mut {string}
  --- The files put, by target and name, as received.
  put: mut {string: string}
  --- The waiting files, by name.
  waiting: mut {string: string}
  --- What `files/` responds with in place of the list, where set.
  mut listing?: string
  --- What `file-targets` responds with in place of TARGETS, where set.
  mut targets?: string
end

local function answer(daemon: Daemon, req: Server.Request): Server.Reply
  local target = req.target
  if target == "/localapi/v0/file-targets" then
    return { status = 200, body = daemon.targets or TARGETS }
  end
  local to, name = target:match("^/localapi/v0/file%-put/([^/]+)/(.+)$")
  if to ~= nil and req.method == "PUT" then
    if to ~= "nZED" and to ~= "nALPHA" then
      return { status = 404, body = "no peer found with StableID\n" }
    end
    daemon.put[to .. "/" .. assert(name)] = assert(Stream.read_all(req.body))
    return { status = 200, body = "{}\n" }
  end
  if target:match("^/localapi/v0/files/%??") ~= nil and req.method == "GET" and
      (target == "/localapi/v0/files/" or target:match("^/localapi/v0/files/%?waitsec=") ~= nil) then
    local listing = daemon.listing
    if listing ~= nil then return { status = 200, body = listing } end
    local names: mut {string} = {}
    for file in pairs(daemon.waiting) do names[#names + 1] = file end
    table.sort(names, function(a: string, b: string): boolean return a > b end)
    local items: mut {string} = {}
    for _, file in ipairs(names) do
      items[#items + 1] = ('{"Name": "%s", "Size": %d}'):format(file, #assert(daemon.waiting[file]))
    end
    return { status = 200, body = "[" .. table.concat(items, ",") .. "]\n" }
  end
  local file = target:match("^/localapi/v0/files/(.+)$")
  if file ~= nil then
    local plain = file:gsub("%%20", " ")
    local data = daemon.waiting[plain]
    if data == nil then return { status = 404, body = "file not found\n" } end
    if req.method == "DELETE" then
      daemon.waiting[plain] = nil
      return { status = 204 }
    end
    return { status = 200, body = data }
  end
  return { status = 404, body = "404 page not found\n" }
end

--- How many stand-ins this process served: each takes a socket of its own.
local served = 0

--- Runs `body` with a client of a stand-in daemon, in a task of the run
--- that serves the stand-in, and stops the stand-in once `body` returns;
--- what the stand-in saw is kept in `daemon.seen`.
local function against(tmp: string, daemon: Daemon, body: function(ts: Tailscale.Client))
  served = served + 1
  assert(Server.serve{
    listeners = { Net.unix(tmp .. "/ts" .. tostring(served) .. ".sock") },
    on_stop = function(_: Net.Server) end,
    handle = function(req: Server.Request): Server.Reply
      daemon.seen[#daemon.seen + 1] = req.method .. " " .. req.target
      return answer(daemon, req)
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local ts = assert(Tailscale.connect({ socket = assert(Array.at(addresses, 1).path) }))
      body(ts)
      server:stop()
    end,
  })
end

--- Appends `line` to `lines`.
local function say(lines: mut {string}, line: string)
  lines[#lines + 1] = line
end

local function new_daemon(): Daemon
  return { seen = {}, put = {}, waiting = {} }
end

--- The targets come back by node name, each with its PeerAPI URL.
local function test_file_targets_lists_the_peers_by_name(tmp: string)
  local daemon = new_daemon()
  local said: mut {string} = {}
  against(tmp, daemon, function(ts: Tailscale.Client)
    for _, target in ipairs((assert(ts:file_targets()))) do
      say(said, target.node.name .. " " .. target.node.stable_id .. " " .. target.peerapi_url .. " " ..
          table.concat(target.node.addresses, ","))
    end
  end)
  local none = new_daemon()
  none.targets = "null"
  local count = -1
  against(tmp, none, function(ts: Tailscale.Client) count = #(assert(ts:file_targets())) end)
  assert(count == 0, tostring(count))
  assert(table.concat(said, "\n") == "alpha.tail1234.ts.net nALPHA http://100.64.0.2:41000 100.64.0.2\n" ..
      "zed.tail1234.ts.net nZED http://100.64.0.9:41000 100.64.0.9", table.concat(said, "\n"))
end

--- A file goes as a PUT of its bytes, its name escaped in the path; a
--- body that is not its size, a name that would leave a directory and
--- a target the daemon does not know each fail, saying why.
local function test_send_file_puts_the_bytes_under_the_escaped_name(tmp: string)
  local daemon = new_daemon()
  local said: mut {string} = {}
  against(tmp, daemon, function(ts: Tailscale.Client)
    local data = string.rep("taildrop ", 20000)
    local ok, why = ts:send_file("nZED", "a report.txt", Stream.from_string(data), #data)
    say(said, tostring(ok) .. " " .. why)
    local _, short = ts:send_file("nZED", "x", Stream.from_string("abc"), 4)
    say(said, short)
    local _, long = ts:send_file("nZED", "x", Stream.from_string("abcde"), 4)
    say(said, long)
    local _, odd = ts:send_file("nZED", "../x", Stream.from_string(""), 0)
    say(said, odd)
    local _, unknown = ts:send_file("nNONE", "x", Stream.from_string(""), 0)
    say(said, unknown)
    -- A refusal the daemon sends before it reads the body is the result,
    -- however much of the body was left to write, not the write's failure.
    local large = string.rep("x", 8 * 1024 * 1024)
    local _, early = ts:send_file("nNONE", "big", Stream.from_string(large), #large, { timeout_ns = 0 })
    say(said, early)
    local _, partial = ts:send_file("nZED", "a.partial", Stream.from_string(""), 0)
    say(said, partial)
  end)
  assert(daemon.put["nZED/a%20report.txt"] == string.rep("taildrop ", 20000))
  assert(table.concat(said, "\n") == table.concat({
    "true ",
    "tailscale: the file is 3 bytes, not its size, 4",
    "tailscale: the file is longer than its size, 4",
    'tailscale: no file may be named "../x"',
    "tailscale: /localapi/v0/file-put/nNONE/x: no peer found with StableID",
    -- The stand-in's server refuses so large a body before it reads it.
    "tailscale: /localapi/v0/file-put/nNONE/big: 413 Content Too Large: the body is longer than limits.body_bytes",
    'tailscale: no file may be named "a.partial"',
  }, "\n"), table.concat(said, "\n"))
end

--- The waiting files come back by name; one is read as it arrives and
--- then deleted. A wait asks the daemon to hold the call, and Go's null
--- is no files.
local function test_a_waiting_file_is_read_and_then_deleted(tmp: string)
  local daemon = new_daemon()
  local big = string.rep("0123456789", 30000)
  daemon.waiting["b c.bin"] = big
  daemon.waiting["a.txt"] = "hello"
  local said: mut {string} = {}
  against(tmp, daemon, function(ts: Tailscale.Client)
    for _, file in ipairs((assert(ts:waiting_files()))) do
      say(said, file.name .. " " .. tostring(file.size))
    end
    local file <close> = assert(ts:open_file("b c.bin"))
    local got = assert(Stream.read_all(file))
    say(said, tostring(file.size) .. " " .. tostring(got == big))
    say(said, tostring((assert(ts:delete_file("b c.bin")))))
    local _, gone = ts:open_file("b c.bin")
    say(said, gone)
    local _, odd = ts:open_file("a/b")
    say(said, odd)
    daemon.listing = "null\n"
    say(said, tostring(#(assert(ts:waiting_files({ wait_ns = 1500000000 })))))
  end)
  assert(table.concat(said, "\n") == table.concat({
    "a.txt 5",
    "b c.bin 300000",
    "300000 true",
    "true",
    "tailscale: /localapi/v0/files/b%20c.bin: file not found",
    'tailscale: no file may be named "a/b"',
    "0",
  }, "\n"), table.concat(said, "\n"))
  assert(daemon.seen[#daemon.seen] == "GET /localapi/v0/files/?waitsec=2", daemon.seen[#daemon.seen])
end

--- A name the daemon lists that would leave a directory fails the list.
local function test_a_listed_name_that_leaves_the_directory_fails_the_list(tmp: string)
  local daemon = new_daemon()
  daemon.listing = '[{"Name": "../../etc/passwd", "Size": 1}]'
  local why = ""
  against(tmp, daemon, function(ts: Tailscale.Client)
    local _, trouble = ts:waiting_files()
    why = trouble
  end)
  assert(why == 'tailscale: files: the daemon names a file "../../etc/passwd"', why)
end
