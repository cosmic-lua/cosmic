--- Worked examples for [`cosmic.flags`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Flags = require("cosmic.flags")

local Example = {}

--- A command's options and paths: a flag, a value after "=", and a word.
function Example.parse()
  local argv = { "fix", "--check", "--jobs=2", "a.tl" }
  local got = assert(Flags.parse(argv, 2, { ["--check"] = false, ["--jobs"] = true }))
  print(got.set["--check"], got.values["--jobs"], got.words[1])
  assert(got.set["--check"] and got.values["--jobs"] == "2" and got.words[1] == "a.tl")
  local _, why = Flags.parse({ "fix", "--chek" }, 2, { ["--check"] = false })
  print(why)
  assert(why == "no such option: --chek")
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
  local ran, why = Flags.dispatch({ [0] = "prog", "build", "-vj2", "all" }, 1, commands)
  assert(ran ~= nil and ran.code == 0 and ran.help == "", why)
  ran, why = Flags.dispatch({ [0] = "prog", "biuld" }, 1, commands)
  print(why)
  assert(ran == nil and why == "no such command: biuld")
end

--- A program whose first word is a command -- `ledger report may.csv
--- --month 2026-05` -- as a `cmd/ledger/main.tl` would be written:
--- [`Flags.dispatch`] reads the command from `argv[1]` and parses the
--- words after it with that command's spec, so `got.words[1]` is the
--- file, never the command, and options may come before the words or
--- after them. `Flags.parse(argv, 1, spec)` reads no command: in such a
--- program it would take "report" for the file.
function Example.subcommands()
  local asked: {string} = {}
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
        asked[#asked + 1] = got.words[1] .. " " .. (got.values["--month"] or "every month")
        return 0
      end,
    },
    add = {
      about = "Adds an amount to a ledger file.",
      usage = "<file> <amount>",
      run = function(got: Flags.Parsed): integer
        asked[#asked + 1] = "add " .. table.concat(got.words, " ")
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
    "no such command: rport",
    "report: no such option: --mnth",
    "needs a command: add, report",
  }, "\n"))
  assert(main({ "--help" }) == 0)
  assert(main({ "report", "--help" }) == 0)
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
  assert(got.values["--jobs"] == "4" and got.set["-v"])
end

return Example
