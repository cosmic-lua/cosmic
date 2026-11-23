--- What the bare verbs (`json`, `hash`, `codec`, `archive`, `fetch`,
--- `time`, `rand`, `qr`, `acme`, `tailscale`: the specs with `bare = true`, build/verb_spec.tl) share:
--- the standard output and error a run writes to, the complaint line's
--- `cosmic: <verb>: ` prefix, the exit codes every one of them answers,
--- the refusal to read a terminal, the escape that keeps a name or a
--- header from moving the terminal, and the URL with its password taken
--- out. A verb keeps the rest: its own `Io` record, whose fields a test
--- stands in for, and what it prints.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")

--- The pieces of a bare verb.
local record bare
  --- How `escape` writes what it finds.
  record EscapeOptions
    --- Write a backslash as `\\`, and tab, newline and return as `\t`,
    --- `\n` and `\r`, so the escaped text can be read back; any other
    --- control byte is `\xHH` either way. Overrides `keep_tab_newline`.
    named?: boolean
    --- Leave a tab and a newline as they are, escaping every other
    --- control byte (a header line, whose lines the caller joins with
    --- newlines, keeps its tabs). `fetch` uses it, so a carriage return
    --- is what it escapes.
    keep_tab_newline?: boolean
    --- Escape too each byte that is not part of valid UTF-8, and the
    --- bytes of each C1 control (U+0080 to U+009F, which a UTF-8
    --- terminal obeys) and of each invisible format character that
    --- reorders or hides text ([`bare.spoofing`]): text another party
    --- chose, as a tailnet peer's name, then passes only as characters
    --- a terminal prints in the order they are written.
    strict_utf8?: boolean
  end

  --- The exit code of a run that did what was asked.
  mut ok: integer
  --- The exit code of a run that ran and found a fault in what it
  --- looked for: a checksum that did not match, a path or a member that
  --- is not there, a value that cannot be printed.
  mut failed: integer
  --- The exit code of a command line or an input it refused, or a write
  --- to standard output that was lost.
  mut refused: integer
  --- What every bare verb says of an empty file argument.
  mut empty_file: string
end

bare.ok = 0
bare.failed = 1
bare.refused = 2
bare.empty_file = "an empty file name"

--- Writes `text` to standard output, as given. False and why when the
--- bytes did not all go, so a run can say so: its exit status is its
--- only verdict.
function bare.out(text: string): boolean, string
  local wrote, why = Fs.put(Fs.stdout, text)
  if not wrote then return false, tostring(why) end
  return true, ""
end

--- Writes one complaint line to standard error, adding its newline.
function bare.err(line: string)
  local _, _ = Fs.put(Fs.stderr, line .. "\n")
end

--- The function a run of the verb `name` complains through: `line` goes
--- to `err` as `cosmic: <name>: <line>`.
--- @param name the verb's name
--- @param err where a complaint line goes, without its newline
function bare.complainer(name: string, err: function(line: string)): function(line: string)
  return function(line: string)
    err("cosmic: " .. name .. ": " .. line)
  end
end

--- The complaint for a write to standard output that did not go, for a
--- run that answers its complaint later than it makes it.
--- @param why what stopped the bytes
function bare.lost(why: string): string
  return "standard output: " .. why
end

--- Whether a write to standard output went: true, or false after a
--- complaint of `standard output: <why>`. Takes what `out` answers.
--- @param complain the run's complaint function
--- @param ok whether the bytes all went
--- @param why what stopped them, when they did not
function bare.delivered(complain: function(line: string), ok: boolean, why: string): boolean
  if ok then return true end
  complain(bare.lost(why))
  return false
end

--- What a write to standard output answers as an exit code: 0, or 2
--- and a complaint, since a value lost to a full disk or a closed pipe
--- is no success. Takes what `out` answers.
function bare.written(complain: function(line: string), ok: boolean, why: string): integer
  if bare.delivered(complain, ok, why) then return bare.ok end
  return bare.refused
end

--- The Reader over standard input, refusing a terminal, where nothing
--- would ever end the bytes: nil and `message` for one.
--- @param message what the refusal says, in the verb's own words
function bare.stdin_reader(message: string): Stream.Reader?, string
  if Proc.is_tty(Fs.stdin) then return nil, message end
  -- [`Stream.from_fd`] borrows the descriptor, which stays open.
  return Stream.from_fd(Fs.stdin), ""
