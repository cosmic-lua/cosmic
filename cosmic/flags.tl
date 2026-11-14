--- A command line's options and the words among them. A spec names each
--- option and whether it takes a value; everything else that begins with
--- "-" is refused, so a mistyped option is never read as a path. A
--- program whose first word is a command (`ledger report <file>`) reads
--- it with [`Flags.dispatch`], which hands each command the words after
--- it: `Flags.parse(argv, 1, spec)` reads no command, and would take
--- "report" for the file. `cosmic docs Flags.dispatch` shows such a
--- program whole.
---
--- The command line is the plain `{string}` a program's entry point is handed
--- (`return function(argv: {string}): integer`): the words after the
--- program's name. Slot 0, where the runtime puts the name, is not read; a
--- function that prints the name, as [`Flags.dispatch`] does in help, takes it
--- as an argument of its own.
---
---     local got, why = Flags.parse(argv, 2, { ["--check"] = false, ["--jobs"] = true })
---     -- cosmic fix --check --jobs 4 a.tl
---     --   => got.set["--check"] == true, got.values["--jobs"] == "4", got.words = { "a.tl" }
---
--- An option that takes no value is read from `set`, one that takes a value
--- from `values` (`all` when it may be repeated).
---
--- A spec may describe its options rather than only name them -- `{
--- ["--jobs"] = { value = "n", about = "run n at once" } }` -- and
--- [`Flags.help`] writes a command's help from it. [`Flags.dispatch`] reads a
--- command first -- `prog build --jobs 4` -- parses the rest with that
--- command's own spec, and answers `--help` from the same descriptions.

local record Flags
  --- One option described, for a spec to name and [`Flags.help`] to show.
  record Option
    --- What its value is called in help ("n", "path"), for an option
    --- that takes one; nil for one that takes none.
    value?: string
    --- One line on what it does.
    about?: string
    --- Whether the line must give it: [`Flags.parse`] refuses a line
    --- without it, and [`Flags.help`] marks it. An empty value
    --- (`--out=`) counts as given.
    required?: boolean
  end

  --- What a command line held.
  record Parsed
    --- Each option given that takes no value.
    set: mut {string:boolean}
    --- Each option given with a value, by name; the last one given wins.
    values: mut {string:string}
    --- Each option given with a value, by name: every value it was
    --- given, in order, for an option that may be repeated.
    all: mut {string: mut {string}}
    --- Every option given, by name, in order, once each time it was
    --- given: what counts a repeat, or tells which came first.
    given: mut {string}
    --- Every other word, in order.
    words: mut {string}
  end

  --- What [`Flags.dispatch`] did.
  record Dispatched
    --- The exit status: what the command's `run` answered, or 0 when
    --- help was asked for instead.
    code: integer
    --- The help asked for, for the caller to print; "" when a command
    --- ran.
    help: string
  end

  --- One line a command can be typed as, for its help to show.
  record Example
    --- What follows the command's name on the line ("--jobs 4 src");
    --- "" for the command alone.
    line: string
    --- One line on what that does; "" to show the line alone.
    about: string
  end

  --- One command [`Flags.dispatch`] can run.
  record Command
    --- The options the command takes, as [`Flags.parse`] reads a spec;
    --- none when nil.
    spec?: {string:boolean | Option}
    --- One line on what the command does, for help.
    about?: string
    --- What follows the command in its usage line ("[options] <file>"),
    --- for help; "[options]" when nil and the command takes any.
    usage?: string
    --- Lines to type, each with what it does, for help to show under
    --- "examples:" in the order given; none when nil.
    examples?: {Example}
    --- Other commands of the program, by name, for help to end "see
    --- also:" with, in the order given; none when nil.
    --- [`Flags.dispatch`] raises for a name that is not another of its
    --- commands.
    see?: {string}
    --- The section of the program's help the command is listed under
    --- ("Reports"); under "commands:" when nil or "", or "other
    --- commands:" where another command names a section.
    group?: string
    --- Runs the command with what its line held, answering its exit
    --- status. None for a command only described, as [`cosmic.cli`]'s
    --- verbs are, which [`Flags.dispatch`] refuses to run.
    run?: function(Parsed): integer
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

