--- `cosmic qr`: the QR code of a text, for the ten-second job of showing
--- an address to a phone, as text for the terminal or as an SVG image.
--- [`cosmic.qr`] makes and draws it; this reads the command line and
--- the text and writes what it drew.
---
--- The text drawing assumes light text on a dark terminal; `--invert`
--- suits a light one, and `--color` paints the code black on white
--- with ANSI escapes, so it is clear on either.
---
--- The text is the words, joined by spaces, or, with no words, standard
--- input, less one newline at its end (`echo url | cosmic qr`), since a
--- shell's line is not part of what was meant. An empty text is refused:
--- its code would show nothing.
---
--- `--read [file|-]` reads a code back instead: the text or SVG that
--- `cosmic qr` drew, from the file or standard input ([`Qr.read`]), and
--- prints what it holds with a newline after it.
---
--- Like `cosmic json` it prints no summary: its standard output is the
--- code, or the text read. Exit 0 is ok, 1 a text too large for a code
--- of the allowed versions at the level or a drawing that holds no code
--- it can read, 2 a command line it refuses, 5 an input it cannot read or a
--- write that failed. Complaints go to standard error as
--- `cosmic: qr: ...`. Its `spec` (build/verb_spec.tl) is `bare`.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Qr = require("cosmic.qr")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")

--- The `cosmic qr` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  mut spec: verb_spec.Spec
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given. False and why when the bytes
    --- did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- The whole of standard input, or nil and why.
    stdin: function(): string?, string
    --- Writes a file whole: [`Fs.write`].
    write: function(path: string, data: string): boolean, string
    --- Reads a file whole: [`Fs.read`].
    read: function(path: string): string?, string
  end
end

local spec = assert(assert(Cli.verbs["qr"]).spec)

local usage = "cosmic qr [--level L|M|Q|H] [--max-version N] [--quiet N] [--invert] [--ascii] [--color] " ..
  "[--svg <file|-> [--scale N] [--title T]] [--] [text...] | cosmic qr --read [file|-]"

local LEVELS <const>: {string: Qr.Level} = { L = "L", M = "M", Q = "Q", H = "H" }

--- What the command line asks for.
local record Request
  mut level: Qr.Level
  mut max_version: integer
  mut quiet: integer
  mut invert: boolean
  mut ascii: boolean
  mut color: boolean
  mut svg?: string
  mut scale: integer
  mut title?: string
  mut text?: string
  --- `--read`: the drawing to read, "-" for standard input.
  mut reading?: string
end

--- `word` as a whole number from `lo` to `hi`, or nil.
local function whole(word: string, lo: integer, hi: integer): integer?
  if not word:match("^%d+$") then return nil end
  local n = math.tointeger(tonumber(word))
  if n == nil or n < lo or n > hi then return nil end
  return n
end

