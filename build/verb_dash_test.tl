--- The "-" convention over every verb ([`cosmic.cli`]): an option whose value is a file or a path takes "-" for
--- standard input or output ([`Flags.Option`]'s `dash`), and a usage that names a file word says `|-` beside it,
--- unless the tables below say why it cannot. A new option or word that reads or writes a file meets the
--- convention, or gives its reason here.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")

--- Each option that names a file or a path and takes no "-", as "<verb> [<subcommand>...] <option>", with why.
local no_dash <const>: {string:string} = {
  ["agent ask --mcp"] = "the agent reads its prompt from standard input",
  ["agent chat --mcp"] = "chat reads its prompts from standard input",
  ["agent resume --mcp"] = "the agent reads its prompt from standard input",
  ["agent rpc --mcp"] = "rpc speaks over standard input and output",
  ["cache trim compiles --restored"] = "a SQLite database, which is opened by path",
  ["lsp --socket"] = "a Unix socket to listen on, not a file to read",
  ["refresh -o"] = "standard output takes the report of what changed; - is refused",
  ["release get -o"] = "an executable, renamed into place once verified",
  ["release launcher -o"] = "an executable, renamed into place once verified",
  ["release pin -o"] = "an executable, renamed into place once verified",
  ["sandbox --read"] = "a grant of a path to the sandbox, not a file this reads",
  ["sandbox --run"] = "a grant of a path to the sandbox, not a file this reads",
  ["sandbox --write"] = "a grant of a path to the sandbox, not a file this writes",
  ["sql --at"] = "a path into a JSON document, not a file",
  ["tailscale cert --socket"] = "the daemon's Unix socket",
  ["tailscale file get --socket"] = "the daemon's Unix socket",
  ["tailscale file list --socket"] = "the daemon's Unix socket",
  ["tailscale file send --socket"] = "the daemon's Unix socket",
  ["tailscale file targets --socket"] = "the daemon's Unix socket",
  ["tailscale ping --socket"] = "the daemon's Unix socket",
  ["tailscale status --socket"] = "the daemon's Unix socket",
  ["tailscale whois --socket"] = "the daemon's Unix socket",
}

--- Each command whose usage names a file word with no `|-` beside it, as "<verb> [<subcommand>...]", with why.
local no_dash_word <const>: {string:string} = {
  ["release launcher"] = "it writes its pin beside the launcher, as <file>.pin",
  ["standalone"] = "`cosmic -` runs standard input, with no tree, as --standalone runs a file",
  ["json"] = "its path is a JSONPath into the value, not a file",
  ["build"] = "paths of the tree, which it builds",
  ["db"] = "paths of the tree, whose rows it shows",
  ["fix"] = "paths of the tree, laid out in place",
  ["uses"] = "paths of the tree, searched",
  ["todos"] = "paths of the tree, searched",
  ["cache trim compiles"] = "a SQLite database, changed in place",
  ["cache trim verdicts"] = "SQLite databases, changed in place",
  ["archive create"] = "the archive's kind is read from its name, and its paths are packed as a tree",
}

--- Whether an option's value names a file or a path.
local function names_a_file(value: string): boolean
  return value == "file" or value == "path" or value == "PATH"
end

--- Each command of `command`, itself first, by its name ("tailscale file send").
local function walk(name: string, command: Flags.Command, out: mut {string:Flags.Command})
  out[name] = command
  for sub, inner in pairs(command.subcommands or {}) do walk(name .. " " .. sub, inner, out) end
end

local function commands(): {string:Flags.Command}
  local out: mut {string:Flags.Command} = {}
  for _, verb in ipairs(Cli.order) do
    local command = Cli.verbs[verb]
    if command ~= nil then walk(verb, command, out) end
  end
  return out
end

local function test_every_file_option_takes_a_dash_or_says_why_not()
  local seen: mut {string:boolean} = {}
  for name, command in pairs(commands()) do
    for option, entry in pairs(command.spec or {}) do
      if entry is Flags.Option and entry.value ~= nil and names_a_file(assert(entry.value)) then
        local key = name .. " " .. option
        seen[key] = true
        assert(entry.dash ~= nil or no_dash[key] ~= nil, key .. " names a " .. tostring(entry.value) ..
            ": give it `dash`, reading or writing it with Flags.read or Flags.write, or say why not in no_dash")
        assert(entry.dash == nil or no_dash[key] == nil, key .. " takes \"-\", so no_dash should not name it")
      end
    end
  end
  for key in pairs(no_dash) do
    assert(seen[key] == true, "no_dash names " .. key .. ", which is no option of a file or path")
  end
end

--- Whether a usage word, its marks taken off, names a file: "file", "file.tl", "path", "PATH", "sums", or an
--- output's name ("out.tar.gz").
local function file_word(first: string): boolean
  return first == "file" or first:match("^file%.") ~= nil or first == "path" or first == "PATH" or first == "sums" or
    first:match("^out%.") ~= nil
end

local function test_every_file_word_takes_a_dash_or_says_why_not()
  local seen: mut {string:boolean} = {}
  for name, command in pairs(commands()) do
    local before = ""
    for raw in (command.usage or ""):gmatch("%S+") do
      -- The value of an option is the option's, which the test above holds.
      local valued = before:gsub("^[%[%(]+", ""):sub(1, 1) == "-" and before:find("[%]%)]$") == nil
      local bare = raw:gsub("[%[%]<>%(%)]", ""):gsub("%.%.%.$", "")
      local first = assert(bare:match("^[^|]*"), "a match at worst empty")
      if not valued and file_word(first) and raw:find("|-", 1, true) == nil then
        seen[name] = true
        assert(no_dash_word[name] ~= nil, name .. "'s usage names " .. raw .. " with no |-: take \"-\" " ..
            "for it, or say why not in no_dash_word")
      end
      before = raw
    end
  end
  for name in pairs(no_dash_word) do
    assert(seen[name] == true, "no_dash_word names " .. name .. ", whose usage names no file without |-")
  end
end

local function test_help_says_what_a_dash_is()
  local rows = Flags.options({
    ["--in"] = { value = "file", about = "read it", dash = "input" },
    ["--out"] = { value = "file", about = "write it", dash = "output" },
  })
  assert(rows:find("read it (-: standard input)", 1, true) ~= nil, rows)
  assert(rows:find("write it (-: standard output)", 1, true) ~= nil, rows)
end

local function test_two_dashes_are_refused()
  assert(Flags.one_stdin({ ["--a"] = "-", ["--b"] = "x" }, { "--a", "--b", "--c" }) == "")
  local why = Flags.one_stdin({ ["--a"] = "-", ["--b"] = "-" }, { "--b", "--a" })
  assert(why == "--a and --b both read standard input, which is read once; give one of them a file", why)
  local three = Flags.one_stdin({ ["--a"] = "-", ["--b"] = "-", ["--c"] = "-" }, { "--a", "--b", "--c" })
  assert(three:find("^%-%-a, %-%-b and %-%-c all read") ~= nil, three)
end

local function test_names_say_which_stream()
  assert(Flags.input_name("-") == "standard input")
  assert(Flags.output_name("-") == "standard output")
  assert(Flags.input_name("a.txt") == "a.txt")
end

local function test_read_and_write_a_file(tmp: string)
  local path = tmp .. "/x.txt"
  local wrote, why = Flags.write(path, "hello")
  assert(wrote, why)
  local text, _ = Flags.read(path)
  assert(text == "hello", tostring(text))
  local none, trouble = Flags.read(tmp .. "/missing")
  assert(none == nil and trouble:find("missing", 1, true) ~= nil, trouble)
end

local function test_a_spool_keeps_standard_input_in_a_file_until_closed()
  local kept: string
  do
    local spool <close> = assert(Flags.spool("bytes", "stdin.db"))
    kept = spool.path
    assert(kept:find("/stdin.db$") ~= nil, kept)
    local text, _ = Flags.read(kept)
    assert(text == "bytes", tostring(text))
  end
  local Fs = require("cosmic.fs")
  local status = assert(Fs.status(kept))
  assert(not status.exists, kept .. " is left after the spool closed")
end
