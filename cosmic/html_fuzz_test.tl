--- Fuzz properties for [`cosmic.html`], whose escapers take any bytes: the
--- text escaper leaves none of the characters that open markup and is
--- undone by reading its five entities; the attribute escaper leaves
--- only letters, digits, character references and bytes of 0x80 or more,
--- and is undone by reading its references; and `concat` is the join
--- of its parts' strings.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Html = require("cosmic.html")

--- Bytes that matter to either escaper, drawn more often than chance would.
local TOKENS <const> = { "<", ">", "&", '"', "'", " ", "=", "`", "/", "\0", "\n", "&amp;", "&#39;", "&lt;",
  "a", "Z", "0", "\xc3\xa9", "\xe2\x82\xac", "\xff", "\x80" }

--- A string of tokens and arbitrary bytes, drawn with [`Fuzz.more`] so
--- shrinking can cut any piece.
local function gen_text(src: Fuzz.Source): string
  local parts: {string} = {}
  while Fuzz.more(src, #parts, 16) do
    parts[#parts + 1] = src:int(0, 3) == 0 and Fuzz.bytes(src, 3) or Fuzz.pick(src, TOKENS)
  end
  return table.concat(parts)
end

local ENTITIES <const>: {string: string} = { amp = "&", lt = "<", gt = ">", quot = '"', ["#39"] = "'" }

--- `text` with the five entities `escape` writes read back.
local function unescape(text: string): string
  return (text:gsub("&(#?%w+);", ENTITIES))
end

--- Whether an `&` of `text` begins none of the five entities.
local function has_stray_ampersand(text: string): boolean
  local rest = text:gsub("&(#?%w+);", function(name: string): string | nil
    if ENTITIES[name] then return "" end
    return nil
  end)
  return rest:find("&", 1, true) ~= nil
end

local function test_escape_leaves_no_markup_and_reads_back(tmp: string)
  Fuzz.run({
    name = "html escape",
    dir = tmp,
    gen = gen_text,
    requires = { "escaped", "plain", "empty", "high" },
    shares = { escaped = 0.5 },
    check = function(input: string): boolean, string
      local out = Html.raw(Html.escape(input))
      if out:find("[<>\"']") then return false, "markup left in " .. out end
      if has_stray_ampersand(out) then return false, "an & that begins no entity in " .. out end
      local back = unescape(out)
      if back ~= input then return false, "read back as " .. back end
      if input:find("[&<>\"']") then Fuzz.label("escaped") else Fuzz.label("plain") end
      if input == "" then Fuzz.label("empty") end
      if input:find("[\128-\255]") then Fuzz.label("high") end
      return true, ""
    end,
  })
end

--- `text` with its decimal character references read back.
local function unescape_attr(text: string): string
  return (text:gsub("&#(%d+);", function(digits: string): string
    return string.char(math.tointeger(digits) or 0)
  end))
end

local function test_escape_attr_leaves_only_letters_digits_references_and_high_bytes(tmp: string)
  Fuzz.run({
    name = "html escape attr",
    dir = tmp,
    gen = gen_text,
    requires = { "encoded", "plain", "empty", "high" },
    shares = { encoded = 0.5 },
    check = function(input: string): boolean, string
      local out = Html.raw_attr(Html.escape_attr(input))
      local bare = out:gsub("&#%d+;", "")
      if bare:find("[^%w\128-\255]") then return false, "a byte left that is neither in " .. out end
      for number in out:gmatch("&#(%d+);") do
        if #number > 3 or (math.tointeger(number) or 999) > 127 then
          return false, "a reference outside ASCII in " .. out
        end
      end
      local back = unescape_attr(out)
      if back ~= input then return false, "read back as " .. back end
      if input:find("[^%w\128-\255]") then Fuzz.label("encoded") else Fuzz.label("plain") end
      if input == "" then Fuzz.label("empty") end
      if input:find("[\128-\255]") then Fuzz.label("high") end
      return true, ""
    end,
  })
end

local function test_concat_is_the_join_of_its_parts(tmp: string)
  Fuzz.run({
    name = "html concat",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local parts: {string} = {}
      while Fuzz.more(src, #parts, 8) do
        parts[#parts + 1] = (src:int(0, 1) == 0 and "e" or "t") .. gen_text(src)
      end
      return Fuzz.pack(parts)
    end,
    requires = { "escaped part", "trusted part", "no parts" },
    check = function(input: string): boolean, string
      local made: {Html.SafeHtml} = {}
      local expected: {string} = {}
      for index, part in ipairs(Fuzz.unpack(input)) do
        local text = part:sub(2)
        if part:sub(1, 1) == "e" then
          made[index] = Html.escape(text)
          expected[index] = Html.raw(made[index])
          Fuzz.label("escaped part")
        else
          made[index] = Html.trust(text)
          expected[index] = text
          Fuzz.label("trusted part")
        end
      end
      if #made == 0 then Fuzz.label("no parts") end
      if Html.raw(Html.concat(made)) ~= table.concat(expected) then
        return false, "concat differs from the join of its parts"
      end
      return true, ""
    end,
  })
end