--- What `argv` asks for, or nil and why it is refused.
local function arguments(argv: {string}): Request?, string
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then return nil, trouble end
  if parsed.set["--read"] == true then
    for _, name in ipairs(parsed.given) do
      if name ~= "--read" then return nil, name .. " is for drawing a code, not --read" end
    end
    if #parsed.words > 1 then
      return nil, ("--read takes one file at most, not %d"):format(#parsed.words)
    end
    local file = parsed.words[1] or "-"
    if file == "" then return nil, bare.empty_file end
    return { level = "M", max_version = 40, quiet = 4, invert = false, ascii = false, color = false, scale = 8,
      reading = file }, ""
  end
  local request: Request = { level = "M", max_version = 40, quiet = 4, invert = parsed.set["--invert"] == true,
    ascii = parsed.set["--ascii"] == true, color = parsed.set["--color"] == true, scale = 8,
    svg = parsed.values["--svg"], title = parsed.values["--title"] }
  local level = parsed.values["--level"]
  if level ~= nil then
    local named = LEVELS[level:upper()]
    if named == nil then return nil, "--level is L, M, Q or H, not " .. level end
    request.level = named
  end
  local bounds: {{string | integer}} = { { "--max-version", 1, 40 }, { "--quiet", 0, 16 }, { "--scale", 1, 1000 } }
  for _, bound in ipairs(bounds) do
    local name, lo, hi = bound[1], bound[2], bound[3]
    assert(name is string and lo is integer and hi is integer)
    local given = parsed.values[name]
    if given ~= nil then
      local n = whole(given, lo, hi)
      if n == nil then
        return nil, ("%s needs a whole number from %d to %d, not %s"):format(name, lo, hi, given)
      end
      if name == "--max-version" then
        request.max_version = n
      elseif name == "--quiet" then
        request.quiet = n
      else
        request.scale = n
      end
    end
  end
  if request.svg == nil then
    for _, name in ipairs({ "--scale", "--title" }) do
      if parsed.values[name] ~= nil then return nil, name .. " is for --svg" end
    end
  else
    for _, name in ipairs({ "--invert", "--ascii", "--color" }) do
      if parsed.set[name] == true then return nil, name .. " is for text, not --svg" end
    end
    if request.svg == "" then return nil, bare.empty_file end
  end
  if request.color and request.invert then
    return nil, "--invert is for a drawing without --color, which paints its own ground"
  end
  if #parsed.words > 0 then request.text = table.concat(parsed.words, " ") end
  return request, ""
end

local standard: verb.Io = {
  out = bare.out,
  err = bare.err,
  stdin = function(): string?, string
    return bare.stdin_text("standard input is a terminal; give the text or a file, or pipe it in")
  end,
  write = function(path: string, data: string): boolean, string
    local wrote, why = Fs.write(path, data)
    if not wrote then return false, tostring(why) end
    return true, ""
  end,
  read = function(path: string): string?, string
    local text, why = Fs.read(path)
    if text == nil then return nil, tostring(why) end
    return text, ""
  end,
}

--- `cosmic qr --read`: prints the text of the code drawn in `file` ("-":
--- standard input), and returns the exit code.
local function read_back(to: verb.Io, complain: function(line: string), file: string): integer
  local drawing, why: string?, string
  if file == "-" then
    drawing, why = to.stdin()
  else
    drawing, why = to.read(file)
  end
  if drawing == nil then
    complain(why)
    return bare.undone
  end
  if drawing:match("^%s*$") ~= nil then
    complain("there is nothing to read")
    return bare.undone
  end
  local read, read_why = Qr.read(drawing)
  if read == nil then
    complain((read_why.message:gsub("^qr: ", "")))
    return bare.failed
  end
  return bare.written(complain, to.out(read.text .. "\n"))
end

--- `cosmic qr [options] [text...]`: prints the code of the text, or
--- writes its SVG, or with `--read` prints the text of a code drawn,
--- and returns the exit code: 0 ok, 1 a text too large or a drawing it
--- cannot read, 2 a command line it refuses, 5 an input or a write it could not use.
--- @param argv the command line, `qr` at slot 1
--- @param io where text is read and written; the process's own when nil
function verb.run(argv: {string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("qr", to.err)
  local found, trouble = arguments(argv)
  if found == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end
  local request: Request = found
  local reading = request.reading
  if reading ~= nil then return read_back(to, complain, reading) end
  local text = request.text
  if text == nil then
    local read, why = to.stdin()
    if read == nil then
      complain(why)
      return bare.undone
    end
    text = read:gsub("\r?\n$", "", 1)
  end
  if text == "" then
    complain("the text is empty; give the text or pipe it in")
    -- An empty word is the command line's; an empty standard input is the data's.
    return if request.text ~= nil then bare.refused else bare.undone end
  end
  local code, why = Qr.encode(text, { level = request.level, max_version = request.max_version })
  if code == nil then
    complain((why.message:gsub("^qr: ", "")))
    return bare.failed
  end
  local svg = request.svg
  if svg == nil then
    return bare.written(complain, to.out(Qr.text(code, { quiet = request.quiet, invert = request.invert,
      ascii = request.ascii, color = request.color })))
  end
  local image = Qr.svg(code, { quiet = request.quiet, scale = request.scale, title = request.title }) .. "\n"
  if svg == "-" then return bare.written(complain, to.out(image)) end
  local ok, write_why = to.write(svg, image)
  if not ok then
    complain(write_why)
    return bare.undone
  end
  return bare.ok
end

--- The `qr` verb as [`build/verb_list.tl`] lists it. It reads no tree,
--- so it is never stale-checked.
verb.spec = {
  name = "qr",
  guide = "more quick tools",
  tests = { "build.qr_test", "build.qr_tool_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "options and the text",
  exits = "`qr` prints the code, its SVG or the text it read, and nothing after; it exits 1 when the text is too large for a code or a drawing holds no code it can read, 2 when it refuses its command line, 5 when it cannot read its input or a write fails.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/qr_test.tl)",
}

return verb
