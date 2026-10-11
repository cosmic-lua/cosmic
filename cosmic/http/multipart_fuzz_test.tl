--- Fuzz properties for cosmic.http.multipart, which reads the bytes any
--- client sends as a form: a well-formed body round-trips under any
--- chunking of the source and of the reads; any bytes, mutated from a
--- well-formed body or not, are refused with a reason of the parser's or
--- read to parts that are bounded by the input and carry no filename that
--- names a path or holds a control byte; and the outcome does not depend on
--- how the source chunks the bytes.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Multipart = require("cosmic.http.multipart")
local Stream = require("cosmic.stream")

local BOUNDARIES <const>: {string} = { "x", "----WebKitFormBoundaryAbC123xYz", "a b c", "--", "'()+_,-./:=?",
  string.rep("B", 70), "boundary", "0", "-" }
local NAMES <const>: {string} = { "a", "field", "é", "a b", 'x"y', "tags", "", "q;r=s", "csrf_token" }
local FILENAMES <const>: {string} = { "a.txt", "../../etc/passwd", "C:\\x\\y.png", "", "é.png", "dir/sub.txt", "..", "a;b",
  'x"y', "a\\..\\b", ".htaccess", "no_ext" }
local TYPES <const>: {string} = { "text/plain; charset=utf-8", "image/png", "application/octet-stream", "text/html" }
local PIECES <const>: {string} = { "", "abc", "\r\n", "\r\n--", "--", "-", "\r", "\n", "\0", "\255", "line1\r\nline2",
  "\r\n\r\n", "Content-Disposition: form-data; name=\"z\"" }
local PREAMBLES <const>: {string} = { "", "", "This is a preamble.\r\n", "\r\n", "x\r\ny\r\n" }

--- A part as drawn, and what reading it back must give.
local record Drawn
  name: string
  filename: string
  content_type: string
  body: string
end

local function escaped(text: string): string
  return (text:gsub('"', "%%22"))
end

--- The filename a client's `raw` must come back as.
local function reduced(raw: string): string
  return raw:match("[^/\\]*$")
end

--- A body that does not hold the delimiter `delim`.
local function without(body: string, delim: string): string
  local at = body:find(delim, 1, true)
  while at ~= nil do
    body = body:sub(1, at + 2) .. "_" .. body:sub(at + 4)
    at = body:find(delim, 1, true)
  end
  return body
end

