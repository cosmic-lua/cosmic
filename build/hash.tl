--- `cosmic hash`: the digest of files or standard input, printed the way
--- `sha256sum` prints it -- `<hex>  <name>` -- and the check of such a
--- list, on every platform alike, where `sha256sum` and `shasum -a 256`
--- differ. Every byte streams through [`Stream.hashing`] a chunk at a
--- time, so a file of any size takes the same memory; only a sums file
--- and an HMAC key are read whole.
---
--- Like `cosmic json` it prints no summary: its standard output is
--- data (or, with `check`, the per-file lines), and its exit status is
--- the verdict: 0 all well, 1 a check failed or a listed file could not
--- be read, 2 a command line it refused, 5 a file to hash or a sums file it
--- cannot use, or a failed write to standard output. Complaints go to standard
--- error as `cosmic: hash: ...`. Its `spec` (build/verb_spec.tl) is `bare`.
---
--- `check` differs from GNU's in three ways. A line it cannot read (a
--- BSD `SHA256 (file) = hex` line, a one-space separator, a bad escape)
--- makes it exit 5 even when every entry is OK, where GNU only warns
--- without `--strict`. A CRLF sums file leaves the CR in each name, as
--- GNU does. And it opens the paths a sums file lists as given, so an
--- untrusted sums file can name any readable path; it refuses one that
--- is not a regular file (a FIFO or /dev/zero would hang it), printing
--- `FAILED open or read`. Names it prints are escaped as GNU's are.
---
--- An HMAC is made here rather than by [`Hash.hmac`], which takes the whole
--- message: [`Stream.hashing`] given a key feeds [`Hash.hmac_hasher`] a chunk
--- at a time, so a file of any size is still one pass. build/hash_test.tl
--- holds it to [`Hash.hmac`].

local Verb = require("cosmic.cli.hash")
local Codec = require("cosmic.codec")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Stream = require("cosmic.stream")
local bare = require("build.bare")
local plural = require("build.plural")
local verb_spec = require("build.verb_spec")

--- The `cosmic hash` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  mut spec: verb_spec.Spec
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given: the caller adds newlines.
    --- False and why when the bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- A Reader over standard input, or nil and why.
    stdin: function(): Stream.Reader?, string
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
    entries: mut {Entry}
    bad: mut {Bad}
  end
end

local type Algorithm = Hash.Algorithm

--- The algorithms [`cosmic.hash`] has, in the order of their options.
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

--- `hash`'s two commands: `digest`, typed by no word, and `check`.
local commands = assert(Verb.subcommands, "hash names its commands")
local digest_command = assert(commands["digest"], "hash has a digest")
local check_command = assert(commands["check"], "hash has a check")

--- The usage line a refusal of each command ends with: the spec's ([`Flags.usage`]).
local digest_usage <const> = Flags.usage(Verb, "cosmic hash")
local check_usage <const> = Flags.usage(check_command, "cosmic hash check")

