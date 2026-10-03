--- `cosmic codec`: bytes to text and back, for the ten-second question
--- ("what is this token in hex?") that a script costs more than. It
--- reads a file, or standard input, and writes the encoding, or with
--- `-d` the bytes it spells -- and nothing else: like `cosmic json` it
--- ends in no verdict line (its `spec` is `bare`), because its
--- standard output is data for a pipe. Its exit status is the verdict:
--- 0 done, 2 a command line, an input or a write it cannot honor.
--- Complaints go to standard error as `cosmic: codec: ...`.
---
--- The encodings are [`cosmic.codec`]'s: hex, base64 and base64url, and no
--- others. One spelling of decode everywhere, `-d`: `base64 -d` and
--- `base64 -D` differ between platforms.
---
--- Encoding writes one line and a newline. Unlike GNU base64, whose
--- default wraps at 76 columns, it does not wrap unless `--wrap N` says
--- so, as the output is usually a token to paste or a value for
--- `$(...)`. Empty input writes just the newline.
---
--- Decoding ignores ASCII whitespace anywhere in the text (space, tab,
--- newline, return, form feed, vertical tab), so wrapped output and a
--- trailing newline read back. Everything else is strict, as
--- [`cosmic.codec`] is: an invalid character, misplaced padding, a bad
--- length or nonzero trailing bits exits 2 and names the byte offset
--- (from 0, counted in the input as given, whitespace included) of the
--- first fault, or for a length or trailing-bits fault of the last
--- character. The defaults are what each encoder writes: base64 must be
--- padded with `=`; base64url must not be, the form JSON Web Tokens use.
--- `--lenient` accepts the other spelling: missing padding on base64,
--- and `=` padding on base64url. Hex has no padding, so `--lenient` with
--- it is refused.
---
--- The input is streamed, 64 KiB at a time (a read that comes up short,
--- as a pipe's does, is read on until the chunk is full or the input
--- ends), through the incremental coders below, which are
--- [`Stream.Transform`]s that [`Stream.transform_writer`] drives. Encoding
--- writes each chunk's text as soon as it is made. Decoding holds one
--- chunk's bytes back (the writer's `hold`) until the next chunk has
--- decoded, so an input of at most 64 KiB writes nothing when it is
--- refused. A padding, length or
--- misplaced-`=` fault shows only at the end of the input, so a decoder
--- reads all of a stream to find one -- in bounded memory, whatever its
--- size -- and for an input of more than 64 KiB may have written most
--- of its bytes before it refuses. An invalid character is refused as
--- soon as its chunk is read.

local Cli = require("cosmic.cli")
local Codec = require("cosmic.codec")
local Flags = require("cosmic.flags")
local Stream = require("cosmic.stream")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")
local plural = require("build.plural")

--- The `cosmic codec` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The encodings, by the name a command line gives.
  enum Name
    "hex"
    "base64"
    "base64url"
  end

  --- One incremental transform, a chunk at a time: a
  --- [`Stream.Transform`] that holds nothing back (it has no
  --- `pending`). `update(chunk)` feeds bytes (or text) and returns the
  --- output that is ready, possibly ""; [`finish()`] says no more input
  --- follows and returns what is left, with `nil` and a reason when a
  --- decoder's text was refused. An encoder never fails. A decoder
  --- fails only at `finish`: it cannot tell a bad length from a bad
  --- character until the text ends, and the whole-string decoders
  --- report the length first, so it keeps the first bad character and
  --- carries on. A coder holds at most three characters of a group not
  --- yet whole, plus a little state, however much passes through it,
  --- and gives all the output it has at each call. After `finish`,
  --- `update` and `finish` raise.
  interface Coder is Stream.Transform
  end

  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given. False and why when the
    --- bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- Standard input, or nil and why, read a chunk at a time. `run`
    --- reads it when no file is named; `stdin` is the whole of it, in
    --- a test's stead, and is used only when `input` is not given.
    --- One of the two is required: `run` says so when neither is.
    input: function(): Stream.Reader | nil, string
    stdin: function(): string | nil, string
  end
end

