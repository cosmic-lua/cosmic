--- `cosmic hash`: the digest of files or standard input, printed the way
--- `sha256sum` prints it -- `<hex>  <name>` -- and the check of such a
--- list, on every platform alike, where `sha256sum` and `shasum -a 256`
--- differ. Every byte streams through `Stream.hashing` a chunk at a
--- time, so a file of any size takes the same memory; only a sums file
--- and an HMAC key are read whole.
---
--- Like `cosmic json` it ends in no verdict line: its standard output is
--- data (or, with `--check`, the per-file lines), and its exit status is
--- the verdict: 0 all well, 1 a check failed or a listed file could not
--- be read, 2 a command line, a file to hash or a sums file it cannot
--- use, or a failed write to standard output. Complaints go to standard
--- error as `cosmic: hash: ...`. build/dispatch.tl's `bare` names it.
---
--- An HMAC is made here rather than by `Hash.hmac`, which takes the whole
--- message: RFC 2104's two passes over `Stream.hashing`, so a file of any
--- size is still one pass. build/hash_test.tl holds it to `Hash.hmac`.
-- TODO: once cosmic.hash carries an incremental HMAC, use it here rather
-- than the pads of `digest_of`, and drop the block sizes in `BLOCK`.

local Cli = require("cosmic.cli")
local Codec = require("cosmic.codec")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")

--- The `cosmic hash` verb: `run` is what `build/dispatch.tl` calls.
local record verb
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given: the caller adds newlines.
    --- False and why when the bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- A Reader over standard input, or nil and why.
    stdin: function(): Stream.Reader | nil, string
  end

  --- One line of a sums file that named a file and its digest.
  record Entry
    --- The digest, as lower-case hex.
    digest: string
    --- The name, with any escapes undone.
    name: string
    --- The 1-based line it stood on.
    line: integer
    --- Whether the line had the binary marker `*`, which changes nothing here.
    binary: boolean
  end

  --- A line that was neither blank, a comment, nor an entry.
  record Bad
    line: integer
    why: string
  end

  --- What a sums file holds.
  record Sums
    entries: {Entry}
    bad: {Bad}
  end
end

local type Algorithm = Hash.Algorithm

--- The algorithms `cosmic.hash` has, in the order of their options.
local ALGORITHMS <const>: {Algorithm} = {
  "md5", "sha1", "sha224", "sha256", "sha384", "sha512",
  "sha3-224", "sha3-256", "sha3-384", "sha3-512",
}

--- The digest sizes of `ALGORITHMS`, in bytes, which fix how long a hex
--- digest in a sums file must be.
local SIZE <const>: {string:integer} = {
  ["md5"] = 16, ["sha1"] = 20, ["sha224"] = 28, ["sha256"] = 32, ["sha384"] = 48, ["sha512"] = 64,
  ["sha3-224"] = 28, ["sha3-256"] = 32, ["sha3-384"] = 48, ["sha3-512"] = 64,
}

--- The block size of each algorithm's compression function, in bytes:
--- what an HMAC key is padded to (the rate of a SHA-3 sponge).
local BLOCK <const>: {string:integer} = {
  ["md5"] = 64, ["sha1"] = 64, ["sha224"] = 64, ["sha256"] = 64, ["sha384"] = 128, ["sha512"] = 128,
  ["sha3-224"] = 144, ["sha3-256"] = 136, ["sha3-384"] = 104, ["sha3-512"] = 72,
}

local spec = Cli.options.hash

local usage = "cosmic hash [--sha256 | --sha512 | --sha1 | --md5 | ...] [--json] " ..
  "[--hmac <key> | --hmac-file <path>] [<file>|-]...; " ..
  "cosmic hash --check <sums>|- [--quiet] [algorithm and HMAC options]"

