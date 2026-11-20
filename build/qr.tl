--- `cosmic qr`: the QR code of a text, for the ten-second job of showing
--- an address to a phone, as text for the terminal or as an SVG image.
--- [`cosmic.qr`] makes and draws it; this reads the command line and
--- the text and writes what it drew.
---
--- The text is the words, joined by spaces, or, with no words, standard
--- input, less one newline at its end (`echo url | cosmic qr`), since a
--- shell's line is not part of what was meant. An empty text is refused:
--- its code would show nothing.
---
--- Like `cosmic json` it prints no summary: its standard output is the
--- code. Exit 0 is ok, 1 a text too large for a code of the allowed
--- versions at the level, 2 a command line or an input it refuses, or a
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
  end
end

local spec = assert(assert(Cli.verbs["qr"]).spec)

local usage = "cosmic qr [--level L|M|Q|H] [--max-version N] [--quiet N] [--invert] [--ascii] " ..
  "[--svg <file|-> [--scale N] [--title T]] [--] [text...]"

local LEVELS <const>: {string: Qr.Level} = { L = "L", M = "M", Q = "Q", H = "H" }

--- What the command line asks for.
local record Request
  mut level: Qr.Level
  mut max_version: integer
  mut quiet: integer
  mut invert: boolean
  mut ascii: boolean
  mut svg?: string
  mut scale: integer
  mut title?: string
  mut text?: string
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
  local request: Request = { level = "M", max_version = 40, quiet = 4, invert = parsed.set["--invert"] == true,
    ascii = parsed.set["--ascii"] == true, scale = 8, svg = parsed.values["--svg"], title = parsed.values["--title"] }
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
    for _, name in ipairs({ "--invert", "--ascii" }) do
      if parsed.set[name] == true then return nil, name .. " is for text, not --svg" end
    end
    if request.svg == "" then return nil, bare.empty_file end
  end
  if #parsed.words > 0 then request.text = table.concat(parsed.words, " ") end
  return request, ""
end

local standard: verb.Io = {
  out = bare.out,
  err = bare.err,
  stdin = function(): string?, string
    return bare.stdin_text("no text given and standard input is a terminal; give the text or pipe it in")
  end,
  write = function(path: string, data: string): boolean, string return Fs.write(path, data) end,
}

--- `cosmic qr [options] [text...]`: prints the code of the text, or
--- writes its SVG, and returns the exit code: 0 ok, 1 a text too large,
--- 2 a command line, an input or a write it refuses.
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
  local text = request.text
  if text == nil then
    local read, why = to.stdin()
    if read == nil then
      complain(why)
      return bare.refused
    end
    text = read:gsub("\r?\n$", "", 1)
  end
  if text == "" then
    complain("the text is empty; give the text or pipe it in")
    return bare.refused
  end
  local code, why = Qr.encode(text, { level = request.level, max_version = request.max_version })
  if code == nil then
    complain((why:gsub("^qr: ", "")))
    return bare.failed
  end
  local svg = request.svg
  if svg == nil then
    return bare.written(complain, to.out(Qr.text(code, { quiet = request.quiet, invert = request.invert,
      ascii = request.ascii })))
  end
  local image = Qr.svg(code, { quiet = request.quiet, scale = request.scale, title = request.title }) .. "\n"
  if svg == "-" then return bare.written(complain, to.out(image)) end
  local ok, write_why = to.write(svg, image)
  if not ok then
    complain(write_why)
    return bare.refused
  end
  return bare.ok
end

--- The `qr` verb as [`build/verb_list.tl`] lists it. It reads no tree,
--- so it is never stale-checked.
verb.spec = {
  name = "qr",
  guide = "a QR code of an address",
  tests = { "build.qr_test", "build.qr_tool_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "options and the text",
  exits = "`qr` prints the code, or its SVG, and nothing after; it exits 1 when the text is too large for a code, 2 when it refuses its command line or its input, or a write fails.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/qr_test.tl)",
}

return verb
