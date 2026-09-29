--- `cosmic codec`: bytes to text and back, for the ten-second question
--- ("what is this token in hex?") that a script costs more than. It
--- reads a file, or standard input, and writes the encoding, or with
--- `-d` the bytes it spells -- and nothing else: like `cosmic json` it
--- ends in no verdict line (its `spec` is `bare`), because its
--- standard output is data for a pipe. Its exit status is the verdict:
--- 0 done, 2 a command line, an input or a write it cannot honor.
--- Complaints go to standard error as `cosmic: codec: ...`.
---
--- The encodings are `cosmic.codec`'s: hex, base64 and base64url, and no
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
--- `cosmic.codec` is: an invalid character, misplaced padding, a bad
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
--- ends), through `cosmic.codec`'s incremental coders. Encoding writes
--- each chunk's text as soon as it is made. Decoding holds one chunk's
--- bytes back until the next chunk has decoded, so an input of at most
--- 64 KiB writes nothing when it is refused. A padding, length or
--- misplaced-`=` fault shows only at the end of the input, so a decoder
--- reads all of a stream to find one -- in bounded memory, whatever its
--- size -- and for an input of more than 64 KiB may have written most
--- of its bytes before it refuses. An invalid character is refused as
--- soon as its chunk is read.

local Cli = require("cosmic.cli")
local Codec = require("cosmic.codec")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")
local verb_spec = require("build.verb_spec")

--- The `cosmic codec` verb: `run` is what `build/dispatch.tl` calls.
local record verb
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

local spec = Cli.options.codec

local usage = "cosmic codec <hex|base64|base64url> [-d] [--wrap N] [--lenient] [<file>|-]"

--- The encodings, by the name a command line gives.
local names: {Codec.Name} = { "hex", "base64", "base64url" }

local by_word: {string:Codec.Name} = {}
for _, each in ipairs(names) do
  by_word[each] = each
end

local function known(word: string): Codec.Name | nil
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
local function encoding(name: Codec.Name, wrap: integer): Codec.Coder
  local inner = Codec.encoder(name)
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
  local coder: Codec.Coder = {}
  coder.update = function(_self: Codec.Coder, chunk: string): string, string
    return shaped((assert(inner:update(chunk)))), ""
  end
  coder.finish = function(_self: Codec.Coder): string, string
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
function verb.decoding(name: Codec.Name, lenient: boolean): Codec.Coder
  local inner = Codec.decoder(name)
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
  --- `why`, a `cosmic.codec` reason, with the offset of the text's end.
  local function at_end(why: string): nil, string
    return fail(("%s (at offset %d)"):format(why:gsub("^codec: ", ""), last or math.max(fed - 1, 0)))
  end
  local coder: Codec.Coder = {}
  coder.update = function(_self: Codec.Coder, chunk: string): string | nil, string
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
    -- A `cosmic.codec` decoder refuses only at `finish`.
    return assert(inner:update(body)), ""
  end
  coder.finish = function(_self: Codec.Coder): string | nil, string
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
function verb.encode(name: Codec.Name, bytes: string, wrap: integer): string
  local coder = encoding(name, wrap)
  return assert(coder:update(bytes)) .. assert(coder:finish())
end

--- The bytes `text` spells in encoding `name`, ignoring ASCII
--- whitespace, or nil and why, the message naming a byte offset.
--- @param name hex, base64 or base64url
--- @param text the encoded text
--- @param lenient whether the other padding spelling is accepted
function verb.decode(name: Codec.Name, text: string, lenient: boolean): string | nil, string
  local coder = verb.decoding(name, lenient)
  local head, why = coder:update(text)
  if head == nil then return nil, why end
  local tail, tail_why = coder:finish()
  if tail == nil then return nil, tail_why end
  return head .. tail, ""
end

--- What a command line asks for.
local record Request
  name: Codec.Name
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
    return nil, "give an encoding and a file at most, not " .. #words .. " words"
  end
  request.file = words[2]
  if request.file == "" then return nil, "an empty file name" end
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
  if Proc.is_tty(Fs.stdin) then
    return nil, "no file given and standard input is a terminal; give a file or pipe bytes in"
  end
  -- `Stream.from_fd` borrows the descriptor, which stays open.
  return Stream.from_fd(Fs.stdin), ""
end

local standard: verb.Io = {
  out = function(text: string): boolean, string
    return Fs.put(Fs.stdout, text)
  end,
  err = function(line: string)
    local _, _ = Fs.put(Fs.stderr, line .. "\n")
  end,
  input = open_stdin,
}

--- `cosmic codec <encoding> [options] [<file>|-]`: writes the encoding
--- of the input, or with `-d` the bytes it spells, and returns the exit
--- code: 0 done, 2 a command line, an input or a write it refused.
--- @param argv the command line, `codec` at slot 1
--- @param io where the text is read and written; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  local function complain(line: string)
    to.err("cosmic: codec: " .. line)
  end
  local request, trouble = arguments(argv)
  if request == nil then
    complain(trouble .. "; " .. usage)
    return 2
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
    return 2
  end
  local reader: Stream.Reader = opened
  local decode = request.decode
  local coder = decode and verb.decoding(request.name, request.lenient)
    or encoding(request.name, request.wrap)
  local source = request.file or "standard input"
  -- What one chunk decoded to, kept until the next chunk shows the
  -- text is sound so far: see the head of this file. Not used to encode.
  local held = ""
  --- Writes `text`, or complains of the write and answers false.
  local function put(text: string): boolean
    if text == "" then return true end
    local ok, why = to.out(text)
    if not ok then complain("standard output: " .. why) end
    return ok
  end
  --- Ends the run in failure, releasing the input.
  local function stop(): integer
    local _, _ = reader:close()
    return 2
  end
  while true do
    -- A read may come up short; fill the chunk, so that what is held
    -- back is a whole chunk of input and not the last read.
    local parts: {string} = {}
    local have = 0
    local ended = false
    while have < chunk_size do
      local piece, why = reader:read(chunk_size - have)
      if piece == nil then
        if why ~= "" then
          complain(why)
          return stop()
        end
        ended = true
        break
      end
      parts[#parts + 1] = piece
      have = have + #piece
    end
    if have > 0 then
      local out, refusal = coder:update(table.concat(parts))
      if out == nil then
        complain(source .. ": " .. refusal)
        return stop()
      end
      if decode then
        if not put(held) then return stop() end
        held = out
      elseif not put(out) then
        return stop()
      end
    end
    if ended then break end
  end
  local last, refusal = coder:finish()
  if last == nil then
    complain(source .. ": " .. refusal)
    return stop()
  end
  if not put(held .. last) then return stop() end
  local closed, close_why = reader:close()
  if not closed then
    complain(close_why)
    return 2
  end
  return 0
end

--- The `codec` verb as `build/verb_list.tl` lists it. Reads what it is
--- given, never the tree.
verb.spec = {
  name = "codec",
  run = function(argv: {integer:string}): integer return verb.run(argv) end,
  bare = true,
  takes = "an encoding and a file",
  exits = "`codec` prints its text or bytes and nothing after, and exits 0 or 2.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/codec_test.tl)",
}

return verb
