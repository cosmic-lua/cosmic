local Fuzz = require("build.fuzz")
local Net = require("cosmic.net")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

local function gen_host(src: Fuzz.Source): string
  local mode = src:int(0, 3)
  if mode == 0 then return "127.0.0.1" end
  if mode == 1 then return "::1%" .. Fuzz.bytes(src, 32) end
  if mode == 2 then return "127.0.0.1\0" .. Fuzz.bytes(src, 32) end
  local parts: {string} = { "127" }
  while Fuzz.more(src, #parts, 6) do
    local part = tostring(src:int(0, 512))
    if src:int(0, 3) == 0 then part = "0" .. part end
    parts[#parts + 1] = part
  end
  return table.concat(parts, ".")
end

--- An independent dotted-quad model; every accepted host generated here
--- is in 127/8, so binding needs only the worker's own loopback.
local function dotted_quad(host: string): boolean
  local a, b, c, d = host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if a == nil then return false end
  for _, part in ipairs({ a, b, c, d }) do
    if (#part > 1 and part:sub(1, 1) == "0") or tonumber(part) > 255 then return false end
  end
  return true
end

local function test_numeric_hosts_match_the_strict_syntax_before_binding(tmp: string)
  Fuzz.run({
    name = "net numeric host syntax",
    dir = tmp,
    gen = gen_host,
    requires = { "bound", "refused" },
    shares = { bound = 0.1, refused = 0.2 },
    check = function(host: string): boolean, string
      local expected = dotted_quad(host)
      local bound, why = Net.datagram(Net.udp(host, 0))
      if bound ~= nil then
        assert(bound:close())
        if not expected then return false, "bound an invalid numeric host" end
        Fuzz.label("bound")
      else
        if expected then return false, "a valid loopback was refused: " .. why end
        if not why:find("not a numeric", 1, true) then
          return false, "refused after parsing: " .. why
        end
        Fuzz.label("refused")
      end
      return true, ""
    end,
  })
end
