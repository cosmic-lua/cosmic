--- A proxy-honouring client (curl) in a sandbox reaches a service of the
--- host's own loopback that a `connect` target names, at 127.0.0.1: its
--- `NO_PROXY` leaves that address out, so curl sends it to the relay
--- (cosmic/relay/config.tl's `proxy_env`). The server is this test's own,
--- at 127.0.0.1 of the worker's network, which the start's connector
--- reaches and the program's network of its own does not. Like
--- cosmic/child_relay_test.tl, it needs a sandbox that nests, and skips
--- itself where this host gives none.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")

Test.policy{
  profiles = { "cosmic", "system" },
  promises = { "nest" },
  loopback = { "127.0.0.1" },
  env = { "TMPDIR", "PATH" },
  grants = {
    { path = "o/bin", letters = "rx" },
    { path = "o/cosmic.db", letters = "r" },
  },
  requires = { "nest", "program:curl" },
}

--- Whether `why`, a start's failure, is the platform or the host giving no
--- Landlock, seccomp or user namespace.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc",
      "root could not be built" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- Runs `body` in a run with an HTTP server at a port of 127.0.0.1 that
--- answers every request "hello from the host".
local function serving(body: function(port: integer))
  Poll.run(function()
    local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
    local task = Poll.spawn(function()
      while true do
        local conn = listener:accept()
        if conn == nil then return end
        Poll.spawn(function()
          local seen = ""
          while not seen:find("\r\n\r\n", 1, true) do
            local chunk = conn:read(4096)
            if chunk == nil then break end
            seen = seen .. chunk
          end
          local _, _ = conn:write("HTTP/1.1 200 OK\r\nContent-Length: 19\r\nConnection: close\r\n\r\nhello from the host")
          local _, _ = conn:close()
        end)
      end
    end)
    body(listener.address.port)
    task:cancel()
    assert(listener:close())
  end)
end

--- curl, in a sandbox whose policy grants `target`, asked for `url` through
--- a CONNECT tunnel (-p) where it uses the proxy; its output and exit code.
local function curl(target: string, url: string, loopback?: {string}): string, integer
  local out, code = "", -1
  local result, why = Child.run({ "curl", "-sS", "-p", "--max-time", "20", url }, {
    policy = { profiles = { "system" }, connect = { target }, loopback = loopback },
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60) })
  if result == nil then
    if unsandboxable(why) then Test.skip(why) end
    error("the start was refused: " .. why)
  end
  out, code = (result.stdout or "") .. (result.stderr or ""), result.code or -1
  return out, code
end

--- A service of the host's own loopback, granted at 127.0.0.1, is reached:
--- curl sends it through the relay because NO_PROXY no longer names it.
--- An address the policy declares under `loopback` stays direct: curl dials
--- it in the sandbox's own network, where nothing listens (exit 7), and the
--- relay is never asked (through it curl would report a CONNECT tunnel the
--- relay refused).
local function test_a_declared_loopback_address_stays_direct()
  serving(function(port: integer)
    local out, code = curl("127.0.0.1:" .. port, "http://127.0.0.2:" .. port .. "/", { "127.0.0.2" })
    -- Not out:find("403"): the port, chosen by the kernel, may hold those digits.
    assert(code == 7 and out:find("Failed to connect to 127.0.0.2", 1, true) ~= nil and
        out:find("CONNECT", 1, true) == nil, "exit " .. code .. ": " .. out)
  end)
end

local function test_a_proxy_client_reaches_a_granted_host_loopback_service()
  serving(function(port: integer)
    local out, code = curl("127.0.0.1:" .. port, "http://127.0.0.1:" .. port .. "/")
    assert(code == 0 and out:find("hello from the host", 1, true), "exit " .. code .. ": " .. out)
  end)
end