-- A coder or the verb's output Writer is made as cosmic/stream.tl's "How an
-- object of this module is made" says: a record of its own per kind, its
-- methods on that record and its state in fields.

--- One base64 alphabet: how [`cosmic.codec`] writes and reads it whole,
--- `class` a pattern matching a character outside it, `padded` whether
--- its text ends in `=`, and `name` what its refusals call it. `class`,
--- `padded` and `name` must match the whole-string decoder's, which
--- keeps them private, so a coder's refusals read as its own.
local record Alphabet
  encode: function(string): string
  decode: function(string): string | nil, string
  class: string
  padded: boolean
  name: string
end

local STANDARD <const>: Alphabet = {
  encode = Codec.base64, decode = Codec.unbase64,
  class = "[^A-Za-z0-9+/]", padded = true, name = "base64",
}
local URL <const>: Alphabet = {
  encode = Codec.base64url, decode = Codec.unbase64url,
  class = "[^A-Za-z0-9_-]", padded = false, name = "base64url",
}

--- The hex encoder: each chunk's digits, as it comes.
local record HexEncoder is verb.Coder
  done: boolean
  update: function(HexEncoder, chunk: string): string | nil, string
  finish: function(HexEncoder): string, string
end

local hex_encoder_mt: metatable<HexEncoder> = { __index = HexEncoder }

function HexEncoder:update(chunk: string): string | nil, string
  if self.done then error("codec: coder is finished", 2) end
  return Codec.hex(chunk), ""
end

function HexEncoder:finish(): string, string
  if self.done then error("codec: coder is finished", 2) end
  self.done = true
  return "", ""
end

--- A base64 encoder: whole groups of three bytes go out as they come,
--- and the last one or two are padded, if the alphabet pads, at `finish`.
local record Base64Encoder is verb.Coder
  alphabet: Alphabet
  carry: string
  done: boolean
  update: function(Base64Encoder, chunk: string): string | nil, string
  finish: function(Base64Encoder): string | nil, string
end

local base64_encoder_mt: metatable<Base64Encoder> = { __index = Base64Encoder }

