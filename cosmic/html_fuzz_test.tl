--- Fuzz properties for [`cosmic.html`], whose escapers take any bytes: the
--- text escaper leaves none of the characters that open markup and is
--- undone by reading its five entities; the attribute escaper's output,
--- read between either quote by the standard's tokenizer, ends at that
--- quote and reads back as its input; and `concat` is the join
--- of its parts' strings; and `href` answers `about:invalid` or a URL
--- with no control byte or edge space whose scheme a browser would see is
--- http, https or mailto, or that is relative and no host.
--- `url_part` writes only unreserved bytes and `%XX`, reads back as its
--- input (but for a whole `.` or `..`) and agrees with [`Url.escape`];
--- `escape_css_attr` leaves only identifier text and hex escapes, which
--- need no attribute escaping.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Html = require("cosmic.html")
local Url = require("cosmic.url")

--- Bytes that matter to either escaper, drawn more often than chance would.
local TOKENS <const> = { "<", ">", "&", '"', "'", " ", "=", "`", "/", "\0", "\n", "&amp;", "&#39;", "&lt;",
  "a", "Z", "0", "\xc3\xa9", "\xe2\x82\xac", "\xff", "\x80" }

--- A string of tokens and arbitrary bytes, drawn with [`Fuzz.more`] so
--- shrinking can cut any piece.
local function gen_text(src: Fuzz.Source): string
  local parts: mut {string} = {}
  while Fuzz.more(src, #parts, 16) do
    parts[#parts + 1] = if src:int(0, 3) == 0 then Fuzz.bytes(src, 3) else Fuzz.pick(src, TOKENS) end
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
  local rest = text:gsub("&(#?%w+);", function(name: string): string?
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

--- The named references [`read_quoted`] knows: those `escape_attr` writes.
local NAMED <const>: {string: string} = { amp = "&", quot = '"', lt = "<", gt = ">" }

--- How a value ended, as [`read_quoted`] tells it.
local record Quoted
  --- The value as the browser holds it, references decoded.
  value: string
  --- The byte after the closing quote, or 0 where the text ran out
  --- first or a reference was one this reader cannot decode.
  after: integer
  --- What went wrong, or "".
  why: string
end

--- The text at the start of `s` read as the HTML standard's tokenizer
--- reads the value of an attribute in `quote` (`"` or `'`), from the
--- states "attribute value (double-quoted)" and "(single-quoted)" (13.2.5.36
--- and 13.2.5.37) and the character reference states (13.2.5.72 to
--- 13.2.5.80): the quote ends it, `&` begins a reference, NUL is U+FFFD,
--- and every other byte is kept. A numeric reference of 0 is U+FFFD and any
--- other below 0x80 is that byte (the C1 table starts at 0x80). A named one
--- is decoded only from `NAMED` with its `;`; any other `&` and a letter or
--- `#` is refused, so a reference this reader does not know fails the check
--- rather than reading wrong. `&` before anything else is kept as itself, as
--- the standard keeps it.
local function read_quoted(s: string, quote: string): Quoted
  local out: mut {string} = {}
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == quote then
      return { value = table.concat(out), after = i + 1, why = "" }
    elseif c == "\0" then
      out[#out + 1] = "\xef\xbf\xbd"
      i = i + 1
    elseif c == "&" then
      local reference, digits = s:match("^(&#[xX]?)(%x+);", i)
      local name = s:match("^&(%w+);", i)
      local named = if name ~= nil then NAMED[name] else nil end
      if reference ~= nil and digits ~= nil and (reference ~= "&#" or digits:find("^%d+$") ~= nil) then
        local code = tonumber(digits, if reference == "&#" then 10 else 16 end)
        if code == nil or code >= 128 then
          return { value = table.concat(out), after = 0, why = "a reference past ASCII: " .. s:sub(i, i + 9) }
        end
        out[#out + 1] = if code == 0 then "\xef\xbf\xbd" else string.char(math.tointeger(code) or 0) end
        i = i + #reference + #digits + 1
      elseif name ~= nil and named ~= nil then
        out[#out + 1] = named
        i = i + #name + 2
      elseif s:find("^&[%w#]", i) then
        return { value = table.concat(out), after = 0, why = "a reference this reader does not know: " .. s:sub(i, i + 9) }
      else
        out[#out + 1] = c
        i = i + 1
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return { value = table.concat(out), after = 0, why = "the text ran out inside the value" }
end

--- `escape_attr`'s output put between double quotes and between single
--- quotes, with markup after it, is read by the standard's tokenizer as a
--- value that ends at the closing quote and holds the input (a NUL as
--- U+FFFD), and holds no `<`, `>` or backtick a looser reader could take
--- for markup or a quote.
local function test_escape_attr_ends_at_its_quote_and_reads_back(tmp: string)
  Fuzz.run({
    name = "html escape attr",
    dir = tmp,
    gen = gen_text,
    requires = { "encoded", "plain", "empty", "high" },
    shares = { encoded = 0.5 },
    check = function(input: string): boolean, string
      local out = Html.raw_attr(Html.escape_attr(input))
      if out:find("[%z\1-\31<>`\127]") then
        return false, "a control, bracket or backtick left in " .. out
      end
      local bare = out:gsub("&amp;", ""):gsub("&quot;", ""):gsub("&lt;", ""):gsub("&gt;", ""):gsub("&#%d+;", "")
      if bare:find("&", 1, true) then
        return false, "an & that begins none of the references written in " .. out
      end
      for number in out:gmatch("&#(%d+);") do
        local code = math.tointeger(number) or 999
        if #number > 3 or not (code < 32 or code == 39 or code == 96 or code == 127) then
          return false, "a reference to a byte that needs none in " .. out
        end
      end
      local expected = input:gsub("%z", "\xef\xbf\xbd")
      for _, quote in ipairs({ '"', "'" }) do
        local tail = quote .. ' x="y"><b>'
        local read = read_quoted(out .. tail, quote)
        if read.why ~= "" then return false, read.why .. " in " .. out end
        if read.after ~= #out + 2 then return false, "the value ended early in " .. out end
        if read.value ~= expected then return false, "read back as " .. read.value end
      end
      if input:find("[%z\1-\31&<>\"'`\127]") then Fuzz.label("encoded") else Fuzz.label("plain") end
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
      local parts: mut {string} = {}
      while Fuzz.more(src, #parts, 8) do
        parts[#parts + 1] = (if src:int(0, 1) == 0 then "e" else "t" end) .. gen_text(src)
      end
      return Fuzz.pack(parts)
    end,
    requires = { "escaped part", "trusted part", "no parts" },
    check = function(input: string): boolean, string
      local made: mut {Html.SafeHtml} = {}
      local expected: mut {string} = {}
      for _, part in ipairs(Fuzz.unpack(input)) do
        local text = part:sub(2)
        if part:sub(1, 1) == "e" then
          local escaped = Html.escape(text)
          made[#made + 1] = escaped
          expected[#expected + 1] = Html.raw(escaped)
          Fuzz.label("escaped part")
        else
          local trusted = Html.trust(text)
          made[#made + 1] = trusted
          expected[#expected + 1] = text
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
  local parts: mut {string} = {}
  -- Half the inputs start as a scheme and a colon, so the allowlist is reached.
  if src:int(0, 1) == 0 then
    parts[1] = Fuzz.pick(src, SCHEMES) .. ":"
  end
  while Fuzz.more(src, #parts, 12) do
    parts[#parts + 1] = if src:int(0, 5) == 0 then Fuzz.bytes(src, 2) else Fuzz.pick(src, URL_TOKENS) end
  end
  return table.concat(parts)
end

local ALLOWED_SCHEMES <const>: {string: boolean} = { http = true, https = true, mailto = true }

--- The scheme of `text` as a browser's parser would see it, from the
--- start: a letter, then letters, digits, `+`, `-` or `.`, then `:`.
local function scheme_of(text: string): string?
  local name = text:match("^(%a[%w+.%-]*):")
  return if name ~= nil then name:lower() else nil end
end

--- Whether `text` is a safe URL by the browser's rules: it
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
  local delimiter = text:find("[/?#]")
  local head = if delimiter == nil then text else text:sub(1, delimiter - 1) end
  if head:find(":", 1, true) ~= nil and scheme_of(text) == nil then return "about:invalid" end
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

local PART_TOKENS <const> = { ".", "..", "%", "%2e", "%41", "/", "?", "#", "&", "=", "+", ":", "@", "\\", " ",
  "-", "_", "~", "a", "Z", "0", "\0", "\n", "\xc3\xa9", "\xff" }

local function gen_part(src: Fuzz.Source): string
  -- A whole dot segment is a case of its own, drawn often enough to be reached.
  if src:int(0, 7) == 0 then return Fuzz.pick(src, { ".", ".." }) end
  local parts: mut {string} = {}
  while Fuzz.more(src, #parts, 6) do
    parts[#parts + 1] = if src:int(0, 3) == 0 then Fuzz.bytes(src, 3) else Fuzz.pick(src, PART_TOKENS) end
  end
  return table.concat(parts)
end

local function test_url_part_writes_only_unreserved_bytes_and_escapes(tmp: string)
  Fuzz.run({
    name = "html url part",
    dir = tmp,
    gen = gen_part,
    requires = { "escaped", "plain", "empty", "dot segment" },
    shares = { escaped = 0.5 },
    check = function(input: string): boolean, string
      local out = Html.raw_url_part(Html.url_part(input))
      local bare = out:gsub("%%%x%x", "")
      if bare:find("[^%w%-._~]") then
        return false, "a byte outside the unreserved set in " .. out
      end
      if out:find("%%%l") or out:find("%%%x%f[%X]") then
        return false, "a malformed or lower-case escape in " .. out
      end
      if input == "." or input == ".." then
        Fuzz.label("dot segment")
        if out ~= (if input == "." then "%252E" else "%252E%252E" end) then
          return false, "a dot segment became " .. out
        end
        return true, ""
      end
      if out ~= Url.escape(input) then return false, "differs from Url.escape: " .. out end
      if assert(Url.unescape(out)) ~= input then
        return false, "reads back as another text: " .. out
      end
      if out ~= input then Fuzz.label("escaped") else Fuzz.label("plain") end
      if input == "" then Fuzz.label("empty") end
      return true, ""
    end,
  })
end

local function test_escape_css_attr_leaves_no_delimiter(tmp: string)
  Fuzz.run({
    name = "html escape css attr",
    dir = tmp,
    gen = gen_text,
    requires = { "escaped", "plain", "empty", "high" },
    shares = { escaped = 0.5 },
    check = function(input: string): boolean, string
      local out = Html.raw_attr(Html.escape_css_attr(input))
      if out:find("[^%w_ \\%-\128-\255]") then
        return false, "a byte left that is not CSS identifier text in " .. out
      end
      if Html.raw_attr(Html.escape_attr(out)) ~= out then
        return false, "not its own attribute escape: " .. out
      end
      -- Every backslash begins a hex escape that a space ends.
      if out:gsub("\\%x%x? ", ""):find("[\\ ]") then
        return false, "a backslash or space outside a hex escape in " .. out
      end
      if input:find("[^%w\128-\255]") then Fuzz.label("escaped") else Fuzz.label("plain") end
      if input == "" then Fuzz.label("empty") end
      if input:find("[\128-\255]") then Fuzz.label("high") end
      return true, ""
    end,
  })
end
