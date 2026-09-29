--- `cosmic rand`: a UUID, a token, a number or a shuffled list, for the
--- ten-second question ("give me an id", "pick one of these") that a
--- script costs more than.
---
--- WHERE THE BYTES COME FROM. Everything secret-grade -- `uuid`, `token`,
--- and `int`, `pick` and `shuffle` without `--seed` -- is drawn from the
--- operating system's entropy source, `Rand.entropy`, and from nothing
--- else: `secret` below is the one function that reads it, and no seeded
--- generator is ever reached from those paths. `--seed <n>` is the other
--- road and the only one to `Rand.new`, a replayable xoshiro256** that is
--- not secret: it exists so a test or a script can name its chance, and
--- its output must never be used as a key, token or nonce. `--seed` is
--- refused with `uuid` and `token`, which have no use for it.
---
--- Like `cosmic json` it ends in no verdict line: its standard output is
--- data for a pipe. Exit 0 is ok, 2 a command line, a file or a request
--- it refuses (a failed write to standard output included), 1 the
--- operating system's entropy source failing. Complaints go to standard
--- error as `cosmic: rand: ...`. build/dispatch.tl's `bare` names it.
---
--- UUIDs. Version 4 is 122 bits of entropy. Version 7 (RFC 9562) is the
--- Unix time in milliseconds from `cosmic.time`, then the rest from
--- entropy. Its 12 bits after the version are the RFC's method 3
--- (section 6.2, increased clock precision): the clock's fraction of the
--- current millisecond, in 4096ths, and where a draw would not sort after
--- the one before -- the same fraction, or a clock that stepped back --
--- the previous value plus one, carrying into the milliseconds. So the
--- values of one run always sort in the order they were drawn. A clock
--- that steps far back leaves the timestamps ahead of real time for the
--- rest of the run: each draw then adds 1/4096 of a millisecond until
--- the clock overtakes them. Only one run is ordered: two runs in one
--- millisecond can draw either way.
---
--- Lines (`pick`, `shuffle`) end at "\n", and a "\r" before it is
--- dropped, so CRLF input gives the same lines as LF input; output ends
--- each line with "\n".

local Codec = require("cosmic.codec")
local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Rand = require("cosmic.rand")
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")

--- The `cosmic rand` verb: `run` is what `build/dispatch.tl` calls.
local record verb
  --- Where `run` reads, writes and draws: what a test stands in for.
  record Io
    --- Writes to standard output, as given: the caller adds newlines.
    --- False and why when the bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- The whole of standard input, or nil and why.
    stdin: function(): string | nil, string
    --- The operating system's entropy: `Rand.entropy` when nil.
    entropy: function(count: integer): string | nil, string
    --- The wall clock in nanoseconds: `Time.now_ns` when nil.
    now_ns: function(): integer
  end

  --- The most bytes `token --bytes` gives, `Rand.entropy`'s own limit.
  MAX_BYTES: integer
  --- The most values `-n` asks for.
  MAX_COUNT: integer
end

verb.MAX_BYTES = 1048576
verb.MAX_COUNT = 10000000

local spec = Cli.options.rand

local usage = "cosmic rand uuid [--v4|--v7] [-n N] | token [--bytes N] [--hex|--base64url] | " ..
  "int [-n N] [--seed S] [--] <lo> <hi> | pick [-n N] [--seed S] [file|-] | shuffle [--seed S] [file|-]"

--- What a run wants of one draw of numbers: `int(lo, hi)` uniform over
--- the inclusive range.
local record Source
  int: function(lo: integer, hi: integer): integer
end

--- Parses `word` as a whole decimal integer, or nil.
local function integer_of(word: string): integer | nil
  if not word:match("^[+-]?%d+$") then return nil end
  return math.tointeger(tonumber(word))
end

--- What `argv` asks for, checked against the subcommand.
local record Request
  command: string
  version: integer
  count: integer | nil
  bytes: integer
  encoding: string
  seed: integer | nil
  words: {string}
end

--- The prefix that keeps a negative number from being read as an option.
local NEGATIVE <const> = "\1"

--- `argv` with each negative integer bound of `int` marked so `Flags`
--- reads it as a word, not an option: `cosmic rand int -5 5` works
--- without a `--`. An option's value is left alone.
local function marked(argv: {integer:string}): {integer:string}
  local out: {integer:string} = {}
  for key, word in pairs(argv) do out[key] = word end
  if argv[2] ~= "int" then return out end
  local slot = 3
  while argv[slot] ~= nil do
    local word = argv[slot]
    if word == "--" then break end
    if word == "-n" or word == "--seed" then
      slot = slot + 1
    elseif word:match("^%-%d+$") then
      out[slot] = NEGATIVE .. word
    end
    slot = slot + 1
  end
  return out
end

--- The options `command` takes, for refusing the rest.
local allowed: {string:{string:boolean}} = {
  uuid = { ["--v4"] = true, ["--v7"] = true, ["-n"] = true },
  token = { ["--bytes"] = true, ["--hex"] = true, ["--base64url"] = true },
  int = { ["-n"] = true, ["--seed"] = true },
  pick = { ["-n"] = true, ["--seed"] = true },
  shuffle = { ["--seed"] = true },
}

