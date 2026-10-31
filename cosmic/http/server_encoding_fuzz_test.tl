--- Fuzz properties for [`Server.encoding`], which reads the
--- Accept-Encoding header any client sends: it is total over any bytes;
--- and for a header drawn from well-formed elements it answers what a
--- reading of RFC 9110 section 12.5.3 written apart from the module
--- says. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Server = require("cosmic.http.server")

local NAMES <const> = { "zstd", "gzip", "identity", "*", "br", "deflate", "ZSTD", "GzIp", "x-gzip", "Identity" }
local WEIGHTS <const> = { "", "", "", ";q=0", ";q=1", ";q=0.5", ";q=0.001", ";q=0.000", ";q=1.000",
  ";Q=0.9", "; q=0.2", ";q=0.", ";q=1." }
local SPACES <const> = { "", "", " ", "\t", "  " }

--- The elements of a header, each a coding or `*` and maybe a weight,
--- with spaces round it; the property joins them with commas.
local function gen_header(src: Fuzz.Source): string
  local fields: mut {string} = {}
  while Fuzz.more(src, #fields, 5) do
    fields[#fields + 1] = Fuzz.pick(src, SPACES) .. Fuzz.pick(src, NAMES) .. Fuzz.pick(src, SPACES) ..
      Fuzz.pick(src, WEIGHTS) .. Fuzz.pick(src, SPACES)
  end
  return Fuzz.pack(fields)
end

--- The weight of an element's `weight` text in thousandths.
local function thousandths(text: string): integer
  if text == "" then return 1000 end
  local digits = text:match("=([%d.]+)$")
  assert(digits, "the generator writes a q=")
  local whole, fraction = digits:match("^(%d)%.?(%d*)$")
  assert(whole and fraction, "the generator writes a qvalue")
  return (math.tointeger(tonumber(whole)) or 0) * 1000 +
    (math.tointeger(tonumber((fraction .. "00"):sub(1, 3))) or 0)
end

-- An answer is a coding offered, "identity" or nil, whatever the bytes.
local function test_encoding_is_total_over_any_header(tmp: string)
  Fuzz.run({
    name = "http encoding total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return if src:int(0, 1) == 0 then Fuzz.mutate(src, "gzip;q=0.5, zstd, *;q=0, identity", 6) else Fuzz.bytes(src, 24) end
    end,
    check = function(input: string): boolean, string
      local got = Server.encoding(input)
      Fuzz.label(got or "none")
      if got ~= nil and got ~= "zstd" and got ~= "gzip" and got ~= "identity" then
        return false, "answered " .. got
      end
      return true, ""
    end,
    requires = { "zstd", "gzip", "identity", "none" },
    shares = { zstd = 0.01, none = 0.01 },
  })
end

-- For a well-formed header, the answer is acceptable (a weight above 0,
-- by its own element or `*`; identity unless refused), no coding offered
-- weighs more, and the answer is "identity" only where no coding is
-- acceptable or identity is named with a weight above every coding's.
local function test_encoding_follows_the_weights(tmp: string)
  Fuzz.run({
    name = "http encoding weights",
    dir = tmp,
    gen = gen_header,
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local named: mut {string: integer} = {}
      local star: integer? = nil
      for _, element in ipairs(fields) do
        local name, weight = element:match("^[ \t]*([%w%-*]+)[ \t]*(.-)[ \t]*$")
        assert(name and weight, "the generator writes elements")
        name = name:lower()
        local q = thousandths(weight)
        if name == "*" then
          star = star or q
        else
          if name == "x-gzip" then name = "gzip" end
          named[name] = named[name] or q
        end
      end
      local function weight_of(coding: string): integer
        return named[coding] or star or 0
      end
      local got = Server.encoding(table.concat(fields, ","))
      local top = math.max(weight_of("zstd"), weight_of("gzip"))
      local identity = named["identity"]
      local identity_ok = if identity ~= nil then identity > 0 else star ~= 0 end
      if got == nil then
        Fuzz.label("none")
        if top > 0 or identity_ok then return false, "refused where something was acceptable" end
      elseif got == "identity" then
        Fuzz.label("identity")
        if not identity_ok then return false, "identity where it is refused" end
        if top > 0 and not (identity ~= nil and identity > top) then
          return false, "identity where a coding was accepted"
        end
      else
        Fuzz.label(got)
        if weight_of(got) ~= top or top == 0 then
          return false, got .. " is not the heaviest accepted"
        end
        if identity ~= nil and identity > top then
          return false, "a coding where identity weighs more"
        end
        if got == "gzip" and weight_of("zstd") == top then
          return false, "gzip on a tie with zstd"
        end
      end
      return true, ""
    end,
    requires = { "zstd", "gzip", "identity", "none" },
    shares = { zstd = 0.05, gzip = 0.05, none = 0.01 },
  })
end
