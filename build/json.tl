--- `cosmic json`: one lookup in a JSON document, for the ten-second
--- question ("is there a key `x` in this export?") that a script costs
--- more than. It reads a file, or standard input, walks the path
--- `Json.parse_pattern` reads, and prints what is there -- and nothing else:
--- no filter, no transform. A path names one value and prints it as JSON;
--- `--flat` prints every leaf under it, and a path with `*` or `..` in it
--- every match, each as a `path = value` line (`Json.flat_line`), whose
--- path is one this verb takes back, so `--flat | grep` finds a leaf and
--- its path pastes into `cosmic json '<path>'`. JSONPath's filters and
--- slices are left out on purpose: the verb is a lookup and no query
--- language, and `grep` over `--flat` does what they would.
---
--- Unlike every other verb it ends in no verdict line. Its standard
--- output is data for a pipe or a `$(...)`, and a line of its own after
--- the value would be in that data; `cosmic sql` puts its verdict last,
--- for a reader to drop, but a JSON value has no line to drop. Its exit
--- status is the verdict: 0 found, 1 the path is not there, 2 a command
--- line, a file or a text it cannot read. Complaints go to standard
--- error, as every verb's do. Its `spec` (build/verb_spec.tl) is `bare`, and
--- build/verbs_test.tl says why the rest of the tree may not.
---
--- A JSON `null` is a value here, not an absence: `--exists` is true of a
--- key whose value is `null`, and a path through one fails for what it
--- is (`Json.get` reads with `null_value = Json.null`).

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")
local verb_spec = require("build.verb_spec")

--- The `cosmic json` verb: `run` is what `build/dispatch.tl` calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given: the caller adds newlines.
    --- False and why when the bytes did not all go, so the run can
    --- say so: its exit status is its only verdict.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- The whole of standard input, or nil and why.
    stdin: function(): string | nil, string
  end

  --- What a command line asks for.
  record Request
    --- The steps to look up; empty for the document itself, and when
    --- `pattern` is set.
    path: {string | integer}
    --- The steps of a path that can match many values (`*`, `..`);
    --- nil for a plain path.
    pattern: {Json.Step} | nil
    --- The path as `Json.child_path` spells it (a pattern as
    --- `Json.spell_pattern` does), for a message; "$" when none was
    --- given.
    spelled: string
    --- The file to read; nil for standard input.
    file: string | nil
    --- "value", "exists", "keys", "shape" or "flat".
    mode: string
    compact: boolean
    raw: boolean
  end
end

local spec = Cli.options.json

local usage = "cosmic json [--flat | --exists | --keys | --shape | --compact | -r] [--] [<path>] [<file>|-]" ..
  "; a file whose name begins with . $ or [ is written ./name, or follows --"

--- Whether a lone word is the path and not the file: it begins with `$`,
--- `[` or `.`, and does not begin `./` or `../`, which name a file.
--- Plain comment, not a TODO: a lone word has to be one or the other,
--- and a path is far likelier than a file named for one. The other
--- reading is always spelled: `./name`, or `--` before the words.
local function is_path(word: string): boolean
  local head = word:sub(1, 1)
  if head == "$" or head == "[" then return true end
  return head == "." and word:sub(1, 2) ~= "./" and word:sub(1, 3) ~= "../"
end

