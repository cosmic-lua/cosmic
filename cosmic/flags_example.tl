--- Worked examples for `cosmic.flags`, shown by `cosmic docs` under the
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

--- Help written from the spec: each option described by a
--- `Flags.Option`, and the program's usage line and what it does.
function Example.help()
  local spec: {string:boolean | Flags.Option} = {
    ["--jobs"] = { value = "n", about = "run n at once" },
    ["-v"] = { about = "say more" },
  }
  local help = Flags.help("count [options] <file>...", spec, "Counts the lines of each file.")
  print(help)
  assert(help == table.concat({
    "usage: count [options] <file>...",
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
