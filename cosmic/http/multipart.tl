--- A streaming `multipart/form-data` parser (RFC 7578, with RFC 2046's
--- boundary rules), for a body that comes from a client that is not to be
--- trusted. It knows nothing of a web framework: it reads a
--- [`cosmic.stream`] Reader and yields the parts one at a time, each with
--- its own Reader, holding no more than a buffer of 16 KiB however large a
--- part is.
---
---     local reader = assert(Multipart.reader(req.body, { boundary = boundary }))
---     while true do
---       local part, why = reader:next_part()
---       if part == nil then assert(why == "", why) break end
---       local data = assert(Stream.read_all(part.body))
---       print(part.name, part.filename, #data)
---     end
---
--- What it refuses, with a reason that begins `multipart: `:
---
--- - a boundary that is empty, longer than 70 bytes or outside the RFC's
---   set (a long one makes the delimiter scan costly);
--- - a body that ends before the closing delimiter, a delimiter line with
---   anything but `--` or a line end after it, and a part header block
---   longer than `max_header_bytes`, of more than `max_header_lines` lines,
---   with a bare CR or LF, a folded line, a control byte, or a header named
---   twice;
--- - a part with no `Content-Disposition: form-data` carrying a `name`, a
---   `name` or `filename` given twice, a name or filename that holds a
---   control byte or is not UTF-8, a filename over 255 bytes once reduced
---   to its last path component or one that reduces to nothing (`dir/`), and a `Content-Transfer-Encoding` other
---   than `binary`, `7bit` or `8bit` (RFC 7578 4.7 retired the rest);
--- - more than `max_parts` parts.
---
--- Text before the first delimiter is discarded (at most `max_header_bytes`
--- of it) and text after the closing delimiter is never read.
---
--- The parser is stricter than RFC 2046 where leniency would let two
--- parsers disagree about one body: a delimiter is followed at once by
--- `--` or CRLF (no transport padding of spaces or tabs), and a line end is
--- CRLF everywhere (a bare LF is part of a body, and in a header block
--- an error).
---
--- A part's `filename` is what the client claimed: it is cut to the text
--- after the last `/` or `\`, so `../../etc/passwd` is `passwd`, and is
--- fit only to show a person, never to name a file. A quoted `name` or
--- `filename` follows the WHATWG form encoding browsers write: the text
--- between the quotes is literal (a backslash is no escape), with `%22`, `%0D`
--- and `%0A` standing for a quote and the line ends. `filename*` (RFC 8187)
--- is read when there is no `filename`.

local Stream = require("cosmic.stream")
local String = require("cosmic.string")

local record Multipart
  --- One part of the body.
  record Part
    --- The part's header lines by lowercase name.
    headers: {string:string}
    --- The `name` of its Content-Disposition, unescaped; may be "".
    name: string
    --- The `filename` of its Content-Disposition reduced to its last path
    --- component; nil for a part with none (a text field), "" for an empty
    --- one (a browser's file input left blank).
    filename: string
    --- Its Content-Type as sent; "text/plain" when it sent none.
    content_type: string
    --- The part's bytes, read as they arrive. It ends at the part's end
    --- and is not usable once [`Multipart.Reader.next_part`] has gone past
    --- it, unless it had already ended.
    body: Stream.Reader
  end

  --- What [`Multipart.reader`] takes.
  record Options
    --- The `boundary` parameter of the request's Content-Type.
    boundary?: string
    --- Most parts (100).
    max_parts?: integer
    --- Longest header block of a part, and longest preamble, in bytes (8 KiB).
    max_header_bytes?: integer
    --- Most header lines in a part (16).
    max_header_lines?: integer
  end

  --- A parser over a body.
  interface Reader
    --- The next part, skipping what is unread of the last one; nil and ""
    --- after the closing delimiter, nil and a reason when the body is
    --- malformed or its source fails (the source's own reason, as it gave it).
    next_part: function(Reader): Part | nil, string
    --- Ends the parser; it does not close the source.
    close: function(Reader): boolean, string
  end
end

--- Bytes asked of the source at a time, and the largest a part body hands out
--- when not asked for fewer.
local CHUNK <const> = 16384

local DEFAULT_PARTS <const> = 100
local DEFAULT_HEADER_BYTES <const> = 8192
local DEFAULT_HEADER_LINES <const> = 16

--- The longest filename kept, after reduction.
local MAX_FILENAME <const> = 255

local TRUNCATED <const> = "multipart: the body ended before the closing boundary"

local TOKEN <const> = "[%w!#$%%&'*+.^_`|~-]+"