--- What `argv` asks for, or nil and why it is refused.
local function arguments(argv: {integer:string}): Request | nil, string
  local command = argv[2]
  if command == nil then
    return nil, "give a subcommand"
  end
  if allowed[command] == nil then
    return nil, "no such subcommand: " .. command
  end
  local parsed, trouble = Flags.parse(marked(argv), 3, spec)
  if parsed == nil then return nil, trouble end
  for _, name in ipairs(parsed.given) do
    if not allowed[command][name] then
      if name == "--seed" then
        return nil, "--seed is refused with " .. command .. ": its output is secret, and a seed would make it replayable"
      end
      return nil, command .. " takes no " .. name
    end
  end
  local request: Request = { command = command, version = 4, bytes = 32, encoding = "base64url", words = {} }
  for _, word in ipairs(parsed.words) do
    if command == "int" and word:sub(1, #NEGATIVE) == NEGATIVE then word = word:sub(#NEGATIVE + 1) end
    request.words[#request.words + 1] = word
  end
  if parsed.set["--v4"] and parsed.set["--v7"] then
    return nil, "name one of --v4 and --v7, not both"
  end
  if parsed.set["--v7"] then request.version = 7 end
  if parsed.set["--hex"] and parsed.set["--base64url"] then
    return nil, "name one of --hex and --base64url, not both"
  end
  if parsed.set["--hex"] then request.encoding = "hex" end
  local given = parsed.values["-n"]
  if given ~= nil then
    local count = integer_of(given)
    if count == nil or count < 1 or count > verb.MAX_COUNT then
      return nil, "-n needs a whole number from 1 to " .. verb.MAX_COUNT .. ", not " .. given
    end
    request.count = count
  end
  given = parsed.values["--bytes"]
  if given ~= nil then
    local bytes = integer_of(given)
    if bytes == nil or bytes < 1 or bytes > verb.MAX_BYTES then
      return nil, "--bytes needs a whole number from 1 to " .. verb.MAX_BYTES .. ", not " .. given
    end
    request.bytes = bytes
  end
  given = parsed.values["--seed"]
  if given ~= nil then
    local seed = integer_of(given)
    if seed == nil then
      return nil, "--seed needs a whole number, not " .. given
    end
    request.seed = seed
  end
  local words = request.words
  if command == "int" then
    if #words ~= 2 then
      return nil, "give a low and a high bound, not " .. #words .. " words"
    end
  elseif command == "pick" or command == "shuffle" then
    if #words > 1 then
      return nil, "give one file at most, not " .. #words .. " words"
    end
    if words[1] == "" then return nil, "an empty file name" end
  elseif #words > 0 then
    return nil, command .. " takes no words, not " .. #words
  end
  return request, ""
end

--- The bytes of standard input, refusing a terminal.
local function read_stdin(): string | nil, string
  if Proc.is_tty(Fs.stdin) then
    return nil, "no file given and standard input is a terminal; give a file or pipe lines in"
  end
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
  entropy = Rand.entropy,
  now_ns = Time.now_ns,
}

--- The lines of `text`, split at "\n" with a "\r" before it dropped; a last line's newline ends it, it
--- does not begin another, so "" is no lines and "a\n\nb" is three.
local function lines_of(text: string): {string}
  local lines: {string} = {}
  local at = 1
  while at <= #text do
    local stop = text:find("\n", at, true)
    if stop == nil then
      lines[#lines + 1] = text:sub(at)
      break
    end
    local last = stop - 1
    if last >= at and text:byte(last) == 13 then last = last - 1 end
    lines[#lines + 1] = text:sub(at, last)
    at = stop + 1
  end
  return lines
end

--- `cosmic rand <subcommand> ...`: prints what it draws, and returns the
--- exit code: 0 ok, 1 the entropy source failed, 2 a command line, a
--- file or a request it refuses, or a standard output that took no write.
--- @param argv the command line, `rand` at slot 1
--- @param io where text is read and written and bytes drawn; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  local function complain(line: string)
    to.err("cosmic: rand: " .. line)
  end
  local found, trouble = arguments(argv)
  if found == nil then
    complain(trouble .. "; " .. usage)
    return 2
  end
  local request: Request = found
  local draw_entropy = to.entropy or Rand.entropy
  local now_ns = to.now_ns or Time.now_ns

  --- THE ONE READ OF THE OPERATING SYSTEM'S ENTROPY. Every value that
  --- may be a secret is made from bytes this returns; a seeded
  --- generator (`Rand.new`) is reached only from `seeded` below.
  local broken: string | nil
  local function fetch(count: integer): string
    local bytes, why = draw_entropy(count)
    if bytes == nil or #bytes ~= count then
      broken = why ~= "" and why or "short read"
      error("entropy", 0)
    end
    return bytes
  end
  -- Small draws share one read of the entropy source (one getentropy
  -- for many values), which is still the operating system's entropy:
  -- each byte is handed out once. A large draw reads for itself.
  local POOL <const> = 8192
  local pool, used = "", 0
  local function secret(count: integer): string
    if count > 64 then return fetch(count) end
    if used + count > #pool then
      pool, used = fetch(POOL), 0
    end
    local bytes = pool:sub(used + 1, used + count)
    used = used + count
    return bytes
  end

  --- Uniform over lo..hi from entropy, by `Rand.uniform`'s rejection.
  local function secret_int(lo: integer, hi: integer): integer
    if lo == hi then return lo end
    return Rand.uniform(function(): integer
      return (string.unpack("<i8", secret(8)))
    end, lo, hi)
  end

  --- The replayable, NOT secret, source `--seed` names.
  local function seeded(seed: integer): Source
    local source = Rand.new(seed)
    return { int = function(lo: integer, hi: integer): integer return source:int(lo, hi) end }
  end

  local source: Source
  if request.seed ~= nil then
    source = seeded(request.seed)
  else
    source = { int = secret_int }
  end

  -- Output goes out in pieces, so a large -n is never held whole.
  local pending: {string} = {}
  local pending_size = 0
  local function flush(): boolean
    if pending_size == 0 then return true end
    local text = table.concat(pending)
    pending, pending_size = {}, 0
    local ok, why = to.out(text)
    if not ok then
      complain("standard output: " .. why)
      return false
    end
    return true
  end
  local function emit(text: string): boolean
    pending[#pending + 1] = text
    pending[#pending + 1] = "\n"
    pending_size = pending_size + #text + 1
    if pending_size >= 65536 then return flush() end
    return true
  end

  local function uuid_text(bytes: string): string
    local hex = Codec.hex(bytes)
    return hex:sub(1, 8) .. "-" .. hex:sub(9, 12) .. "-" .. hex:sub(13, 16) .. "-" ..
      hex:sub(17, 20) .. "-" .. hex:sub(21, 32)
  end

  local last_v7 = -1
  --- One UUID: version 4 from 16 entropy bytes with the version and
  --- variant bits set, or version 7 laid out as 48 bits of milliseconds,
  --- the version, the 12-bit counter, the variant and 62 entropy bits.
  local function uuid(version: integer): string
    if version == 4 then
      local bytes = secret(16)
      local b6 = (bytes:byte(7) & 0x0f) | 0x40
      local b8 = (bytes:byte(9) & 0x3f) | 0x80
      return uuid_text(bytes:sub(1, 6) .. string.char(b6) .. bytes:sub(8, 8) ..
        string.char(b8) .. bytes:sub(10))
    end
    local ns = now_ns()
    local stamp = ((ns // 1000000) << 12) | ((ns % 1000000) * 4096 // 1000000)
    if stamp <= last_v7 then stamp = last_v7 + 1 end
    last_v7 = stamp
    local tail = secret(8)
    local b8 = (tail:byte(1) & 0x3f) | 0x80
    local head = string.pack(">I6", stamp >> 12)
    local counter = stamp & 0xfff
    return uuid_text(head .. string.char(0x70 | (counter >> 8), counter & 0xff) ..
      string.char(b8) .. tail:sub(2))
  end

  local code = 0
  local function body()
    local command = request.command
    if command == "uuid" then
      for _ = 1, request.count or 1 do
        if not emit(uuid(request.version)) then
          code = 2
          return
        end
      end
    elseif command == "token" then
      local bytes = secret(request.bytes)
      local text = request.encoding == "hex" and Codec.hex(bytes) or Codec.base64url(bytes)
      if not emit(text) then
        code = 2
        return
      end
    elseif command == "int" then
      local lo, hi = integer_of(request.words[1]), integer_of(request.words[2])
      if lo == nil or hi == nil then
        complain("the bounds are whole numbers, not " .. request.words[1] .. " and " .. request.words[2])
        code = 2
        return
      end
      if lo > hi then
        complain(("the low bound %d is above the high bound %d"):format(lo, hi))
        code = 2
        return
      end
      for _ = 1, request.count or 1 do
        if not emit(tostring(source.int(lo, hi))) then
          code = 2
          return
        end
      end
    else
      local file = request.words[1]
      local text: string | nil
      local why: string
      if file == nil or file == "-" then
        text, why = to.stdin()
      else
        text, why = Fs.read(file)
      end
      if text == nil then
        complain(why)
        code = 2
        return
      end
      local items = lines_of(text)
      -- Fisher-Yates: each step swaps slot i with a uniform slot from i
      -- to the end, so every order is equally likely. `pick` stops after
      -- the slots it prints, `shuffle` runs to the end.
      local wanted = #items
      if command == "pick" then
        wanted = request.count or 1
        if wanted > #items then
          complain(("cannot pick %d of %d lines"):format(wanted, #items))
          code = 2
          return
        end
      end
      for slot = 1, wanted do
        local other = source.int(slot, #items)
        items[slot], items[other] = items[other], items[slot]
        if not emit(items[slot]) then
          code = 2
          return
        end
      end
    end
    if not flush() then code = 2 end
  end

  local ok, result = pcall(function(): integer
    body()
    return code
  end)
  if not ok then
    if broken ~= nil then
      complain("the operating system's entropy source failed: " .. broken)
      return 1
    end
    error(result, 0)
  end
  return code
end

return verb