--- `name` as a sums line writes it, and whether it needed escaping: a
--- backslash, newline or carriage return becomes `\\`, `\n` or `\r`, as GNU
--- coreutils writes them, and the line then begins with `\`.
local function escape_name(name: string): string, boolean
  if not name:find("[\\\n\r]") then return name, false end
  local escaped = name:gsub("[\\\n\r]", function(c: string): string
    return if c == "\n" then "\\n" elseif c == "\r" then "\\r" else "\\\\" end
  end)
  return escaped, true
end

--- One sums line for `digest` and `name`.
--- @param digest the hex digest
--- @param name the file's name; `-` for standard input
function verb.format_line(digest: string, name: string): string
  local escaped, changed = escape_name(name)
  return (if changed then "\\" else "" end) .. digest .. "  " .. escaped
end

--- `text` with the escapes of [`format_line`] undone, or nil for any other.
local function unescape(text: string): string?
  local parts: mut {string} = {}
  local at = 1
  while at <= #text do
    local c = text:sub(at, at)
    if c == "\\" then
      local escape = text:sub(at + 1, at + 1)
      if escape == "\\" then
        parts[#parts + 1] = "\\"
      elseif escape == "n" then
        parts[#parts + 1] = "\n"
      elseif escape == "r" then
        parts[#parts + 1] = "\r"
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
  for line in (text .. (if text:sub(-1) == "\n" then "" else "\n" end)):gmatch("([^\n]*)\n") do
    number = number + 1
    local function refuse(why: string)
      sums.bad[#sums.bad + 1] = { line = number, why = why }
    end
    if line == "" or line:sub(1, 1) == "#" then
      -- blank or a comment
    else
      local escaped = line:sub(1, 1) == "\\"
      local body = if escaped then line:sub(2) else line end
      local digest = body:sub(1, width)
      if #digest ~= width or not digest:match("^%x+$") then
        refuse("improperly formatted: no " .. tostring(width) .. "-digit hex digest")
      elseif body:sub(width + 1, width + 1) ~= " " or not body:sub(width + 2, width + 2):match("^[ *]$") then
        refuse("improperly formatted: no space and marker after the digest")
      elseif #body < width + 3 then
        refuse("improperly formatted: no file name")
      else
        local written = body:sub(width + 3)
        local name: string? = written
        if escaped then name = unescape(written) end
        if name == nil then
          refuse("improperly formatted: bad escape in the file name")
        else
          table.insert(sums.entries, {
            digest = digest:lower(), name = name, line = number,
            binary = body:sub(width + 2, width + 2) == "*",
          })
        end
      end
    end
  end
  return sums
end

--- The lower-case hex digest, or HMAC when `key` is given, of everything
--- `reader` yields, a chunk at a time; nil and why when it fails.
local function digest_of(reader: Stream.Reader, algorithm: Algorithm, key: string?): string?, string
  local inner, why = Stream.hashing(algorithm, key)
  if inner == nil then return nil, tostring(why) end
  local copied, trouble = Stream.copy(reader, inner)
  if copied == nil then return nil, tostring(trouble) end
  local raw, finished = inner:digest()
  if raw == nil then return nil, finished end
  return Codec.hex(raw), ""
end

--- What a command line asks for.
local record Request
  algorithm: Algorithm
  --- The files to hash, `-` for standard input; empty for `check`.
  mut files: {string}
  --- The sums file to check, `-` for standard input; nil to hash.
  mut check: string?
  quiet: boolean
  json: boolean
  --- The HMAC key; nil for a plain digest.
  mut key?: string
  --- The file `--hmac-file` names, read into `key` once the line is accepted: a file it cannot read is not the
  --- command line's fault.
  mut key_file?: string
  --- A complaint to make before running, or "".
  mut warning: string
end

--- What `argv` asks for, or nil and why it is refused, with the usage line its refusal ends with.
local function arguments(argv: {string}): Request?, string
  local checking = argv[2] == "check"
  local command = if checking then check_command else digest_command end
  local spec = assert(command.spec, "each command has options")
  local parsed, trouble = Flags.parse(argv, if checking then 3 else 2 end, spec)
  if parsed == nil then
    return nil, trouble
  end
  local named = parsed.values["--algorithm"]
  local algorithm: Algorithm = "sha256"
  for _, name in ipairs(ALGORITHMS) do
    if name == named then algorithm = name end
  end
  local request: Request = {
    algorithm = algorithm, files = {}, check = nil, warning = "",
    quiet = parsed.set["--quiet"] == true, json = parsed.set["--json"] == true,
  }
  if checking then
    if #parsed.words ~= 1 then
      return nil, "takes one sums file, or - for standard input, but was given " ..
        (if #parsed.words == 0 then "none" else plural.count(#parsed.words, "word") end)
    end
    local sums = assert(parsed.words[1])
    if sums == "" then return nil, bare.empty_file end
    request.check = sums
  else
    request.files = parsed.words
    if #request.files == 0 then request.files = { "-" } end
  end
  local literal, key_file = parsed.values["--hmac"], parsed.values["--hmac-file"]
  if literal ~= nil and key_file ~= nil then
    return nil, "name one of --hmac and --hmac-file, not both"
  end
  request.key = literal
  request.key_file = key_file
  for _, name in ipairs(request.files) do
    if name == "" then return nil, bare.empty_file end
  end
  return request, ""
end

--- The Reader over standard input, refusing a terminal, where nothing
--- would ever end the bytes.
local function open_stdin(): Stream.Reader?, string
  return bare.stdin_reader("no file given and standard input is a terminal; give a file, or pipe bytes in")
end

local standard: verb.Io = {
  out = bare.out,
  err = bare.err,
  stdin = open_stdin,
}

--- Whether `path` names a regular file, after links: what `check` will
--- open, so a sums file cannot make it read a FIFO or a device.
local function is_regular(path: string): boolean
  local st, _ = Fs.stat(path)
  return st ~= nil and st.kind == "file"
end

--- The digest of the file `name`, or of standard input for `-`; nil and
--- why when it cannot be read. The reader is closed either way.
local function digest_named(to: verb.Io, request: Request, name: string): string?, string
  local reader: Stream.Reader?
  local why: string
  if name == "-" then
    reader, why = to.stdin()
  else
    local reader_got, why_failure = Stream.open(name)
    reader, why = reader_got, if reader_got == nil then tostring(why_failure) else "" end
  end
  if reader == nil then return nil, why end
  local digest, trouble = digest_of(reader, request.algorithm, request.key)
  local _, _ = reader:close()
  if digest == nil then
    return nil, (if name == "-" then "standard input" else name end) .. ": " .. trouble
  end
  return digest, ""
end

--- `cosmic hash [options] [<file>|-]...` and `cosmic hash check [options] <sums>`:
--- returns the exit code: 0 all well, 1 a check failed or a listed file
--- could not be read, 2 a command line it refused, 5 a file to hash, a sums
--- file, or a write it cannot use.
--- @param argv the command line, `hash` at slot 1
--- @param io where the text is read and written; the process's own when nil
function verb.run(argv: {string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("hash", to.err)
  local request, trouble = arguments(argv)
  if request == nil then
    local checking = argv[2] == "check"
    complain((if checking then "check: " else "" end) .. trouble .. "; " .. (if checking then check_usage else digest_usage end))
    return bare.refused
  end
  local key_file = request.key_file
  if key_file ~= nil then
    local text, why = Fs.read(key_file)
    if text == nil then
      complain("--hmac-file: " .. tostring(why))
      return bare.undone
    end
    request.key = text
    if text:sub(-1) == "\n" then
      request.warning = "--hmac-file: the key ends in a newline, which is part of it; " ..
        "write the file with `printf %s` if that is not meant"
    end
  end
  if request.warning ~= "" then complain(request.warning) end
  local label = if request.key ~= nil then "hmac-" .. request.algorithm else request.algorithm end
  local code = bare.ok

  local check = request.check
  if check == nil then
    local rows: mut {string} = {}
    for _, name in ipairs(request.files) do
      local digest, why = digest_named(to, request, name)
      if digest == nil then
        complain(why)
        code = bare.undone
      elseif request.json then
        -- Only `--json` writes JSON, so only it loads the module.
        local Json = require("cosmic.json")
        local row, refused = Json.encode({ path = name, algorithm = label, digest = digest }, { pretty = false })
        if row == nil then
          complain(Json.quote(name) .. ": --json cannot write this path: " .. tostring(refused))
          code = bare.undone
        else
          rows[#rows + 1] = "  " .. row
        end
      else
        if not bare.delivered(complain, to.out(verb.format_line(digest, name) .. "\n")) then
          return bare.undone
        end
      end
    end
    if request.json then
      local text = if #rows == 0 then "[]\n" else "[\n" .. table.concat(rows, ",\n") .. "\n]\n" end
      if not bare.delivered(complain, to.out(text)) then
        return bare.undone
      end
    end
    return code
  end

  -- A sums file is a list, small beside what it names: read whole.
  local sums_name = check
  local text: string
  if sums_name == "-" then
    local reader, why = to.stdin()
    if reader == nil then
      complain(why)
      return bare.undone
    end
    local read, read_why = Stream.read_all(reader)
    if read == nil then
      complain("standard input: " .. tostring(read_why))
      return bare.undone
    end
    text = read
  else
    local read, read_why = Fs.read(sums_name)
    if read == nil then
      complain(tostring(read_why))
      return bare.undone
    end
    text = read
  end
  local sums = verb.parse_sums(text, (assert(SIZE[request.algorithm], "every algorithm has its digest size")))
  for _, bad in ipairs(sums.bad) do
    complain((if sums_name == "-" then "standard input" else sums_name end) .. ":" .. tostring(bad.line) .. ": " .. bad.why)
  end
  if #sums.entries == 0 then
    if #sums.bad == 0 then
      complain((if sums_name == "-" then "standard input" else sums_name end) .. ": no checksum lines found")
    end
    return bare.undone
  end
  local failed, unread = 0, 0
  for _, entry in ipairs(sums.entries) do
    local digest: string?
    local why: string
    local listed, changed = escape_name(entry.name)
    local shown = (if changed then "\\" else "" end) .. listed
    if entry.name == "-" and sums_name == "-" then
      why = "-: standard input holds the sums file"
    elseif entry.name ~= "-" and not is_regular(entry.name) then
      why = entry.name .. ": not a regular file, or not there"
    else
      digest, why = digest_named(to, request, entry.name)
    end
    local line: string?
    if digest == nil then
      complain(why)
      unread = unread + 1
      line = shown .. ": FAILED open or read\n"
    elseif digest ~= entry.digest then
      failed = failed + 1
      line = shown .. ": FAILED\n"
    elseif not request.quiet then
      line = shown .. ": OK\n"
    end
    if line ~= nil then
      if not bare.delivered(complain, to.out(line)) then
        return bare.undone
      end
    end
  end
  if failed > 0 then
    complain(tostring(failed) .. " of " .. tostring(#sums.entries) .. " computed " .. (if failed == 1 then "checksum" else "checksums" end) .. " did NOT match")
  end
  if unread > 0 then
    complain(tostring(unread) .. " listed " .. (if unread == 1 then "file" else "files" end) .. " could not be read")
  end
  if #sums.bad > 0 then return bare.undone end
  return if failed > 0 or unread > 0 then bare.failed else bare.ok end
end

--- The `hash` verb as [`build/verb_list.tl`] lists it. Reads the files it
--- is given, never the tree: never stale-checked.
verb.spec = {
  name = "hash",
  guide = "hashing bytes",
  tests = { "build.hash_test", "build.hash_tool_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "the files to digest",
  exits = "`hash` prints digests, and exits 1 when a `check` fails, 2 for a command line it refused, 5 for a file or sums file it could not read, or a write that failed.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/hash_test.tl)",
}

return verb