--- What the parser is in: "start" (nothing read), "headers" (a delimiter is
--- consumed up to its line end), "body" (inside a part), "delimited" (a
--- part's end delimiter is at the head of the buffer), "done" (after the
--- closing delimiter or a close) or "failed".
local record Parser is Multipart.Reader
  source: Stream.Reader
  delim: string
  buf: string
  --- Whether the source has ended.
  eof: boolean
  state: string
  failure: string
  count: integer
  generation: integer
  --- Bytes at the head of `buf` known to hold no delimiter.
  safe: integer
  max_parts: integer
  max_header_bytes: integer
  max_header_lines: integer
  next_part: function(Parser): Multipart.Part | nil, string
  close: function(Parser): boolean, string
end

local parser_mt: metatable<Parser> = { __index = Parser }

local record BodyReader is Stream.Reader
  parser: Parser
  generation: integer
  finished: boolean
  read: function(BodyReader, max_bytes?: integer): string | nil, string
  close: function(BodyReader): boolean, string
end

local body_mt: metatable<BodyReader> = { __index = BodyReader }

local function fail(p: Parser, why: string): nil, string
  p.state = "failed"
  p.failure = why
  p.buf = ""
  return nil, why
end

--- Reads more of the source into the buffer; false and why when it fails.
--- At the end of the source `eof` is set and nothing is added.
local function fill(p: Parser): boolean, string
  if p.eof then return true, "" end
  local chunk, why = p.source:read(CHUNK)
  if chunk == nil then
    if why ~= "" then return false, why end
    p.eof = true
    return true, ""
  end
  p.buf = p.buf .. chunk
  return true, ""
end

--- Whether `boundary` is 1 to 70 bytes of RFC 2046's set, not ending in a
--- space.
local function good_boundary(boundary: string): boolean
  return #boundary >= 1 and #boundary <= 70 and boundary:find("^[%w'()+_,./:=?%- ]+$") ~= nil and
    boundary:sub(-1) ~= " "
end

--- A parser over `source`. Raises on an option that is not a positive integer.
--- @param source Stream.Reader The body
--- @param opts Multipart.Options The boundary and limits
--- @return Multipart.Reader The parser, or nil
--- @return string Why not: the boundary is unusable
function Multipart.reader(source: Stream.Reader, opts: Multipart.Options): Multipart.Reader | nil, string
  for field, v in pairs({ max_parts = opts.max_parts, max_header_bytes = opts.max_header_bytes,
      max_header_lines = opts.max_header_lines }) do
    if v < 1 then error(("multipart: %s is a positive integer, not %d"):format(field, v), 2) end
  end
  local boundary = opts.boundary
  if type(boundary) ~= "string" or not good_boundary(boundary) then
    return nil, "multipart: the boundary is empty, longer than 70 bytes or has a byte outside RFC 2046's set"
  end
  local p: Parser = setmetatable({
    source = source, delim = "\r\n--" .. boundary,
    -- The first delimiter has no CRLF before it when the body starts with it.
    buf = "\r\n", eof = false, state = "start", failure = "", count = 0, generation = 0, safe = 0,
    max_parts = opts.max_parts or DEFAULT_PARTS,
    max_header_bytes = opts.max_header_bytes or DEFAULT_HEADER_BYTES,
    max_header_lines = opts.max_header_lines or DEFAULT_HEADER_LINES,
  }, parser_mt)
  return p, ""
end

--- The refusal for a preamble over the cap, the same however the source
--- chunks the body.
local function no_boundary(p: Parser): string
  return ("multipart: no boundary within the first %s"):format(String.counted(p.max_header_bytes, "byte"))