--- Draws one well-formed body: its text and the parts it holds.
local function draw_body(src: Fuzz.Source, boundary: string): string, {Drawn}
  local delim = "\r\n--" .. boundary
  local out: {string} = { Fuzz.pick(src, PREAMBLES) }
  local drawn: {Drawn} = {}
  while Fuzz.more(src, #drawn, 6) do
    local pieces: {string} = {}
    while Fuzz.more(src, #pieces, 6) do
      local which = src:int(0, 4)
      if which == 0 then
        pieces[#pieces + 1] = Fuzz.bytes(src, 12)
      elseif which == 1 then
        pieces[#pieces + 1] = "--" .. boundary
      elseif which == 2 then
        pieces[#pieces + 1] = delim:sub(1, src:int(1, #delim - 1))
      else
        pieces[#pieces + 1] = Fuzz.pick(src, PIECES)
      end
    end
    local part: Drawn = { name = Fuzz.pick(src, NAMES), body = without(table.concat(pieces), delim),
      content_type = "text/plain" }
    local head = '--' .. boundary .. '\r\nContent-Disposition: form-data; name="' .. escaped(part.name) .. '"'
    if src:int(0, 1) == 1 then
      local raw = Fuzz.pick(src, FILENAMES)
      part.filename = reduced(raw)
      head = head .. '; filename="' .. escaped(raw) .. '"'
    end
    head = head .. "\r\n"
    if src:int(0, 2) == 0 then
      part.content_type = Fuzz.pick(src, TYPES)
      head = head .. "Content-Type: " .. part.content_type .. "\r\n"
    end
    out[#out + 1] = head .. "\r\n" .. part.body .. "\r\n"
    drawn[#drawn + 1] = part
  end
  out[#out + 1] = "--" .. boundary .. "--"
  out[#out + 1] = Fuzz.pick(src, { "", "\r\n", "\r\nepilogue\r\n--" .. boundary:sub(1, 1) })
  return table.concat(out), drawn
end

--- A source over `text` that hands out at most `n` bytes a read.
local function drip(text: string, n: integer): Stream.Reader
  local inner = Stream.from_string(text)
  local r: Stream.Reader = {
    read = function(_self: Stream.Reader, max?: integer): string | nil, string
      return inner:read(math.min(n, max or n))
    end,
    close = function(_self: Stream.Reader): boolean, string return inner:close() end,
  }
  return r
end

local record Outcome
  parts: {Drawn}
  failure: string
  total: integer
end

--- Reads every part of `text`, `chunk` bytes at a time from the source and
--- `step` from each part.
local function read_all(text: string, boundary: string, chunk: integer, step: integer): Outcome
  local out: Outcome = { parts = {}, failure = "", total = 0 }
  local reader, bad = Multipart.reader(drip(text, chunk), { boundary = boundary, max_parts = 8,
    max_header_bytes = 256, max_header_lines = 6 })
  if reader == nil then
    out.failure = bad
    return out
  end
  while true do
    local part, why = reader:next_part()
    if part == nil then
      out.failure = why
      return out
    end
    local pieces: {string} = {}
    local failure = ""
    while true do
      local data, trouble = part.body:read(step)
      if data == nil then
        failure = trouble
        break
      end
      pieces[#pieces + 1] = data
    end
    local body = table.concat(pieces)
    out.total = out.total + #body
    out.parts[#out.parts + 1] = { name = part.name, filename = part.filename, content_type = part.content_type,
      body = body }
    if failure ~= "" then
      out.failure = failure
      return out
    end
  end
end

local function same(a: Outcome, b: Outcome): boolean, string
  if a.failure ~= b.failure then
    return false, ("failure %q against %q"):format(a.failure, b.failure)
  end
  if #a.parts ~= #b.parts then return false, ("%d parts against %d"):format(#a.parts, #b.parts) end
  for i, p in ipairs(a.parts) do
    local q = b.parts[i]
    if p.name ~= q.name or p.filename ~= q.filename or p.content_type ~= q.content_type then
      return false, "part " .. i .. " differs in a header"
    end
    -- A body cut by a failure may be cut anywhere, but never differently once complete.
    if a.failure == "" and p.body ~= q.body then
      return false, "part " .. i .. " differs in its body"
    end
  end
  return true, ""
end

local function test_a_well_formed_body_round_trips_under_any_chunking(tmp: string)
  Fuzz.run({
    name = "multipart round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local boundary = Fuzz.pick(src, BOUNDARIES)
      local text = draw_body(src, boundary)
      return Fuzz.pack({ boundary, tostring(src:int(1, 80)), tostring(src:int(1, 40)), text })
    end,
    requires = { "parts", "file_part", "crlf_in_body", "split_delimiter", "empty_body", "bare_dashes" },
    shares = { parts = 0.5, file_part = 0.3 },
    check = function(input: string): boolean, string
      local f = Fuzz.unpack(input)
      local boundary, chunk, step, text = f[1], math.tointeger(tonumber(f[2])), math.tointeger(tonumber(f[3])), f[4]
      -- The whole body in one read is the reference for any chunking.
      local whole = read_all(text, boundary, #text + 1, 1 << 20)
      local got = read_all(text, boundary, chunk, step)
      local ok, why = same(whole, got)
      if not ok then return false, "chunking changed the result: " .. why end
      if got.failure ~= "" then return false, "a well-formed body was refused: " .. got.failure end
      if #got.parts > 0 then Fuzz.label("parts") end
      for _, p in ipairs(got.parts) do
        if p.filename ~= nil then
          Fuzz.label("file_part")
          if p.filename:find("[/\\]") or p.filename:find("%c") then
            return false, "a filename holds a path or control"
          end
        end
        if p.body == "" then Fuzz.label("empty_body") end
        if p.body:find("\r\n", 1, true) then Fuzz.label("crlf_in_body") end
        if p.body:find("--", 1, true) then Fuzz.label("bare_dashes") end
        if p.body:find("\r\n--", 1, true) and chunk < 8 then Fuzz.label("split_delimiter") end
      end
      return true, ""
    end,
  })
end

local function test_parts_come_back_as_they_were_drawn(tmp: string)
  Fuzz.run({
    name = "multipart parts as drawn",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local boundary = Fuzz.pick(src, BOUNDARIES)
      local text, drawn = draw_body(src, boundary)
      local fields: {string} = { boundary, tostring(src:int(1, 80)), text }
      for _, d in ipairs(drawn) do
        fields[#fields + 1] = d.name
        fields[#fields + 1] = d.filename ~= nil and ("F" .. d.filename) or "N"
        fields[#fields + 1] = d.content_type
        fields[#fields + 1] = d.body
      end
      return Fuzz.pack(fields)
    end,
    requires = { "parts" },
    check = function(input: string): boolean, string
      local f = Fuzz.unpack(input)
      local got = read_all(f[3], f[1], math.tointeger(tonumber(f[2])), 7)
      if got.failure ~= "" then return false, "refused: " .. got.failure end
      local last: {Drawn} = {}
      for i = 4, #f - 3, 4 do
        local filename: string = nil
        if f[i + 1]:sub(1, 1) == "F" then filename = f[i + 1]:sub(2) end
        last[#last + 1] = { name = f[i], filename = filename, content_type = f[i + 2], body = f[i + 3] }
      end
      if #last ~= #got.parts then
        return false, ("%d parts drawn, %d read"):format(#last, #got.parts)
      end
      for i, want in ipairs(last) do
        local p = got.parts[i]
        if p.name ~= want.name or p.filename ~= want.filename or p.content_type ~= want.content_type or
            p.body ~= want.body then
          return false, "part " .. i .. " is not the part drawn"
        end
      end
      if #last > 0 then Fuzz.label("parts") end
      return true, ""
    end,
  })
end

local function test_any_bytes_are_refused_or_read_within_bounds_and_the_same_in_any_chunking(tmp: string)
  Fuzz.run({
    name = "multipart hostile bytes",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local boundary = Fuzz.pick(src, BOUNDARIES)
      local text: string
      if src:int(0, 7) == 0 then
        text = Fuzz.bytes(src, 200)
      else
        text = Fuzz.mutate(src, (draw_body(src, boundary)), 5)
      end
      return Fuzz.pack({ boundary, tostring(src:int(1, 80)), tostring(src:int(1, 40)), text })
    end,
    requires = { "accepted", "refused", "truncated", "header_refused" },
    shares = { accepted = 0.05, refused = 0.2 },
    check = function(input: string): boolean, string
      local f = Fuzz.unpack(input)
      local boundary, chunk, step, text = f[1], math.tointeger(tonumber(f[2])), math.tointeger(tonumber(f[3])), f[4]
      local ok, got = pcall(read_all, text, boundary, chunk, step)
      if not ok then return false, "raised: " .. tostring(got) end
      local reference = read_all(text, boundary, 1 << 20, 1 << 20)
      local equal, why = same(reference, got)
      if not equal then return false, "chunking changed the result: " .. why end
      if got.total > #text then return false, "parts hold more bytes than the input" end
      if #got.parts > 8 then return false, "more parts than max_parts" end
      for _, p in ipairs(got.parts) do
        local fn = p.filename
        if fn ~= nil and (fn:find("[/\\]") or fn:find("%c") or #fn > 255 or not utf8.len(fn)) then
          return false, "an unsafe filename"
        end
        if p.name:find("%c") or not utf8.len(p.name) then return false, "an unsafe name" end
      end
      if got.failure == "" then
        Fuzz.label("accepted")
        return true, ""
      end
      if not got.failure:find("^multipart: ") then
        return false, "a reason that is not the parser's: " .. got.failure
      end
      Fuzz.label("refused")
      if got.failure:find("before the closing") then Fuzz.label("truncated") end
      if got.failure:find("header") or got.failure:find("Content%-") or got.failure:find("name") then
        Fuzz.label("header_refused")
      end
      return true, ""
    end,
  })
end
