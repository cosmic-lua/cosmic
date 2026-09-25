--- A command line's options and the words among them. A spec names each
--- option and whether it takes a value; everything else that begins with
--- "-" is refused, so a mistyped option is never read as a path.
---
---     local got, why = Flags.parse(argv, 2, { ["--check"] = false, ["--jobs"] = true })
---     -- cosmic fix --check a.tl  => got.set["--check"], got.words = { "a.tl" }
---
--- A spec may describe its options rather than only name them -- `{
--- ["--jobs"] = { value = "n", about = "run n at once" } }` -- and
--- `Flags.help` writes a program's help from it. `Flags.dispatch` reads a
--- command first -- `prog build --jobs 4` -- parses the rest with that
--- command's own spec, and answers `--help` from the same descriptions.

local record Flags
  --- One option described, for a spec to name and `Flags.help` to show.
  record Option
    --- What its value is called in help ("n", "path"), for an option
    --- that takes one; nil for one that takes none.
    value: string
    --- One line on what it does.
    about: string
  end

  --- What a command line held.
  record Parsed
    --- Each option given that takes no value.
    set: {string:boolean}
    --- Each option given with a value, by name; the last one given wins.
    values: {string:string}
    --- Each option given with a value, by name: every value it was
    --- given, in order, for an option that may be repeated.
    all: {string:{string}}
    --- Every option given, by name, in order, once each time it was
    --- given: what counts a repeat, or tells which came first.
    given: {string}
    --- Every other word, in order.
    words: {string}
  end

  --- What `Flags.dispatch` did.
  record Dispatched
    --- The exit status: what the command's `run` answered, or 0 when
    --- help was asked for instead.
    code: integer
    --- The help asked for, for the caller to print; "" when a command
    --- ran.
    help: string
  end

  --- One command `Flags.dispatch` can run.
  record Command
    --- The options the command takes, as `Flags.parse` reads a spec;
    --- none when nil.
    spec: {string:boolean | Option}
    --- One line on what the command does, for help.
    about: string
    --- What follows the command in its usage line ("[options] <file>"),
    --- for help; "[options]" when nil and the command takes any.
    usage: string
    --- Runs the command with what its line held, answering its exit
    --- status.
    run: function(Parsed): integer
  end
end

--- Whether `word`, the word after an option that takes a value, looks
--- like an option rather than a value: it begins with "-", and is
--- neither a lone "-" nor a number ("-1", "-0.5").
local function looks_like_option(word: string): boolean
  return word:sub(1, 1) == "-" and word ~= "-" and tonumber(word) == nil
end

--- Whether the option a spec entry describes takes a value.
local function takes_value(entry: boolean | Flags.Option): boolean
  if entry is boolean then
    return entry
  end
  return entry.value ~= nil
end

