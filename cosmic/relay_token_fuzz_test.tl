--- A fuzz property for the decision of a relay that holds a token: whatever
--- bytes a program sends on a connection to either listener, none of them
--- the right credential, the relay never carries a connection to the
--- upstream, answers no request, and counts no connection as served.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Fixture = require("build.relay_wire_fixture")
local Fuzz = require("build.fuzz")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Relay = require("cosmic.relay")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

local TOKEN <const> = "fuzz-token-0123456789abcdef"

--- A password that is not the token: a cut of it, a byte changed, bytes added.
local function near(src: Fuzz.Source): string
  local kind = src:int(0, 3)
  if kind == 0 then return TOKEN:sub(1, src:int(0, #TOKEN - 1)) end
  if kind == 1 then
    local at = src:int(1, #TOKEN)
    return TOKEN:sub(1, at - 1) .. string.char((TOKEN:byte(at) + src:int(1, 255)) % 256) .. TOKEN:sub(at + 1)
  end
  if kind == 2 then return TOKEN .. "x" .. Fuzz.bytes(src, 4) end
  return Fuzz.bytes(src, 30)
end

local function gen_http(src: Fuzz.Source): string
  local headers: {string} = {}
  local kind = src:int(0, 4)
  if kind == 0 then
    headers[1] = "Proxy-Authorization: Basic " .. Codec.base64("u:" .. near(src))
  elseif kind == 1 then
    headers[1] = "Proxy-Authorization: Bearer " .. near(src)
  elseif kind == 2 then
    headers[1] = "Proxy-Authorization: " .. Fuzz.bytes(src, 20)
  elseif kind == 3 then
    headers[1] = "Proxy-Authorization: Basic " .. Codec.base64(near(src))
  end
  return "H" .. Fixture.connect("127.0.0.1:80", headers)
end

local function gen_socks(src: Fuzz.Source): string
  local out = "S" .. Fuzz.pick(src, { "\5\1\0", "\5\1\2", "\5\2\0\2", "\5\0", "\4\1\2" })
  if src:int(0, 1) == 0 then
    local user = Fuzz.pick(src, { "u", "cosmic", "", Fuzz.bytes(src, 5) })
    local password = near(src)
    out = out .. "\1" .. string.char(#user) .. user .. string.char(#password % 256) .. password
  end
  if src:int(0, 1) == 0 then
    out = out .. Fixture.socks_request(1, 1, "\127\0\0\1", 80)
  end
  return out
end

local function gen(src: Fuzz.Source): string
  local kind = src:int(0, 5)
  local text: string
  if kind == 0 then
    text = Fuzz.pick(src, { "H", "S" }) .. Fuzz.bytes(src, 60)
  elseif kind <= 2 then
    text = gen_http(src)
  else
    text = gen_socks(src)
  end
  return Fuzz.mutate(src, text, src:int(0, 4) == 0 and 2 or 0)
end

local function test_no_bytes_but_the_token_reach_the_upstream(tmp: string)
  Fuzz.run({
    name = "a token relay serves nothing without the token",
    dir = tmp,
    gen = gen,
    requires = { "http", "socks", "answered" },
    shares = { http = 0.1, socks = 0.1, answered = 0.1 },
    check = function(input: string): boolean, string
      -- The one input class outside the property: a credential that is right.
      if input:find(TOKEN, 1, true) then return true, "" end
      local trouble = ""
      Poll.run(function()
        local http = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
        local socks = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
        local asked = 0
        local server = Relay.start({
          http = http, socks = socks, grants = { "127.0.0.1:80" }, token = TOKEN,
          timeouts = { auth = Clock.ms(300) }, log = function(_: string) end,
          connector = function(): Net.Conn | nil, string
            asked = asked + 1
            return nil, "Connection refused"
          end,
        })
        local first = input:sub(1, 1)
        Fuzz.label(first == "H" and "http" or "socks")
        local conn = assert(Net.connect(first == "H" and http.address or socks.address,
          { timeout_ns = Clock.seconds(5) }))
        conn:set_timeout(Clock.seconds(5))
        local _, _ = conn:write(input:sub(2))
        local _, _ = conn:shutdown("write")
        local reply = ""
        while true do
          local data, _ = conn:read()
          if data == nil then break end
          reply = reply .. data
        end
        local _, _ = conn:close()
        server:stop()
        server:wait()
        local stats = server:stats()
        local _, _ = http:close()
        local _, _ = socks:close()
        if asked ~= 0 then
          trouble = "the connector was asked for a connection"
        elseif stats.accepted ~= 0 or stats.open ~= 0 then
          trouble = ("%d accepted, %d open"):format(stats.accepted, stats.open)
        elseif reply:find("200 Connection established", 1, true) or (first == "S" and reply:sub(3, 4) == "\1\0") then
          trouble = "an acceptance was answered"
        end
        if reply ~= "" then Fuzz.label("answered") end
      end)
      return trouble == "", trouble
    end,
  })
end
