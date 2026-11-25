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
--- command's own spec, and returns the help for `--help` from the same
--- descriptions.
--- A [`Flags.Documented`] adds what a program's help holds beyond its
--- commands -- topics, the order of its groups, the text around its
--- index -- for [`Flags.dispatch`] and [`Flags.program_help`] alike.
--- [`Flags.main`] runs a program's whole line with them, writing its help
--- and refusals and returning its exit status.

local Distance = require("cosmic.internal.distance")
local Fs = require("cosmic.fs")
local source_run = require("cosmic.internal.source_run")
local type Doc = require("cosmic.doc")
local type Stream = require("cosmic.stream")

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
    --- Other spellings of the option (`{ "-r" }` for "--raw"). A line may give any of them;
    --- [`Flags.Parsed`] holds the option under its spec name alone, and help shows them on its row,
    --- one-dash spellings first ("-r, --raw"). An alias that is no option, that names another option,
    --- or that is "-h" or "--help" raises.
    aliases?: {string}
    --- The values the option takes, for one that takes a value. [`Flags.parse`] refuses any other
    --- ("--level takes L, M, Q or H, not Z"), and help lists them after what the option does.
    choices?: {string}
    --- That the value is a whole number, within the range's bounds: [`Flags.parse`] refuses any
    --- other ("-n takes a whole number from 1 to 100, not 0"), holds it in [`Flags.Parsed`]'s
    --- `integers`, and help shows the bounds.
    integer?: Range
    --- The value the option has when the line gives none, for one that takes a value. [`Flags.parse`]
    --- puts it in `values` (and `integers`), but not in `all` or `given`, which hold what the line
    --- gave; help shows it ("default: M"). One that the option's `choices` or `integer` refuse, or
    --- one on a `required` option, raises.
    default?: string
    --- Where an option that is gone went, for a line that still gives it: [`Flags.parse`] refuses it with
    --- this after its name ("no such option: --read; `prog read` reads one back"), and help leaves it out.
    moved?: string
    --- That the option's value may be "-" in place of a file: "input" for standard input, "output" for
    --- standard output. The command reads or writes it with [`Flags.read`], [`Flags.reader`] or
    --- [`Flags.write`], and help says so ("-: standard input").
    dash?: Dash
  end

  --- What "-" stands for as an [`Option`]'s value: standard input or standard output.
  enum Dash
    "input"
    "output"
  end

  -- TODO: move the other verbs' value checks onto `choices` and `integer` (qr, codec, sandbox,
  -- test, build, sql, lsp), their "(default ...)" text onto `default`, and json's -r and codec's -d onto
  -- `aliases`; each still words its own refusal of a bad value. A gap: it waits on nothing.

  --- The bounds of a whole number an option takes, each inclusive; no bound where nil.
  record Range
    --- The least whole number taken.
    min?: integer
    --- The greatest whole number taken.
    max?: integer
  end

  --- What a command line held.
  record Parsed
    --- Each option given that takes no value.
    set: mut {string:boolean}
    --- Each option given with a value, by name; the last one given wins. An option the line does
    --- not give holds its `default`, where its spec gives one.
    values: mut {string:string}
    --- The value of each option in `values` whose spec says it is an `integer`, as one.
    integers: mut {string:integer}
    --- Each option given with a value, by name: every value it was
    --- given, in order, for an option that may be repeated.
    all: mut {string: mut {string}}
    --- Every option given, by name, in order, once each time it was
    --- given: what counts a repeat, or tells which came first.
    given: mut {string}
    --- Every other word, in order.
    words: mut {string}
    --- The words the command keeps for itself, unread, in order: set by [`Flags.dispatch`] for a command that
    --- says which they are ([`Flags.Command`]'s `rest`), nil for any other and from [`Flags.parse`].
    mut rest?: {string}
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
    --- Other commands of the program, or its topics, by name, for help
    --- to end "see also:" with, in the order given; none when nil.
    --- [`Flags.dispatch`] raises for a name that is not another of its
    --- commands, "help" among them, or one of its [`Flags.Topic`]s.
    see?: {string}
    --- The section of the program's help the command is listed under
    --- ("Reports"); under "commands:" when nil or "", or "other
    --- commands:" where another command names a section.
    group?: string
    --- The word that runs the command where that is not its name in `commands`: an option's spelling
    --- ("--version"), or "" for the command a first word that names no other runs, that word being the first
    --- of its own (a file to run). [`Flags.dispatch`] raises where two commands are typed alike.
    typed?: string
    --- The slot of the line from which the words are the command's own, read by no spec: those of a program
    --- it starts, say, whose options are not its options. Given the line and the slot of its first word after
    --- the command; nil where the line holds none. They are the `rest` of what `run` is given.
    rest?: function(argv: {string}, from: integer): integer?
    --- The command's own commands, by the word that names each (`time add`, `rand uuid`): each a command as
    --- this one is, with its own `spec`, `usage`, `about` and `run`. [`Flags.dispatch`] runs the one the word
    --- after this command names, reads the line with its spec alone, and refuses a line with that one's usage;
    --- `prog help cmd sub` and `prog cmd sub --help` answer its help. This command's help lists them under
    --- "commands:", and its usage is `<a|b> ...` when it gives none. A command with these has no `spec` or `rest`
    --- of its own, and holds one at least, or [`Flags.dispatch`] raises; nil for a command that has none.
    subcommands?: {string:Command}
    --- Runs the command with what its line held, answering its exit
    --- status. None for a command only described, as [`cosmic.cli`]'s
    --- verbs are, which [`Flags.dispatch`] refuses to run.
    run?: function(Parsed): integer
  end

  --- A page of a program's help that is no command ("pairing",
  --- "exit"): `prog help pairing` prints it, and the program's index
  --- lists it under "topics:".
  record Topic
    --- One line on what it covers, for the index and the page's first
    --- line.
    about?: string
    --- The page: paragraphs, printed as written, so already wrapped.
    text?: string
    --- The guide whose text is the page in place of `text`: `pairing` for `doc/guides/pairing.md`, which the
    --- program carries as it carries every public guide of its project. [`Flags.dispatch`] reads it from the
    --- program's documentation, and refuses `help` for the topic where that holds no such guide; it raises for a
    --- topic that gives both, or a name that is "" or holds a "." or a "/". [`Flags.topic_help`] reads none.
    guide?: string
    --- Commands and topics of the program, by name, for the page to end
    --- "see also:" with, in the order given; none when nil.
    --- [`Flags.dispatch`] raises for a name that is neither.
    see?: {string}
  end

  --- What [`Flags.dispatch`] reads of the program's documentation, for a program that documents its commands
  --- as it documents its code: in doc comments, which the build indexes and the built program carries. Given
  --- one, even an empty one, the program answers `docs`.
  record Documented
    --- The module whose record documents the commands: the doc comment on its field `add` is the page of the
    --- command `add`, shown after what [`Flags.help`] writes of it. The record may be the commands themselves,
    --- each field a [`Flags.Command`], which the program then hands to [`Flags.dispatch`] by name. A command
    --- with no such field has that help alone, as every command has where the documentation holds no such
    --- module. A built program documents a module it carries that any module may require, or one under its own
    --- `cmd/<name>/`, which it carries whether its main requires it or not (a test or an example aside); it carries
    --- another where its main requires it, and documents the module a module it carries names as `pages` by a string
    --- (`{ pages = "commands" }`, or a local bound to that string and written there), which it carries
    --- for that, but a test, an example, one under `internal/` and one of another program's `cmd/<name>/`; a field of
    --- a module it requires that binds it so names it too (`{ pages = Names.pages }`). A name made at run time is not
    --- known to the build, which carries no module for it.
    pages?: string
    --- The titles of the sections of the program's help ([`Flags.Command`]'s `group`), in the order to show
    --- them; a title not among them follows, those in order by title. In order by title when nil.
    groups?: {string}
    --- The commands, by name, in the order to list them in their sections; one not among them follows, those
    --- in order by name. In order by name when nil.
    order?: {string}
    --- Whether the program's help lists each command as its line is typed, the usage [`Flags.help`] opens
    --- with ("prog count [options] <file>"), in place of its name.
    usages?: boolean
    --- What the program's help opens with, in place of its usage line.
    before?: string
    --- What the program's help ends with, in place of the lines that say how to read more.
    after?: string
    --- The program's topics, by the word `help` takes for each, listed under "topics:" after the commands; a
    --- topic's page may be one of the program's guides ([`Flags.Topic`]'s `guide`).
    --- A name that is "", a command's or the word one is typed as, "help", "docs", or one that begins with
    --- "-" raises. A program with a command named "help" answers `prog help` itself, so [`Flags.dispatch`]
    --- prints no topic for it: that command can, with [`Flags.topic_help`].
    topics?: {string:Topic}
    --- The columns a line of help may reach, at least 1, for a command's examples and options and the index
    --- alike, laid out as [`Flags.help`] lays out examples. When nil, examples keep within 80 and the rest
    --- are not wrapped. `before`, `after` and a topic's text are printed as written.
    width?: integer
  end

  --- Where a command line writes: `out` for what was asked, `err` for
  --- what went wrong. [`Flags.std_io`] gives the standard streams; a test
  --- passes functions that keep the lines.
  record Io
    --- Writes a line of what was asked.
    out: function(line: string)
    --- Writes a line of what went wrong.
    err: function(line: string)
  end

  --- What ends a command: it says why, and answers the exit code.
  type Verdict = function(why: string): integer

  --- [`Flags.verdicts`]' three.
  record Verdicts
    --- Says why on `err`, and answers [`Flags.FAILED`].
    failed: Verdict
    --- Says why on `err`, and answers [`Flags.REFUSED`].
    refused: Verdict
    --- Says why on `err`, and returns [`Flags.UNDONE`].
    undone: Verdict
  end

  --- The exit code of a command that failed: 1.
  FAILED: integer
  --- The exit code of a command line refused as it was typed: 2, as
  --- [`Flags.dispatch`]'s example gives for a word that names no command.
  REFUSED: integer
  --- The exit code of a command that could not do what was asked: 5. A file it could not read or write,
  --- a request that failed, or input data it refused. [`Flags.FAILED`] is the reply "no" (not found, a
  --- check that did not pass); this is "could not tell".
  UNDONE: integer
end

Flags.FAILED = 1
Flags.REFUSED = 2
Flags.UNDONE = 5

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

--- `words` joined as a sentence lists them: "a", "a or b", "a, b or c".
local function either(words: {string}): string
  if #words <= 1 then
    return words[1] or ""
  end
  return table.concat(words, ", ", 1, #words - 1) .. " or " .. words[#words]
end

--- What a whole number within `range` is, as a refusal and help say it: "a whole number from 1
--- to 9", "at least 1", "at most 9", or none.
local function range_text(range: Flags.Range): string
  local min, max = range.min, range.max
  if min ~= nil and max ~= nil then
    return "a whole number from " .. tostring(min) .. " to " .. tostring(max)
  elseif min ~= nil then
    return "a whole number, at least " .. tostring(min)
  elseif max ~= nil then
    return "a whole number, at most " .. tostring(max)
  end
  return "a whole number"
end

--- Why the option `name` refuses `value`, by its `choices` or `integer`; "" when it takes it, and
--- the whole number it is when the option is an `integer`.
local function refusal_of(name: string, entry: Flags.Option, value: string): string, integer?
  local shown = if value == "" then "\"\"" else value end
  local choices = entry.choices
  if choices ~= nil then
    local found = false
    for _, choice in ipairs(choices) do
      if choice == value then found = true end
    end
    if not found then
      return name .. " takes " .. either(choices) .. ", not " .. shown, nil
    end
  end
  local range = entry.integer
  if range ~= nil then
    local number = math.tointeger(tonumber(value))
    if number == nil or value:find("^[+-]?%d+$") == nil or (range.min ~= nil and number < range.min) or
        (range.max ~= nil and number > range.max) then
      return name .. " takes " .. range_text(range) .. ", not " .. shown, nil
    end
    return "", number
  end
  return "", nil
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
  local reach = Distance.reach(bare)
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
        local far = Distance.between(word, name, reach)
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

--- `names` in order, as a list of its own.
local function sorted(names: {string}): {string}
  local out: mut {string} = {}
  for _, name in ipairs(names) do out[#out + 1] = name end
  table.sort(out)
  return out
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
  local function nameable(name: string): boolean
    return name:sub(1, 1) == "-" and name ~= "-" and name ~= "--" and name:find("=", 2, true) == nil
  end
  -- Each name a line may give, by the spec name it stands for.
  local named: mut {string:string} = {}
  for name in pairs(spec) do
    if not nameable(name) then
      error("flags: " .. name .. " is not an option a spec can name", 3)
    end
    named[name] = name
  end
  for name, entry in pairs(spec) do
    if entry is Flags.Option then
      if entry.value == "" then
        error("flags: " .. name .. "'s value name is empty", 3)
      end
      if (entry.choices ~= nil or entry.integer ~= nil or entry.default ~= nil) and entry.value == nil then
        error("flags: " .. name .. " has choices, an integer range or a default, and takes no value", 3)
      end
      if entry.choices ~= nil and #entry.choices == 0 then
        error("flags: " .. name .. "'s choices are empty", 3)
      end
      if entry.choices ~= nil and entry.integer ~= nil then
        error("flags: " .. name .. " has both choices and an integer range", 3)
      end
      local range = entry.integer
      if range ~= nil and range.min ~= nil and range.max ~= nil and range.min > range.max then
        error("flags: " .. name .. "'s integer range is empty", 3)
      end
      if entry.dash ~= nil and entry.value == nil then
        error("flags: " .. name .. " reads or writes \"-\", and takes no value", 3)
      end
      if entry.default ~= nil and entry.required == true then
        error("flags: " .. name .. " is required and has a default", 3)
      end
      local default = entry.default
      if default ~= nil and refusal_of(name, entry, default) ~= "" then
        error("flags: " .. name .. "'s default " .. default .. " is not a value it takes", 3)
      end
      for _, alias in ipairs(entry.aliases or {}) do
        if not nameable(alias) or named[alias] ~= nil or alias == "-h" or alias == "--help" then
          error("flags: " .. name .. "'s alias " .. alias .. " is not an option of its own", 3)
        end
        named[alias] = name
      end
    end
  end
  local known: mut {string} = {}
  for name, spec_name in pairs(named) do
    local entry = spec[spec_name]
    if not (entry is Flags.Option and entry.moved ~= nil) then known[#known + 1] = name end
  end
  for _, name in ipairs(also) do known[#known + 1] = name end
  -- Whether the spec names an option that begins with a digit ("-1"), which then is what such a word is.
  local digits = false
  for name in pairs(named) do
    if name:match("^%-%d") ~= nil then digits = true end
  end
  local parsed: Flags.Parsed = { set = {}, values = {}, integers = {}, all = {}, given = {}, words = {} }
  local cursor: integer = from
  local function flag(name: string)
    parsed.set[name] = true
    parsed.given[#parsed.given + 1] = name
  end
  -- Records `name`'s value: `value` when the word held it, otherwise
  -- the next word, which must not look like an option. `same` is how a
  -- value is attached to `name` in one word, for the refusal to show.
  -- `typed` is how the line spelled `name`, an alias or the name itself, for a refusal to show.
  local function valued(name: string, value: string?, same: string, typed: string): string
    if value == nil then
      cursor = cursor + 1
      value = argv[cursor]
      if value == nil then
        return typed .. " needs a value"
      elseif looks_like_option(value) and (digits or value:match("^%-%d") == nil) then
        return typed .. " needs a value, not " .. value .. "; give one that " ..
          "begins with \"-\" as " .. typed .. same .. value
      end
    end
    local entry = spec[name]
    if entry is Flags.Option then
      local why, number = refusal_of(typed, entry, value)
      if why ~= "" then
        return why
      end
      if number ~= nil then parsed.integers[name] = number end
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
    return name ~= nil and #name > 2 and named[name] ~= nil
  end
  local options = true
  while argv[cursor] ~= nil do
    local word = argv[cursor]
    if not options or word == "-" or word:sub(1, 1) ~= "-" or (not digits and word:match("^%-%d") ~= nil) then
      parsed.words[#parsed.words + 1] = word
    elseif word == "--" then
      options = false
    elseif word:sub(2, 2) == "-" or named[word] ~= nil or whole(word) then
      local typed, value = word:match("^(%-%-?[^=]+)=(.*)$")
      if typed == nil then typed = word end
      local name = named[typed] or typed
      local entry = spec[name]
      if entry == nil then
        return nil, "no such option: " .. name .. meant(name, known)
      elseif entry is Flags.Option and entry.moved ~= nil then
        return nil, "no such option: " .. typed .. "; " .. entry.moved
      elseif takes_value(entry) then
        local trouble = valued(name, value, if #typed > 2 then "=" else "" end, typed)
        if trouble ~= "" then
          return nil, trouble
        end
      elseif value ~= nil then
        return nil, typed .. " takes no value"
      else
        flag(name)
      end
    elseif named[word:sub(1, 2)] == nil then
      return nil, "no such option: " .. word .. meant(word, known)
    else
      local at = 2
      while at <= #word do
        local letter = word:sub(at, at)
        local typed = "-" .. letter
        local name = named[typed] or typed
        local entry = spec[name]
        if letter == "=" then
          return nil, "-" .. word:sub(at - 1, at - 1) .. " takes no value"
        elseif not letter:match("^%w$") then
          return nil, "no such option: " .. word .. meant(word, known)
        elseif entry == nil then
          return nil, "no such option: " .. typed .. " in " .. word .. meant(word, known)
        elseif entry is Flags.Option and entry.moved ~= nil then
          return nil, "no such option: " .. typed .. "; " .. entry.moved
        elseif takes_value(entry) then
          local rest = word:sub(at + 1)
          local trouble = valued(name, if rest ~= "" then rest else nil end, "", typed)
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
  for name, entry in pairs(spec) do
    if entry is Flags.Option and entry.default ~= nil and parsed.values[name] == nil then
      local default = entry.default
      parsed.values[name] = default
      local _, number = refusal_of(name, entry, default)
      if number ~= nil then parsed.integers[name] = number end
    end
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
--- begins with "-". A word that begins with "-" and a digit ("-5",
--- "-0.5", "-90m") is a word too, a negative number or a span of time,
--- and may be an option's value; where the spec names any option that
--- begins so ("-1"), every such word is read as an option. A file run as `cosmic
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
--- begins with "-" and is not a lone "-", a number `tonumber` reads
--- ("-1", "-0.5"; not "-inf") or a word that begins with "-" and a digit
--- ("-90m") -- so a mistyped option ("--jobs --chek")
--- is never read as a value. A value that begins with "-" is given in
--- the same word: "--jobs=--x", "-std=-x", "-n--x". It refuses a value
--- outside an option's `choices` or `integer` range too ("-n takes a whole
--- number from 1 to 9, not 0"). An alias is read as the option it spells,
--- and an option the line does not give holds its `default`. A spec key
--- that is not an option ("x", "-", "--"), or that holds an "=" no word
--- could reach ("--a=b"), raises, as does an [`Option`] whose `value` is
--- "", and one whose `aliases`, `choices`, `integer` or `default` the
--- [`Option`] fields' own text says raise.
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

--- How many columns a row's lines take with its head padded to `column`:
--- what it does follows the head, and a line of it after a newline stands
--- as written, from the line's start.
local function row_reach(row: Row, column: integer): integer
  local about = row.about
  if about == nil or about == "" then
    return 2 + columns(row.head)
  end
  local reach = 0
  for line in (about .. "\n"):gmatch("([^\n]*)\n") do
    reach = if reach == 0 then 2 + column + 2 + columns(line) else math.max(reach, columns(line)) end
  end
  return reach
end

--- `text`'s words, in lines of at most `room` columns where a word
--- allows: a word wider than that has a line of its own.
local function wrapped(text: string, room: integer): {string}
  local lines: mut {string} = {}
  local line = ""
  for word in text:gmatch("%S+") do
    if line == "" then
      line = word
    elseif columns(line) + 1 + columns(word) <= room then
      line = line .. " " .. word
    else
      lines[#lines + 1] = line
      line = word
    end
  end
  lines[#lines + 1] = line
  return lines
end

--- Each of `rows` as help lists it: indented two spaces, its head padded
--- to `column` where what it does follows. With `wrap`, a row whose line
--- would pass that many columns has what it does wrapped at them, under
--- the column, beginning on a line of its own after a head wider than
--- the column; a row that fits, one whose words run over lines of their
--- own, and one that says only spaces are left as they are written.
local function row_lines(rows: {Row}, column: integer, wrap?: integer): {string}
  local lines: mut {string} = {}
  local indent = string.rep(" ", 2 + column + 2)
  for _, row in ipairs(rows) do
    local about = row.about
    if about == nil or about == "" then
      lines[#lines + 1] = "  " .. row.head
    elseif wrap == nil or about:find("\n", 1, true) ~= nil or about:find("%S") == nil or
        (columns(row.head) <= column and row_reach(row, column) <= wrap) then
      lines[#lines + 1] = "  " .. row.head .. string.rep(" ", column - columns(row.head)) .. "  " .. about
    else
      local beside = columns(row.head) <= column
      if not beside then
        lines[#lines + 1] = "  " .. row.head
      end
      for slot, said in ipairs(wrapped(about, wrap - #indent)) do
        if slot == 1 and beside then
          lines[#lines + 1] = "  " .. row.head .. string.rep(" ", column - columns(row.head)) .. "  " .. said
        else
          lines[#lines + 1] = indent .. said
        end
      end
    end
  end
  return lines
end

--- The column what `rows` do starts at, counted from the end of the
--- indent, for lines that stay within `wrap` columns: the widest head
--- when `wrap` is nil or every row's line fits there. Otherwise the
--- widest head of a row whose line fits alone, so a head too wide for
--- that takes a line of its own; 0 where none fits. A column that lays
--- `rows` out in fewer lines wins over that one: another row's head
--- width, or 0. So one wide head with a short line does not push every
--- other row's line past the edge. A row with nothing said beside its
--- head moves no column.
local function row_column(rows: {Row}, wrap?: integer): integer
  local widest = row_width(rows)
  if wrap == nil then
    return widest
  end
  local fits = true
  for _, row in ipairs(rows) do
    local about = row.about
    if about ~= nil and about ~= "" and row_reach(row, widest) > wrap then fits = false end
  end
  if fits then
    return widest
  end
  local column = 0
  for _, row in ipairs(rows) do
    local about = row.about
    if about ~= nil and about ~= "" and row_reach(row, columns(row.head)) <= wrap then
      column = math.max(column, columns(row.head))
    end
  end
  local fewest = #row_lines(rows, column, wrap)
  local candidates: mut {integer} = { 0 }
  for _, row in ipairs(rows) do
    if row.about ~= nil and row.about ~= "" then candidates[#candidates + 1] = columns(row.head) end
  end
  for _, candidate in ipairs(candidates) do
    if 2 + candidate + 2 < wrap then
      local count = #row_lines(rows, candidate, wrap)
      if count < fewest then
        column, fewest = candidate, count
      end
    end
  end
  return column
end

--- `rows` as [`row_lines`] lays them out within `wrap` columns, or in
--- one column, unwrapped, when nil.
local function laid_out(rows: {Row}, wrap?: integer): {string}
  return row_lines(rows, row_column(rows, wrap), wrap)
end

--- Each option `spec` names, as help shows it -- its name and the name
--- of its value -- with what it does: sorted by name without its dashes.
local function option_rows(spec: {string:boolean | Flags.Option}): {Row}
  local names: mut {string} = {}
  for name, entry in pairs(spec) do
    -- An option that moved is refused, not offered.
    if not (entry is Flags.Option and entry.moved ~= nil) then names[#names + 1] = name end
  end
  table.sort(names, function(a: string, b: string): boolean
    local bare_a, bare_b = a:gsub("^%-+", ""), b:gsub("^%-+", "")
    if bare_a ~= bare_b then return bare_a < bare_b end
    return a < b
  end)
  local rows: mut {Row} = {}
  for _, name in ipairs(names) do
    local entry = spec[name]
    local head = name
    if entry is Flags.Option and entry.aliases ~= nil and #entry.aliases > 0 then
      local spellings: mut {string} = {}
      for _, alias in ipairs(entry.aliases) do spellings[#spellings + 1] = alias end
      spellings[#spellings + 1] = name
      table.sort(spellings, function(a: string, b: string): boolean
        local long_a, long_b = a:sub(2, 2) == "-", b:sub(2, 2) == "-"
        if long_a ~= long_b then return long_b end
        if a == name or b == name then return a == name end
        return a < b
      end)
      head = table.concat(spellings, ", ")
    end
    local value = if entry is Flags.Option then entry.value else nil end
    if value ~= nil then
      head = head .. " <" .. value .. ">"
    elseif entry == true then
      head = head .. " <value>"
    end
    local about = if entry is Flags.Option then entry.about else nil end
    local notes: mut {string} = {}
    if entry is Flags.Option then
      if entry.choices ~= nil then notes[#notes + 1] = either(entry.choices) end
      local range = entry.integer
      if range ~= nil then notes[#notes + 1] = range_text(range) end
      if entry.default ~= nil then notes[#notes + 1] = "default: " .. entry.default end
      if entry.dash ~= nil then notes[#notes + 1] = "-: standard " .. entry.dash end
    end
    if entry ~= nil and is_required(entry) then notes[#notes + 1] = "required" end
    if #notes > 0 then
      local said = "(" .. table.concat(notes, "; ") .. ")"
      about = if about ~= nil and about ~= "" then about .. " " .. said else said end
    end
    rows[#rows + 1] = { head = head, about = about }
  end
  return rows
end

--- The options `spec` names, one line each as [`Flags.help`] lists them:
--- indented two spaces, sorted, what each does in a column. "" when it
--- names none. For help of another shape that still lists options the
--- same way.
--- @param spec {string:boolean|Option} The options
--- @return string The lines, without a newline after the last
function Flags.options(spec: {string:boolean | Flags.Option}): string
  local rows = option_rows(spec)
  return table.concat(row_lines(rows, row_width(rows)), "\n")
end

--- A subcommand and the word that runs it.
local record Typed
  word: string
  command: Flags.Command
end

--- The subcommands of `command` as they are typed, in order by word.
local function typed_subcommands(command: Flags.Command): {Typed}
  local listed: mut {Typed} = {}
  local subcommands = command.subcommands or {}
  for _, held in ipairs(sorted(keys(subcommands))) do
    local sub = assert(subcommands[held], "a name of subcommands names one")
    local typed = sub.typed or held
    if typed ~= "" then listed[#listed + 1] = { word = typed, command = sub } end
  end
  table.sort(listed, function(a: Typed, b: Typed): boolean return a.word < b.word end)
  return listed
end

--- What follows `command` in its usage line: its `usage`; else, for one with subcommands, each word that runs one
--- ("<add|now> ..."); else "[options]" where it takes any, and "" where it takes none.
local function usage_of(command: Flags.Command): string
  local given = command.usage
  if given ~= nil then return given end
  local listed = typed_subcommands(command)
  if #listed > 0 then
    local words: mut {string} = {}
    for _, pair in ipairs(listed) do words[#words + 1] = pair.word end
    return "<" .. table.concat(words, "|") .. "> ..."
  end
  return if next(command.spec or {}) ~= nil then "[options]" else "" end
end

--- The line `command` is typed as, for its help: `program`, the word that runs it (`name`, or its `typed`), and
--- its usage ([`usage_of`]).
local function typed_line(program: string, name: string, command: Flags.Command): string
  local words: mut {string} = { program }
  local typed = command.typed or name
  if typed ~= "" then words[#words + 1] = typed end
  local usage = usage_of(command)
  if usage ~= "" then words[#words + 1] = usage end
  return table.concat(words, " ")
end

--- The word `command`, held as `name`, is listed by: the word that runs it, or "<" and its name and ">" for the
--- command no word names.
local function shown(name: string, command: Flags.Command): string
  local typed = command.typed or name
  return if typed ~= "" then typed else "<" .. name .. ">" end
end

--- What help calls `command`, held as `name`: `program` and the word that runs it, or `program` alone for the
--- command no word names.
local function called(program: string, name: string, command: Flags.Command): string
  local typed = command.typed or name
  return if typed ~= "" then program .. " " .. typed else program end
end

--- A command's help, written from its record: the usage line, `about`
--- when given, and each option the command's `spec` names with its
--- value's name and what it does, as a [`Flags.Option`] describes it:
--- one named `false` is listed bare, and one named `true` with
--- "<value>". An option the line must give ends "(required)". Then its
--- `subcommands`, each by its word, usage and `about` under "commands:",
--- with a line that says how to ask for one's help. Then its
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
---
--- The examples keep within `width` columns where their words allow, 80
--- when nil, and so do `about` and the options where `width` is given.
--- An `about` past the width is wrapped at it, unless it runs over lines
--- of its own or says only spaces, which are left as written. Where every
--- line of a section fits beside the widest head, the section is laid out
--- as above. Otherwise what a row does is wrapped, in a column as wide as
--- the widest head of a row that fits alone, and a head wider than that
--- has a line of its own with what it does on the lines under it:
---
---     examples:
---       prog count notes.txt  the lines of one file
---       prog count --jobs 8 --exclude 'output/**' src/*.tl
---                             each file's count, eight at once, leaving out the
---                             generated files
--- @param command Command The command to describe
--- @param name string What the usage line calls it: the program, and the
---   command's own word after it when it has one ("prog count"); not
---   empty, or this raises
--- @param width? integer The columns a line may reach, at least 1, or
---   this raises: an example's 80, and an option's and `about`'s
---   unbounded, when nil
--- @return string The help
function Flags.help(command: Flags.Command, name: string, width?: integer): string
  if name == "" then
    error("flags: help's name is empty", 2)
  elseif width ~= nil and width < 1 then
    error("flags: help's width is not a positive number of columns", 2)
  end
  -- A subcommand typed by no word runs when the line names none, so its options are shown with the command's own.
  local spec: mut {string: boolean | Flags.Option} = {}
  for option_name, option in pairs(command.spec or {}) do spec[option_name] = option end
  for _, sub in pairs(command.subcommands or {}) do
    if sub.typed == "" then
      for option_name, option in pairs(sub.spec or {}) do spec[option_name] = option end
    end
  end
  local parts: mut {string} = { Flags.usage(command, name) }
  local about = command.about
  if about ~= nil and about ~= "" then
    if width ~= nil and columns(about) > width and about:find("\n", 1, true) == nil and
        about:find("%S") ~= nil then
      about = table.concat(wrapped(about, width), "\n")
    end
    parts[#parts + 1] = "\n" .. about
  end
  if next(spec) ~= nil then
    parts[#parts + 1] = "\noptions:\n" .. table.concat(laid_out(option_rows(spec), width), "\n")
  end
  local listed = typed_subcommands(command)
  if #listed > 0 then
    local rows: mut {Row} = {}
    for _, pair in ipairs(listed) do
      local sub, described = pair.word, pair.command
      local sub_usage = usage_of(described)
      rows[#rows + 1] = {
        head = if sub_usage ~= "" then sub .. " " .. sub_usage else sub end,
        about = described.about,
      }
    end
    parts[#parts + 1] = "\ncommands:\n" .. table.concat(laid_out(rows, width), "\n") ..
      "\n\n`" .. name .. " <command> --help` says more."
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
    parts[#parts + 1] = "\nexamples:\n" .. table.concat(laid_out(rows, width or 80), "\n")
  end
  local see = command.see or {}
  if #see > 0 then
    parts[#parts + 1] = "\nsee also: " .. table.concat(see, ", ")
  end
  return table.concat(parts, "\n")
end

--- The usage line of `command`, as its help's first line and every refusal's end give it ("usage: prog count
--- [options] <file>"), or of the subcommand that `words` name, one level a word: "usage: prog time add <time>
--- <duration>" for `Flags.usage(time, "prog time", { "add" })`. The walk stops at a word that names no
--- subcommand, and the line is then that of the last command reached.
--- @param command Command The command the words start from
--- @param name string What its usage line calls it: the program, and the command's own word after it when it
---   has one ("prog time"); not empty, or this raises
--- @param words? {string} The words that name its subcommands, outermost first; none when nil
--- @return string The usage line, with no newline
function Flags.usage(command: Flags.Command, name: string, words?: {string}): string
  if name == "" then
    error("flags: usage's name is empty", 2)
  end
  local reached, called_as = command, name
  for _, word in ipairs(words or {}) do
    local sub = (reached.subcommands or {})[word]
    if sub == nil then break end
    reached, called_as = sub, called_as .. " " .. word
  end
  local usage = usage_of(reached)
  return "usage: " .. (if usage ~= "" then called_as .. " " .. usage else called_as end)
end

--- A topic's page, as `prog help <topic>` prints it: its name and
--- `about` ("pairing: how a device is paired with"), its `text`, and
--- its `see` names after "see also:". Each part is left out where it is
--- nil or empty, and the page ends without a newline. A topic's `guide`
--- is not read here: [`Flags.dispatch`] reads it as the topic's `text`.
---
---     pairing: how a device is paired with
---
---     A device is paired with once. ...
---
---     see also: pair, unpair
--- @param topic Topic The topic
--- @param name string The word `help` takes for it; not empty, or this raises
--- @return string The page
function Flags.topic_help(topic: Flags.Topic, name: string): string
  if name == "" then
    error("flags: a topic's name is empty", 2)
  end
  local about = topic.about
  local parts: mut {string} = { if about ~= nil and about ~= "" then name .. ": " .. about else name end }
  local text = topic.text
  if text ~= nil and text ~= "" then
    parts[#parts + 1] = "\n" .. text
  end
  local see = topic.see or {}
  if #see > 0 then
    parts[#parts + 1] = "\nsee also: " .. table.concat(see, ", ")
  end
  return table.concat(parts, "\n")
end

--- The help of `program` as a whole, as `prog help` prints it: a usage
--- line, then each command with its `about`, under "commands:" in order by
--- name. Where any names a `group`, each group is a section under its
--- title, the sections in order by title, and the commands that name
--- none come last, under "other commands:". Where any command takes
--- options, it ends with a line that says how to ask for a command's.
---
--- `documented` changes that as its fields say ([`Flags.Documented`]): the
--- sections in the order of its `groups` and the commands in its `order`,
--- each listed as typed where `usages` is set, `before` in place of the
--- usage line, its `topics` under "topics:" after the commands, by name,
--- and `after` in place of the last lines. Given at all, and where
--- `commands` holds no `docs`, the index ends with a line that says how to
--- search the documentation, which [`Flags.dispatch`] then answers. One
--- column holds every section's names, topics' among them, and where
--- `width` is given what each does is laid out within it as
--- [`Flags.help`] lays out examples; a width below 1 raises.
---
---     usage: prog <command> [options]
---
---     Counting:
---       count    Counts the lines of each file.
---
---     other commands:
---       version  Says which build this is.
---
---     topics:
---       globs    How a file is named by a pattern.
---
---     `prog help <command or topic>` says more.
--- @param program string What the help calls the program
--- @param commands {string:Command} Each command, by the word that names it
--- @param documented? Documented What the help says beyond the commands
--- @return string The help, without a newline after the last line
function Flags.program_help(program: string, commands: {string:Flags.Command},
                            documented?: Flags.Documented): string
  local wrap = documented and documented.width
  if wrap ~= nil and wrap < 1 then
    error("flags: help's width is not a positive number of columns", 2)
  end
  local names: mut {string} = {}
  local sections: mut {string: mut {Row}} = {}
  local titles: mut {string} = {}
  local every: mut {Row} = {}
  local any_options = false
  for name in pairs(commands) do names[#names + 1] = name end
  -- The commands the caller orders come first, in its order.
  local listed: mut {string: integer} = {}
  for place, name in ipairs(documented and documented.order or {}) do
    if listed[name] == nil then listed[name] = place end
  end
  table.sort(names, function(a: string, b: string): boolean
    local at_a, at_b = listed[a], listed[b]
    if at_a ~= nil and at_b ~= nil then return at_a < at_b end
    if at_a ~= nil or at_b ~= nil then return at_a ~= nil end
    return a < b
  end)
  local usages = documented ~= nil and documented.usages == true
  for _, name in ipairs(names) do
    local command = commands[name]
    if command ~= nil then
      local spec = command.spec
      if spec ~= nil and next(spec) ~= nil then any_options = true end
      local title = command.group or ""
      local row: Row = { head = if usages then typed_line(program, name, command) else shown(name, command) end, about = command.about }
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
  -- The titles the caller orders come first, in its order.
  local placed: mut {string: integer} = {}
  for place, title in ipairs(documented and documented.groups or {}) do
    if placed[title] == nil then placed[title] = place end
  end
  table.sort(titles, function(a: string, b: string): boolean
    local at_a, at_b = placed[a], placed[b]
    if at_a ~= nil and at_b ~= nil then return at_a < at_b end
    if at_a ~= nil or at_b ~= nil then return at_a ~= nil end
    return a < b
  end)
  local topic_rows: mut {Row} = {}
  local topics = documented and documented.topics or {}
  for _, name in ipairs(sorted(keys(topics))) do
    local topic = topics[name]
    local row: Row = { head = name, about = if topic ~= nil then topic.about else nil end }
    topic_rows[#topic_rows + 1] = row
    every[#every + 1] = row
  end
  local width = row_column(every, wrap)
  local lines: mut {string} = {
    documented and documented.before or
      "usage: " .. program .. " <command>" .. (if any_options then " [options]" else "" end),
  }
  local function section(heading: string, rows: {Row})
    lines[#lines + 1] = ""
    lines[#lines + 1] = heading .. ":"
    for _, line in ipairs(row_lines(rows, width, wrap)) do lines[#lines + 1] = line end
  end
  for _, title in ipairs(titles) do
    section(title, sections[title] or {})
  end
  local ungrouped = sections[""]
  if ungrouped ~= nil then
    section(if #titles > 0 then "other commands" else "commands" end, ungrouped)
  end
  if #topic_rows > 0 then
    section("topics", topic_rows)
  end
  local after = documented and documented.after
  if after ~= nil then
    lines[#lines + 1] = ""
    lines[#lines + 1] = after
    return table.concat(lines, "\n")
  end
  if any_options then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Run `" .. program .. " <command> --help` for a command's options."
  end
  if documented ~= nil and commands["docs"] == nil then
    if not any_options then lines[#lines + 1] = "" end
    lines[#lines + 1] = "Run `" .. program .. " docs <words>` to search the documentation, `" .. program ..
      " docs` to list it."
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

--- The program's documentation as [`cosmic.doc`] answers from it: the rows of the program's own store, with each
--- command a field of the pages record documents shown, and searched, with what its help says of it: its usage
--- line, `about`, options and examples. The modules are required here, when
--- a program asks, so one that never asks loads neither; its build carries both all the same.
local function documentation(program: string, commands: {string:Flags.Command},
                             documented: Flags.Documented): Doc.View?, string
  local library = require("cosmic.doc")
  local view, trouble = library.program(require("cosmic.store").databases(), program, nil, documented.pages)
  if view == nil then
    return nil, tostring(trouble)
  end
  local pages = documented.pages
  if pages == nil then
    return view, ""
  end
  local described: mut {Doc.Command} = {}
  for _, name in ipairs(sorted(keys(commands))) do
    local row, row_trouble = library.member(view, pages, name)
    if row == nil then
      return nil, tostring(row_trouble)
    end
    if row is Doc.Entry then
      local command = assert(commands[name], "a name of commands names a command")
      local spec = command.spec
      local options = if spec ~= nil and next(spec) ~= nil then
        table.concat(laid_out(option_rows(spec), documented.width), "\n")
        else
        nil
        end
      local examples: mut {Row} = {}
      local said = called(program, name, command)
      for _, example in ipairs(command.examples or {}) do
        examples[#examples + 1] = {
          head = if example.line ~= "" then said .. " " .. example.line else said end, about = example.about,
        }
      end
      local about = command.about
      described[#described + 1] = {
        name = name, module = row.module, symbol = row.symbol, options = options,
        about = if about ~= nil and about ~= "" then about else nil end,
        usage = typed_line(program, name, command),
        examples = if #examples > 0 then table.concat(laid_out(examples, documented.width or 80), "\n") else nil end,
      }
    end
  end
  view.commands = described
  return view, ""
end

--- The help of the command `name`: what [`Flags.help`] writes of it, then the doc comment of its field of the
--- pages record, where `documented` names one and the field has a comment.
local function command_help(program: string, name: string, commands: {string:Flags.Command},
                            documented?: Flags.Documented): string?, string
  local described = assert(commands[name])
  local help = Flags.help(described, called(program, name, described), documented and documented.width)
  local pages = documented and documented.pages
  if documented == nil or pages == nil then
    return help, ""
  end
  local view, trouble = documentation(program, commands, documented)
  if view == nil then
    return nil, trouble
  end
  local library = require("cosmic.doc")
  local row, row_trouble = library.member(view, pages, name)
  if row == nil then
    return nil, tostring(row_trouble)
  end
  local comment = if row is Doc.Entry then library.shown(row.text) else "" end
  return if comment ~= "" then help .. "\n\n" .. comment else help end, ""
end

--- The help of the `help` command [`Flags.dispatch`] answers itself, which takes a topic too where there are any.
local function help_help(program: string, topics: boolean): string
  local what = if topics then "command or topic" else "command" end
  return "usage: " .. program .. " help [" .. what .. "]\n\n" ..
    "What a " .. what .. " is and how to use it; with none, every command there is."
end

--- The page of the topic `name`: [`Flags.topic_help`]'s, its text read from its guide where it names one. Nil and
--- why where the documentation cannot be read or holds no such guide.
local function topic_page(program: string, name: string, topic: Flags.Topic, commands: {string:Flags.Command},
                          documented: Flags.Documented): string?, string
  local guide = topic.guide
  if guide == nil then
    return Flags.topic_help(topic, name), ""
  end
  local view, trouble = documentation(program, commands, documented)
  if view == nil then
    return nil, trouble
  end
  local text, text_trouble = require("cosmic.doc").guide(view, guide)
  if text == nil then
    return nil, tostring(text_trouble)
  end
  if text is string then
    return Flags.topic_help({ about = topic.about, text = text, see = topic.see }, name), ""
  end
  return nil, "the topic " .. name .. "'s guide, doc/guides/" .. guide .. ".md, is not in the documentation"
end

--- The help of the `docs` command [`Flags.dispatch`] answers itself.
local function docs_help(program: string): string
  return "usage: " .. program .. " docs [words...]\n\n" ..
    "What the program's documentation says of the words: a module or a symbol by its name, or the pages\n" ..
    "that hold the words. With no words, every module there is."
end

--- What `prog docs <words...>` answers: the page [`cosmic.doc`] writes of the words from the program's own
--- documentation, or nil and why when they name and find nothing. It takes no option but `--help`.
local function docs_answer(argv: {string}, from: integer, program: string, commands: {string:Flags.Command},
                           documented: Flags.Documented): Flags.Dispatched?, string
  if Flags.asks_help(argv, from, {}) then
    return { code = 0, help = docs_help(program) }, ""
  end
  local parsed, why = read(argv, from, {}, { "--help" })
  if parsed == nil then
    return nil, "docs: " .. why .. "; usage: " .. program .. " docs [words...]"
  end
  local view, trouble = documentation(program, commands, documented)
  if view == nil then
    return nil, "docs: " .. trouble
  end
  local answer, answer_trouble = require("cosmic.doc").answer(view, parsed.words)
  if answer == nil then
    return nil, "docs: " .. tostring(answer_trouble)
  end
  if not answer.found then
    return nil, "docs: " .. answer.said
  end
  local lines: mut {string} = {}
  for _, line in ipairs(answer.lines) do lines[#lines + 1] = line end
  while lines[#lines] == "" do lines[#lines] = nil end
  return { code = 0, help = table.concat(lines, "\n") }, ""
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
--- command of `commands` ("help" is one, held or not) or topic of
--- `documented`'s, a topic whose `see` names itself or neither, or a
--- topic named "", as a command is, or as an option is, whatever the
--- line: a caller's mistake, met by its first run. The first such
--- command by name is the one named, then the first such topic.
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
--- titles in order, and the rest last under "other commands:", as
--- [`Flags.program_help`] writes it. `help` given more than one word is
--- refused. `prog help help` answers a page of its own, as `prog help docs`
--- does where the program answers `docs`. Where `documented` holds topics,
--- `prog help <topic>` answers [`Flags.topic_help`]'s page, its text read
--- from the program's guide where the topic names one ([`Flags.Topic`]'s
--- `guide`), and a word `help` is given that is neither is refused as "no
--- such command or topic", with the names near it of both, "help" among
--- them, and "docs" where the program answers it.
---
--- A command is run by its name in `commands`, or by the word it says it is
--- typed as ([`Flags.Command`]'s `typed`), and then not by its name: an
--- option's spelling ("--version"), or no word at all, which is the command
--- a first word that names no other runs, that word being the first of its
--- own ("prog notes.txt"), and a line of no words runs it too. With such a command no first word is refused as
--- no command, a mistyped one among them, and a file named "help" is not
--- run. Help calls a command as it is typed, and `help` takes that word or
--- the name. A command's `rest` says from which slot the words are its
--- own, which its spec does not read and its `run` is given as `rest`.
--- Two commands typed alike raise, as does one typed as "help", "-h" or
--- "--help", and a `rest` that begins before the command's first word.
---
--- A command with `subcommands` runs the one the word after it names, as
--- this runs one of `commands`: that one's spec reads the rest of the
--- line, and a refusal names both, with that one's usage ("time: add:
--- --days needs a value; usage: prog time add [options] <time>").
--- `prog help time add`, `prog time help add` and `prog time add --help`
--- answer its help, and `prog time --help` the command's, which lists
--- them. A command with both `subcommands` and a `spec` or a `rest`
--- raises, as does one whose `subcommands` are empty; a subcommand's
--- own record is checked when the line reaches it.
---
--- With `documented`, the program answers from its own documentation, which
--- `cosmic build` carries in it ([`Flags.Documented`]). A command's help
--- ends with the doc comment of its field of the `pages` record. `docs`,
--- where `commands` holds no command of that name, answers what
--- [`cosmic.doc`] writes of the words after it: a module or a symbol the
--- program documents, by name, else the doc comments and guides that hold
--- the words, and the commands whose help does -- their `about`, usage
--- line, options and examples, shown on the command's page -- a misspelled
--- word put right; with no words, every module
--- documented. Words that name and find nothing are refused, as a command
--- that is none is. The program's help says `docs` is there, and orders
--- its sections as `groups` gives them and its commands as `order` does,
--- lists each as it is typed where `usages` is set, and opens and ends
--- with `before` and `after` where they are given, within its `width`. A test of either reads the
--- documentation, so it declares `Test.policy { store_text = true }`.
---
---     local ran, why = Flags.dispatch(argv, 1, commands, "prog")
---     if ran == nil then local _, _ = Fs.put(Fs.stderr, "prog: " .. why .. "\n") return 2 end
---     if ran.help ~= "" then print(ran.help) end
---     return ran.code
--- @param argv {string} The command line
--- @param from integer The slot holding the command
--- @param commands {string:Command} Each command, by the word that names it
--- @param program string What help calls the program ("prog" in `prog build
---   --help`): not read from `argv`, which holds the words after the program's
---   name
--- @param documented Documented | nil Where the program's documentation is and how its help is ordered; nil for a
---   program that answers from its commands' records alone
--- @return Dispatched | nil What the command answered, or the help
--- @return string Why nothing ran, or "" when a command or help did
function Flags.dispatch(argv: {string}, from: integer,
                        commands: {string:Flags.Command}, program: string,
                        documented?: Flags.Documented): Flags.Dispatched?, string
  if next(commands) == nil then
    error("flags: dispatch needs a command to choose among", 2)
  end
  -- The module the program names as its pages, which a run from source answers an error's guidance from.
  if documented ~= nil and documented.pages ~= nil and source_run.script ~= nil then
    source_run.pages = documented.pages
  end
  local topics = documented and documented.topics or {}
  local spelled: mut {string: string} = {}
  for _, held in ipairs(sorted(keys(commands))) do
    local command = commands[held]
    local typed = if command ~= nil then command.typed or held else held end
    local alike = spelled[typed]
    if alike ~= nil then
      error("flags: " .. alike .. " and " .. held .. " are typed alike: " ..
          (if typed ~= "" then typed else "by no word" end), 2)
    end
    spelled[typed] = held
    if typed == "help" and held ~= "help" or typed == "-h" or typed == "--help" then
      error("flags: " .. held .. " is typed as " .. typed .. ", which asks for help", 2)
    end
    local subcommands = if command ~= nil then command.subcommands else nil end
    if subcommands ~= nil and command ~= nil and (command.spec ~= nil or command.rest ~= nil) then
      error("flags: " .. held .. " has subcommands, so it reads no options or rest of its own", 2)
    elseif subcommands ~= nil and next(subcommands) == nil then
      error("flags: " .. held .. "'s subcommands are empty; give none, or one at least", 2)
    end
    local see = if command ~= nil then command.see else nil end
    if see ~= nil then
      for _, other in ipairs(see) do
        local answered = other == "help" or (other == "docs" and documented ~= nil) or topics[other] ~= nil
        if other == held or (commands[other] == nil and not answered) then
          error("flags: " .. held .. "'s see names no other command: " .. other, 2)
        end
      end
    end
  end
  for _, held in ipairs(sorted(keys(topics))) do
    if held == "" then
      error("flags: a topic's name is empty", 2)
    elseif commands[held] ~= nil or spelled[held] ~= nil or held == "help" or held == "docs" then
      error("flags: the topic " .. held .. " is named as a command is", 2)
    elseif held:sub(1, 1) == "-" then
      error("flags: the topic " .. held .. " is named as an option is, which help takes for none", 2)
    end
    local topic = topics[held]
    local guide = if topic ~= nil then topic.guide else nil end
    if guide ~= nil and topic ~= nil and topic.text ~= nil then
      error("flags: the topic " .. held .. " gives both a text and a guide", 2)
    elseif guide ~= nil and (guide == "" or guide:find("[./]") ~= nil) then
      error("flags: the topic " .. held .. "'s guide is no guide's name: " .. guide, 2)
    end
    local see = if topic ~= nil then topic.see else nil end
    if see ~= nil then
      for _, other in ipairs(see) do
        local answered = other == "help" or other == "docs" or topics[other] ~= nil
        if other == held or (commands[other] == nil and not answered) then
          error("flags: the topic " .. held .. "'s see names no other command or topic: " .. other, 2)
        end
      end
    end
  end
  local name = argv[from]
  if name == "--help" or name == "-h" or (name == "help" and commands.help == nil) then -- checked: map_field
    local asked = if name == "help" then argv[from + 1] else nil end
    if asked == "--help" or asked == "-h" then
      asked = nil
    end
    if asked == nil then
      return { code = 0, help = Flags.program_help(program, commands, documented) }, ""
    end
    -- A command is asked about by the word that runs it, or by its name: the command no word runs has no other.
    for _, held in ipairs(sorted(keys(commands))) do
      local other = commands[held]
      if other ~= nil and other.typed == asked and asked ~= "" then asked = held end
    end
    local asked_command = commands[asked]
    local asked_subcommands = if asked_command ~= nil then asked_command.subcommands else nil end
    if asked_command ~= nil and asked_subcommands ~= nil and argv[from + 2] ~= nil then
      -- `prog help cmd sub` is `prog cmd help sub`.
      local line: mut {string} = { "help" }
      for slot, word in ipairs(argv) do
        if slot >= from + 2 then line[#line + 1] = word end
      end
      local answered, why = Flags.dispatch(line, 1, asked_subcommands, called(program, asked, asked_command))
      if answered == nil then
        return nil, asked .. ": " .. why
      end
      return answered, ""
    end
    if argv[from + 2] ~= nil then
      return nil, if next(topics) ~= nil then "help: one command or topic at a time" else "help: one command at a time" end
    end
    if asked_command == nil and asked == "help" then
      return { code = 0, help = help_help(program, next(topics) ~= nil) }, ""
    end
    if asked_command == nil and asked == "docs" and documented ~= nil then
      return { code = 0, help = docs_help(program) }, ""
    end
    local asked_topic = topics[asked]
    if asked_command == nil and asked_topic ~= nil and documented ~= nil then
      local page, page_trouble = topic_page(program, asked, asked_topic, commands, documented)
      if page == nil then
        return nil, "help: " .. page_trouble
      end
      return { code = 0, help = page }, ""
    end
    if asked_command == nil then
      local held: mut {string} = { "help" }
      if documented ~= nil then held[#held + 1] = "docs" end
      for other, command in pairs(commands) do
        local typed = command.typed or other
        held[#held + 1] = if typed ~= "" then typed else other end
      end
      for other in pairs(topics) do held[#held + 1] = other end
      local what = if next(topics) ~= nil then "no such command or topic: " else "no such command: " end
      return nil, what .. asked .. meant(asked, held)
    end
    local asked_help, asked_trouble = command_help(program, asked, commands, documented)
    if asked_help == nil then
      return nil, "help: " .. asked_trouble
    end
    return { code = 0, help = asked_help }, ""
  end
  if name == "docs" and documented ~= nil and commands["docs"] == nil then
    return docs_answer(argv, from + 1, program, commands, documented)
  end
  if name == nil then
    local names: mut {string} = {}
    local defaulted = false
    for known, other in pairs(commands) do
      local typed = other.typed or known
      if typed ~= "" then names[#names + 1] = typed else defaulted = true end
    end
    if not defaulted then
      table.sort(names)
      return nil, "needs a command: " .. table.concat(names, ", ")
    end
  end
  -- A line that names no command runs the one typed by no word, as a first word that names none does.
  name = name or ""
  local command = commands[name]
  -- The slot of the command's first word: after its name, or the word itself where no command is named.
  local first = from + 1
  if command ~= nil and command.typed ~= nil then
    -- A command typed another way is not run by its name in `commands`.
    command = nil
  end
  if command == nil then
    local unnamed: string? = nil
    for _, held in ipairs(sorted(keys(commands))) do
      local other = commands[held]
      if other ~= nil and other.typed == name then
        command, name = other, held
      elseif other ~= nil and other.typed == "" then
        unnamed = held
      end
    end
    if command == nil and unnamed ~= nil then
      command, name, first = commands[unnamed], unnamed, from
    end
  end
  if command == nil then
    local known: mut {string} = { "help" }
    if documented ~= nil and commands["docs"] == nil then known[#known + 1] = "docs" end
    for held, other in pairs(commands) do
      local typed = other.typed or held
      if typed ~= "" then known[#known + 1] = typed end
    end
    return nil, "no such command: " .. name .. meant(name, known)
  end
  -- The words the command keeps are not its spec's to read.
  local own = argv
  local kept: {string} = {}
  local keeps = command.rest
  local at = if keeps ~= nil then keeps(argv, first) else nil end
  if at ~= nil and at < first then
    error("flags: " .. name .. "'s rest begins at slot " .. tostring(at) .. ", before its first word", 2)
  end
  if at ~= nil then
    local before: mut {string} = {}
    local after: mut {string} = {}
    for slot, word in ipairs(argv) do
      if slot < at then before[#before + 1] = word else after[#after + 1] = word end
    end
    own, kept = before, after
  end
  local subcommands = command.subcommands
  if subcommands ~= nil and argv[first] ~= "--help" and argv[first] ~= "-h" then
    -- The word after the command names one of its own, which reads the rest of the line.
    local answered, why = Flags.dispatch(argv, first, subcommands, called(program, name, command))
    if answered == nil then
      -- A line that names none of its subcommands is answered with the command's own usage, naming them; a
      -- refusal by one of them, or by help, ends with its own.
      local named = argv[first]
      local reached = named ~= nil and (subcommands[named] ~= nil or named == "help")
      local usage = if reached then "" else "; " .. Flags.usage(command, called(program, name, command)) end
      return nil, name .. ": " .. why .. usage
    end
    return answered, ""
  end
  local spec = command.spec or {}
  if Flags.asks_help(own, first, spec) then
    local help, help_trouble = command_help(program, name, commands, documented)
    if help == nil then
      return nil, name .. ": " .. help_trouble
    end
    return { code = 0, help = help }, ""
  end
  local parsed, why = read(own, first, spec, { "--help" })
  if parsed == nil then
    local usage_line = Flags.usage(command, called(program, name, command))
    -- A command typed by no word is not named in its refusal: the line never said it.
    local label = if command.typed == "" then "" else name .. ": " end
    return nil, label .. why .. "; " .. usage_line
  end
  local run = command.run
  if run == nil then
    return nil, name .. ": the command has no run"
  end
  if keeps ~= nil then parsed.rest = kept end
  return { code = run(parsed), help = "" }, ""
end

--- Runs the command line `argv`, the words after the program's name, as a
--- program's main does, and answers its exit status. An empty line
--- writes the program's help ([`Flags.program_help`]) to `to.out` and
--- answers [`Flags.REFUSED`], even where a command is typed by no word
--- (which [`Flags.dispatch`] runs for an empty line). Any other line is
--- [`Flags.dispatch`]'s from slot 1: help it answers goes to `to.out`
--- with the status 0, a command answers its own status, and a line it
--- refuses is said on `to.err` with where the commands are listed, and
--- answers [`Flags.REFUSED`]. `to` is [`Flags.std_io`]'s when nil. It
--- raises where [`Flags.dispatch`] does.
---
---     return function(argv: {string}): integer
---       return Flags.main(argv, commands, "prog", documented, Flags.std_io(function(line: string): string
---         return "prog: " .. line
---       end))
---     end
---     -- prog biuld => prog: no such command: biuld; did you mean build?
---     --               prog: `prog help` lists the commands.
--- @param argv {string} The command line
--- @param commands {string:Command} Each command, by the word that names it
--- @param program string What help calls the program
--- @param documented Documented | nil As [`Flags.dispatch`] takes it
--- @param to Io | nil Where it writes
--- @return integer The exit status
function Flags.main(argv: {string}, commands: {string:Flags.Command}, program: string,
                    documented?: Flags.Documented, to?: Flags.Io): integer
  local streams = to or Flags.std_io()
  if argv[1] == nil then
    streams.out(Flags.program_help(program, commands, documented))
    return Flags.REFUSED
  end
  local ran, why = Flags.dispatch(argv, 1, commands, program, documented)
  if ran == nil then
    streams.err(why)
    local listed = if documented ~= nil and documented.topics ~= nil and next(documented.topics) ~= nil
      then "commands and topics" else "commands" end
    streams.err("`" .. program .. " help` lists the " .. listed .. ".")
    return Flags.REFUSED
  end
  if ran.help ~= "" then streams.out(ran.help) end
  return ran.code
end

--- The standard streams: `out` writes a line to standard output as it
--- is, `err` one to standard error as `said` words it where given (the
--- program's name before it, say). A write that fails, as to a closed
--- pipe, is dropped: a command's output has nowhere else to say so.
---
---     local streams = Flags.std_io(function(line: string): string return "prog: " .. line end)
---     streams.err("no such file") -- prog: no such file
--- @param said function | nil How a line on `err` is worded; as it is where nil
--- @return Flags.Io The streams
function Flags.std_io(said?: function(line: string): string): Flags.Io
  return {
    out = function(line: string)
      local _, _ = Fs.put(Fs.stdout, line .. "\n")
    end,
    err = function(line: string)
      local worded = if said ~= nil then said(line) else line end
      local _, _ = Fs.put(Fs.stderr, worded .. "\n")
    end,
  }
end

--- What ends a command, saying why on `err`: `failed` answers
--- [`Flags.FAILED`], `refused` [`Flags.REFUSED`], `undone` [`Flags.UNDONE`].
---
---     local ends = Flags.verdicts(Flags.std_io().err)
---     return ends.refused("give one path") -- 2
--- @param err function Where why is said
--- @return Flags.Verdicts The three
function Flags.verdicts(err: function(line: string)): Flags.Verdicts
  return {
    failed = function(why: string): integer
      err(why)
      return Flags.FAILED
    end,
    refused = function(why: string): integer
      err(why)
      return Flags.REFUSED
    end,
    undone = function(why: string): integer
      err(why)
      return Flags.UNDONE
    end,
  }
end

--- How a message names the file `path`: "standard input" for "-", the path as it is otherwise. A command
--- that writes to `path` names "-" with [`Flags.output_name`].
function Flags.input_name(path: string): string
  return if path == "-" then "standard input" else path end
end

--- How a message names the file `path` a command writes: "standard output" for "-", the path otherwise.
function Flags.output_name(path: string): string
  return if path == "-" then "standard output" else path end
end

--- The Reader over the file `path` names, or over standard input for "-", the word a command line gives
--- for it in place of a file. Standard input that is a terminal is refused, since nothing would end its
--- bytes: nil and "standard input is a terminal; pipe the input in, or name a file". A Reader over
--- standard input borrows the descriptor, which stays open; one over a file closes it at its end, or at
--- `close` ([`Stream.open`]).
---
---     local reader, why = Flags.reader(parsed.words[1] or "-")
--- @param path string The file, or "-"
--- @return Stream.Reader | nil The bytes, to read
--- @return string Why there is none, naming the file
function Flags.reader(path: string): (Stream.Reader) | (nil, string)
  local streams = require("cosmic.stream")
  if path ~= "-" then
    local reader, failure = streams.open(path)
    if reader == nil then return nil, tostring(failure) end
    return reader
  end
  if require("cosmic.proc").is_tty(Fs.stdin) then
    return nil, "standard input is a terminal; pipe the input in, or name a file"
  end
  return streams.from_fd(Fs.stdin)
end

--- The bytes of the file `path` names, read whole, or of all of standard input for "-", which
--- [`Flags.reader`] refuses where it is a terminal. Nil and why, naming the file, where they cannot be
--- read.
---
---     local text, why = Flags.read(parsed.values["--key"])
---     -- cosmic tool --key - < key.pem: the key from standard input
--- @param path string The file, or "-"
--- @return string | nil The bytes
--- @return string Why there are none
function Flags.read(path: string): (string) | (nil, string)
  if path ~= "-" then
    local text, failure = Fs.read(path)
    if text == nil then return nil, tostring(failure) end
    return text
  end
  local reader, why = Flags.reader(path)
  if reader == nil then return nil, why end
  local text, trouble = require("cosmic.stream").read_all(reader)
  if text == nil then return nil, "standard input: " .. tostring(trouble) end
  return text
end

--- Writes `data` whole to the file `path` names, through [`Fs.write_output`] (a new file is renamed into
--- place once complete, standard output or a device is written in place), or to standard output for
--- "-". False and why, naming the file, when the bytes did not all go.
--- @param path string The file, or "-"
--- @param data string The bytes
--- @param mode integer | nil A new file's mode, as [`Fs.write_output`] takes it
--- @return boolean Whether they all went
--- @return string Why not, or "" when they did
function Flags.write(path: string, data: string, mode?: integer): boolean, string
  if path == "-" then
    local wrote, why = Fs.put(Fs.stdout, data)
    if not wrote then return false, "standard output: " .. tostring(why) end
    return true, ""
  end
  local wrote, failure = Fs.write_output(path, data, mode)
  if not wrote then return false, tostring(failure) end
  return true, ""
end

--- The refusal of a command line that gives "-" for standard input more than once among the `names` of
--- `values` (a [`Flags.Parsed`]'s, say), since standard input is read once: "--account and --key both
--- read standard input, which is read once; give one of them a file". "" when at most one does.
---
---     local why = Flags.one_stdin(parsed.values, { "--account", "--key" })
--- @param values {string:string} The paths the line gives, by how a refusal names each ("--key")
--- @param names {string} The names of `values` that are read as files; one `values` lacks is skipped
--- @return string The refusal, or ""
function Flags.one_stdin(values: {string:string}, names: {string}): string
  local named: mut {string} = {}
  for _, name in ipairs(names) do
    if values[name] == "-" then named[#named + 1] = name end
  end
  if #named < 2 then return "" end
  table.sort(named)
  local listed = table.concat(named, ", ", 1, #named - 1) .. " and " .. assert(named[#named], "two at least")
  if #named == 2 then
    return listed .. " both read standard input, which is read once; give one of them a file"
  end
  return listed .. " all read standard input, which is read once; give each but one a file"
end

return Flags