--- Reads `argv` from slot `from` on: 1 for a program's own `argv`, 2
--- for a verb's, whose slot 1 is the verb. `spec` maps each option,
--- written as it is typed ("--check", "-v"), to whether it takes a value
--- -- `true` or `false`, or a `Flags.Option` that takes one when it
--- names its `value` --: the next word, or for a "--" option also what
--- follows "=" in the same word ("--jobs=4"). A lone "-" is a word, and "--" ends the options:
--- every word after it is a word even when it begins with "-", as a
--- negative number must.
---
--- A word with one "-" that the spec does not name whole is a cluster of
--- one-letter options, as getopt reads one: "-vq" is "-v -q", and a
--- letter that takes a value takes the rest of the word ("-n3", "-vn3";
--- "-n=3" is "=3", as getopt has it) or, at the word's end, the next
--- word ("-vn 3"). A letter in a cluster is one ASCII letter or digit;
--- a spec may name "-foo" or "-é" whole, and then that word is that
--- option, never a cluster.
---
--- Answers nil and why for an option the spec does not name, a value
--- given to one that takes none, or one whose value is missing: the end
--- of the line, or a next word that looks like an option -- one that
--- begins with "-" and is not a lone "-" or a number -- so a mistyped
--- option ("--jobs --chek") is never read as a value. A value that
--- begins with "-" is given in the same word: "--jobs=--x", "-n--x". A spec
--- key that is not an option ("x", "-", "--"), or that holds an "=" no
--- word could reach ("--a=b"), raises.
--- @param argv {integer:string} The command line
--- @param from integer The first slot to read
--- @param spec {string:boolean|Option} Each option, and whether it takes a value
--- @return Parsed | nil What the line held
--- @return string Why it was refused, or "" when it was not
function Flags.parse(argv: {integer:string}, from: integer,
    spec: {string:boolean | Flags.Option}): Flags.Parsed | nil, string
  for name in pairs(spec) do
    if name:sub(1, 1) ~= "-" or name == "-" or name == "--" or name:find("=", 2, true) then
      error("flags: " .. name .. " is not an option a spec can name", 2)
    end
  end
  local parsed: Flags.Parsed = { set = {}, values = {}, all = {}, given = {}, words = {} }
  local slot = from
  local function flag(name: string)
    parsed.set[name] = true
    parsed.given[#parsed.given + 1] = name
  end
  -- Records `name`'s value: `value` when the word held it, otherwise
  -- the next word, which must not look like an option. `same` is how a
  -- value is attached to `name` in one word, for the refusal to show.
  local function valued(name: string, value: string | nil, same: string): string
    if value == nil then
      slot = slot + 1
      value = argv[slot]
      if value == nil then
        return name .. " needs a value"
      elseif looks_like_option(value) then
        return name .. " needs a value, not " .. value .. "; give one that " ..
          "begins with \"-\" as " .. name .. same .. value
      end
    end
    parsed.values[name] = value
    local list = parsed.all[name]
    if list == nil then
      list = {}
      parsed.all[name] = list
    end
    list[#list + 1] = value
    parsed.given[#parsed.given + 1] = name
    return ""
  end
  local options = true
  while argv[slot] ~= nil do
    local word = argv[slot]
    if not options or word == "-" or word:sub(1, 1) ~= "-" then
      parsed.words[#parsed.words + 1] = word
    elseif word == "--" then
      options = false
    elseif word:sub(2, 2) == "-" or spec[word] ~= nil then
      local name, value = word:match("^(%-%-[^=]+)=(.*)$")
      if name == nil then name = word end
      local entry = spec[name]
      if entry == nil then
        return nil, "no such option: " .. name
      elseif takes_value(entry) then
        local trouble = valued(name, value, word:sub(2, 2) == "-" and "=" or "")
        if trouble ~= "" then
          return nil, trouble
        end
      elseif value ~= nil then
        return nil, name .. " takes no value"
      else
        flag(name)
      end
    elseif spec[word:sub(1, 2)] == nil then
      return nil, "no such option: " .. word
    else
      local at = 2
      while at <= #word do
        local letter = word:sub(at, at)
        local name = "-" .. letter
        local entry = spec[name]
        if letter == "=" then
          return nil, "-" .. word:sub(at - 1, at - 1) .. " takes no value"
        elseif not letter:match("^%w$") then
          return nil, "no such option: " .. word
        elseif entry == nil then
          return nil, "no such option: " .. name .. " in " .. word
        elseif takes_value(entry) then
          local rest = word:sub(at + 1)
          local trouble = valued(name, rest ~= "" and rest or nil, "")
          if trouble ~= "" then
            return nil, trouble
          end
          break
        end
        flag(name)
        at = at + 1
      end
    end
    slot = slot + 1
  end
  return parsed, ""
end

--- Each option `spec` names, as help shows it -- its name and the name
--- of its value -- beside what it does, in a column: sorted by name
--- without its dashes, each line indented two spaces.
local function option_lines(spec: {string:boolean | Flags.Option}): {string}
  local names: {string} = {}
  for name in pairs(spec) do names[#names + 1] = name end
  table.sort(names, function(a: string, b: string): boolean
    local bare_a, bare_b = a:gsub("^%-+", ""), b:gsub("^%-+", "")
    if bare_a ~= bare_b then return bare_a < bare_b end
    return a < b
  end)
  local heads: {string} = {}
  local width = 0
  for index, name in ipairs(names) do
    local entry = spec[name]
    local head = name
    if entry is Flags.Option and entry.value ~= nil then
      head = name .. " <" .. entry.value .. ">"
    elseif entry == true then
      head = name .. " <value>"
    end
    heads[index] = head
    if #head > width then width = #head end
  end
  local lines: {string} = {}
  for index, name in ipairs(names) do
    local entry = spec[name]
    local about = entry is Flags.Option and entry.about or nil
    if about ~= nil and about ~= "" then
      lines[index] = "  " .. heads[index] .. string.rep(" ", width - #heads[index]) ..
        "  " .. about
    else
      lines[index] = "  " .. heads[index]
    end
  end
  return lines
end

--- A program's help, written from its spec: the usage line, `about`
--- when given, and each option the spec names with its value's name and
--- what it does, as a `Flags.Option` describes it (an option named only
--- `true` or `false` is listed bare). It ends without a newline.
---
---     usage: prog [options] <file>...
---
---     Counts the lines of each file.
---
---     options:
---       --jobs <n>  run n at once
---       -v          say more
--- @param usage string What follows "usage: " -- the program and its words
--- @param spec {string:boolean|Option} The options it takes
--- @param about string | nil One line on what it does
--- @return string The help
function Flags.help(usage: string, spec: {string:boolean | Flags.Option},
    about?: string): string
  local parts: {string} = { "usage: " .. usage }
  if about ~= nil and about ~= "" then
    parts[#parts + 1] = "\n" .. about
  end
  if next(spec) ~= nil then
    parts[#parts + 1] = "\noptions:\n" .. table.concat(option_lines(spec), "\n")
  end
  return table.concat(parts, "\n")
end

--- The help of one command of `program`.
local function command_help(program: string, name: string, command: Flags.Command): string
  local spec = command.spec or {}
  local usage = command.usage
  if usage == nil then
    usage = next(spec) ~= nil and "[options]" or ""
  end
  local line = program .. " " .. name
  if usage ~= "" then line = line .. " " .. usage end
  return Flags.help(line, spec, command.about)
end

--- The help of `program` as a whole: its commands, each with its about.
local function commands_help(program: string, commands: {string:Flags.Command}): string
  local names: {string} = {}
  local width = 0
  for name in pairs(commands) do
    names[#names + 1] = name
    if #name > width then width = #name end
  end
  table.sort(names)
  local lines: {string} = { "usage: " .. program .. " <command> [options]", "", "commands:" }
  for _, name in ipairs(names) do
    local about = commands[name].about
    if about ~= nil and about ~= "" then
      lines[#lines + 1] = "  " .. name .. string.rep(" ", width - #name) .. "  " .. about
    else
      lines[#lines + 1] = "  " .. name
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Run `" .. program .. " <command> --help` for a command's options."
  return table.concat(lines, "\n")
end

--- Whether the words after a command, from `slot` up to a "--", ask for
--- its help: "--help" or "-h", when its spec does not name them.
local function asks_help(argv: {integer:string}, slot: integer,
    spec: {string:boolean | Flags.Option}): boolean
  while argv[slot] ~= nil and argv[slot] ~= "--" do
    local word = argv[slot]
    if (word == "--help" or word == "-h") and spec[word] == nil then
      return true
    end
    slot = slot + 1
  end
  return false
end

--- Runs the command named at `argv[from]`: parses the words after it
--- with that command's spec, as `Flags.parse(argv, from + 1, spec)`
--- would, and answers what its `run` answers. Answers nil and why, run
--- nothing, when the line names no command, one `commands` does not
--- hold -- an option before the command is one -- or a line the
--- command's spec refuses, whose why names the command. Empty
--- `commands` raises.
---
--- Help is answered rather than run -- `code` 0 and `help` for the
--- caller to print -- when the command is "--help" or "-h", or "help"
--- and `commands` holds no command of that name (`prog help build`
--- answers build's), or when "--help" or "-h" comes after a command
--- whose spec does not name it, before any "--". Each command's help is `Flags.help`'s, from its
--- spec, `usage` and `about`; the program's lists every command's
--- `about`.
---
---     local ran, why = Flags.dispatch(argv, 1, commands, "prog")
---     if ran == nil then io.stderr:write("prog: ", why, "\n") return 2 end
---     if ran.help ~= "" then print(ran.help) end
---     return ran.code
--- @param argv {integer:string} The command line
--- @param from integer The slot holding the command
--- @param commands {string:Command} Each command, by the word that names it
--- @param program string | nil What help calls the program: by default
---   the last part of `argv[0]`'s path, or "program" without one
--- @return Dispatched | nil What the command answered, or the help
--- @return string Why nothing ran, or "" when a command or help did
function Flags.dispatch(argv: {integer:string}, from: integer,
    commands: {string:Flags.Command}, program?: string): Flags.Dispatched | nil, string
  if next(commands) == nil then
    error("flags: dispatch needs a command to choose among", 2)
  end
  if program == nil then
    program = argv[0] ~= nil and argv[0]:match("([^/]*)$") or "program"
  end
  local name = argv[from]
  if name == "--help" or name == "-h" or (name == "help" and commands.help == nil) then
    local asked = name == "help" and argv[from + 1] or nil
    if asked == nil then
      return { code = 0, help = commands_help(program, commands) }, ""
    elseif commands[asked] == nil then
      return nil, "no such command: " .. asked
    end
    return { code = 0, help = command_help(program, asked, commands[asked]) }, ""
  end
  if name == nil then
    local names: {string} = {}
    for known in pairs(commands) do names[#names + 1] = known end
    table.sort(names)
    return nil, "needs a command: " .. table.concat(names, ", ")
  end
  local command = commands[name]
  if command == nil then
    return nil, "no such command: " .. name
  end
  local spec = command.spec or {}
  if asks_help(argv, from + 1, spec) then
    return { code = 0, help = command_help(program, name, command) }, ""
  end
  local parsed, why = Flags.parse(argv, from + 1, spec)
  if parsed == nil then
    return nil, name .. ": " .. why
  end
  return { code = command.run(parsed), help = "" }, ""
end

return Flags
