--- Fuzz properties for [`cosmic.relay.address`], which reads addresses out
--- of DNS answers, untrusted bytes: no text raises it; an IPv6 address
--- reads as the 16 bytes it was written from, however it is spelled; an
--- address that carries an IPv4 one is refused undecoded;
--- and a literal grant opens its address alone, and selection answers the
--- first allowed address. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local relay_address = require("cosmic.relay.address")

local NONE: {string} = {}
local NO_OWN: {{integer}} = {}

--- Octets at the edges of the classes' ranges, and neighbours.
local EDGES <const>: {integer} = { 0, 1, 9, 10, 11, 15, 16, 31, 32, 63, 64, 99, 100, 101, 126, 127,
  128, 167, 168, 169, 170, 171, 172, 173, 191, 192, 197, 198, 199, 200, 202, 203, 204, 223, 224,
  239, 240, 253, 254, 255 }

local function octet(src: Fuzz.Source): integer
  if src:int(0, 3) == 0 then return src:int(0, 255) end
  return Fuzz.pick(src, EDGES)
end

local function four(src: Fuzz.Source): {integer}
  return { octet(src), octet(src), octet(src), octet(src) }
end

local function dotted(b: {integer}): string
  return table.concat(b, ".")
end

local function gen_group(src: Fuzz.Source): integer
  local kind = src:int(0, 3)
  if kind == 0 then return 0 end
  if kind == 1 then
    return Fuzz.pick(src, { 1, 0x64, 0xff9b, 0xffff, 0x2002, 0x2001, 0xfe80, 0xfd00, 0xfc00, 0xff00, 0x0db8, 0xec2, 0x254 })
  end
  return src:int(0, 0xffff)
end

