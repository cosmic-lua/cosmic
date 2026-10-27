--- Fuzz properties for the cookie parsers, which read a header and a
--- `Set-Cookie` line a peer chose: neither raises, [`Cookies.parse`] keeps
--- to its limits and invents no name, and what [`Cookies.format`] writes is
--- read back by both.

local Cookies = require("cosmic.web.cookies")
local Fuzz = require("build.fuzz")

--- Characters that make a header interesting.
local PIECES <const>: {string} = { "a", "b", "sid", "=", ";", ",", " ", "\t", '"', "1", "x y", "%41", "é", "\0",
  "\r", "Path=/", "Secure", "; ", ", ", "==" }

local function gen_header(src: Fuzz.Source): string
  local parts: mut {string} = {}
  while Fuzz.more(src, #parts, 24) do
    if src:int(0, 4) == 0 then
      parts[#parts + 1] = Fuzz.bytes(src, 8)
    else
      parts[#parts + 1] = Fuzz.pick(src, PIECES)
    end
  end
  return table.concat(parts)
end

local TOKEN <const>: {string} = { "a", "sid", "__Host-id", "__Secure-x", "A-b_c", "n1" }
local VALUE <const>: {string} = { "", "v", "abc123", "a=b", "%41%42", "Zm9v.YmFy", "~!#$&'()*+-./:<=>?@[]^_`{|}" }

local function test_parse_never_raises_and_keeps_to_its_limits(tmp: string)
  Fuzz.run({
    name = "cookies parse",
    dir = tmp,
    gen = gen_header,
    requires = { "some", "none" },
    shares = { some = 0.2, none = 0.05 },
    check = function(input: string): boolean, string
      local got = Cookies.parse(input)
      local n = 0
      for name, value in pairs(got) do
        n = n + 1
        if name == "" or name:find("[;,=]") then return false, ("name %q"):format(name) end
        if value:find("[;,]") then
          return false, ("value %q of %s holds a separator"):format(value, name)
        end
        if not input:find(name, 1, true) then
          return false, ("name %q is not in the header"):format(name)
        end
      end
      if n > 100 then return false, tostring(n) .. " cookies" end
      Fuzz.label(if n > 0 then "some" else "none" end)
      return true, ""
    end,
  })
end

local function test_what_format_writes_is_read_back_by_both_parsers(tmp: string)
  Fuzz.run({
    name = "cookies round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ Fuzz.pick(src, TOKEN), Fuzz.pick(src, VALUE), tostring(src:int(0, 7)) })
    end,
    requires = { "written", "refused" },
    shares = { written = 0.3, refused = 0.02 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local name, value, bits = fields[1], fields[2], math.tointeger(tonumber(fields[3])) or 0
      local line = Cookies.format(name, value, {
        secure = bits & 1 ~= 0, http_only = bits & 2 ~= 0, max_age = if bits & 4 ~= 0 then 30 else nil end,
        same_site = if bits & 1 ~= 0 then "None" else "Lax" end, path = "/",
      })
      if line == nil then
        Fuzz.label("refused")
        return true, ""
      end
      Fuzz.label("written")
      if #line > 4096 then return false, "a line over 4096 bytes was written" end
      local parsed = Cookies.parse_set_cookie(line)
      if parsed == nil or parsed.name ~= name or parsed.value ~= value then
        return false, ("%q is not read back as %s=%s"):format(line, name, value)
      end
      if Cookies.parse(name .. "=" .. value)[name] ~= value then
        return false, ("the header %s=%s is not read back"):format(name, value)
      end
      return true, ""
    end,
  })
end

local function test_parse_set_cookie_never_raises(tmp: string)
  Fuzz.run({
    name = "cookies parse_set_cookie",
    dir = tmp,
    gen = gen_header,
    requires = { "parsed", "refused" },
    shares = { parsed = 0.1, refused = 0.1 },
    check = function(input: string): boolean, string
      local parsed = Cookies.parse_set_cookie(input)
      if parsed == nil then
        Fuzz.label("refused")
        return true, ""
      end
      if parsed.name == "" then return false, "an empty name" end
      Fuzz.label("parsed")
      return true, ""
    end,
  })
end