function Base64Encoder:update(chunk: string): string | nil, string
  if self.done then error("codec: coder is finished", 2) end
  local data = self.carry .. chunk
  local whole = #data - #data % 3
  self.carry = data:sub(whole + 1)
  if whole == 0 then return "", "" end
  return self.alphabet.encode(whole == #data and data or data:sub(1, whole)), ""
end

function Base64Encoder:finish(): string | nil, string
  if self.done then error("codec: coder is finished", 2) end
  self.done = true
  return self.alphabet.encode(self.carry), ""
end

--- The hex decoder.
local record HexDecoder is verb.Coder
  total: integer
  carry: string
  --- The first character that is no hex digit: where it lies and what
  --- it is.
  bad_at: integer | nil
  bad_byte: integer
  done: boolean
  update: function(HexDecoder, chunk: string): string, string
  finish: function(HexDecoder): string | nil, string
end

local hex_decoder_mt: metatable<HexDecoder> = { __index = HexDecoder }

function HexDecoder:update(chunk: string): string, string
  if self.done then error("codec: coder is finished", 2) end
  local before = self.total - #self.carry
  self.total = self.total + #chunk
  if self.bad_at ~= nil then return "", "" end
  local data = self.carry .. chunk
  -- Text that is sound decodes in one pass through the library;
  -- only a refusal, or a character in the held-back byte, looks for
  -- where the first bad character lies.
  local even = #data - #data % 2
  local tail = data:sub(even + 1)
  if not tail:find("[^0-9a-fA-F]") then
    local out, _why = Codec.unhex(even == #data and data or data:sub(1, even))
    if out ~= nil then
      self.carry = tail
      return out, ""
    end
  end
  local at = data:find("[^0-9a-fA-F]")
  assert(at ~= nil, "codec: hex text refused though every character is a digit")
  self.bad_at, self.bad_byte, self.carry = before + at, data:byte(at), ""
  return "", ""
end

function HexDecoder:finish(): string | nil, string
  if self.done then error("codec: coder is finished", 2) end
  self.done = true
  if self.total % 2 ~= 0 then
    return nil, ("codec: hex text of odd length %d"):format(self.total)
  end
  if self.bad_at ~= nil then
    return nil, ("codec: byte 0x%02x at %d is not a hex digit"):format(self.bad_byte, self.bad_at)
  end
  return "", ""
end

--- A decoder for an alphabet, as the whole-string one is: the same
--- refusals in the same order, the same words, and offsets counted from
--- the first character fed.
local record Base64Decoder is verb.Coder
  alphabet: Alphabet
  total: integer
  -- Characters of the group in progress, all in the alphabet.
  carry: string
  -- The first character outside the alphabet, where it lies and what
  -- it is; from there on, only how many characters follow and whether
  -- all of them are `=`, which decides whether it is padding.
  bad_at: integer | nil
  bad_byte: integer
  run: integer
  run_pad: boolean
  done: boolean
  update: function(Base64Decoder, chunk: string): string | nil, string
  finish: function(Base64Decoder): string | nil, string
end

local base64_decoder_mt: metatable<Base64Decoder> = { __index = Base64Decoder }

function Base64Decoder:update(chunk: string): string | nil, string
  if self.done then error("codec: coder is finished", 2) end
  local a = self.alphabet
  local before = self.total - #self.carry
  self.total = self.total + #chunk
  if self.bad_at ~= nil then
    self.run = self.run + #chunk
    if self.run_pad and chunk:find("[^=]") then self.run_pad = false end
    return "", ""
  end
  local data = self.carry .. chunk
  -- As in [`HexDecoder`]: a chunk whose whole groups the library
  -- decodes needs no search for a bad character. A group ending in
  -- `=` is left to the search below, since the library would take
  -- it for padding.
  local whole = #data - #data % 4
  if whole > 0 and data:byte(whole) ~= 61 then
    local tail = data:sub(whole + 1)
    if not tail:find(a.class) then
      local out, _why = a.decode(whole == #data and data or data:sub(1, whole))
      if out ~= nil then
        self.carry = tail
        return out, ""
      end
    end
  end
  local at = data:find(a.class)
  local usable = at ~= nil and at - 1 or #data
  whole = usable - usable % 4
  self.carry = data:sub(whole + 1, usable)
  if at ~= nil then
    self.bad_at, self.bad_byte = before + at, data:byte(at)
    self.run = #data - at + 1
    self.run_pad = self.bad_byte == 61 and data:find("[^=]", at) == nil
  end
  if whole == 0 then return "", "" end
  return (assert(a.decode(data:sub(1, whole)))), ""
end

function Base64Decoder:finish(): string | nil, string
  if self.done then error("codec: coder is finished", 2) end
  self.done = true
  local a = self.alphabet
  local name = a.name
  local total = self.total
  if a.padded then
    if total % 4 ~= 0 then
      return nil, ("codec: %s text of length %d, not a multiple of 4"):format(name, total)
    end
  elseif total % 4 == 1 then
    return nil, ("codec: %s text of length %d leaves one character over"):format(name, total)
  end
  local bad_at = self.bad_at
  if bad_at ~= nil and not (a.padded and self.run_pad and self.run <= 2) then
    if self.bad_byte == 61 then
      return nil, ("codec: %s text has misplaced '=' padding at %d"):format(name, bad_at)
    end
    return nil, ("codec: byte 0x%02x at %d is outside the %s alphabet"):format(
      self.bad_byte, bad_at, name)
  end
  local carry = self.carry
  if #carry < 2 then return "", "" end
  -- The last, partial group decodes as the whole-string decoder
  -- would see it, padded out if the alphabet is.
  local last = a.padded and carry .. ("="):rep(4 - #carry) or carry
  local out, why = a.decode(last)
  if out == nil then return nil, why end
  return out, ""
end

local function base64_encoder(a: Alphabet): verb.Coder
  local c: Base64Encoder = setmetatable({ alphabet = a, carry = "", done = false }, base64_encoder_mt)
  return c
end

local function hex_decoder(): verb.Coder
  local c: HexDecoder = setmetatable({
    total = 0, carry = "", bad_byte = 0, done = false,
  }, hex_decoder_mt)
  return c
end

local function base64_decoder(a: Alphabet): verb.Coder
  local c: Base64Decoder = setmetatable({
    alphabet = a, total = 0, carry = "", bad_byte = 0, run = 0, run_pad = false, done = false,
  }, base64_decoder_mt)
  return c
end

--- An incremental encoder for `name`: feed it chunks of bytes with
--- `update` and it returns the text they spell so far, holding back at
--- most two bytes of an unfinished base64 group; `finish` returns the
--- rest, with the padding [`Codec.base64`] writes. The text of all the
--- chunks together is exactly the whole-string encoder's, whatever the
--- chunking. Raises on a name it does not know.
--- @param name hex, base64 or base64url
--- @return verb.Coder The encoder
function verb.encoder(name: verb.Name): verb.Coder
  if name == "hex" then
    local c: HexEncoder = setmetatable({ done = false }, hex_encoder_mt)
    return c
  elseif name == "base64" then
    return base64_encoder(STANDARD)
  elseif name == "base64url" then
    return base64_encoder(URL)
  end
  error("codec: no such encoding: " .. tostring(name), 2)
end

--- An incremental decoder for `name`, as strict as the whole-string
--- one ([`Codec.unhex`], [`Codec.unbase64`], [`Codec.unbase64url`]) and
--- refusing with the same reason, its offsets counted from the first
--- character fed, whatever the chunking. `update` returns the bytes
--- whole groups of text spell, holding back at most three characters;
--- `finish` returns the last bytes, or `nil` and the reason.
--- Raises on a name it does not know.
--- @param name hex, base64 or base64url
--- @return verb.Coder The decoder
function verb.decoder(name: verb.Name): verb.Coder
  if name == "hex" then
    return hex_decoder()
  elseif name == "base64" then
    return base64_decoder(STANDARD)
  elseif name == "base64url" then
    return base64_decoder(URL)
  end
  error("codec: no such encoding: " .. tostring(name), 2)
end

local spec = Cli.verbs.codec.spec

local usage = "cosmic codec <hex|base64|base64url> [-d] [--wrap N] [--lenient] [<file>|-]"

--- The encodings, by the name a command line gives.
local names: {verb.Name} = { "hex", "base64", "base64url" }

local by_word: {string:verb.Name} = {}
for _, each in ipairs(names) do
  by_word[each] = each
end

local function known(word: string): verb.Name | nil
  return by_word[word]
end

--- Characters a text of each encoding may hold, as a pattern class of
--- what is refused (`=` is judged apart, as padding).
local refused: {string:string} = {
  hex = "[^0-9a-fA-F]",
  base64 = "[^A-Za-z0-9+/=]",
  base64url = "[^A-Za-z0-9_=%-]",
}

--- `text` without its ASCII whitespace.
local function squeezed(text: string): string
  return (text:gsub("[ \t\n\r\f\v]", ""))
end

--- The offset, from 0, in `text` of the `at`th character that is not
--- ASCII whitespace (1-based): where a fault in the squeezed text lies
--- in the input as given.
local function offset_of(text: string, at: integer): integer
  local seen = 0
  for i = 1, #text do
    if not text:sub(i, i):find("^[ \t\n\r\f\v]") then
      seen = seen + 1
      if seen == at then return i - 1 end
    end
  end
  return math.max(#text - 1, 0)
end

--- Bytes of input read, coded and written at a time.
local chunk_size <const> = 1 << 16

--- The whitespace `decoding` skips, as a pattern class.
local blank <const> = "[ \t\n\r\f\v]"

--- An encoder that writes its text in lines of `wrap` columns when that
--- is positive, and ends in a newline at `finish` (so empty input
--- writes just the newline).
local record Encoding is verb.Coder
  inner: verb.Coder
  wrap: integer
  --- How many columns of the line in progress are written.
  column: integer
  update: function(Encoding, chunk: string): string | nil, string
  finish: function(Encoding): string, string
end

local encoding_mt: metatable<Encoding> = { __index = Encoding }

--- `text` with a newline wherever a line is full and more follows.
local function shaped(self: Encoding, text: string): string
  local wrap = self.wrap
  if wrap <= 0 then return text end
  local parts: {string} = {}
  local at = 1
  local column = self.column
  while at <= #text do
    if column == wrap then
      parts[#parts + 1] = "\n"
      column = 0
    end
    local take = math.min(wrap - column, #text - at + 1)
    parts[#parts + 1] = text:sub(at, at + take - 1)
    column = column + take
    at = at + take
  end
  self.column = column
  return table.concat(parts)
end

function Encoding:update(chunk: string): string | nil, string
  return shaped(self, (assert(self.inner:update(chunk)))), ""
end

function Encoding:finish(): string, string
  return shaped(self, (assert(self.inner:finish()))) .. "\n", ""
end

--- An encoder for `name` that writes its text in lines of `wrap`
--- columns when that is positive, and ends in a newline at `finish`
--- (so empty input writes just the newline).
--- @param name hex, base64 or base64url
--- @param wrap columns per line; 0 for one line
local function encoding(name: verb.Name, wrap: integer): verb.Coder
  local c: Encoding = setmetatable({ inner = verb.encoder(name), wrap = wrap, column = 0 }, encoding_mt)
  return c
end

--- A decoder of text with ASCII whitespace anywhere in it.
local record Decoding is verb.Coder
  inner: verb.Coder
  name: verb.Name
  --- A pattern class of what `name`'s text may not hold.
  wrong: string
  lenient: boolean
  -- Bytes fed so far, characters that are not whitespace, and the
  -- offset of the last of them.
  fed: integer
  seen: integer
  last: integer | nil
  -- The first `=`: its offset and how many `=` and other characters
  -- follow, which is all the padding rules need.
  pad_at: integer | nil
  pad_run: integer
  pad_other: boolean
  failed: string | nil
  update: function(Decoding, chunk: string): string | nil, string
  finish: function(Decoding): string | nil, string
end

local decoding_mt: metatable<Decoding> = { __index = Decoding }

local function fail(self: Decoding, why: string): nil, string
  self.failed = why
  return nil, why
end

--- `why`, a [`cosmic.codec`] reason, with the offset of the text's end.
local function at_end(self: Decoding, why: string): nil, string
  return fail(self, ("%s (at offset %d)"):format(why:gsub("^codec: ", ""),
    self.last or math.max(self.fed - 1, 0)))
end

function Decoding:update(chunk: string): string | nil, string
  if self.failed ~= nil then return nil, self.failed end
  local name = self.name
  local clean = squeezed(chunk)
  local bad = clean:find(self.wrong)
  if bad ~= nil then
    return fail(self, ("byte 0x%02x at offset %d is not in the %s alphabet"):format(
      clean:byte(bad), self.fed + offset_of(chunk, bad), name))
  end
  if #clean > 0 then
    self.seen = self.seen + #clean
    self.last = self.fed + chunk:find("[^ \t\n\r\f\v]" .. blank .. "*$") - 1
  end
  local body = clean
  if name ~= "hex" then
    if self.pad_at == nil then
      local pad = clean:find("=", 1, true)
      if pad ~= nil then
        self.pad_at = self.fed + offset_of(chunk, pad)
        self.pad_run = #clean - pad + 1
        self.pad_other = clean:find("[^=]", pad) ~= nil
        if name == "base64url" then body = clean:sub(1, pad - 1) end
      end
    else
      self.pad_run = self.pad_run + #clean
      if clean:find("[^=]") ~= nil then self.pad_other = true end
      if name == "base64url" then body = "" end
    end
  end
  self.fed = self.fed + #chunk
  -- The strict decoder refuses only at `finish`.
  return assert(self.inner:update(body)), ""
end

function Decoding:finish(): string | nil, string
  if self.failed ~= nil then return nil, self.failed end
  local name, seen, pad_at = self.name, self.seen, self.pad_at
  -- Padding: `=` is only ever a run at the end, at most two long.
  local head = ""
  if pad_at ~= nil then
    if self.pad_run > 2 or self.pad_other then
      return fail(self, ("misplaced '=' padding at offset %d"):format(pad_at))
    end
    if name == "base64url" and not self.lenient then
      return fail(self, ("'=' padding at offset %d is not accepted for base64url; --lenient accepts it"):format(
        pad_at))
    end
    if name == "base64url" and seen % 4 ~= 0 then
      return fail(self, ("base64url padding at offset %d does not complete a group of four"):format(pad_at))
    end
  elseif name == "base64" and self.lenient and seen % 4 ~= 0 then
    if seen % 4 == 1 then
      return fail(self, ("base64 text of length %d leaves one character over (at offset %d)"):format(
        seen, self.last or 0))
    end
    head = assert(self.inner:update(("="):rep(4 - seen % 4)))
  end
  local out, why = self.inner:finish()
  if out == nil then return at_end(self, why) end
  return head .. out, ""
end

--- A decoder for `name` of text with ASCII whitespace anywhere in it.
--- `update` refuses a character outside the alphabet at once; the other
--- faults wait for `finish`, since only the end of the text tells a
--- length or a padding from a fault: both answer `nil` and a reason
--- naming a byte offset, from 0, counted in the input as given.
--- @param name hex, base64 or base64url
--- @param lenient whether the other padding spelling is accepted
function verb.decoding(name: verb.Name, lenient: boolean): verb.Coder
  local c: Decoding = setmetatable({
    inner = verb.decoder(name), name = name, wrong = refused[name], lenient = lenient,
    fed = 0, seen = 0, pad_run = 0, pad_other = false,
  }, decoding_mt)
  return c
end

--- The text `name` writes for `bytes`, wrapped to `wrap` columns when
--- that is positive, and always ending in a newline.
--- @param name hex, base64 or base64url
--- @param bytes what to encode
--- @param wrap columns per line; 0 for one line
function verb.encode(name: verb.Name, bytes: string, wrap: integer): string
  return (assert(Stream.run(encoding(name, wrap), bytes)))
end

--- The bytes `text` spells in encoding `name`, ignoring ASCII
--- whitespace, or nil and why, the message naming a byte offset.
--- @param name hex, base64 or base64url
--- @param text the encoded text
--- @param lenient whether the other padding spelling is accepted
function verb.decode(name: verb.Name, text: string, lenient: boolean): string | nil, string
  return Stream.run(verb.decoding(name, lenient), text)
end

--- What a command line asks for.
local record Request
  name: verb.Name
  decode: boolean
  wrap: integer
  lenient: boolean
  file: string | nil
end

--- What `argv` asks for, or nil and why it is refused.
local function arguments(argv: {integer:string}): Request | nil, string
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then return nil, trouble end
  local words = parsed.words
  if #words == 0 then
    return nil, "name an encoding: " .. table.concat(names, ", ")
  end
  local name = known(words[1])
  if name == nil then
    return nil, ("no such encoding: %s; there are %s"):format(words[1], table.concat(names, ", "))
  end
  local request: Request = {
    name = name, decode = parsed.set["-d"] or parsed.set["--decode"] or false,
    wrap = 0, lenient = parsed.set["--lenient"] or false,
  }
  if #words > 2 then
    return nil, "give an encoding and a file at most, not " .. plural.count(#words, "word")
  end
  request.file = words[2]
  if request.file == "" then return nil, bare.empty_file end
  if request.file == "-" then request.file = nil end
  local wrap = parsed.values["--wrap"]
  if wrap ~= nil then
    local n = math.tointeger(tonumber(wrap))
    if n == nil or n < 1 then
      return nil, "--wrap needs a whole number of columns, at least 1, not " .. wrap
    end
    if request.decode then
      return nil, "--wrap shapes what is written by an encoding, which -d does not do"
    end
    request.wrap = n
  end
  if request.lenient then
    if not request.decode then return nil, "--lenient is for -d" end
    if request.name == "hex" then
      return nil, "--lenient has nothing to accept for hex, which has no padding"
    end
  end
  return request, ""
end

--- Standard input, refusing a terminal, where nothing would ever end
--- the bytes.
local function open_stdin(): Stream.Reader | nil, string
  return bare.stdin_reader("no file given and standard input is a terminal; give a file or pipe bytes in")
end

local standard: verb.Io = {
  out = bare.out,
  err = bare.err,
  input = open_stdin,
}

--- The Writer a run gives [`Stream.transform_writer`]: what `to.out`
--- takes, and why it refused, which tells a lost write from a coder's
--- refusal.
local record OutputWriter is Stream.Writer
  out: function(text: string): boolean, string
  lost: string | nil
  write: function(OutputWriter, text: string): boolean, string
  close: function(OutputWriter): boolean, string
  abort: function(OutputWriter): boolean, string
end

local output_writer_mt: metatable<OutputWriter> = { __index = OutputWriter }

function OutputWriter:write(text: string): boolean, string
  local ok, why = self.out(text)
  if ok then return true, "" end
  self.lost = why
  return false, why
end

function OutputWriter:close(): boolean, string
  return true, ""
end

function OutputWriter:abort(): boolean, string
  return true, ""
end

--- `cosmic codec <encoding> [options] [<file>|-]`: writes the encoding
--- of the input, or with `-d` the bytes it spells, and returns the exit
--- code: 0 done, 2 a command line, an input or a write it refused.
--- @param argv the command line, `codec` at slot 1
--- @param io where the text is read and written; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("codec", to.err)
  local request, trouble = arguments(argv)
  if request == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end
  local opened: Stream.Reader | nil
  local read_trouble: string
  if request.file ~= nil then
    opened, read_trouble = Stream.open(request.file)
  elseif to.input ~= nil then
    opened, read_trouble = to.input()
  elseif to.stdin ~= nil then
    local whole: string | nil
    whole, read_trouble = to.stdin()
    if whole ~= nil then opened = Stream.from_string(whole) end
  else
    read_trouble = "no standard input is given to read"
  end
  if opened == nil then
    complain(read_trouble)
    return bare.refused
  end
  local reader: Stream.Reader = opened
  local decode = request.decode
  local coder = decode and verb.decoding(request.name, request.lenient)
    or encoding(request.name, request.wrap)
  local source = request.file or "standard input"
  -- A Writer over `to.out`, local because no Stream helper adapts a
  -- function to a Writer and no other verb needs one. `lost` is why a
  -- write failed, which tells it from a coder's refusal.
  local standard_output: OutputWriter = setmetatable({ out = to.out }, output_writer_mt)
  -- A decoder's output is held one chunk back, so that an input of at
  -- most one chunk that is refused writes nothing: see the head of this
  -- file.
  local sink = Stream.transform_writer(standard_output, coder, { hold = decode and 1 or 0 })
  --- Complains of `line` and ends the run in failure, releasing the input.
  local function stop(line: string): integer
    complain(line)
    local _, _ = sink:abort()
    local _, _ = reader:close()
    return bare.refused
  end
  --- The complaint for what `sink` refused: a lost write or a coder's refusal.
  local function blame(why: string): string
    local lost = standard_output.lost
    return lost ~= nil and bare.lost(lost) or source .. ": " .. why
  end
  while true do
    -- A read may come up short; fill the chunk, so that what is held
    -- back is a whole chunk of input and not the last read.
    local chunk, why = Stream.read_up_to(reader, chunk_size)
    if chunk == nil then return stop(why) end
    local wrote, refusal = sink:write(chunk)
    if not wrote then return stop(blame(refusal)) end
    if #chunk < chunk_size then break end
  end
  local committed, last_refusal = sink:close()
  if not committed then return stop(blame(last_refusal)) end
  local closed, close_why = reader:close()
  if not closed then
    complain(close_why)
    return bare.refused
  end
  return bare.ok
end

--- The `codec` verb as [`build/verb_list.tl`] lists it. Reads what it is
--- given, never the tree.
verb.spec = {
  name = "codec",
  guide = "bytes to text and back",
  tests = { "build.codec_test", "build.codec_tool_test" },
  run = function(argv: {integer:string}): integer return verb.run(argv) end,
  bare = true,
  takes = "an encoding and a file",
  exits = "`codec` prints its text or bytes and nothing after, and exits 0 or 2.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/codec_test.tl)",
}

return verb