--- The IPv6 text of the groups `g`, the run from `at` of `count` zero groups
--- written "::" (when `count` is at least 1 and they are zero), in `upper`
--- case, with its last two groups as a dotted quad when `tail`.
local function render(g: {integer}, at: integer, count: integer, upper: boolean, tail: boolean): string
  local run = count >= 1 and at >= 1 and at + count - 1 <= 8
  if run then
    for i = at, at + count - 1 do
      if g[i] ~= 0 then run = false end
    end
  end
  local function part(i: integer): string
    if tail and i == 7 then
      return dotted({ g[7] >> 8, g[7] & 0xff, g[8] >> 8, g[8] & 0xff })
    end
    if tail and i == 8 then return "" end
    local text = ("%x"):format(g[i])
    if upper then text = text:upper() end
    return text
  end
  local function list(from: integer, to: integer): string
    local out: {string} = {}
    for i = from, to do
      local text = part(i)
      if text ~= "" then out[#out + 1] = text end
    end
    return table.concat(out, ":")
  end
  if run and tail and at + count - 1 >= 7 then run = false end
  if not run then return list(1, 8) end
  return list(1, at - 1) .. "::" .. list(at + count, 8)
end

--- Text near an address: valid ones, their mutations and token soup.
local TOKENS <const> = { "0", "1", "10", "ff", "ffff", "12345", ":", "::", ".", "1.2.3.4", "255",
  "256", "00", "%", "g", "-", " ", "\0", "[", "]", "/", "::ffff:", "64:ff9b::", "2002:", "fe80::" }

local function gen_text(src: Fuzz.Source): string
  local mode = src:int(0, 3)
  if mode == 0 then return Fuzz.bytes(src, 48) end
  if mode == 1 then
    local out: {string} = {}
    while Fuzz.more(src, #out, 20) do out[#out + 1] = Fuzz.pick(src, TOKENS) end
    return table.concat(out)
  end
  local sample: string
  if mode == 2 then
    sample = dotted(four(src))
  else
    local g: {integer} = {}
    for i = 1, 8 do g[i] = gen_group(src) end
    sample = render(g, src:int(1, 8), src:int(0, 8), src:int(0, 1) == 1, src:int(0, 1) == 1)
  end
  return Fuzz.mutate(src, sample, 3)
end

local function test_no_text_raises_the_parser_or_the_check(tmp: string)
  Fuzz.run({
    name = "relay address never raises",
    dir = tmp,
    gen = gen_text,
    requires = { "ipv4", "ipv6", "rejected" },
    shares = { ipv4 = 0.02, ipv6 = 0.02, rejected = 0.1 },
    check = function(text: string): boolean, string
      local ok, parsed = pcall(relay_address.parse, text)
      if not ok then return false, "parse raised: " .. tostring(parsed) end
      local checked, allowed, why = pcall(relay_address.check, text, 443, { (text:find(":", 1, true) and "[" .. text .. "]" or text) .. ":443" }, NO_OWN)
      if not checked then return false, "check raised: " .. tostring(allowed) end
      local selected, picked, reason = pcall(relay_address.select,
        { { address = text, family = "inet" } }, 443, NONE, NO_OWN)
      if not selected then return false, "select raised: " .. tostring(picked) end
      local bytes = parsed as {integer} | nil
      if bytes == nil then
        Fuzz.label("rejected")
        if allowed then return false, "allowed text that is no address" end
        if picked ~= nil then return false, "selected text that is no address" end
        return true, ""
      end
      Fuzz.label(#bytes == 4 and "ipv4" or "ipv6")
      if #bytes ~= 4 and #bytes ~= 16 then return false, "bytes of length " .. #bytes end
      for _, b in ipairs(bytes) do
        if math.type(b) ~= "integer" or b < 0 or b > 255 then return false, "byte out of range" end
      end
      if not allowed then
        return false, "an address its own grant does not open: " .. tostring(why)
      end
      return true, tostring(reason)
    end,
  })
end

--- Sixteen bytes from eight drawn groups.
local function gen_bytes16(src: Fuzz.Source): string
  local out: {string} = {}
  for _ = 1, 8 do
    local g = gen_group(src)
    out[#out + 1] = string.char(g >> 8, g & 0xff)
  end
  return table.concat(out)
end

local function groups_of(bytes: string): {integer}
  local g: {integer} = {}
  for i = 1, 8 do g[i] = bytes:byte(2 * i - 1) * 256 + bytes:byte(2 * i) end
  return g
end

--- How `bytes` is written, in the spelling `style` (four bytes: where a
--- run of zero groups starts and how long it is, upper case, an IPv4 tail)
--- chooses.
local function spelled(bytes: string, style: string): string
  return render(groups_of(bytes), style:byte(1), style:byte(2), style:byte(3) == 1, style:byte(4) == 1)
end

local function gen_style(src: Fuzz.Source): string
  return string.char(src:int(1, 8), src:int(0, 8), src:int(0, 1), src:int(0, 1))
end

local function test_an_ipv6_address_reads_as_the_bytes_it_was_written_from(tmp: string)
  Fuzz.run({
    name = "relay address ipv6 round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local bytes, style = gen_bytes16(src), gen_style(src)
      if src:int(0, 2) > 0 then
        -- Zero the run the style compresses, so that it can be.
        local at, count = style:byte(1), style:byte(2)
        local zeroed: {string} = {}
        for i = 1, 8 do
          local inside = i >= at and i < at + count
          zeroed[i] = inside and "\0\0" or bytes:sub(2 * i - 1, 2 * i)
        end
        bytes = table.concat(zeroed)
      end
      return Fuzz.pack({ bytes, style })
    end,
    requires = { "compressed", "tail", "plain" },
    shares = { compressed = 0.2, tail = 0.1, plain = 0.05 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local text = spelled(fields[1], fields[2])
      local parsed = relay_address.parse(text)
      if parsed == nil then return false, "refused " .. text end
      if string.char(table.unpack(parsed)) ~= fields[1] then
        return false, text .. " read as other bytes"
      end
      Fuzz.label(text:find("::", 1, true) and "compressed" or "plain")
      if text:find(".", 1, true) then Fuzz.label("tail") end
      return true, ""
    end,
  })
end

--- Which prefix carries the IPv4 address `v4`: the 16 bytes, filled with
--- `filler` where the form leaves bits free: 0 is IPv4-mapped, 1 IPv4-compatible,
--- 2 NAT64 in 64:ff9b::/96 and 3 the local-use 64:ff9b:1::/48 laid out as
--- RFC 6052 would, which the relay refuses rather than decodes.
local function carrying(form: integer, v4: {integer}, filler: string): string
  local head = filler
  if form == 0 then
    return string.rep("\0", 10) .. "\xff\xff" .. string.char(table.unpack(v4))
  elseif form == 1 then
    return string.rep("\0", 12) .. string.char(table.unpack(v4))
  elseif form == 2 then
    return "\0\x64\xff\x9b" .. string.rep("\0", 8) .. string.char(table.unpack(v4))
  end
  -- RFC 6052 /48: the address in octets 6-7 and 9-10 (0-based), the u octet
  -- between them and the suffix after being free.
  return "\0\x64\xff\x9b\0\x01" .. string.char(v4[1], v4[2], head:byte(1)) ..
    string.char(v4[3], v4[4]) .. head:sub(2, 6)
end

local function test_an_address_carrying_ipv4_is_refused_whatever_it_carries(tmp: string)
  Fuzz.run({
    name = "relay address embedded forms",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local v4 = four(src)
      return Fuzz.pack({ string.char(src:int(0, 3), src:int(0, 1), table.unpack(v4)),
        gen_bytes16(src), gen_style(src) })
    end,
    requires = { "refused", "own" },
    shares = { refused = 0.9, own = 0.3 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local form, own_mode = fields[1]:byte(1), fields[1]:byte(2)
      local v4 = { fields[1]:byte(3, 6) }
      local text = spelled(carrying(form, v4, fields[2]), fields[3])
      local own = own_mode == 0 and relay_address.own_addresses({ dotted(v4) }) or NO_OWN
      if own_mode == 0 then Fuzz.label("own") end
      local got, why = relay_address.check(text, 443, NONE, own)
      if got then return false, text .. " is allowed though it carries " .. dotted(v4) end
      if why:find("carrying", 1, true) then
        return false, "the reason decodes the carried address: " .. why
      end
      Fuzz.label("refused")
      return true, ""
    end,
  })
end

--- An address, spelled in one of the ways of the classes above.
local function gen_address(src: Fuzz.Source): string
  local kind = src:int(0, 2)
  if kind == 0 then return dotted(four(src)) end
  if kind == 1 then return spelled(gen_bytes16(src), gen_style(src)) end
  return spelled(carrying(src:int(0, 3), four(src), gen_bytes16(src)), gen_style(src))
end

local function target(address: string, port: integer): string
  return (address:find(":", 1, true) and "[" .. address .. "]" or address) .. ":" .. port
end

local function test_a_grant_opens_its_address_and_selection_takes_the_first_allowed(tmp: string)
  Fuzz.run({
    name = "relay address grants and selection",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local list: {string} = {}
      -- A fourth of the lists hold only addresses a whole class refuses.
      local refused = src:int(0, 3) == 0
      while Fuzz.more(src, #list, 8) do
        if refused then
          local first = Fuzz.pick(src, { 0, 10, 127, 224, 240, 255 })
          list[#list + 1] = dotted({ first, octet(src), octet(src), octet(src) })
        else
          list[#list + 1] = gen_address(src)
        end
      end
      return Fuzz.pack(list)
    end,
    requires = { "picked", "none", "granted" },
    shares = { picked = 0.2, none = 0.05, granted = 0.5 },
    check = function(input: string): boolean, string
      local list = Fuzz.unpack(input)
      local port = 8443
      local answers: {relay_address.Answer} = {}
      for _, a in ipairs(list) do answers[#answers + 1] = { address = a, family = "" } end
      -- A grant of an address opens it on its port or any, and no other address.
      for i, a in ipairs(list) do
        for _, grant in ipairs({ target(a, port), (target(a, port):gsub(":%d+$", ":*")) }) do
          if not relay_address.check(a, port, { grant }, NO_OWN) then
            return false, a .. " is not opened by " .. grant
          end
          if relay_address.check(a, port + 1, { target(a, port) }, NO_OWN) ~=
              relay_address.check(a, port + 1, NONE, NO_OWN) then
            return false, a .. " is opened on another port by " .. grant
          end
          Fuzz.label("granted")
          local mine = relay_address.parse(a) as {integer}
          for j, b in ipairs(list) do
            local theirs = relay_address.parse(b) as {integer}
            if j ~= i and table.concat(theirs, ",") ~= table.concat(mine, ",") then
              if relay_address.check(b, port, { grant }, NO_OWN) ~= relay_address.check(b, port, NONE, NO_OWN) then
                return false, grant .. " opens " .. b
              end
            end
          end
        end
      end
      -- Selection: the first answer check allows, else a reason naming every one.
      local first: integer = nil
      for i, a in ipairs(list) do
        if relay_address.check(a, port, NONE, NO_OWN) then
          first = i
          break
        end
      end
      local picked, why = relay_address.select(answers, port, NONE, NO_OWN)
      if first ~= nil then
        if picked == nil or picked ~= answers[first] then
          return false, "did not pick answer " .. first
        end
        Fuzz.label("picked")
      elseif #list > 0 then
        if picked ~= nil then return false, "picked a refused answer" end
        for _, a in ipairs(list) do
          if not why:find(a, 1, true) then return false, "the refusal omits " .. a end
        end
        Fuzz.label("none")
      end
      return true, ""
    end,
  })
end