--- What `argv` asks for, or nil and why it is refused.
local function arguments(argv: {integer:string}): verb.Request | nil, string
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then return nil, trouble end
  local modes: {string} = {}
  for _, name in ipairs({ "exists", "keys", "shape", "flat" }) do
    if parsed.set["--" .. name] then modes[#modes + 1] = "--" .. name end
  end
  if #modes > 1 then
    return nil, "name one of " .. table.concat(modes, " and ") .. ", not both"
  end
  local raw = parsed.set["-r"] or parsed.set["--raw"] or false
  local compact = parsed.set["--compact"] or false
  if #modes == 1 and (raw or compact) then
    return nil, (raw and "--raw" or "--compact") .. " shapes a printed value, which " ..
      modes[1] .. (modes[1] == "--flat" and " prints in one form" or " does not print")
  end
  local words = parsed.words
  -- No option of this verb takes a value, so the first `--` is the one
  -- that ended the options. After it the words are `[path] file`.
  local ended = false
  local slot = 2
  while argv[slot] ~= nil do
    if argv[slot] == "--" then
      ended = true
      break
    end
    slot = slot + 1
  end
  local request: verb.Request = { path = {}, pattern = nil, spelled = "$", mode = "value", compact = compact, raw = raw }
  if #modes == 1 then request.mode = modes[1]:sub(3) end
  local path: string | nil
  if #words == 2 then
    path, request.file = words[1], words[2]
  elseif #words == 1 then
    if is_path(words[1]) and not ended then path = words[1] else request.file = words[1] end
  elseif #words > 2 then
    return nil, "give a path and a file at most, not " .. #words .. " words"
  end
  if request.file == "" then return nil, "an empty file name" end
  if request.file == "-" then request.file = nil end
  if path ~= nil then
    local steps, _ = Json.parse_path(path)
    if steps ~= nil then
      request.path, request.spelled = steps, "$"
      for _, step in ipairs(steps) do
        request.spelled = Json.child_path(request.spelled, step)
      end
    else
      -- Not a plain path: a pattern, or no path at all, which says so.
      local pattern, why = Json.parse_pattern(path)
      if pattern == nil then return nil, why end
      request.pattern = pattern
      request.spelled = Json.spell_pattern(pattern)
      if request.mode == "keys" or request.mode == "shape" then
        return nil, "--" .. request.mode .. " reads one value and `" .. request.spelled ..
          "` can match many; name one path (`--flat` lists every leaf under a pattern)"
      end
    end
  end
  return request, ""
end

--- What kind of value `value` is, for a complaint: a scalar's type, or
--- `{...}` and `[n x ...]` for a container.
local function shown(value: any): string
  return Json.describe(value, { max_depth = 0 })
end

--- What `--keys` prints for `value`: an object's keys, sorted, one per
--- line, or an array's length; nil and why when it is neither.
local function keys_of(value: any): string | nil, string
  local object, _ = Json.entries(value)
  if object ~= nil then
    local names: {string} = {}
    for key in pairs(object) do names[#names + 1] = key end
    table.sort(names)
    if #names == 0 then return "", "" end
    return table.concat(names, "\n") .. "\n", ""
  end
  local items, _ = Json.items(value)
  if items ~= nil then return #items .. "\n", "" end
  return nil, "--keys needs an object or an array, got " .. shown(value)
end

--- The bytes of standard input, refusing a terminal, where nothing
--- would ever end them.
local function read_stdin(): string | nil, string
  if Proc.is_tty(Fs.stdin) then
    return nil, "no file given and standard input is a terminal; give a file " ..
      "(written ./name, or after --, when its name begins with . $ or [), or pipe JSON in"
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

--- `cosmic json [options] [<path>] [<file>|-]`: prints the value at the
--- path, and returns the exit code: 0 found, 1 the path is not there
--- (or `--keys` was asked of a scalar), 2 a command line, a file or a
--- text it cannot read.
--- @param argv the command line, `json` at slot 1
--- @param io where the text is read and written; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  local function complain(line: string)
    to.err("cosmic: json: " .. line)
  end
  -- What a write to standard output answers: 0, or 2 and a complaint,
  -- since a value lost to a full disk or a closed pipe is no success.
  local function written(ok: boolean, why: string): integer
    if ok then return 0 end
    complain("standard output: " .. why)
    return 2
  end
  local parsed, trouble = arguments(argv)
  if parsed == nil then
    complain(trouble .. "; " .. usage)
    return 2
  end
  local request: verb.Request = parsed
  local text: string | nil
  local read_trouble: string
  if request.file == nil then
    text, read_trouble = to.stdin()
  else
    text, read_trouble = Fs.read(request.file)
  end
  if text == nil then
    complain(read_trouble)
    return 2
  end
  local document, decode_trouble = Json.decode(text, { null_value = Json.null })
  if decode_trouble ~= "" then
    complain((request.file or "standard input") .. ": " .. decode_trouble)
    return 2
  end
  -- What `--flat` and a pattern print: one `path = value` line per leaf
  -- or match; `-r` prints a pattern's matches as their text, one to a line.
  local walk: Json.WalkOptions = { max_depth = Json.depth_limit }
  local function print_lines(found: {Json.Located}, bare: boolean): integer
    local lines: {string} = {}
    for _, item in ipairs(found) do
      local line: string | nil
      local why: string
      local leaf = item.value
      if bare and leaf is string then
        line = leaf
      elseif bare then
        line, why = Json.encode(leaf)
        if line == nil then why = item.path .. ": " .. why end
      else
        line, why = Json.flat_line(item.path, leaf)
      end
      if line == nil then
        complain(why)
        return 1
      end
      lines[#lines + 1] = line
    end
    if #lines == 0 then return 0 end
    return written(to.out(table.concat(lines, "\n") .. "\n"))
  end
  if request.pattern ~= nil then
    local matches, why = Json.select(document, request.pattern, walk)
    if matches == nil then
      complain(why)
      return 2
    end
    if #matches == 0 then
      if request.mode ~= "exists" then complain(request.spelled .. ": no match") end
      return 1
    end
    if request.mode == "exists" then return 0 end
    if request.mode ~= "flat" then return print_lines(matches, request.raw) end
    local leaves: {Json.Located} = {}
    -- Matches come before what is inside them, so those under a match
    -- already flattened follow it: skip them, or each leaf would print
    -- once per match above it (`$..a` over nested `a`s, `$..*`).
    local covered: string | nil
    for _, match in ipairs(matches) do
      if covered ~= nil and match.path:sub(1, #covered) == covered
        and match.path:find("^[.%[]", #covered + 1) then
        goto next_match
      end
      covered = match.path
      local under, flat_why = Json.flatten(match.value, { max_depth = walk.max_depth, root = match.path })
      if under == nil then
        complain(flat_why)
        return 2
      end
      for _, leaf in ipairs(under) do leaves[#leaves + 1] = leaf end
      ::next_match::
    end
    return print_lines(leaves, false)
  end
  local value, missing = Json.get(document, request.path)
  if missing ~= "" then
    if request.mode ~= "exists" then complain(missing) end
    return 1
  end
  if request.mode == "exists" then return 0 end
  if request.mode == "flat" then
    local leaves, why = Json.flatten(value, { max_depth = walk.max_depth, root = request.spelled })
    if leaves == nil then
      complain(why)
      return 2
    end
    return print_lines(leaves, false)
  end
  if request.mode == "shape" then
    return written(to.out(Json.describe(value) .. "\n"))
  end
  if request.mode == "keys" then
    local listed, why = keys_of(value)
    if listed == nil then
      complain(request.spelled .. ": " .. why)
      return 1
    end
    return written(to.out(listed))
  end
  if request.raw and value is string then
    return written(to.out(value .. "\n"))
  end
  local encoded, encode_trouble = Json.encode(value, { pretty = not request.compact })
  if encoded == nil then
    complain(request.spelled .. ": " .. encode_trouble)
    return 1
  end
  return written(to.out(encoded .. "\n"))
end

--- The `json` verb as `build/verb_list.tl` lists it. Reads a document it
--- is given, never the tree, so never stale-checked either.
verb.spec = {
  name = "json",
  run = function(argv: {integer:string}): integer return verb.run(argv) end,
  bare = true,
  takes = "a path and a file",
  exits = "`json` prints its\nvalue and nothing after, for a pipe, and exits 0 when it found the path, 1\nwhen the path is not there, 2 for a command line or a text it refused.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/json_test.tl)",
}

return verb
