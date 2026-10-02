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
  --- output that is ready, possibly ""; `finish()` says no more input
  --- follows and returns what is left, with `nil` and a reason when a
  --- decoder's text was refused. An encoder never fails. A decoder
  --- fails only at `finish`: it cannot tell a bad length from a bad
  --- character until the text ends, and the whole-string decoders
  --- report the length first, so it keeps the first bad character and
  --- carries on. A coder holds at most three characters of a group not
  --- yet whole, plus a little state, however much passes through it,
  --- and gives all the output it has at each call. After `finish`,
  --- `update` and `finish` raise.
  record Coder is Stream.Transform
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

--- A coder whose `update` and `finish` are the given functions, each
--- refused once `finish` has run.
local function guarded(
    update: function(chunk: string): string, string,
    finish: function(): string | nil, string): verb.Coder
  local done = false
  local c: verb.Coder = {}
  c.update = function(_self: verb.Coder, chunk: string): string | nil, string
    if done then error("codec: coder is finished", 2) end
    return update(chunk)
  end
  c.finish = function(_self: verb.Coder): string | nil, string
    if done then error("codec: coder is finished", 2) end
    done = true
    return finish()
  end
  return c
end

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

--- A base64 encoder: whole groups of three bytes go out as they come,
--- and the last one or two are padded, if `a` pads, at `finish`.
local function base64_encoder(a: Alphabet): verb.Coder
  local carry = ""
  return guarded(
    function(chunk: string): string, string
      local data = carry .. chunk
      local whole = #data - #data % 3
      carry = data:sub(whole + 1)
      if whole == 0 then return "", "" end
      return a.encode(whole == #data and data or data:sub(1, whole)), ""
    end,
    function(): string, string
      return a.encode(carry), ""
    end)
end

local function hex_decoder(): verb.Coder
  local total = 0
  local carry = ""
  local bad_at: integer | nil
  local bad_byte = 0
  return guarded(
    function(chunk: string): string, string
      local before = total - #carry
      total = total + #chunk
      if bad_at ~= nil then return "", "" end
      local data = carry .. chunk
      -- Text that is sound decodes in one pass through the library;
      -- only a refusal, or a character in the held-back byte, looks for
      -- where the first bad character lies.
      local even = #data - #data % 2
      local tail = data:sub(even + 1)
      if not tail:find("[^0-9a-fA-F]") then
        local out, _why = Codec.unhex(even == #data and data or data:sub(1, even))
        if out ~= nil then
          carry = tail
          return out, ""
        end
      end
      local at = data:find("[^0-9a-fA-F]")
      assert(at ~= nil, "codec: hex text refused though every character is a digit")
      bad_at, bad_byte, carry = before + at, data:byte(at), ""
      return "", ""
    end,
    function(): string | nil, string
      if total % 2 ~= 0 then
        return nil, ("codec: hex text of odd length %d"):format(total)
      end
      if bad_at ~= nil then
        return nil, ("codec: byte 0x%02x at %d is not a hex digit"):format(bad_byte, bad_at)
      end
      return "", ""
    end)
end

--- A decoder for `a`, as the whole-string one is: the same refusals in
--- the same order, the same words, and offsets counted from the first
--- character fed.
local function base64_decoder(a: Alphabet): verb.Coder
  local name = a.name
  local padded = a.padded
  local total = 0
  -- Characters of the group in progress, all in the alphabet.
  local carry = ""
  -- The first character outside the alphabet, where it lies and what
  -- it is; from there on, only how many characters follow and whether
  -- all of them are `=`, which decides whether it is padding.
  local bad_at: integer | nil
  local bad_byte = 0
  local run = 0
  local run_pad = false
  return guarded(
    function(chunk: string): string, string
      local before = total - #carry
      total = total + #chunk
      if bad_at ~= nil then
        run = run + #chunk
        if run_pad and chunk:find("[^=]") then run_pad = false end
        return "", ""
      end
      local data = carry .. chunk
      -- As in [`hex_decoder`]: a chunk whose whole groups the library
      -- decodes needs no search for a bad character. A group ending in
      -- `=` is left to the search below, since the library would take
      -- it for padding.
      local whole = #data - #data % 4
      if whole > 0 and data:byte(whole) ~= 61 then
        local tail = data:sub(whole + 1)
        if not tail:find(a.class) then
          local out, _why = a.decode(whole == #data and data or data:sub(1, whole))
          if out ~= nil then
            carry = tail
            return out, ""
          end
        end
      end
      local at = data:find(a.class)
      local usable = at ~= nil and at - 1 or #data
      whole = usable - usable % 4
      carry = data:sub(whole + 1, usable)
      if at ~= nil then
        bad_at, bad_byte = before + at, data:byte(at)
        run = #data - at + 1
        run_pad = bad_byte == 61 and data:find("[^=]", at) == nil
      end
      if whole == 0 then return "", "" end
      return (assert(a.decode(data:sub(1, whole)))), ""
    end,
    function(): string | nil, string
      if padded then
        if total % 4 ~= 0 then
          return nil, ("codec: %s text of length %d, not a multiple of 4"):format(name, total)
        end
      elseif total % 4 == 1 then
        return nil, ("codec: %s text of length %d leaves one character over"):format(name, total)
      end
      if bad_at ~= nil and not (padded and run_pad and run <= 2) then
        if bad_byte == 61 then
          return nil, ("codec: %s text has misplaced '=' padding at %d"):format(name, bad_at)
        end
        return nil, ("codec: byte 0x%02x at %d is outside the %s alphabet"):format(
          bad_byte, bad_at, name)
      end
      if #carry < 2 then return "", "" end
      -- The last, partial group decodes as the whole-string decoder
      -- would see it, padded out if the alphabet is.
      local last = padded and carry .. ("="):rep(4 - #carry) or carry
      local out, why = a.decode(last)
      if out == nil then return nil, why end
      return out, ""
    end)
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
    return guarded(
      function(chunk: string): string, string
        return Codec.hex(chunk), ""
      end,
      function(): string, string
        return "", ""
      end)
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

--- An encoder for `name` that writes its text in lines of `wrap`
--- columns when that is positive, and ends in a newline at `finish`
--- (so empty input writes just the newline).
--- @param name hex, base64 or base64url
--- @param wrap columns per line; 0 for one line
local function encoding(name: verb.Name, wrap: integer): verb.Coder
  local inner = verb.encoder(name)
  local column = 0
  --- `text` with a newline wherever a line is full and more follows.
  local function shaped(text: string): string
    if wrap <= 0 then return text end
    local parts: {string} = {}
    local at = 1
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
    return table.concat(parts)
  end
  local coder: verb.Coder = {}
  coder.update = function(_self: verb.Coder, chunk: string): string, string
    return shaped((assert(inner:update(chunk)))), ""
  end
  coder.finish = function(_self: verb.Coder): string, string
    return shaped((assert(inner:finish()))) .. "\n", ""
  end
  return coder
end

--- A decoder for `name` of text with ASCII whitespace anywhere in it.
--- `update` refuses a character outside the alphabet at once; the other
--- faults wait for `finish`, since only the end of the text tells a
--- length or a padding from a fault: both answer `nil` and a reason
--- naming a byte offset, from 0, counted in the input as given.
--- @param name hex, base64 or base64url
--- @param lenient whether the other padding spelling is accepted
function verb.decoding(name: verb.Name, lenient: boolean): verb.Coder
  local inner = verb.decoder(name)
  local wrong = refused[name]
  -- Bytes fed so far, characters that are not whitespace, and the
  -- offset of the last of them.
  local fed = 0
  local seen = 0
  local last: integer | nil
  -- The first `=`: its offset and how many `=` and other characters
  -- follow, which is all the padding rules need.
  local pad_at: integer | nil
  local pad_run = 0
  local pad_other = false
  local failed: string | nil
  local function fail(why: string): nil, string
    failed = why
    return nil, why
  end
  --- `why`, a [`cosmic.codec`] reason, with the offset of the text's end.
  local function at_end(why: string): nil, string
    return fail(("%s (at offset %d)"):format(why:gsub("^codec: ", ""), last or math.max(fed - 1, 0)))
  end
  local coder: verb.Coder = {}
  coder.update = function(_self: verb.Coder, chunk: string): string | nil, string
    if failed ~= nil then return nil, failed end
    local clean = squeezed(chunk)
    local bad = clean:find(wrong)
    if bad ~= nil then
      return fail(("byte 0x%02x at offset %d is not in the %s alphabet"):format(
        clean:byte(bad), fed + offset_of(chunk, bad), name))
    end
    if #clean > 0 then
      seen = seen + #clean
      last = fed + chunk:find("[^ \t\n\r\f\v]" .. blank .. "*$") - 1
    end
    local body = clean
    if name ~= "hex" then
      if pad_at == nil then
        local pad = clean:find("=", 1, true)
        if pad ~= nil then
          pad_at = fed + offset_of(chunk, pad)
          pad_run = #clean - pad + 1
          pad_other = clean:find("[^=]", pad) ~= nil
          if name == "base64url" then body = clean:sub(1, pad - 1) end
        end
      else
        pad_run = pad_run + #clean
        if clean:find("[^=]") ~= nil then pad_other = true end
        if name == "base64url" then body = "" end
      end
    end
    fed = fed + #chunk
    -- The strict decoder refuses only at `finish`.
    return assert(inner:update(body)), ""
  end
  coder.finish = function(_self: verb.Coder): string | nil, string
    if failed ~= nil then return nil, failed end
    -- Padding: `=` is only ever a run at the end, at most two long.
    local head = ""
    if pad_at ~= nil then
      if pad_run > 2 or pad_other then
        return fail(("misplaced '=' padding at offset %d"):format(pad_at))
      end
      if name == "base64url" and not lenient then
        return fail(("'=' padding at offset %d is not accepted for base64url; --lenient accepts it"):format(
          pad_at))
      end
      if name == "base64url" and seen % 4 ~= 0 then
        return fail(("base64url padding at offset %d does not complete a group of four"):format(pad_at))
      end
    elseif name == "base64" and lenient and seen % 4 ~= 0 then
      if seen % 4 == 1 then
        return fail(("base64 text of length %d leaves one character over (at offset %d)"):format(
          seen, last or 0))
      end
      head = assert(inner:update(("="):rep(4 - seen % 4)))
    end
    local out, why = inner:finish()
    if out == nil then return at_end(why) end
    return head .. out, ""
  end
  return coder
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
    if request.name == "hex" then return nil, "--lenient has nothing to accept for hex, which has no padding" end
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
  -- Why a write to `to.out` failed, which tells it from a coder's refusal.
  local lost: string | nil
  local standard_output: Stream.Writer = {
    write = function(_self: Stream.Writer, text: string): boolean, string
      local ok, why = to.out(text)
      if ok then return true, "" end
      lost = why
      return false, why
    end,
    close = function(_self: Stream.Writer): boolean, string return true, "" end,
    abort = function(_self: Stream.Writer): boolean, string return true, "" end,
  }
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