--- `name` as a sums line writes it: with a leading `\` on the line, and
--- `\\` and `\n` in the name, when it holds a backslash or a newline.
--- @param digest the hex digest
--- @param name the file's name; `-` for standard input
function verb.format_line(digest: string, name: string): string
  if name:find("[\\\n]") then
    local escaped = name:gsub("[\\\n]", function(c: string): string
      return c == "\n" and "\\n" or "\\\\"
    end)
    return "\\" .. digest .. "  " .. escaped
  end
  return digest .. "  " .. name
end

--- `text` with the escapes of `format_line` undone, or nil for any other.
local function unescape(text: string): string | nil
  local parts: {string} = {}
  local at = 1
  while at <= #text do
    local c = text:sub(at, at)
    if c == "\\" then
      local escape = text:sub(at + 1, at + 1)
      if escape == "\\" then
        parts[#parts + 1] = "\\"
      elseif escape == "n" then
        parts[#parts + 1] = "\n"
      else
        return nil
      end
      at = at + 2
    else
      parts[#parts + 1] = c
      at = at + 1
    end
  end
  return table.concat(parts)
end

--- The entries of a sums file in GNU's format -- `[\]<hex> <space|*><name>`,
--- one to a line, a name escaped when the line begins `\` -- and the lines
--- that are not one. Blank lines and lines beginning `#` are skipped. A
--- digest must be `digest_size` bytes in hex, of either case. Total: any
--- bytes are a sums file, and a bad line is listed, never raised.
--- @param text the sums file
--- @param digest_size the algorithm's digest size in bytes
function verb.parse_sums(text: string, digest_size: integer): verb.Sums
  local sums: verb.Sums = { entries = {}, bad = {} }
  local width = digest_size * 2
  local number = 0
  for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("([^\n]*)\n") do
    number = number + 1
    local function refuse(why: string)
      sums.bad[#sums.bad + 1] = { line = number, why = why }
    end
    if line == "" or line:sub(1, 1) == "#" then
      -- blank or a comment
    else
      local escaped = line:sub(1, 1) == "\\"
      local body = escaped and line:sub(2) or line
      local digest = body:sub(1, width)
      if #digest ~= width or not digest:match("^%x+$") then
        refuse("improperly formatted: no " .. width .. "-digit hex digest")
      elseif body:sub(width + 1, width + 1) ~= " " or not body:sub(width + 2, width + 2):match("^[ *]$") then
        refuse("improperly formatted: no space and marker after the digest")
      elseif #body < width + 3 then
        refuse("improperly formatted: no file name")
      else
        local written = body:sub(width + 3)
        local name: string | nil = written
        if escaped then name = unescape(written) end
        if name == nil then
          refuse("improperly formatted: bad escape in the file name")
        else
          sums.entries[#sums.entries + 1] = {
            digest = digest:lower(), name = name, line = number,
            binary = body:sub(width + 2, width + 2) == "*",
          }
        end
      end
    end
  end
  return sums
end

--- `key` with every byte xor `mask`.
local function xor_with(key: string, mask: integer): string
  return (key:gsub(".", function(c: string): string
    return string.char(c:byte() ~ mask)
  end))
end

--- The lower-case hex digest, or HMAC when `key` is given, of everything
--- `reader` yields, a chunk at a time; nil and why when it fails.
local function digest_of(reader: Stream.Reader, algorithm: Algorithm, key: string | nil): string | nil, string
  local inner, why = Stream.hashing(algorithm)
  if inner == nil then return nil, why end
  local outer_pad: string
  if key ~= nil then
    local block = BLOCK[algorithm]
    local padded = #key > block and Hash.digest(algorithm, key) or key
    padded = padded .. string.rep("\0", block - #padded)
    outer_pad = xor_with(padded, 0x5c)
    local ok, wrote = inner:write(xor_with(padded, 0x36))
    if not ok then return nil, wrote end
  end
  local copied, trouble = Stream.copy(reader, inner)
  if copied == nil then return nil, trouble end
  local raw, finished = inner:digest()
  if raw == nil then return nil, finished end
  if key ~= nil then raw = Hash.digest(algorithm, outer_pad .. raw) end
  return Codec.hex(raw), ""
end

--- What a command line asks for.
local record Request
  algorithm: Algorithm
  --- The files to hash, `-` for standard input; empty for `--check`.
  files: {string}
  --- The sums file to check, `-` for standard input; nil to hash.
  check: string | nil
  quiet: boolean
  json: boolean
  --- The HMAC key; nil for a plain digest.
  key: string | nil
end

--- What `argv` asks for, or nil and why it is refused.
local function arguments(argv: {integer:string}): Request | nil, string
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then return nil, trouble end
  local chosen: {Algorithm} = {}
  local spelled: {string} = {}
  for _, name in ipairs(ALGORITHMS) do
    if parsed.set["--" .. name] then
      chosen[#chosen + 1] = name
      spelled[#spelled + 1] = "--" .. name
    end
  end
  if #chosen > 1 then
    return nil, "name one algorithm, not " .. table.concat(spelled, " and ")
  end
  local request: Request = {
    algorithm = chosen[1] or "sha256",
    files = parsed.words, check = parsed.values["--check"],
    quiet = parsed.set["--quiet"] or false, json = parsed.set["--json"] or false,
  }
  if request.check == "" then return nil, "--check needs a sums file, or - for standard input" end
  if request.check ~= nil then
    if #parsed.words > 0 then
      return nil, "--check reads the files its sums file lists, not " .. #parsed.words .. " named on the command line"
    end
    if request.json then return nil, "--json prints digests, which --check does not" end
  elseif request.quiet then
    return nil, "--quiet is for --check"
  elseif #request.files == 0 then
    request.files = { "-" }
  end
  local literal, key_file = parsed.values["--hmac"], parsed.values["--hmac-file"]
  if literal ~= nil and key_file ~= nil then
    return nil, "name one of --hmac and --hmac-file, not both"
  end
  request.key = literal
  if key_file ~= nil then
    local text, why = Fs.read(key_file)
    if text == nil then return nil, "--hmac-file: " .. why end
    request.key = text
  end
  for _, name in ipairs(request.files) do
    if name == "" then return nil, "an empty file name" end
  end
  return request, ""
end

--- The Reader over standard input, refusing a terminal, where nothing
--- would ever end the bytes.
local function open_stdin(): Stream.Reader | nil, string
  if Proc.is_tty(Fs.stdin) then
    return nil, "no file given and standard input is a terminal; give a file, or pipe bytes in"
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
  stdin = open_stdin,
}

--- The digest of the file `name`, or of standard input for `-`; nil and
--- why when it cannot be read. The reader is closed either way.
local function digest_named(to: verb.Io, request: Request, name: string): string | nil, string
  local reader: Stream.Reader | nil
  local why: string
  if name == "-" then
    reader, why = to.stdin()
  else
    reader, why = Stream.open(name)
  end
  if reader == nil then return nil, why end
  local digest, trouble = digest_of(reader, request.algorithm, request.key)
  local _, _ = reader:close()
  if digest == nil then
    return nil, (name == "-" and "standard input" or name) .. ": " .. trouble
  end
  return digest, ""
end

--- `cosmic hash [options] [<file>|-]...` and `cosmic hash --check <sums>`:
--- returns the exit code: 0 all well, 1 a check failed or a listed file
--- could not be read, 2 a command line, a file to hash, a sums file, or a
--- write it cannot use.
--- @param argv the command line, `hash` at slot 1
--- @param io where the text is read and written; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  local function complain(line: string)
    to.err("cosmic: hash: " .. line)
  end
  local request, trouble = arguments(argv)
  if request == nil then
    complain(trouble .. "; " .. usage)
    return 2
  end
  local label = request.key ~= nil and "hmac-" .. request.algorithm or request.algorithm
  local code = 0

  if request.check == nil then
    local rows: {string} = {}
    for _, name in ipairs(request.files) do
      local digest, why = digest_named(to, request, name)
      if digest == nil then
        complain(why)
        code = 2
      elseif request.json then
        rows[#rows + 1] = "  " ..
          assert(Json.encode({ path = name, algorithm = label, digest = digest }, { pretty = false }))
      else
        local ok, lost = to.out(verb.format_line(digest, name) .. "\n")
        if not ok then
          complain("standard output: " .. lost)
          return 2
        end
      end
    end
    if request.json then
      local text = #rows == 0 and "[]\n" or "[\n" .. table.concat(rows, ",\n") .. "\n]\n"
      local ok, lost = to.out(text)
      if not ok then
        complain("standard output: " .. lost)
        return 2
      end
    end
    return code
  end

  -- A sums file is a list, small beside what it names: read whole.
  local sums_name = request.check
  local text: string | nil
  if sums_name == "-" then
    local reader, why = to.stdin()
    if reader == nil then
      complain(why)
      return 2
    end
    text, why = Stream.read_all(reader)
    if text == nil then
      complain("standard input: " .. why)
      return 2
    end
  else
    local why: string
    text, why = Fs.read(sums_name)
    if text == nil then
      complain(why)
      return 2
    end
  end
  local sums = verb.parse_sums(text, SIZE[request.algorithm])
  for _, bad in ipairs(sums.bad) do
    complain((sums_name == "-" and "standard input" or sums_name) .. ":" .. bad.line .. ": " .. bad.why)
  end
  if #sums.entries == 0 then
    if #sums.bad == 0 then complain((sums_name == "-" and "standard input" or sums_name) .. ": no checksum lines found") end
    return 2
  end
  local failed, unread = 0, 0
  for _, entry in ipairs(sums.entries) do
    local digest: string | nil
    local why: string
    if entry.name == "-" and sums_name == "-" then
      why = "-: standard input holds the sums file"
    else
      digest, why = digest_named(to, request, entry.name)
    end
    local line: string | nil
    if digest == nil then
      complain(why)
      unread = unread + 1
      line = entry.name .. ": FAILED open or read\n"
    elseif digest ~= entry.digest then
      failed = failed + 1
      line = entry.name .. ": FAILED\n"
    elseif not request.quiet then
      line = entry.name .. ": OK\n"
    end
    if line ~= nil then
      local ok, lost = to.out(line)
      if not ok then
        complain("standard output: " .. lost)
        return 2
      end
    end
  end
  if failed > 0 then
    complain(failed .. " of " .. #sums.entries .. " computed " .. (failed == 1 and "checksum" or "checksums") .. " did NOT match")
  end
  if unread > 0 then
    complain(unread .. " listed " .. (unread == 1 and "file" or "files") .. " could not be read")
  end
  if #sums.bad > 0 then return 2 end
  return (failed > 0 or unread > 0) and 1 or 0
end

return verb
