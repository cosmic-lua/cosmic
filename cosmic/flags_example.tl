--- Worked examples for [`cosmic.flags`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Flags = require("cosmic.flags")

local Example = {} -- checked: literal_needs_type

--- A command's options and paths: a flag, a value after "=", and a word.
function Example.parse()
  local argv = { "fix", "--check", "--jobs=2", "a.tl" }
  local got = assert(Flags.parse(argv, 2, { ["--check"] = false, ["--jobs"] = true }))
  print(got.set["--check"], got.values["--jobs"], got.words[1])
  assert(got.set["--check"] == true and got.values["--jobs"] == "2" and got.words[1] == "a.tl")
  local _, why = Flags.parse({ "fix", "--chek" }, 2, { ["--check"] = false })
  print(why)
  assert(why == "no such option: --chek; did you mean --check?")
end

--- An option the line must give: `required` in its [`Flags.Option`]. A line
--- without it is refused by name, and [`Flags.dispatch`] adds the command's
--- usage line, so a program that prints the refusal shows how to type it.
function Example.required()
  local out: Flags.Option = { value = "path", about = "where to write", required = true }
  local _, why = Flags.parse({ "put", "a.txt" }, 2, { ["--out"] = out })
  print(why)
  assert(why == "--out is required")
  local put: Flags.Command = { usage = "[options] <file>", spec = { ["--out"] = out } }
  local commands: {string:Flags.Command} = { put = put }
  local ran, refusal = Flags.dispatch({ "put", "a.txt" }, 1, commands, "prog")
  print(refusal)
  assert(ran == nil and refusal == "put: --out is required; usage: prog put [options] <file>")
  print(Flags.help(put, "prog put"))
end

--- A program with commands: each parses the rest of the line with its
--- own spec, and one-letter options cluster ("-vj2" is "-v -j 2").
function Example.dispatch()
  local commands: {string:Flags.Command} = {
    build = {
      spec = { ["-v"] = false, ["-j"] = true },
      run = function(got: Flags.Parsed): integer
        print(got.set["-v"], got.values["-j"], got.words[1])
        return 0
      end,
    },
  }
  local ran, why = Flags.dispatch({ "build", "-vj2", "all" }, 1, commands, "prog")
  assert(ran ~= nil and ran.code == 0 and ran.help == "", why)
  ran, why = Flags.dispatch({ "biuld" }, 1, commands, "prog")
  print(why)
  assert(ran == nil and why == "no such command: biuld; did you mean build?")
end

--- A program whose first word is a command -- `ledger report may.csv
--- --month 2026-05` -- as a `cmd/ledger/main.tl` would be written:
--- [`Flags.dispatch`] reads the command from `argv[1]` and parses the
--- words after it with that command's spec, so `got.words[1]` is the
--- file, never the command, and options may come before the words or
--- after them. The program's name, "ledger", is an argument of its own,
--- for help to show; `argv` holds only the words after it. `Flags.parse(argv,
--- 1, spec)` reads no command: in such a program it would take "report"
--- for the file.
function Example.subcommands()
  local asked: mut {string} = {}
  local commands: {string:Flags.Command} = {
    report = {
      about = "Totals a ledger file.",
      usage = "[options] <file>",
      spec = { ["--month"] = { value = "yyyy-mm", about = "only this month" } },
      run = function(got: Flags.Parsed): integer
        if #got.words ~= 1 then
          asked[#asked + 1] = "report needs one file"
          return 2
        end
        table.insert(asked, assert(got.words[1]) .. " " .. (got.values["--month"] or "every month"))
        return 0
      end,
    },
    add = {
      about = "Adds an amount to a ledger file.",
      usage = "<file> <amount>",
      run = function(got: Flags.Parsed): integer
        table.insert(asked, "add " .. table.concat(got.words, " "))
        return 0
      end,
    },
  }
  -- The program's entry: what it returns is its exit status.
  local function main(argv: {string}): integer
    local ran, why = Flags.dispatch(argv, 1, commands, "ledger")
    if ran == nil then
      -- A program writes this to standard error: Log.new("ledger"):complain(why).
      asked[#asked + 1] = why
      return 2
    end
    if ran.help ~= "" then print(ran.help) end
    return ran.code
  end
  assert(main({ "report", "may.csv" }) == 0)
  assert(main({ "report", "--month", "2026-05", "may.csv" }) == 0)
  assert(main({ "report", "may.csv", "--month=2026-05" }) == 0)
  assert(main({ "add", "may.csv", "12" }) == 0)
  assert(main({ "report" }) == 2)
  assert(main({ "rport", "may.csv" }) == 2)
  assert(main({ "report", "--mnth", "5", "may.csv" }) == 2)
  assert(main({}) == 2)
  print(table.concat(asked, "\n"))
  assert(table.concat(asked, "\n") == table.concat({
    "may.csv every month",
    "may.csv 2026-05",
    "may.csv 2026-05",
    "add may.csv 12",
    "report needs one file",
    "no such command: rport; did you mean report?",
    "report: no such option: --mnth; did you mean --month?; usage: ledger report [options] <file>",
    "needs a command: add, report",
  }, "\n"))
  assert(main({ "--help" }) == 0)
  assert(main({ "report", "--help" }) == 0)
end

--- A program that words its own refusal of a mistyped name:
--- [`Flags.nearest`] answers the names near it, by the rule the refusals of
--- [`Flags.parse`] and [`Flags.dispatch`] end "did you mean" by, and none
--- for a word near nothing.
function Example.nearest()
  local profiles = { "debug", "release", "release-small" }
  local function refusal(word: string): string
    local near = Flags.nearest(word, profiles)
    if #near == 0 then
      return "no profile " .. word .. "; one of " .. table.concat(profiles, ", ")
    end
    return "no profile " .. word .. "; the nearest: " .. table.concat(near, ", ")
  end
  print(refusal("relaese"))
  print(refusal("rel"))
  print(refusal("fast"))
  assert(refusal("relaese") == "no profile relaese; the nearest: release")
  assert(refusal("rel") == "no profile rel; the nearest: release, release-small")
  assert(refusal("fast") == "no profile fast; one of debug, release, release-small")
end

--- Help written from a command: each option described by a
--- [`Flags.Option`], and the command's usage line and what it does.
function Example.help()
  local spec: {string:boolean | Flags.Option} = {
    ["--jobs"] = { value = "n", about = "run n at once" },
    ["-v"] = { about = "say more" },
  }
  local count: Flags.Command = {
    spec = spec,
    usage = "[options] <file>...",
    about = "Counts the lines of each file.",
  }
  local help = Flags.help(count, "prog count")
  print(help)
  assert(help == table.concat({
    "usage: prog count [options] <file>...",
    "",
    "Counts the lines of each file.",
    "",
    "options:",
    "  --jobs <n>  run n at once",
    "  -v          say more",
  }, "\n"))
  local got = assert(Flags.parse({ "--jobs", "4", "-v" }, 1, spec))
  assert(got.values["--jobs"] == "4" and got.set["-v"] == true)
end

--- A command's page with lines to type and the commands beside it, and a
--- program's help in sections: `examples`, `see` and `group` in each
--- [`Flags.Command`]. [`Flags.dispatch`] raises for a `see` that names no
--- other command.
function Example.pages()
  local commands: {string:Flags.Command} = {
    report = {
      about = "Totals a ledger file.",
      usage = "[options] <file>",
      spec = { ["--month"] = { value = "yyyy-mm", about = "only this month" } },
      examples = {
        { line = "may.csv", about = "every month's total" },
        { line = "--month 2026-05 may.csv", about = "one month's" },
      },
      see = { "add" },
      group = "Reading",
    },
    add = { about = "Adds an amount to a ledger file.", usage = "<file> <amount>", group = "Writing" },
    version = { about = "Says which build this is." },
  }
  local page = assert(Flags.dispatch({ "help", "report" }, 1, commands, "ledger")).help
  print(page)
  assert(page == table.concat({
    "usage: ledger report [options] <file>",
    "",
    "Totals a ledger file.",
    "",
    "options:",
    "  --month <yyyy-mm>  only this month",
    "",
    "examples:",
    "  ledger report may.csv                  every month's total",
    "  ledger report --month 2026-05 may.csv  one month's",
    "",
    "see also: add",
  }, "\n"))
  local index = assert(Flags.dispatch({ "--help" }, 1, commands, "ledger")).help
  print(index)
  assert(index == table.concat({
    "usage: ledger <command> [options]",
    "",
    "Reading:",
    "  report   Totals a ledger file.",
    "",
    "Writing:",
    "  add      Adds an amount to a ledger file.",
    "",
    "other commands:",
    "  version  Says which build this is.",
    "",
    "Run `ledger <command> --help` for a command's options.",
  }, "\n"))
end

return Example -- checked: export_not_declared
