--- Fuzz properties for [`cosmic.relay.grant`], which reads the `connect`
--- targets of a policy and the hosts of requests the program sends: no text
--- raises it; a target it accepts reads again as itself; and every accepted
--- host but "*" is one the CONNECT and SOCKS readers carry unchanged.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Grant = require("cosmic.relay.grant")
local Wire = require("cosmic.relay.wire")

local HOSTS <const>: {string} = { "example.com", "EXAMPLE.Com.", "a-b.c", "x1.y2.z3", "127.0.0.1",
  "1.2.3.4", "[::1]", "[2001:DB8::1]", "[0:0:0:0:0:0:0:1]", "[::ffff:1.2.3.4]", "*", "*.example.com",
  "bad_name", "-a.b", ".", "", "0177.0.0.1", "2130706433", "0x7f.1", "1.2.3.256", "a..b", "[1.2.3.4]",
  "::1", "host name", "ho\0st" }
local PORTS <const>: {string} = { "1", "80", "443", "65535", "*", "0", "65536", "080", "-1", "", "x", "4 3" }
local TOKENS <const>: {string} = { "a", "0", "1", ".", ":", "-", "_", "*", "[", "]", " ", "\0", "\r\n",
  "example", "com", "::", "ff", "256", "x" }

--- A target: a listed host and port, a mutation of one, or token soup.
local function gen_target(src: Fuzz.Source): string
  local mode = src:int(0, 3)
  if mode == 0 then return Fuzz.bytes(src, 40) end
  if mode == 1 then
    local out: {string} = {}
    while Fuzz.more(src, #out, 16) do out[#out + 1] = Fuzz.pick(src, TOKENS) end
    return table.concat(out)
  end
  local sample = Fuzz.pick(src, HOSTS) .. ":" .. Fuzz.pick(src, PORTS)
  if mode == 3 then sample = Fuzz.mutate(src, sample, 2) end
  return sample
end

--- A listed host with a port that reads, so that most inputs reach the readers.
local function gen_listed_target(src: Fuzz.Source): string
  local mode = src:int(0, 7)
  if mode == 0 then return gen_target(src) end
  if mode == 1 then return "*:*" end
  return Fuzz.pick(src, HOSTS) .. ":" .. Fuzz.pick(src, { "1", "80", "443", "65535", "*" })
end

local function test_no_target_raises_and_an_accepted_one_reads_as_itself(tmp: string)
  Fuzz.run({
    name = "relay grant parse never raises and is idempotent",
    dir = tmp,
    gen = gen_listed_target,
    requires = { "accepted", "refused", "name", "address", "any" },
    shares = { accepted = 0.05, refused = 0.1, name = 0.02, address = 0.01, any = 0.001 },
    check = function(text: string): boolean, string
      local ok, target, why = pcall(Grant.parse, text)
      if not ok then return false, "parse raised: " .. tostring(target) end
      if target == nil then
        Fuzz.label("refused")
        if why == nil or why == "" then return false, "a refusal with no reason" end
        return true, ""
      end
      local read = target as Grant.Target
      Fuzz.label("accepted")
      Fuzz.label(read.kind == "any" and "any" or read.kind == "name" and "name" or "address")
      local again, why_again = Grant.parse(read.text)
      if again == nil then
        return false, "its own text " .. read.text .. " is refused: " .. why_again
      end
      if again.text ~= read.text or again.host ~= read.host or again.port ~= read.port or
          again.kind ~= read.kind then
        return false, "its text " .. read.text .. " reads as " .. again.text
      end
      return true, ""
    end,
  })
end

local function test_every_accepted_host_is_carried_by_both_request_readers(tmp: string)
  Fuzz.run({
    name = "relay grant hosts round-trip through the request readers",
    dir = tmp,
    gen = gen_listed_target,
    requires = { "name", "ipv4", "ipv6" },
    shares = { name = 0.01, ipv4 = 0.005, ipv6 = 0.005 },
    check = function(text: string): boolean, string
      local ok, target = pcall(Grant.parse, text)
      if not ok then return false, "parse raised: " .. tostring(target) end
      if target == nil then return true, "" end
      local read = target as Grant.Target
      if read.kind == "any" then return true, "" end
      Fuzz.label(read.kind)
      local port = read.port == 0 and 443 or read.port
      local shown = read.kind == "ipv6" and "[" .. read.host .. "]" or read.host
      local head = Wire.connect_reader():feed(("CONNECT %s:%d HTTP/1.1\r\n\r\n"):format(shown, port))
      if head.status ~= "done" or head.host ~= read.host or head.port ~= port then
        return false, ("CONNECT reader: %s for %s (%s)"):format(head.status, text, tostring(head.reason))
      end
      local request, why = Wire.socks_client_request(read.host, port)
      if request == nil then return false, "SOCKS request for " .. text .. ": " .. why end
      local socks = Wire.socks_request_reader():feed(request)
      if socks.status ~= "done" or socks.host ~= read.host or socks.port ~= port then
        return false, ("SOCKS reader: %s for %s (%s)"):format(socks.status, text, tostring(socks.reason))
      end
      return true, ""
    end,
  })
end
