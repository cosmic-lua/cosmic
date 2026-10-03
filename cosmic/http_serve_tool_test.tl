--- [`Http.serve`] with a process of this program on the other side:
--- cosmic.http's own client, which holds its thread while it waits and
--- so runs in a child against a server here, and a server in a child
--- stopped by SIGTERM.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local Time = require("cosmic.time")
local Url = require("cosmic.url")

--- A server on the worker's own loopback, and the program itself,
--- started to run a script `--standalone`.
Test.needs{ network = { "127.0.0.1" }, lua = true, standalone = true }

--- cosmic.http's client and server speak the same HTTP/1.1: a GET, a
--- PUT with a body, a HEAD and a DELETE over TCP, each answered as sent.
local function test_the_client_and_the_server_agree(tmp: string)
  local script = tmp .. "/client.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
return function(argv: {string}): integer
  local base = argv[1]
  local said: {string} = {}
  local missing = assert(Http.get(base .. "/items/a"))
  said[#said + 1] = missing.status .. " " .. missing.body
  local put = assert(Http.request("PUT", base .. "/items/a", { body = "first value" }))
  said[#said + 1] = put.status .. " " .. put.body
  local got = assert(Http.get(base .. "/items/a?x=1"))
  said[#said + 1] = got.status .. " " .. got.body .. " " .. got.headers["content-type"]
  local head = assert(Http.request("HEAD", base .. "/items/a"))
  said[#said + 1] = head.status .. " [" .. head.body .. "] " .. head.headers["content-length"]
  local gone = assert(Http.request("DELETE", base .. "/items/a"))
  said[#said + 1] = tostring(gone.status)
  Fs.put(Fs.stdout, table.concat(said, "\n"))
  return 0
end
]]))
  local items: {string:string} = {}
  local result: Child.Result = nil
  assert(Http.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    handle = function(req: Http.Request): Http.Reply
      local key = req.path:match("^/items/(.+)$")
      if key == nil then return { status = 404 } end
      if req.method == "PUT" then
        items[key] = assert(Stream.read_all(req.body))
        return { status = 201, body = "stored" }
      elseif req.method == "DELETE" then
        items[key] = nil
        return { status = 204 }
      end
      local value = items[key]
      if value == nil then return { status = 404, body = "no " .. key } end
      return { status = 200, headers = { ["Content-Type"] = "text/plain" }, body = value }
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local base = "http://127.0.0.1:" .. addresses[1].port
      local started = this_program.program({ "--standalone", script, base },
        { stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(60) })
      result = assert(Child.run(started.argv, started.options))
      server:stop()
    end,
  })
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  local expected = table.concat({
    "404 no a", "201 stored", "200 first value text/plain", "200 [] 11", "204",
  }, "\n")
  assert(result.stdout == expected, result.stdout)
  assert(items.a == nil)
end

--- A name with a space or a byte past ASCII, joined into a URL as
--- written, reaches the server escaped and names the file it was;
--- an escaped URL and a reserved byte reach it as written.
local function test_a_name_joined_unescaped_reaches_the_server_escaped(tmp: string)
  local root = tmp .. "/files"
  assert(Fs.mkdirs(root))
  for _, name in ipairs({ "two words.txt", "caf\xc3\xa9.txt" }) do
    assert(Fs.write(root .. "/" .. name, "this is " .. name))
  end
  local script = tmp .. "/client.tl"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
return function(argv: {string}): integer
  local said: {string} = {}
  for _, name in ipairs({ "two words.txt", "caf\xc3\xa9.txt", "two%20words.txt", "a=b&c;d?e=f" }) do
    local got = assert(Http.get(argv[1] .. "/" .. name))
    said[#said + 1] = got.status .. " " .. got.body
  end
  Fs.put(Fs.stdout, table.concat(said, "\n"))
  return 0
end
]]))
  local targets: {string} = {}
  local result: Child.Result = nil
  assert(Http.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    handle = function(req: Http.Request): Http.Reply
      targets[#targets + 1] = req.target
      local names = assert(Url.segments(req.path))
      local body = Fs.read(root .. "/" .. table.concat(names, "/"))
      if body == nil then return { status = 404 } end
      return { status = 200, body = body }
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local base = "http://127.0.0.1:" .. addresses[1].port
      local started = this_program.program({ "--standalone", script, base },
        { stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(60) })
      result = assert(Child.run(started.argv, started.options))
      server:stop()
    end,
  })
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  assert(table.concat(targets, " ") == "/two%20words.txt /caf%C3%A9.txt /two%20words.txt /a=b&c;d?e=f",
    table.concat(targets, " "))
  local expected = table.concat({
    "200 this is two words.txt", "200 this is caf\xc3\xa9.txt", "200 this is two words.txt", "404 ",
  }, "\n")
  assert(result.stdout == expected, result.stdout)
end

--- SIGTERM stops a server in a process of its own, which exits 0: an
--- idle kept-alive connection is closed at once rather than held for
--- idle_ns.
local function test_sigterm_stops_a_server_and_it_exits_0(tmp: string)
  local script = tmp .. "/server.tl"
  local marker = tmp .. "/ready"
  local socket = tmp .. "/s.sock"
  assert(Fs.write(script, [[
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Time = require("cosmic.time")
return function(argv: {string}): integer
  local ok, why = Http.serve{
    listeners = { Net.unix(argv[1]) },
    idle_ns = Time.seconds(60),
    handle = function(_req: Http.Request): Http.Reply return { status = 200, body = "up" } end,
    on_ready = function(_addresses: {Net.Address}, _server: Net.Server)
      assert(Fs.write(argv[2], ""))
    end,
  }
  if not ok then
    Fs.put(Fs.stderr, why)
    return 1
  end
  return 0
end
]]))
  local started = this_program.program({ "--standalone", script, socket, marker },
    { stdout = "capture", stderr = "capture" })
  local child <close> = assert(Child.start(started.argv, started.options))
  for _ = 1, 3000 do
    if Fs.stat(marker) ~= nil then break end
    assert(sys.nanosleep(Time.ms(10)))
  end
  assert(Fs.stat(marker) ~= nil, "the server never listened")
  local conn <close> = assert(Net.connect(Net.unix(socket), { timeout_ns = Time.seconds(20) }))
  assert(conn:write("GET / HTTP/1.1\r\nHost: test\r\n\r\n"))
  local head = ""
  while not head:find("\r\n\r\nup", 1, true) do head = head .. assert(conn:read()) end
  local stopped_at = Time.monotonic_ns()
  assert(child:stop(sys.SIGTERM))
  local result = assert(child:wait(Time.seconds(30)))
  assert(result.code == 0, tostring(result.code) .. " " .. tostring(result.stderr))
  assert(Time.monotonic_ns() - stopped_at < Time.seconds(10), "the idle connection held the stop")
  local after, why = conn:read()
  assert(after == nil and why == "", tostring(after) .. " " .. why)
end
