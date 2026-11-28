--- Makes the shop tree a repository of six commits on `main`, with cosmic.git and no git program: the setup of
--- shop-git-commit and shop-git-history, run in the tree as `$tool - < shop.tl`. Names and dates are fixed, so
--- every copy's commits have the same oids.
local Fs = require("cosmic.fs")
local Git = require("cosmic.git")

local who: Git.Person = { name = "Eval", email = "eval@example.com", time = 1767323045, tz = "+0000" }
local files = assert(Fs.walk("."))
assert(Fs.mkdirs(".git/objects"))
assert(Fs.mkdirs(".git/refs/heads"))
assert(Fs.write(".git/HEAD", "ref: refs/heads/main\n"))
assert(Fs.write(".git/config", "[core]\n\trepositoryformatversion = 0\n\tbare = false\n" ..
    "[user]\n\tname = Eval\n\temail = eval@example.com\n"))
local repo = assert(Git.open("."))

local function commit(paths: {string}, message: string)
  assert(repo:add(paths))
  assert(repo:commit({ message = message, author = who, committer = who }))
end

local function note(path: string, line: string)
  assert(Fs.append(path, line .. "\n"))
end

commit(files, "shop: first tree")
note("money.tl", "-- Amounts are whole cents.")
commit({ "money.tl" }, "money: say what an amount is")
note("text.tl", "-- Widths are in bytes.")
commit({ "text.tl" }, "text: say what a width is")
note("catalog.tl", "-- Money.format writes the cents.")
commit({ "catalog.tl" }, "catalog: name the money format")
note("money.tl", "-- Parse refuses three decimals.")
note("report.tl", "-- Totals use money.")
commit({ "money.tl", "report.tl" }, "money and report: note the rules")
note("report.tl", "-- Rows are one product each.")
commit({ "report.tl" }, "report: say what a row is")