--- Whether the option a spec entry describes must be given.
local function is_required(entry: boolean | Flags.Option): boolean
  if entry is boolean then
    return false
  end
  return entry.required == true
end

--- The edit distance between `a` and `b`, or `reach + 1` when it is past
--- `reach`: insertions, deletions, replacements and swaps of two adjacent
--- bytes, each counting one (optimal string alignment).
local function distance(a: string, b: string, reach: integer): integer
  if math.abs(#a - #b) > reach then
    return reach + 1
  end
  -- A row holds the distances from a prefix of `a` to each prefix of
  -- `b`, that of b's first `j` bytes at slot `j + 1`.
  local function cell(cells: {integer}, j: integer): integer
    return assert(cells[j + 1])
  end
  local before: {integer} = {}
  local row: mut {integer} = {}
  for j = 0, #b do row[#row + 1] = j end
  for i = 1, #a do
    local next_row: mut {integer} = { i }
    local least = i
    for j = 1, #b do
      local cost = if a:byte(i) == b:byte(j) then 0 else 1 end
      local best = math.min(cell(row, j) + 1, cell(next_row, j - 1) + 1, cell(row, j - 1) + cost)
      if i > 1 and j > 1 and a:byte(i) == b:byte(j - 1) and a:byte(i - 1) == b:byte(j) then
        best = math.min(best, cell(before, j - 2) + 1)
      end
      next_row[#next_row + 1] = best
      if best < least then least = best end
    end
    if least > reach then
      return reach + 1
    end
    before, row = row, next_row
  end
  return math.min(cell(row, #b), reach + 1)
end

--- The names of `names` a mistyped `word` most likely meant, likeliest
--- first, at most three; none when nothing is near. The rule the
--- refusals of [`Flags.parse`] and [`Flags.dispatch`] end "did you mean"
--- by, for a program that words its own. A name is near when:
---
--- - `word` begins it and is shorter ("rep" for "report"); or
--- - it is within reach by edit distance: the fewest bytes inserted,
---   deleted or replaced, or adjacent pairs swapped, that turn one into
---   the other. The reach grows with `word`'s length, counted in
---   characters without its leading dashes: none under 3, then 1, 2
---   from 8 and 3 from 12.
---   So "biuld" is near "build" and "--chek" near "--check", and "ab"
---   is not near "ac".
---
--- A name equal to `word` comes first, then the names `word` begins,
--- then the others by distance; ties go shorter first, then by name. A
--- name given twice is answered once.
---
---     Flags.nearest("stauts", { "start", "status", "stash" })  -- => { "status" }
--- @param word string The word given
--- @param names {string} The names it could have been
--- @return {string} The near names, likeliest first
function Flags.nearest(word: string, names: {string}): {string}
  local bare = word:gsub("^%-+", "")
  local length = utf8.len(bare) or #bare
  local reach = if length < 3 then 0 elseif length < 8 then 1 elseif length < 12 then 2 else 3 end
  local record Near
    name: string
    rank: integer
  end
  local near: mut {Near} = {}
  local seen: mut {string:boolean} = {}
  for _, name in ipairs(names) do
    if seen[name] == nil then
      seen[name] = true
      if name == word then
        near[#near + 1] = { name = name, rank = 0 }
      elseif word ~= "" and #name > #word and name:sub(1, #word) == word then
        near[#near + 1] = { name = name, rank = 1 }
      elseif reach > 0 then
        local far = distance(word, name, reach)
        if far <= reach then
          near[#near + 1] = { name = name, rank = far + 1 }
        end
      end
    end
  end
  table.sort(near, function(a: Near, b: Near): boolean
    if a.rank ~= b.rank then return a.rank < b.rank end
    if #a.name ~= #b.name then return #a.name < #b.name end
    return a.name < b.name
  end)
  local out: mut {string} = {}
  for slot, found in ipairs(near) do
    if slot > 3 then break end
    out[slot] = found.name
  end
  return out
end

--- What a refusal of `word` ends with when `names` holds any near it
--- ([`Flags.nearest`]): "; did you mean build?", or "; did you mean one of
--- build, built?". "" when none is near.
local function meant(word: string, names: {string}): string
  local found = Flags.nearest(word, names)
  if #found == 0 then
    return ""
  elseif #found == 1 then
    return "; did you mean " .. found[1] .. "?"
  end
  return "; did you mean one of " .. table.concat(found, ", ") .. "?"
end

--- The keys of `map`, in no order.
local function keys<V>(map: {string:V}): {string}
  local out: mut {string} = {}
  for key in pairs(map) do out[#out + 1] = key end
  return out
end

--- [`Flags.parse`], for it and for [`Flags.dispatch`], whose commands take
--- options no spec names ("--help"): `also` holds those, for a refusal to
--- name beside the spec's when a mistyped option is near one.
local function read(argv: {string}, from: integer, spec: {string:boolean | Flags.Option},
                    also: {string}): Flags.Parsed?, string
  for name in pairs(spec) do
    if name:sub(1, 1) ~= "-" or name == "-" or name == "--" or name:find("=", 2, true) ~= nil then
      error("flags: " .. name .. " is not an option a spec can name", 3)
    end
    local entry = spec[name]
    if entry is Flags.Option and entry.value == "" then -- checked: is_on_record
      error("flags: " .. name .. "'s value name is empty", 3)
    end
  end
  local known: mut {string} = {}
  for name in pairs(spec) do known[#known + 1] = name end
  for _, name in ipairs(also) do known[#known + 1] = name end
  local parsed: Flags.Parsed = { set = {}, values = {}, all = {}, given = {}, words = {} }
  local cursor: integer = from
  local function flag(name: string)
    parsed.set[name] = true
    parsed.given[#parsed.given + 1] = name
  end
  -- Records `name`'s value: `value` when the word held it, otherwise
  -- the next word, which must not look like an option. `same` is how a
  -- value is attached to `name` in one word, for the refusal to show.
  local function valued(name: string, value: string?, same: string): string
    if value == nil then
      cursor = cursor + 1
      value = argv[cursor]
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
      parsed.all[name] = { value }
    else
      list[#list + 1] = value
    end
    parsed.given[#parsed.given + 1] = name
    return ""
  end
  -- Whether `word` is a one-dash option the spec names whole, of more
  -- than one letter, with its value after "=" ("-std=c99"): not a
  -- cluster, as "-n=3" is.
  local function whole(word: string): boolean
    local name = word:match("^(%-[^=]+)=")
    return name ~= nil and #name > 2 and spec[name] ~= nil
  end
  local options = true
  while argv[cursor] ~= nil do
    local word = argv[cursor]
    if not options or word == "-" or word:sub(1, 1) ~= "-" then
      parsed.words[#parsed.words + 1] = word
    elseif word == "--" then
      options = false
    elseif word:sub(2, 2) == "-" or spec[word] ~= nil or whole(word) then
      local name, value = word:match("^(%-%-?[^=]+)=(.*)$")
      if name == nil then name = word end
      local entry = spec[name]
      if entry == nil then
        return nil, "no such option: " .. name .. meant(name, known)
      elseif takes_value(entry) then
        local trouble = valued(name, value, if #name > 2 then "=" else "" end)
        if trouble ~= "" then
          return nil, trouble
        end
      elseif value ~= nil then
        return nil, name .. " takes no value"
      else
        flag(name)
      end
    elseif spec[word:sub(1, 2)] == nil then
      return nil, "no such option: " .. word .. meant(word, known)
    else
      local at = 2
      while at <= #word do
        local letter = word:sub(at, at)
        local name = "-" .. letter
        local entry = spec[name]
        if letter == "=" then
          return nil, "-" .. word:sub(at - 1, at - 1) .. " takes no value"
        elseif not letter:match("^%w$") then
          return nil, "no such option: " .. word .. meant(word, known)
        elseif entry == nil then
          return nil, "no such option: " .. name .. " in " .. word .. meant(word, known)
        elseif takes_value(entry) then
          local rest = word:sub(at + 1)
          local trouble = valued(name, if rest ~= "" then rest else nil end, "")
          if trouble ~= "" then
            return nil, trouble
          end
          break
        end
        flag(name)
        at = at + 1
      end
    end
    cursor = cursor + 1
  end
  local missing: mut {string} = {}
  for name, entry in pairs(spec) do
    if is_required(entry) and parsed.set[name] == nil and parsed.values[name] == nil then
      missing[#missing + 1] = name
    end
  end
  table.sort(missing)
  local first = missing[1]
  if first ~= nil then
    return nil, first .. " is required"
  end
  return parsed, ""
end

--- Parses command line options. Reads `argv` from slot `from` on: 1
--- for a program's own `argv`, 2 for a verb's, whose slot 1 is the verb.
--- `spec` maps each option, written as it is typed ("--check", "-v"), to
--- whether it takes a value: `true` or `false`, or a [`Flags.Option`], which
--- takes one when it names its `value`. The value is the next word, or
--- what follows "=" in the same word for a "--" option or a one-dash
--- option named whole ("--jobs=4", "-std=c99"). A lone "-" is a word, and
--- "--" ends the options: every word after it is a word even when it
--- begins with "-", as a negative number must. A file run as `cosmic
--- f.tl` gets its words as typed, a "--" among them. So for `cosmic f.tl
--- -- --email x`, Flags.parse from slot 1 reads "--email" and "x" as
--- words. Write `cosmic f.tl --email x`.
---
--- A word with one "-" that the spec does not name whole is a cluster of
--- one-letter options, as getopt reads one: "-vq" is "-v -q", and a
--- letter that takes a value takes the rest of the word ("-n3", "-vn3";
--- "-n=3" is "=3", as getopt has it) or, at the word's end, the next
--- word ("-vn 3"). A letter in a cluster is one ASCII letter or digit;
--- a spec may name "-foo" or "-é" whole, and then that word is that
--- option, never a cluster.
---
--- Answers nil and why for an option the spec does not name ("no such
--- option: --chek; did you mean --check?", the names [`Flags.nearest`]
--- answers for it, when any is near), a value
--- given to one that takes none, an option the spec marks `required` that
--- the line does not give ("--jobs is required"; the first by name when
--- several are missing), or one whose value is missing: the end
--- of the line, or a next word that looks like an option -- one that
--- begins with "-" and is not a lone "-" or a number `tonumber` reads
--- ("-1", "-0.5"; not "-inf") -- so a mistyped option ("--jobs --chek")
--- is never read as a value. A value that begins with "-" is given in
--- the same word: "--jobs=--x", "-std=-x", "-n--x". A spec key that is
--- not an option ("x", "-", "--"), or that holds an "=" no word could
--- reach ("--a=b"), raises, as does an [`Option`] whose `value` is "".
--- @param argv {string} The command line: the words after the program's name, as typed
--- @param from integer The first slot to read
--- @param spec {string:boolean|Option} Each option, and whether it takes a value
--- @return Parsed | nil What the line held
--- @return string Why it was refused, or "" when it was not
function Flags.parse(argv: {string}, from: integer,
                     spec: {string:boolean | Flags.Option}): Flags.Parsed?, string
  return read(argv, from, spec, {})
end

--- How many characters `text` shows as: its UTF-8 characters, or its
--- bytes when it is not UTF-8.
local function columns(text: string): integer
  return utf8.len(text) or #text
end

--- One line of a help column: what it is of, and what that does.
local record Row
  head: string
  about: string?
end

--- How wide the widest head of `rows` shows.
local function row_width(rows: {Row}): integer
  local width = 0
  for _, row in ipairs(rows) do
    if columns(row.head) > width then width = columns(row.head) end
  end
  return width
end

--- Each of `rows` as help lists it: indented two spaces, its head padded
--- to `width` where what it does follows.
local function row_lines(rows: {Row}, width: integer): {string}
  local lines: mut {string} = {}
  for _, row in ipairs(rows) do
    local about = row.about
    if about ~= nil and about ~= "" then
      lines[#lines + 1] = "  " .. row.head .. string.rep(" ", width - columns(row.head)) .. "  " .. about
    else
      lines[#lines + 1] = "  " .. row.head
    end
  end
  return lines
end

--- Each option `spec` names, as help shows it -- its name and the name
--- of its value -- beside what it does, in a column: sorted by name
--- without its dashes, each line indented two spaces.
local function option_lines(spec: {string:boolean | Flags.Option}): {string}
  local names: mut {string} = {}
  for name in pairs(spec) do names[#names + 1] = name end
  table.sort(names, function(a: string, b: string): boolean
    local bare_a, bare_b = a:gsub("^%-+", ""), b:gsub("^%-+", "")
    if bare_a ~= bare_b then return bare_a < bare_b end
    return a < b
  end)
  local rows: mut {Row} = {}
  for _, name in ipairs(names) do
    local entry = spec[name]
    local head = name
    local value = if entry is Flags.Option then entry.value else nil end -- checked: is_on_record
    if value ~= nil then
      head = name .. " <" .. value .. ">"
    elseif entry == true then
      head = name .. " <value>"
    end
    local about = if entry is Flags.Option then entry.about else nil end -- checked: is_on_record
    if entry ~= nil and is_required(entry) then
      about = if about ~= nil and about ~= "" then about .. " (required)" else "(required)" end
    end
    rows[#rows + 1] = { head = head, about = about }
  end
  return row_lines(rows, row_width(rows))
end

--- The options `spec` names, one line each as [`Flags.help`] lists them:
--- indented two spaces, sorted, what each does in a column. "" when it
--- names none. For help of another shape that still lists options the
--- same way.
--- @param spec {string:boolean|Option} The options
--- @return string The lines, without a newline after the last
function Flags.options(spec: {string:boolean | Flags.Option}): string
  return table.concat(option_lines(spec), "\n")
end

--- A command's help, written from its record: the usage line, `about`
--- when given, and each option the command's `spec` names with its
--- value's name and what it does, as a [`Flags.Option`] describes it:
--- one named `false` is listed bare, and one named `true` with
--- "<value>". An option the line must give ends "(required)". Then its
--- `examples`, each line after `name` beside what it does, and its `see`
--- names after "see also:", as written: given one command, it cannot
--- tell a name that is no command. A command with neither reads as one
--- that has no such fields. Columns are
--- aligned by characters, not bytes. `run` is not read, so a program with
--- one command, or a tool that runs its command itself, describes it the
--- way [`Flags.dispatch`] describes each of its own. It ends without a newline.
---
---     usage: prog count [options] <file>...
---
---     Counts the lines of each file.
---
---     options:
---       --jobs <n>  run n at once
---       -v          say more
---
---     examples:
---       prog count notes.txt     the lines of one file
---       prog count -v src/*.tl   each file's count, then the total
---
---     see also: words
--- @param command Command The command to describe
--- @param name string What the usage line calls it: the program, and the
---   command's own word after it when it has one ("prog count"); not
---   empty, or this raises
--- @return string The help
function Flags.help(command: Flags.Command, name: string): string
  if name == "" then
    error("flags: help's name is empty", 2)
  end
  local spec = command.spec or {}
  local usage = command.usage or (if next(spec) ~= nil then "[options]" else "" end)
  local parts: mut {string} = { "usage: " .. (if usage ~= "" then name .. " " .. usage else name end) }
  local about = command.about
  if about ~= nil and about ~= "" then
    parts[#parts + 1] = "\n" .. about
  end
  if next(spec) ~= nil then
    parts[#parts + 1] = "\noptions:\n" .. Flags.options(spec)
  end
  local examples = command.examples or {}
  if #examples > 0 then
    local rows: mut {Row} = {}
    for _, example in ipairs(examples) do
      rows[#rows + 1] = {
        head = if example.line ~= "" then name .. " " .. example.line else name end,
        about = example.about,
      }
    end
    parts[#parts + 1] = "\nexamples:\n" .. table.concat(row_lines(rows, row_width(rows)), "\n")
  end
  local see = command.see or {}
  if #see > 0 then
    parts[#parts + 1] = "\nsee also: " .. table.concat(see, ", ")
  end
  return table.concat(parts, "\n")
end

--- The help of `program` as a whole: its commands, each with its about,
--- under "commands:" in order by name. Where any names a `group`, each
--- group is a section under its title, the sections in order by title,
--- and the commands that name none come last, under "other commands:".
--- One column holds every section's names.
local function commands_help(program: string, commands: {string:Flags.Command}): string
  local names: mut {string} = {}
  local sections: mut {string: mut {Row}} = {}
  local titles: mut {string} = {}
  local every: mut {Row} = {}
  local any_options = false
  for name in pairs(commands) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local command = commands[name]
    if command ~= nil then
      local spec = command.spec
      if spec ~= nil and next(spec) ~= nil then any_options = true end
      local title = command.group or ""
      local row: Row = { head = name, about = command.about }
      local rows = sections[title]
      if rows == nil then
        sections[title] = { row }
        if title ~= "" then titles[#titles + 1] = title end
      else
        rows[#rows + 1] = row
      end
      every[#every + 1] = row
    end
  end
  table.sort(titles)
  local width = row_width(every)
  local lines: mut {string} = {
    "usage: " .. program .. " <command>" .. (if any_options then " [options]" else "" end),
  }
  local function section(heading: string, rows: {Row})
    lines[#lines + 1] = ""
    lines[#lines + 1] = heading .. ":"
    for _, line in ipairs(row_lines(rows, width)) do lines[#lines + 1] = line end
  end
  for _, title in ipairs(titles) do
    section(title, sections[title] or {})
  end
  local ungrouped = sections[""]
  if ungrouped ~= nil then
    section(if #titles > 0 then "other commands" else "commands" end, ungrouped)
  end
  if any_options then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Run `" .. program .. " <command> --help` for a command's options."
  end
  return table.concat(lines, "\n")
end

--- Whether the words from `from` on ask for a command's help: "--help"
--- or "-h" before any "--", when `spec` does not name it -- even where
--- an option's value would go, which [`Flags.parse`] refuses anyway. For
--- a program that reads its own line, as [`Flags.dispatch`] does not:
--- its refusals and its help are then the same rule's.
--- @param argv {string} The command line
--- @param from integer The first slot to read
--- @param spec {string:boolean|Option} The options the command names
--- @return boolean Whether help was asked for
function Flags.asks_help(argv: {string}, from: integer,
                         spec: {string:boolean | Flags.Option}): boolean
  local slot = from
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
--- hold -- an option before the command is one; "no such command: biuld;
--- did you mean build?" where [`Flags.nearest`] answers any, of the
--- commands and "help", as of a command's options and "--help" -- or a line the
--- command's spec refuses, or a command with no `run`. A line the spec
--- refuses is answered with the command's name, the refusal and its usage
--- line -- "build: --jobs is required; usage: prog build [options] <file>"
--- -- so a program that prints `why` shows how to type the line. Only the
--- first line of a multi-line `usage` is shown. Empty
--- `commands` raises, as does a command whose `see` names itself or no
--- command of `commands`, whatever the line: a caller's mistake, met by
--- its first run.
---
--- Help is answered rather than run -- `code` 0 and `help` for the
--- caller to print -- when the command is "--help" or "-h", or "help"
--- and `commands` holds no command of that name (`prog help build`
--- answers build's; `prog help --help` the program's), or when
--- "--help" or "-h" comes after a command whose spec does not name it,
--- before any "--" -- even as what would be an option's value, which
--- [`Flags.parse`] refuses anyway. Each command's help is [`Flags.help`]'s,
--- from its spec, `usage`, `about`, `examples` and `see`; the program's
--- lists every command's `about`, in order by name: under "commands:",
--- or, where any command names a `group`, each group under its title, the
--- titles in order, and the rest last under "other commands:". `help` given more than one word is refused.
---
---     local ran, why = Flags.dispatch(argv, 1, commands, "prog")
---     if ran == nil then Fs.put(Fs.stderr, "prog: " .. why .. "\n") return 2 end
---     if ran.help ~= "" then print(ran.help) end
---     return ran.code
--- @param argv {string} The command line
--- @param from integer The slot holding the command
--- @param commands {string:Command} Each command, by the word that names it
--- @param program string What help calls the program ("prog" in `prog build
---   --help`): not read from `argv`, which holds the words after the program's
---   name
--- @return Dispatched | nil What the command answered, or the help
--- @return string Why nothing ran, or "" when a command or help did
function Flags.dispatch(argv: {string}, from: integer,
                        commands: {string:Flags.Command}, program: string): Flags.Dispatched?, string
  if next(commands) == nil then
    error("flags: dispatch needs a command to choose among", 2)
  end
  for held, command in pairs(commands) do
    for _, other in ipairs(command.see or {}) do
      if other == held or commands[other] == nil then
        error("flags: " .. held .. "'s see names no other command: " .. other, 2)
      end
    end
  end
  local name = argv[from]
  if name == "--help" or name == "-h" or (name == "help" and commands.help == nil) then -- checked: map_field
    local asked = if name == "help" then argv[from + 1] else nil end
    if asked == "--help" or asked == "-h" then
      asked = nil
    end
    if asked ~= nil and argv[from + 2] ~= nil then
      return nil, "help: one command at a time"
    end
    if asked == nil then
      return { code = 0, help = commands_help(program, commands) }, ""
    end
    local asked_command = commands[asked]
    if asked_command == nil then
      return nil, "no such command: " .. asked .. meant(asked, keys(commands))
    end
    return { code = 0, help = Flags.help(asked_command, program .. " " .. asked) }, ""
  end
  if name == nil then
    local names: mut {string} = {}
    for known in pairs(commands) do names[#names + 1] = known end
    table.sort(names)
    return nil, "needs a command: " .. table.concat(names, ", ")
  end
  local command = commands[name]
  if command == nil then
    local known: mut {string} = { "help" }
    for held in pairs(commands) do known[#known + 1] = held end
    return nil, "no such command: " .. name .. meant(name, known)
  end
  local spec = command.spec or {}
  if Flags.asks_help(argv, from + 1, spec) then
    return { code = 0, help = Flags.help(command, program .. " " .. name) }, ""
  end
  local parsed, why = read(argv, from + 1, spec, { "--help" })
  if parsed == nil then
    local usage_line = Flags.help(command, program .. " " .. name):match("^[^\n]*") or ""
    return nil, name .. ": " .. why .. "; " .. usage_line
  end
  local run = command.run
  if run == nil then
    return nil, name .. ": the command has no run"
  end
  return { code = run(parsed), help = "" }, ""
end

return Flags
