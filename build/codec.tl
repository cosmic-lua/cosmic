--- `cosmic codec`: bytes to text and back, for the ten-second question
--- ("what is this token in hex?") that a script costs more than. It
--- reads a file, or standard input, and writes the encoding, or with
--- `-d` the bytes it spells -- and nothing else: like `cosmic json` it
--- ends in no verdict line (build/dispatch.tl's `bare`), because its
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
--- The whole input is read and held: `cosmic.codec` has no incremental
--- coder.
--- TODO: stream, once cosmic.codec carries an incremental encoder and
--- decoder that takes a chunk and keeps its leftover (up to two bytes of
--- input, or three characters of text).

local Cli = require("cosmic.cli")
local Codec = require("cosmic.codec")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")

--- The `cosmic codec` verb: `run` is what `build/dispatch.tl` calls.
local record verb
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given. False and why when the
    --- bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- The whole of standard input, or nil and why.
    stdin: function(): string | nil, string
  end
end

local spec = Cli.options.codec

local usage = "cosmic codec <hex|base64|base64url> [-d] [--wrap N] [--lenient] [<file>|-]"

--- The encodings, by the name a command line gives.
local names: {string} = { "hex", "base64", "base64url" }

local function known(name: string): boolean
  for _, each in ipairs(names) do
    if each == name then return true end
  end
  return false
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

--- The text `name` writes for `bytes`, wrapped to `wrap` columns when
--- that is positive, and always ending in a newline.
--- @param name hex, base64 or base64url
--- @param bytes what to encode
--- @param wrap columns per line; 0 for one line
function verb.encode(name: string, bytes: string, wrap: integer): string
  local text: string
  if name == "hex" then
    text = Codec.hex(bytes)
  elseif name == "base64" then
    text = Codec.base64(bytes)
  else
    text = Codec.base64url(bytes)
  end
  if wrap <= 0 or #text <= wrap then return text .. "\n" end
  local lines: {string} = {}
  for first = 1, #text, wrap do
    lines[#lines + 1] = text:sub(first, first + wrap - 1)
  end
  return table.concat(lines, "\n") .. "\n"
end

--- The bytes `text` spells in encoding `name`, ignoring ASCII
--- whitespace, or nil and why, the message naming a byte offset.
--- @param name hex, base64 or base64url
--- @param text the encoded text
--- @param lenient whether the other padding spelling is accepted
function verb.decode(name: string, text: string, lenient: boolean): string | nil, string
  local clean = squeezed(text)
  local bad = clean:find(refused[name])
  if bad ~= nil then
    return nil, ("byte 0x%02x at offset %d is not in the %s alphabet"):format(
      clean:byte(bad), offset_of(text, bad), name)
  end
  if name == "hex" then
    local bytes, why = Codec.unhex(clean)
    if bytes == nil then
      return nil, ("%s (at offset %d)"):format(why:gsub("^codec: ", ""), offset_of(text, #clean))
    end
    return bytes, ""
  end
  -- Padding: `=` is only ever a run at the end, at most two long.
  local pad = clean:find("=", 1, true)
  local body = clean
  if pad ~= nil then
    local run = clean:sub(pad)
    if #run > 2 or run:find("[^=]") then
      return nil, ("misplaced '=' padding at offset %d"):format(offset_of(text, pad))
    end
    if name == "base64url" and not lenient then
      return nil, ("'=' padding at offset %d is not accepted for base64url; --lenient accepts it"):format(
        offset_of(text, pad))
    end
    body = clean:sub(1, pad - 1)
  end
  local bytes: string | nil
  local why: string
  if name == "base64" then
    local spelled = clean
    if lenient and pad == nil and #clean % 4 ~= 0 then
      if #clean % 4 == 1 then
        return nil, ("base64 text of length %d leaves one character over (at offset %d)"):format(
          #clean, offset_of(text, #clean))
      end
      spelled = clean .. ("="):rep(4 - #clean % 4)
    end
    bytes, why = Codec.unbase64(spelled)
  else
    if pad ~= nil and #clean % 4 ~= 0 then
      return nil, ("base64url padding at offset %d does not complete a group of four"):format(
        offset_of(text, pad))
    end
    bytes, why = Codec.unbase64url(body)
  end
  if bytes == nil then
    return nil, ("%s (at offset %d)"):format(why:gsub("^codec: ", ""), offset_of(text, #clean))
  end
  return bytes, ""
end

--- What a command line asks for.
local record Request
  name: string
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
  local request: Request = {
    name = words[1], decode = parsed.set["-d"] or parsed.set["--decode"] or false,
    wrap = 0, lenient = parsed.set["--lenient"] or false,
  }
  if not known(request.name) then
    return nil, ("no such encoding: %s; there are %s"):format(request.name, table.concat(names, ", "))
  end
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

--- The bytes of standard input, refusing a terminal, where nothing
--- would ever end them.
local function read_stdin(): string | nil, string
  if Proc.is_tty(Fs.stdin) then
    return nil, "no file given and standard input is a terminal; give a file or pipe bytes in"
  end
  -- `Stream.from_fd` borrows the descriptor, which stays open.
  return Stream.read_all(Stream.from_fd(Fs.stdin))
end

local standard: verb.Io = {
  out = function(text: string): boolean, string
    return Fs.put(Fs.stdout, text)
  end,
  err = function(line: string)
    local _, _ = Fs.put(Fs.stderr, line .. "\n")
  end,
  stdin = read_stdin,
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
  local input: string | nil
  local read_trouble: string
  if request.file == nil then
    input, read_trouble = to.stdin()
  else
    input, read_trouble = Fs.read(request.file)
  end
  if input == nil then
    complain(read_trouble)
    return 2
  end
  local output: string
  if request.decode then
    local bytes, why = verb.decode(request.name, input, request.lenient)
    if bytes == nil then
      complain((request.file or "standard input") .. ": " .. why)
      return 2
    end
    output = bytes
  else
    output = verb.encode(request.name, input, request.wrap)
  end
  local ok, why = to.out(output)
  if not ok then
    complain("standard output: " .. why)
    return 2
  end
  return 0
end

return verb
