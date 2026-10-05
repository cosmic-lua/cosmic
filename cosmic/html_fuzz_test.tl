--- Fuzz properties for [`cosmic.html`], whose escapers take any bytes: the
--- text escaper leaves none of the characters that open markup and is
--- undone by reading its five entities; the attribute escaper leaves
--- only letters, digits, character references and bytes of 0x80 or more,
--- and is undone by reading its references; and `concat` is the join
--- of its parts' strings; and `href` answers `about:invalid` or a URL
--- with no control byte or edge space whose scheme a browser would see is
--- http, https or mailto, or that is relative and no host.
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

local URL_TOKENS <const> = { "http", "https", "HTTPS", "mailto", "javascript", "data", "java", "script", ":", "://",
  "/", "//", "\\", "?", "#", ".", "+", "-", "%6A", "a", "Z", "9", " ", "\t", "\n", "\r", "\0", "\1", "\127",
  "\xc3\xa9", "\xff", "@", "=", "&", "<" }

local SCHEMES <const> = { "http", "HTTPS", "mailto", "javascript", "data", "ftp", "x-y.z+1", "1a", "%6A" }

local function gen_url(src: Fuzz.Source): string
  local parts: {string} = {}
  -- Half the inputs start as a scheme and a colon, so the allowlist is reached.
  if src:int(0, 1) == 0 then
    parts[1] = Fuzz.pick(src, SCHEMES) .. ":"
  end
  while Fuzz.more(src, #parts, 12) do
    parts[#parts + 1] = src:int(0, 5) == 0 and Fuzz.bytes(src, 2) or Fuzz.pick(src, URL_TOKENS)
  end
  return table.concat(parts)
end

local ALLOWED_SCHEMES <const>: {string: boolean} = { http = true, https = true, mailto = true }

--- The scheme of `text` as a browser's parser would see it, from the
--- start: a letter, then letters, digits, `+`, `-` or `.`, then `:`.
local function scheme_of(text: string): string | nil
  local name = text:match("^(%a[%w+.%-]*):")
  if name ~= nil and name:find("[^%w+.%-]") == nil then
    return name:lower()
  end
  return nil
end

--- Whether `text` is a safe URL by the rules stated apart from the C: it
--- holds no control byte and no edge space, and either has an allowed
--- scheme or is relative (no colon ahead of a `/`, `?` or `#`, or not
--- starting two slashes).
local function url_is_safe(text: string): boolean
  if text:find("[%z\1-\31\127]") or text:find("^ ") or text:find(" $") then
    return false
  end
  local scheme = scheme_of(text)
  if scheme ~= nil then
    return ALLOWED_SCHEMES[scheme] == true
  end
  return text:find("^[/\\][/\\]") == nil
end

--- What `href` must answer for `text` when it does not refuse more than
--- the browser's reading needs: the same, but a colon ahead of any `/`,
--- `?` or `#` without an allowed scheme is refused too.
local function url_expected(text: string): string
  if not url_is_safe(text) then return "about:invalid" end
  local head = text:match("^[^/?#]*")
  if head:find(":", 1, true) and scheme_of(text) == nil then return "about:invalid" end
  return text
end

local function test_href_answers_a_safe_url_or_about_invalid(tmp: string)
  Fuzz.run({
    name = "html href",
    dir = tmp,
    gen = gen_url,
    requires = { "allowed", "refused", "scheme", "relative", "empty" },
    shares = { allowed = 0.05, scheme = 0.2 },
    check = function(input: string): boolean, string
      local out = Html.raw_url(Html.href(input))
      if out ~= "about:invalid" then
        if out ~= input then return false, "answered a different text " .. out end
        if not url_is_safe(out) then return false, "let through an unsafe URL" end
      end
      if out ~= url_expected(input) then
        return false, "answered " .. out .. " where " .. url_expected(input)
      end
      if out == "about:invalid" then Fuzz.label("refused") else Fuzz.label("allowed") end
      if scheme_of(input) ~= nil then Fuzz.label("scheme") else Fuzz.label("relative") end
      if input == "" then Fuzz.label("empty") end
      return true, ""
    end,
  })
end
