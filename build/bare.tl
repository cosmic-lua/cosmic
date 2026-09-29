--- What the bare verbs (`json`, `hash`, `codec`, `archive`, `fetch`,
--- `time`, `rand`: the specs with `bare = true`, build/verb_spec.tl) share:
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
    named: boolean | nil
    --- Leave a tab and a newline as they are, escaping every other
    --- control byte (a header line, whose lines the caller joins with
    --- newlines, keeps its tabs). `fetch` uses it, so a carriage return
    --- is what it escapes.
    keep_tab_newline: boolean | nil
  end

  --- The exit code of a run that did what was asked.
  ok: integer
  --- The exit code of a run that ran and found a fault in what it
  --- looked for: a checksum that did not match, a path or a member that
  --- is not there, a value that cannot be printed.
  failed: integer
  --- The exit code of a command line or an input it refused, or a write
  --- to standard output that was lost.
  refused: integer
  --- What every bare verb says of an empty file argument.
  empty_file: string
end

bare.ok = 0
bare.failed = 1
bare.refused = 2
bare.empty_file = "an empty file name"

--- Writes `text` to standard output, as given. False and why when the
--- bytes did not all go, so a run can say so: its exit status is its
--- only verdict.
function bare.out(text: string): boolean, string
  return Fs.put(Fs.stdout, text)
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
function bare.stdin_reader(message: string): Stream.Reader | nil, string
  if Proc.is_tty(Fs.stdin) then return nil, message end
  -- `Stream.from_fd` borrows the descriptor, which stays open.
  return Stream.from_fd(Fs.stdin), ""
end

--- The bytes of standard input, refusing a terminal as `stdin_reader`
--- does; nil and why when there is none or it cannot be read.
--- @param message what the refusal says, in the verb's own words
function bare.stdin_text(message: string): string | nil, string
  local reader, why = bare.stdin_reader(message)
  if reader == nil then return nil, why end
  return Stream.read_all(reader)
end

--- `text` with each byte a terminal would act on -- 0x00 through 0x1f
--- and 0x7f -- as `\xHH`, so a name, a cell or a header never moves the
--- terminal or starts a line of its own. Bytes from 0x80 on, valid UTF-8
--- or not, pass through as they are. `options` chooses the spellings of
--- backslash, tab, newline and return.
--- @param text the text to make safe to print
--- @param options `named` and `keep_tab_newline`; both off when nil
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
    return string.format("\\x%02X", byte:byte())
  end)
  return safe
end

--- `url` with any userinfo replaced by `***`, for every place a verb
--- prints one: a password in a URL must not reach a log.
function bare.redact_url(url: string): string
  local scheme, authority, rest = url:match("^(%a+://)([^/?#]*)(.*)$")
  if scheme == nil or not authority:find("@", 1, true) then return url end
  return scheme .. "***@" .. authority:match("([^@]*)$") .. rest
end

return bare