end

--- Moves to the first delimiter, dropping the preamble. The preamble is
--- the bytes before the delimiter, at most `max_header_bytes`.
local function seek_first(p: Parser): boolean, string
  -- The buffer starts with the two bytes of a line end that are no
  -- preamble.
  local dropped = -2
  local keep = #p.delim - 1
  while true do
    local at = p.buf:find(p.delim, 1, true)
    if at ~= nil then
      if dropped + at - 1 > p.max_header_bytes then return false, no_boundary(p) end
      p.buf = p.buf:sub(at + #p.delim)
      return true, ""
    end
    if #p.buf > keep then
      dropped = dropped + #p.buf - keep
      p.buf = p.buf:sub(#p.buf - keep + 1)
      if dropped > p.max_header_bytes then return false, no_boundary(p) end
    end
    if p.eof then return false, no_boundary(p) end
    local ok, why = fill(p)
    if not ok then return false, why end
  end
end

--- Reads the two bytes after a delimiter: "end" for the closing `--`,
--- "headers" for a line end.
local function after_delimiter(p: Parser): string | nil, string
  while #p.buf < 2 do
    if p.eof then return nil, TRUNCATED end
    local ok, why = fill(p)
    if not ok then return nil, why end
  end
  local two = p.buf:sub(1, 2)
  if two == "--" then return "end", "" end
  if two == "\r\n" then return "headers", "" end
  return nil, "multipart: a boundary is followed by neither -- nor a line end"
end

--- Whether `text` holds a byte that must not be in a name, filename or header:
--- a control byte, DEL included.
local function has_control(text: string): boolean
  return text:find("[%c\127]") ~= nil
end

--- `text` with the escapes a browser writes in a quoted name undone.
local function unescape(text: string): string
  return (text:gsub("%%22", '"'):gsub("%%0[Dd]", "\r"):gsub("%%0[Aa]", "\n"))
end

--- `text` without the spaces and tabs at its end, in a scan from the end: a
--- pattern's `(.-)[ \t]*$` costs the square of a run of spaces.
local function trim_end(text: string): string
  local last = #text
  while last > 0 do
    local byte = text:byte(last)
    if byte ~= 32 and byte ~= 9 then break end
    last = last - 1
  end
  return text:sub(1, last)
end

--- The bytes of the RFC 8187 value `text`, `charset'language'escaped`,
--- as UTF-8; nil and why for another charset or a bad escape.
local function ext_value(text: string): string | nil, string
  local charset, escaped = text:match("^([%w-]+)'[%w-]*'(.*)$")
  if charset == nil then return nil, "multipart: filename* is not charset'language'value" end
  local bad = false
  local raw = escaped:gsub("%%(%x?%x?)", function(hex: string): string
    if #hex ~= 2 then
      bad = true
      return ""
    end
    return string.char(tonumber(hex, 16))
  end)
  if bad then return nil, "multipart: filename* has a bad escape" end
  local lower = charset:lower()
  if lower == "utf-8" then return raw, "" end
  if lower == "iso-8859-1" then
    return (raw:gsub("[\128-\255]", function(c: string): string return utf8.char(c:byte()) end)), ""
  end
  return nil, "multipart: filename* is in a charset other than UTF-8 and ISO-8859-1"
end

--- The parameters of a Content-Disposition value after `form-data`, by
--- lowercase name; nil and why when it is malformed or names one twice.
local function disposition_params(value: string): {string:string} | nil, string
  local params: {string:string} = {}
  local _, head, kind = value:find("^[ \t]*(" .. TOKEN .. ")[ \t]*")
  if kind == nil or kind:lower() ~= "form-data" then
    return nil, "multipart: a part's Content-Disposition is not form-data"
  end
  local pos = head + 1
  while pos <= #value do
    if value:sub(pos, pos) ~= ";" then
      return nil, "multipart: a Content-Disposition parameter is malformed"
    end
    local _, equals, name = value:find("^;[ \t]*(" .. TOKEN .. ")[ \t]*=[ \t]*", pos)
    if name == nil then return nil, "multipart: a Content-Disposition parameter is malformed" end
    local after = equals + 1
    local text: string
    if value:sub(after, after) == '"' then
      local close = value:find('"', after + 1, true)
      if close == nil then return nil, "multipart: a Content-Disposition quote is not closed" end
      text = value:sub(after + 1, close - 1)
      local _, blanks = value:find("^[ \t]*", close + 1)
      pos = blanks + 1
    else
      local token = value:match("^[^;]*", after)
      text = trim_end(token)
      pos = after + #token
    end
    local key = name:lower()
    if params[key] ~= nil then
      return nil, "multipart: Content-Disposition names " .. key .. " twice"
    end
    params[key] = text
  end
  return params, ""
end

--- `raw`, a client's filename, reduced to its last path component; nil and
--- why when it holds a control byte, is not UTF-8 or is too long.
local function clean_filename(raw: string): string | nil, string
  if has_control(raw) then return nil, "multipart: a filename holds a control byte" end
  local base = raw:match("[^/\\]*$")
  if base == "" and raw ~= "" then return nil, "multipart: a filename names a directory" end
  if #base > MAX_FILENAME then return nil, "multipart: a filename is longer than 255 bytes" end
  if not utf8.len(base) then return nil, "multipart: a filename is not UTF-8" end
  return base, ""
end

--- The part the header block `block` (without its last line end) describes
--- apart from its body.
local function parse_headers(p: Parser, block: string, body: Stream.Reader): Multipart.Part | nil, string
  if block == "" then return nil, "multipart: a part has no headers" end
  local headers: {string:string} = {}
  local lines = 0
  local pos = 1
  local text = block .. "\r\n"
  while pos <= #text do
    local stop = text:find("\r\n", pos, true)
    local line = text:sub(pos, stop - 1)
    pos = stop + 2
    lines = lines + 1
    if lines > p.max_header_lines then return nil, "multipart: a part has too many header lines" end
    if line:find("[\r\n]") then return nil, "multipart: a part header has a bare CR or LF" end
    if line:find("^[ \t]") then return nil, "multipart: a part header is folded" end
    if line:find("[\0-\8\11-\31\127]") then
      return nil, "multipart: a part header holds a control byte"
    end
    local name, value = line:match("^(" .. TOKEN .. "):[ \t]*(.*)$")
    if name == nil then return nil, "multipart: a part header is malformed" end
    value = trim_end(value)
    local key = name:lower()
    if headers[key] ~= nil then
      return nil, "multipart: a part names the header " .. key .. " twice"
    end
    headers[key] = value
  end
  local disposition = headers["content-disposition"]
  if disposition == nil then return nil, "multipart: a part has no Content-Disposition" end
  local params, why = disposition_params(disposition)
  if params == nil then return nil, why end
  local name = params["name"]
  if name == nil then return nil, "multipart: a part has no name" end
  name = unescape(name)
  if has_control(name) or not utf8.len(name) then
    return nil, "multipart: a part's name holds a control byte or is not UTF-8"
  end
  local filename: string = nil
  local claimed = params["filename"]
  if claimed ~= nil then
    local clean, trouble = clean_filename(unescape(claimed))
    if clean == nil then return nil, trouble end
    filename = clean
  elseif params["filename*"] ~= nil then
    local decoded, trouble = ext_value(params["filename*"])
    if decoded == nil then return nil, trouble end
    local clean, bad = clean_filename(decoded)
    if clean == nil then return nil, bad end
    filename = clean
  end
  local encoding = headers["content-transfer-encoding"]
  if encoding ~= nil then
    local lower = encoding:lower()
    if lower ~= "binary" and lower ~= "7bit" and lower ~= "8bit" then
      return nil, "multipart: a part's Content-Transfer-Encoding is " .. lower .. ", which RFC 7578 retired"
    end
  end
  return { headers = headers, name = name, filename = filename,
    content_type = headers["content-type"] or "text/plain", body = body }, ""
end

--- Reads the header block after a delimiter's line end and the part it
--- describes; the buffer is left at the start of the body.
local function read_part_headers(p: Parser, body: Stream.Reader): Multipart.Part | nil, string
  local from = 1
  while true do
    local at = p.buf:find("\r\n\r\n", from, true)
    if at ~= nil then
      if at - 1 > p.max_header_bytes then
        return nil, "multipart: a part's headers are longer than max_header_bytes"
      end
      local block = p.buf:sub(3, at - 1)
      p.buf = p.buf:sub(at + 4)
      return parse_headers(p, block, body)
    end
    if #p.buf > p.max_header_bytes + 4 then
      return nil, "multipart: a part's headers are longer than max_header_bytes"
    end
    if p.eof then return nil, TRUNCATED end
    from = math.max(1, #p.buf - 2)
    local ok, why = fill(p)
    if not ok then return nil, why end
  end
end

--- The next bytes of the body of the current part, at most `max`; "" when
--- the part is over, with the delimiter at the head of the buffer.
local function take(p: Parser, max: integer): string | nil, string
  while true do
    if p.safe > 0 then
      local n = math.min(p.safe, max)
      local chunk = p.buf:sub(1, n)
      p.buf = p.buf:sub(n + 1)
      p.safe = p.safe - n
      return chunk, ""
    end
    local at = p.buf:find(p.delim, 1, true)
    if at == 1 then
      p.state = "delimited"
      return "", ""
    elseif at ~= nil then
      p.safe = at - 1
    else
      p.safe = #p.buf - (#p.delim - 1)
      if p.safe <= 0 then
        p.safe = 0
        if p.eof then return nil, TRUNCATED end
        local ok, why = fill(p)
        if not ok then return nil, why end
      end
    end
  end
end

function BodyReader:read(max_bytes?: integer): string | nil, string
  if max_bytes ~= nil and max_bytes < 1 then
    error("multipart: a part body reads at least one byte", 2)
  end
  local p = self.parser
  if self.finished then return nil, "" end
  if p.generation ~= self.generation then
    return nil, "multipart: the part was passed by next_part"
  end
  if p.state == "failed" then return nil, p.failure end
  if p.state == "done" then return nil, "multipart: the parser was closed" end
  local chunk, why = take(p, max_bytes or CHUNK)
  if chunk == nil then return fail(p, why) end
  if chunk == "" then
    self.finished = true
    return nil, ""
  end
  return chunk, ""
end

function BodyReader:close(): boolean, string
  self.finished = true
  return true, ""
end

--- Skips what is left of the current part, up to its end delimiter.
local function drain(p: Parser): boolean, string
  while p.state == "body" do
    local chunk, why = take(p, CHUNK)
    if chunk == nil then
      local _, _ = fail(p, why)
      return false, why
    end
  end
  return true, ""
end

function Parser:next_part(): Multipart.Part | nil, string
  if self.state == "failed" then return nil, self.failure end
  if self.state == "done" then return nil, "" end
  if self.state == "body" then
    local ok, _ = drain(self)
    if not ok then return nil, self.failure end
  end
  local ok: boolean
  local why: string
  if self.state == "start" then
    ok, why = seek_first(self)
  else
    -- "delimited": the delimiter is at the head of the buffer.
    self.buf = self.buf:sub(#self.delim + 1)
    ok, why = true, ""
  end
  if not ok then return fail(self, why) end
  local what, trouble = after_delimiter(self)
  if what == nil then return fail(self, trouble) end
  if what == "end" then
    self.state = "done"
    self.buf = ""
    return nil, ""
  end
  self.count = self.count + 1
  if self.count > self.max_parts then return fail(self, "multipart: more than max_parts parts") end
  local body: BodyReader = setmetatable({ parser = self, generation = self.generation + 1, finished = false }, body_mt)
  local part, bad = read_part_headers(self, body)
  if part == nil then return fail(self, bad) end
  self.state = "body"
  self.safe = 0
  self.generation = body.generation
  return part, ""
end

function Parser:close(): boolean, string
  if self.state ~= "failed" then self.state = "done" end
  self.buf = ""
  return true, ""
end

return Multipart