end

--- The bytes of standard input, refusing a terminal as [`stdin_reader`]
--- does; nil and why when there is none or it cannot be read.
--- @param message what the refusal says, in the verb's own words
function bare.stdin_text(message: string): string?, string
  local reader, why = bare.stdin_reader(message)
  if reader == nil then return nil, why end
  return Stream.read_all(reader)
end

--- Whether code point `c` is a C1 control or a format character that
--- reorders or hides the text around it: a zero-width space, joiner or
--- mark (U+200B to U+200F), a line or paragraph separator or a bidi
--- embedding or override (U+2028 to U+202E), a bidi isolate (U+2066 to
--- U+2069) or the byte order mark, U+FEFF. A peer could otherwise show
--- a name that reads as another's.
function bare.spoofing(c: integer): boolean
  return (c >= 0x80 and c <= 0x9F) or (c >= 0x200B and c <= 0x200F) or (c >= 0x2028 and c <= 0x202E) or
    (c >= 0x2066 and c <= 0x2069) or c == 0xFEFF
end

--- `text` with each byte from 0x80 on as `\xHH`, unless it starts a
--- valid UTF-8 character that is not [`bare.spoofing`], which passes
--- whole. An escaped character comes out as one escape per byte.
local function strict_utf8(text: string): string
  local out: mut {string} = {}
  local i = 1
  while true do
    local at = text:find("[\128-\255]", i)
    if at == nil then
      out[#out + 1] = text:sub(i)
      return table.concat(out)
    end
    out[#out + 1] = text:sub(i, at - 1)
    local lead = assert(text:byte(at), "find answers a byte's index")
    -- The lead byte gives the length, never utf8.offset, which steps past
    -- any continuation bytes that follow the character as well.
    local width = if utf8.len(text, at, at) ~= 1 then 1 elseif lead < 0xE0 then 2 elseif lead < 0xF0 then 3 else 4 end
    if width > 1 and not bare.spoofing((assert(utf8.codepoint(text, at), "a valid character has one"))) then
      out[#out + 1] = text:sub(at, at + width - 1)
    else
      for k = at, at + width - 1 do
        out[#out + 1] = string.format("\\x%02X", (assert(text:byte(k), "the character's bytes are there")))
      end
    end
    i = at + width
  end
end

--- `text` with each byte a terminal would act on -- 0x00 through 0x1f
--- and 0x7f -- as `\xHH`, so a name, a cell or a header never moves the
--- terminal or starts a line of its own. Bytes from 0x80 on, valid UTF-8
--- or not, pass through as they are unless `options.strict_utf8`.
--- `options` chooses the spellings of backslash, tab, newline and return.
--- @param text the text to make safe to print
--- @param options `named`, `keep_tab_newline` and `strict_utf8`; all off when nil
function bare.escape(text: string, options?: bare.EscapeOptions): string
  local named = options ~= nil and options.named == true
  local keep_tab_newline = options ~= nil and options.keep_tab_newline == true
  local pattern = "[\0-\31\127]"
  if named then
    pattern = "[\0-\31\127\\]"
  elseif keep_tab_newline then
    pattern = "[\0-\8\11-\31\127]"
  end
  local safe = text:gsub(pattern, function(byte: string): string
    if named then
      if byte == "\\" then return "\\\\" end
      if byte == "\t" then return "\\t" end
      if byte == "\n" then return "\\n" end
      if byte == "\r" then return "\\r" end
    end
    return string.format("\\x%02X", (assert(byte:byte(), "gsub hands over one byte")))
  end)
  if options == nil or options.strict_utf8 ~= true then return safe end
  return strict_utf8(safe)
end

--- `url` with any userinfo replaced by `***`, for every place a verb
--- prints one: a password in a URL must not reach a log.
function bare.redact_url(url: string): string
  local scheme, authority, rest = url:match("^(%a+://)([^/?#]*)(.*)$")
  if scheme == nil then return url end
  assert(authority ~= nil and rest ~= nil, "a match sets every capture")
  if not authority:find("@", 1, true) then return url end
  local host = assert(authority:match("([^@]*)$"), "the pattern matches an empty tail at worst")
  return scheme .. "***@" .. host .. rest
end

return bare
