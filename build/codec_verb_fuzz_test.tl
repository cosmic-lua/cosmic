--- Fuzz properties for `cosmic codec`'s decoding (build/codec.tl), which
--- reads more than [`cosmic.codec`] does: it strips whitespace and
--- handles padding and `--lenient`. Every encoding decodes what it
--- wrote, wrapped or not and with whitespace strewn through it; every
--- spelling of the text is total -- bytes or a reason naming an offset,
--- and never a raise; and what it accepts encodes back to the text
--- it came from, whitespace aside. `FUZZ_SEED` and `FUZZ_ITERS` pick the
--- inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Codec = require("cosmic.codec")
local codec = require("build.codec")

local NAMES <const>: {Codec.Name} = { "hex", "base64", "base64url" }

local TEXT <const> = "0123456789abcdefABCDEFxyzXYZ+/-_==\n \t\r\0\xff"

local function gen_text(src: Fuzz.Source): string
  if src:int(0, 1) == 0 then
    return Fuzz.bytes(src, 64)
  end
  local out: {string} = {}
  while Fuzz.more(src, #out, 64) do
    local at = src:int(1, #TEXT)
    out[#out + 1] = TEXT:sub(at, at)
  end
  return table.concat(out)
end

--- `text` with whitespace dropped in where the bytes of `where` say:
--- each byte picks a place and which whitespace.
local function strewn(text: string, where: string): string
  local marks: {string} = { " ", "\t", "\n", "\r", "\f", "\v" }
  local out = text
  for i = 1, #where do
    local b = where:byte(i)
    local at = b % (#out + 1)
    out = out:sub(1, at) .. marks[b % #marks + 1] .. out:sub(at + 1)
  end
  return out
end

local function test_decoding_takes_back_what_encoding_writes(tmp: string)
  for _, name in ipairs(NAMES) do
    Fuzz.run({
      name = name .. " verb round trip",
      dir = tmp,
      gen = function(src: Fuzz.Source): string
        return Fuzz.pack({ Fuzz.bytes(src, 200), tostring(src:int(0, 9)),
          tostring(src:int(0, 1)), Fuzz.bytes(src, 12) })
      end,
      check = function(input: string): boolean, string
        local fields = Fuzz.unpack(input)
        local bytes, wrap = fields[1], math.tointeger(tonumber(fields[2])) or 0
        local lenient = fields[3] == "1" and name ~= "hex"
        local text = codec.encode(name, bytes, wrap)
        local mixed = strewn(text, fields[4])
        local back, why = codec.decode(name, mixed, lenient)
        if back ~= bytes then
          return false, ("%q decoded to %q: %s"):format(mixed, tostring(back), why)
        end
        if lenient then
          -- Padding dropped or added to the other spelling still reads.
          local bare = strewn(text:gsub("[=\n]", ""), fields[4])
          local again = codec.decode(name, bare, true)
          if again ~= bytes then return false, ("%q decoded to %q"):format(bare, tostring(again)) end
        end
        return true, ""
      end,
    })
  end
end

local function test_decoding_is_total_and_exact(tmp: string)
  for _, name in ipairs(NAMES) do
    for _, lenient in ipairs({ false, true }) do
      if not (name == "hex" and lenient) then
        Fuzz.run({
          name = name .. (lenient and " lenient" or "") .. " verb decoder total",
          dir = tmp,
          gen = function(src: Fuzz.Source): string
            local text = gen_text(src)
            if src:int(0, 2) == 0 then
              return Fuzz.mutate(src, codec.encode(name, text, 0), 3)
            end
            return text
          end,
          check = function(input: string): boolean, string
            local bytes, why = codec.decode(name, input, lenient)
            if bytes == nil then
              if why == "" then return false, "refused without a reason" end
              if not why:find("offset %d+") then return false, "no offset in: " .. why end
              Fuzz.label("refused")
              return true, ""
            end
            Fuzz.label("accepted")
            if why ~= "" then return false, "accepted with a reason: " .. why end
            -- What it took encodes to the text without its whitespace,
            -- but for the padding a lenient read let go and hex's case.
            local squeezed = input:gsub("[ \t\n\r\f\v]", "")
            local again = codec.encode(name, bytes, 0):gsub("\n", "")
            if name == "hex" then again = again:lower(); squeezed = squeezed:lower() end
            if lenient then again = again:gsub("=", ""); squeezed = squeezed:gsub("=", "") end
            if again ~= squeezed then
              return false, ("%q read as %q, which writes %q"):format(input, bytes, again)
            end
            return true, ""
          end,
          requires = { "refused", "accepted" },
        })
      end
    end
  end
end

--- Draws a cutting of the input: chunk sizes, empty ones included, one
--- byte each so that shrinking can cut any of them.
local function gen_cuts(src: Fuzz.Source): string
  local sizes: {string} = {}
  while Fuzz.more(src, #sizes, 24) do
    sizes[#sizes + 1] = string.char(src:int(0, 9))
  end
  return table.concat(sizes)
end

--- What decoding `text` in chunks of the sizes `cuts` bytes give, then
--- a byte at a time, answers: the bytes, or nil and the reason.
local function decode_cut(name: Codec.Name, text: string, lenient: boolean, cuts: string): string | nil, string
  local coder = codec.decoding(name, lenient)
  local out: {string} = {}
  local at, k = 1, 0
  while at <= #text do
    k = k + 1
    local size = k <= #cuts and cuts:byte(k) or 1
    local part, why = coder:update(text:sub(at, at + size - 1))
    if part == nil then return nil, why end
    out[#out + 1] = part
    at = at + size
  end
  local last, why = coder:finish()
  if last == nil then return nil, why end
  out[#out + 1] = last
  return table.concat(out), ""
end

local function test_chunked_decoding_answers_as_the_whole_text_does(tmp: string)
  for _, name in ipairs(NAMES) do
    for _, lenient in ipairs({ false, true }) do
      if not (name == "hex" and lenient) then
        Fuzz.run({
          name = name .. (lenient and " lenient" or "") .. " verb chunked decode",
          dir = tmp,
          gen = function(src: Fuzz.Source): string
            local text = gen_text(src)
            local shape = src:int(0, 2)
            if shape == 0 then
              text = Fuzz.mutate(src, codec.encode(name, Fuzz.bytes(src, 60), src:int(0, 7)), 2)
            elseif shape == 1 then
              text = strewn(codec.encode(name, Fuzz.bytes(src, 60), 0), Fuzz.bytes(src, 6))
            end
            return Fuzz.pack({ text, gen_cuts(src) })
          end,
          check = function(input: string): boolean, string
            local fields = Fuzz.unpack(input)
            local want, want_why = codec.decode(name, fields[1], lenient)
            local got, why = decode_cut(name, fields[1], lenient, fields[2])
            if got ~= want or why ~= want_why then
              return false, ("%q cut %q: %s | %s, whole %s | %s"):format(
                fields[1], fields[2], tostring(got), why, tostring(want), want_why)
            end
            Fuzz.label(want == nil and "refused" or "accepted")
            return true, ""
          end,
          requires = { "refused", "accepted" },
        })
      end
    end
  end
end
