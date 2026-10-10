--- Fuzz properties for [`cosmic.url`], which reads the paths and URLs
--- a client or a server is handed: what `escape` writes is only
--- unreserved bytes and escapes, and `unescape` takes it back to the
--- bytes it came from; `unescape` and `parse` are total on any bytes;
--- `segments` never answers a segment that is empty, `.`, `..` or holds
--- a `/` or a NUL, and reads back every name `escape` wrote; and `parse`
--- reads back the parts a URL was built from. `FUZZ_SEED` and
--- `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Url = require("cosmic.url")

--- Bytes an escaped text has to get right: a `%` and hex digits of both
--- cases (escapes, half escapes and bad ones), the separators, a `+`,
--- a space, a NUL and a byte past ASCII.
local TEXT <const> = { "%", "%2", "%2e", "%2E", "%2f", "%2F", "%00", "%zz", "%%", "a", "F", "9", ".", "..",
  "/", "+", " ", "\0", "\xff", "~", "-", "_" }

--- Text drawn from [`TEXT`] or as arbitrary bytes, a piece at a time.
local function gen_text(src: Fuzz.Source): string
  if src:int(0, 3) == 0 then
    return Fuzz.bytes(src, 48)
  end
  local out: {string} = {}
  while Fuzz.more(src, #out, 24) do
    out[#out + 1] = Fuzz.pick(src, TEXT)
  end
  return table.concat(out)
end

local function test_escape_writes_only_unreserved_bytes_and_unescape_takes_it_back(tmp: string)
  Fuzz.run({
    name = "url escape round trip",
    dir = tmp,
    gen = gen_text,
    requires = { "escaped", "unreserved" },
    shares = { escaped = 0.3 },
    check = function(input: string): boolean, string
      local text = Url.escape(input)
      if text:gsub("%%%x%x", ""):find("[^A-Za-z0-9._~-]") then
        return false, ("escape wrote %q"):format(text)
      end
      if text:find("%%%x?[a-f]") then
        return false, ("escape wrote lowercase hex: %q"):format(text)
      end
      local back, why = Url.unescape(text)
      if back ~= input then
        return false, ("%q unescaped to %q: %s"):format(text, tostring(back), why)
      end
      if text ~= input then Fuzz.label("escaped") end
      if input:find("[A-Za-z0-9._~-]") then Fuzz.label("unreserved") end
      return true, ""
    end,
  })
end

local function test_unescape_is_total_and_exact(tmp: string)
  Fuzz.run({
    name = "url unescape total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local text = gen_text(src)
      if src:int(0, 2) == 0 then
        return Fuzz.mutate(src, Url.escape(text), 3)
      end
      return text
    end,
    requires = { "decoded", "refused" },
    shares = { decoded = 0.2, refused = 0.2 },
    check = function(input: string): boolean, string
      local bytes, why = Url.unescape(input)
      if bytes == nil then
        if not why:find("^url: '%%' at byte %d+ is not followed by two hex digits$") then
          return false, "refused with " .. why
        end
        local at = math.tointeger(tonumber(why:match("byte (%d+)")))
        if input:sub(at, at) ~= "%" or input:find("^%x%x", at + 1) then
          return false, "refused naming the wrong byte: " .. why
        end
        Fuzz.label("refused")
        return true, ""
      end
      if why ~= "" then return false, "decoded with a reason: " .. why end
      local again = input:gsub("%%(%x%x)", function(hex: string): string
        return string.char(math.tointeger(tonumber(hex, 16)))
      end)
      if again ~= bytes then return false, ("decoded to %q, not %q"):format(bytes, again) end
      Fuzz.label("decoded")
      return true, ""
    end,
  })
end

--- Path segments that need care, escaped or raw.
local SEGMENTS <const> = { "", ".", "%2e", "...", "%2F", "a%2fb", "%00", "%", "%g0", "a", "a%20b", "?", "%3F",
  "~", "\xff" }

--- Every way a segment spells `..`.
local CLIMBS <const> = { "..", "%2e%2e", "%2E%2E", ".%2e", "%2E." }

--- A path as packed segments: each one raw from [`SEGMENTS`] or
--- [`CLIMBS`] or drawn text (`r` before it), or a name to write through [`Url.escape`]
--- (`e`), which mostly holds no `/` or NUL, so that most paths are
--- read rather than refused.
local function gen_path(src: Fuzz.Source): string
  local parts: {string} = {}
  while Fuzz.more(src, #parts, 6) do
    local kind = src:int(0, 6)
    if kind == 6 then
      parts[#parts + 1] = "r" .. Fuzz.pick(src, CLIMBS)
    elseif kind == 0 then
      parts[#parts + 1] = "r" .. Fuzz.pick(src, SEGMENTS)
    elseif kind == 1 then
      parts[#parts + 1] = "r" .. gen_text(src)
    elseif kind == 2 then
      parts[#parts + 1] = "e" .. gen_text(src)
    else
      parts[#parts + 1] = "e" .. gen_text(src):gsub("[/\0]", "")
    end
  end
  return Fuzz.pack(parts)
end

local function test_segments_answer_no_climb_and_read_back_escaped_names(tmp: string)
  Fuzz.run({
    name = "url segments",
    dir = tmp,
    gen = gen_path,
    requires = { "segments", "root", "refused", "climb refused" },
    shares = { segments = 0.1, refused = 0.1 },
    check = function(input: string): boolean, string
      local pieces: {string} = {}
      -- The names a segment escaped from them must read back as, when
      -- the path holds only such segments and no name is dropped or
      -- refused by its value.
      local names: {string} = {}
      local only_names = true
      for _, part in ipairs(Fuzz.unpack(input)) do
        if part:sub(1, 1) == "e" then
          local name = part:sub(2)
          pieces[#pieces + 1] = Url.escape(name)
          if name == "" or name == "." or name == ".." or name:find("[/\0]") then
            only_names = false
          else
            names[#names + 1] = name
          end
        else
          pieces[#pieces + 1] = part:sub(2)
          only_names = false
        end
      end
      local path = "/" .. table.concat(pieces, "/")
      local segs, why = Url.segments(path)
      if segs == nil then
        if not why:find("^url: ") then return false, "refused with " .. why end
        if only_names then
          return false, ("refused %q, built of escaped names: %s"):format(path, why)
        end
        if why:find("'..'", 1, true) then Fuzz.label("climb refused") end
        Fuzz.label("refused")
        return true, ""
      end
      if why ~= "" then return false, "answered with a reason: " .. why end
      for _, seg in ipairs(segs) do
        if seg == "" or seg == "." or seg == ".." or seg:find("[/\0]") then
          return false, ("%q answered the segment %q"):format(path, seg)
        end
      end
      if only_names then
        if #segs ~= #names then
          return false, ("%q answered %d segments, not %d"):format(path, #segs, #names)
        end
        for i, name in ipairs(names) do
          if segs[i] ~= name then
            return false, ("%q answered %q for %q"):format(path, segs[i], name)
          end
        end
      end
      Fuzz.label(#segs == 0 and "root" or "segments")
      return true, ""
    end,
  })
end

local function test_parse_is_total(tmp: string)
  local samples <const> = { "http://example.com/", "https://u:p@[::1]:8443/a%20b?q=1#f", "HTTP://H:0",
    "x-y+z.w://host:65535/p?", "http://a@b/c#", "file:///" }
  Fuzz.run({
    name = "url parse total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      if src:int(0, 3) == 0 then return gen_text(src) end
      return Fuzz.mutate(src, Fuzz.pick(src, samples), 4)
    end,
    requires = { "parsed", "refused" },
    shares = { parsed = 0.1, refused = 0.1 },
    check = function(input: string): boolean, string
      local parts, why = Url.parse(input)
      if parts == nil then
        if not why:find("^url: ") then return false, "refused with " .. why end
        Fuzz.label("refused")
        return true, ""
      end
      if why ~= "" then return false, "parsed with a reason: " .. why end
      if not parts.scheme:find("^[a-z][a-z0-9+.-]*$") then
        return false, "scheme " .. parts.scheme
      end
      if parts.host == "" or parts.host ~= parts.host:lower() or parts.host:find("[@%[%]/?#]") then
        return false, "host " .. parts.host
      end
      if parts.port ~= nil and (parts.port < 0 or parts.port > 65535) then
        return false, "port " .. parts.port
      end
      if parts.path ~= "" and parts.path:sub(1, 1) ~= "/" then
        return false, "path " .. parts.path
      end
      for _, piece in ipairs({ parts.scheme, parts.userinfo or "", parts.host, parts.path, parts.query or "",
          parts.fragment or "" }) do
        if piece:find("[\0-\32\127]") then return false, ("a part holds %q"):format(piece) end
      end
      Fuzz.label("parsed")
      return true, ""
    end,
  })
end

--- Parts a URL is built from, each drawn so that the URL parses.
local SCHEMES <const> = { "http", "HTTPS", "x+y.z-1", "S" }
local USERINFO <const> = { "u", "u:p", "", "%40a:b%3A", "a;b=c" }
local HOSTS <const> = { "example.com", "EXAMPLE.org", "127.0.0.1", "[::1]", "[2001:DB8::A]", "[::ffff:1.2.3.4]",
  "h-1.x_y~z", "%41" }
local PORTS <const> = { "0", "80", "008080", "65535", "" }

local function test_parse_reads_back_the_parts_a_url_was_built_from(tmp: string)
  Fuzz.run({
    name = "url parse parts",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local function maybe(choice: string): string
        return src:int(0, 1) == 0 and "" or choice
      end
      local path: {string} = {}
      while Fuzz.more(src, #path, 4) do path[#path + 1] = "/" .. Url.escape(gen_text(src)) end
      return Fuzz.pack({ Fuzz.pick(src, SCHEMES), maybe("u" .. Fuzz.pick(src, USERINFO)), Fuzz.pick(src, HOSTS),
        maybe("p" .. Fuzz.pick(src, PORTS)), table.concat(path), maybe("q" .. Url.escape(gen_text(src)) .. "?/"),
        maybe("f" .. Url.escape(gen_text(src)) .. "#?") })
    end,
    requires = { "userinfo", "port", "ipv6", "query", "fragment" },
    check = function(input: string): boolean, string
      local f = Fuzz.unpack(input)
      if #f ~= 7 then return false, ("%d fields, not the 7 the generator packs"):format(#f) end
      local scheme, userinfo, host, port, path, query, fragment = f[1], f[2], f[3], f[4], f[5], f[6], f[7]
      local url = scheme .. "://" .. (userinfo ~= "" and userinfo:sub(2) .. "@" or "") .. host ..
        (port ~= "" and ":" .. port:sub(2) or "") .. path .. (query ~= "" and "?" .. query:sub(2) or "") ..
        (fragment ~= "" and "#" .. fragment:sub(2) or "")
      local parts, why = Url.parse(url)
      if parts == nil then return false, ("refused %q: %s"):format(url, why) end
      local want_host = host:lower():match("^%[(.*)%]$") or host:lower()
      local want_port = port:sub(2) ~= "" and math.tointeger(tonumber(port:sub(2))) or nil
      local checks: {{string}} = {
        { "scheme", parts.scheme, scheme:lower() },
        { "userinfo", parts.userinfo or "-", userinfo ~= "" and userinfo:sub(2) or "-" },
        { "host", parts.host, want_host },
        { "port", tostring(parts.port), tostring(want_port) },
        { "path", parts.path, path },
        { "query", parts.query or "-", query ~= "" and query:sub(2) or "-" },
        { "fragment", parts.fragment or "-", fragment ~= "" and fragment:sub(2) or "-" },
      }
      for _, c in ipairs(checks) do
        if c[2] ~= c[3] then
          return false, ("%q: %s is %q, not %q"):format(url, c[1], c[2], c[3])
        end
      end
      if parts.userinfo ~= nil then Fuzz.label("userinfo") end
      if parts.port ~= nil then Fuzz.label("port") end
      if host:sub(1, 1) == "[" then Fuzz.label("ipv6") end
      if parts.query ~= nil then Fuzz.label("query") end
      if parts.fragment ~= nil then Fuzz.label("fragment") end
      return true, ""
    end,
  })
end

--- Pairs drawn from [`gen_text`], packed as the names and values in turn.
local function gen_pairs(src: Fuzz.Source): string
  local fields: {string} = {}
  while Fuzz.more(src, #fields // 2, 8) do
    fields[#fields + 1] = gen_text(src)
    fields[#fields + 1] = gen_text(src)
  end
  return Fuzz.pack(fields)
end

local function test_encode_query_decodes_back_to_the_same_pairs(tmp: string)
  Fuzz.run({
    name = "url query round trip",
    dir = tmp,
    gen = gen_pairs,
    requires = { "pairs", "repeated" },
    shares = { pairs = 0.5 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local want: {Url.Pair} = {}
      for i = 1, #fields - 1, 2 do
        want[#want + 1] = { name = fields[i], value = fields[i + 1] }
      end
      local text = Url.encode_query(want)
      if text:find("[^A-Za-z0-9._~%%&=+-]") then
        return false, ("encode wrote %q"):format(text)
      end
      local q, why = Url.decode_query(text, { utf8 = false, max_pairs = 100 })
      if q == nil then return false, ("%q refused: %s"):format(text, why) end
      if #q.pairs ~= #want then
        return false, ("%q read %d pairs, not %d"):format(text, #q.pairs, #want)
      end
      local seen: {string:integer} = {}
      for i, p in ipairs(want) do
        local got = q.pairs[i]
        if got.name ~= p.name or got.value ~= p.value then
          return false, ("pair %d of %q read as %q=%q"):format(i, text, got.name, got.value)
        end
        seen[p.name] = (seen[p.name] or 0) + 1
        if Url.query_all(q, p.name)[seen[p.name]] ~= p.value then
          return false, ("by_name misses pair %d of %q"):format(i, text)
        end
      end
      for name, n in pairs(seen) do
        if #Url.query_all(q, name) ~= n then return false, "by_name holds the wrong count" end
        if n > 1 then Fuzz.label("repeated") end
      end
      if #want > 0 then Fuzz.label("pairs") end
      return true, ""
    end,
  })
end

local function test_decode_query_is_total_and_keeps_what_it_reads(tmp: string)
  Fuzz.run({
    name = "url query total",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local pieces: {string} = {}
      while Fuzz.more(src, #pieces, 12) do
        pieces[#pieces + 1] = (gen_text(src):gsub("&", "%%26"))
      end
      local text = table.concat(pieces, src:int(0, 3) == 0 and ";" or "&")
      if src:int(0, 2) == 0 then
        text = Fuzz.mutate(src, text, 3)
      end
      return Fuzz.pack({ tostring(src:int(0, 3)), text })
    end,
    requires = { "decoded", "refused" },
    shares = { decoded = 0.2, refused = 0.1 },
    check = function(input: string): boolean, string
      local f = Fuzz.unpack(input)
      local mode = math.tointeger(tonumber(f[1])) or 0
      local text = f[2] or ""
      local opts: Url.QueryOptions = { lenient = mode & 1 == 1, utf8 = mode & 2 == 0, max_pairs = 6 }
      local ok, q, why = pcall(Url.decode_query, text, opts)
      if not ok then return false, "raised: " .. tostring(q) end
      if q == nil then
        if not why:find("^url: ") then return false, "refused with " .. why end
        Fuzz.label("refused")
        return true, ""
      end
      if why ~= "" or #q.pairs > 6 then return false, "decoded with a reason or past the cap" end
      local total = 0
      for name, values in pairs(q.by_name) do
        if #values == 0 then return false, "empty list for " .. name end
        total = total + #values
      end
      if total ~= #q.pairs then return false, "by_name and pairs disagree" end
      Fuzz.label("decoded")
      return true, ""
    end,
  })
end
