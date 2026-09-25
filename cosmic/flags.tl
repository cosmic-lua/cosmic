--- A command line's options and the words among them. A spec names each
--- option and whether it takes a value; everything else that begins with
--- "-" is refused, so a mistyped option is never read as a path.
---
---     local got, why = Flags.parse(argv, 2, { ["--check"] = false, ["--jobs"] = true })
---     -- cosmic fix --check a.tl  => got.set["--check"], got.words = { "a.tl" }
---
--- `Flags.dispatch` reads a command first -- `prog build --jobs 4` -- and
--- parses the rest with that command's own spec.

local record Flags
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

  --- One command `Flags.dispatch` can run.
  record Command
    --- The options the command takes, as `Flags.parse` reads a spec;
    --- none when nil.
    spec: {string:boolean}
    --- Runs the command with what its line held, answering its exit
    --- status.
    run: function(Parsed): integer
  end
end

--- Whether `word` would be read as an option `spec` names, and so can
--- never be taken as another option's value: "--", an option named
--- whole, a "--name=value" whose name is named, or a cluster whose
--- first letter is.
local function names_option(spec: {string:boolean}, word: string): boolean
  if word == "--" or spec[word] ~= nil then
    return true
  end
  local long = word:match("^(%-%-[^=]+)=")
  if long ~= nil then
    return spec[long] ~= nil
  end
  return word:sub(1, 1) == "-" and word:sub(2, 2) ~= "-" and #word > 2 and
    spec[word:sub(1, 2)] ~= nil
end

--- Reads `argv` from slot `from` on: 1 for a program's own `argv`, 2
--- for a verb's, whose slot 1 is the verb. `spec` maps each option,
--- written as it is typed ("--check", "-v"), to whether it takes a value:
--- the next word, or for a "--" option also what follows "=" in the same
--- word ("--jobs=4"). A lone "-" is a word, and "--" ends the options:
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
--- given to one that takes none, or one whose value is missing -- the
--- end of the line, or a word that is itself an option the spec names
--- ("--", "--check", "--check=1", or "-vq" when "-v" is named). A spec
--- key that is not an option ("x", "-", "--"), or that holds an "=" no
--- word could reach ("--a=b"), raises.
--- @param argv {integer:string} The command line
--- @param from integer The first slot to read
--- @param spec {string:boolean} Each option, and whether it takes a value
--- @return Parsed | nil What the line held
--- @return string Why it was refused, or "" when it was not
function Flags.parse(argv: {integer:string}, from: integer,
    spec: {string:boolean}): Flags.Parsed | nil, string
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
  -- the next word, which must not itself be an option.
  local function valued(name: string, value: string | nil): boolean
    if value == nil then
      slot = slot + 1
      value = argv[slot]
      if value == nil or names_option(spec, value) then
        return false
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
    return true
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
      local takes = spec[name]
      if takes == nil then
        return nil, "no such option: " .. name
      elseif takes then
        if not valued(name, value) then
          return nil, name .. " needs a value"
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
        local takes = spec[name]
        if letter == "=" then
          return nil, "-" .. word:sub(at - 1, at - 1) .. " takes no value"
        elseif not letter:match("^%w$") then
          return nil, "no such option: " .. word
        elseif takes == nil then
          return nil, "no such option: " .. name .. " in " .. word
        elseif takes then
          local rest = word:sub(at + 1)
          if not valued(name, rest ~= "" and rest or nil) then
            return nil, name .. " needs a value"
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

--- Runs the command named at `argv[from]`: parses the words after it
--- with that command's spec, as `Flags.parse(argv, from + 1, spec)`
--- would, and answers what its `run` answers. Answers nil and why, run
--- nothing, when the line names no command, one `commands` does not
--- hold -- an option before the command is one -- or a line the
--- command's spec refuses, whose why names the command. Empty
--- `commands` raises.
--- @param argv {integer:string} The command line
--- @param from integer The slot holding the command
--- @param commands {string:Command} Each command, by the word that names it
--- @return integer | nil What the command's `run` answered
--- @return string Why nothing ran, or "" when a command did
function Flags.dispatch(argv: {integer:string}, from: integer,
    commands: {string:Flags.Command}): integer | nil, string
  if next(commands) == nil then
    error("flags: dispatch needs a command to choose among", 2)
  end
  local name = argv[from]
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
  local parsed, why = Flags.parse(argv, from + 1, command.spec or {})
  if parsed == nil then
    return nil, name .. ": " .. why
  end
  return command.run(parsed), ""
end

return Flags
