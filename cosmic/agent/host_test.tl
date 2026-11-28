--- What a snippet reads of the library from the binary's docs, with no call to the agent.
local Host = require("cosmic.agent.host")
local Test = require("cosmic.test")

-- Host.docs reads the docs of the store, which a test holds none of.
Test.policy{ store_text = true }

local Fs = require("cosmic.fs")

--- The modules are a line each, the first clause of what each is for, but the agent's own and tooling's.
local function test_the_modules_a_snippet_may_require_are_listed_short()
  local modules = Host.modules({
    { module = "cosmic.fs", text = "Files and\n directories.", closed = "" },
    { module = "cosmic.web.route", text = "Routes.", closed = "" },
    { module = "cosmic.test", text = "Tests.", closed = "" },
    { module = "cosmic.long", text = string.rep("word ", 40), closed = "" },
    { module = "cosmic.bare", text = "", closed = "" },
    { module = "cosmic.comma", text = string.rep("a", 80) .. " b, ccccccccccc", closed = "" },
    { module = "cosmic.wide", text = string.rep("\u{e9}", 60), closed = "" },
    { module = "cosmic.csv", text = "CSV and TSV text as records and rows: an RFC 4180 reader. More.", closed = "" },
    { module = "cosmic.key", text = "Keys: keys that sign and keys that check -- and more.", closed = "" },
  })
  local lines: mut {string} = {}
  for line in modules:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(#lines == 7 and lines[1] == "cosmic.fs: Files and directories" and lines[3] == "cosmic.bare", modules)
  assert(lines[4] == "cosmic.comma: " .. string.rep("a", 58) .. "...", modules)
  -- With no space to cut at, the cut ends at a character's end.
  assert(lines[5] == "cosmic.wide: " .. string.rep("\u{e9}", 29) .. "...", modules)
  assert(#lines[2] <= 60 + #"cosmic.long: " and lines[2]:sub(-7) == "word...", modules)
  -- The first clause past its first few words: a short head keeps what follows it.
  assert(lines[6] == "cosmic.csv: CSV and TSV text as records and rows", modules)
  assert(lines[7] == "cosmic.key: Keys: keys that sign and keys that check", modules)
end

--- Where the docs cannot be read, or nothing is asked, docs say so, as a string to print, and raise nothing.
local function test_docs_say_why_there_are_none()
  assert(Host.docs("zzqqxx"):find("host: docs: ", 1, true) == 1)
  assert(Host.docs("  ") == "host: docs: name a module, a function or words to search for")
end

--- Host.check reads a data file by its type, as its module reads it, and raises naming where it does not read; a
--- type it has no check for is refused by name. These need no checker, so they run outside a worker.
local function test_check_reads_a_data_file_by_its_type(tmp: string)
  Host.write(tmp .. "/good.json", "{\"a\": [1, 2]}\n")
  Host.check(tmp .. "/good.json")
  Host.write(tmp .. "/bad.json", "{\"a\": [1, 2,]}\n")
  Test.raises(function() Host.check(tmp .. "/bad.json") end, "host: check: " .. tmp .. "/bad.json does not pass: json: ")
  Host.write(tmp .. "/rows.jsonl", "{\"a\": 1}\n{\"b\": 2}\n")
  Host.check(tmp .. "/rows.jsonl")
  Host.write(tmp .. "/rows.ndjson", "{\"a\": 1}\n{\"b\"\n")
  Test.raises(function() Host.check(tmp .. "/rows.ndjson") end, "rows.ndjson does not pass: ")
  -- A CSV file is read as Csv.table reads it: every record as wide as the header.
  Host.write(tmp .. "/good.csv", { "name,n", "a,1", "\"b,c\",2" })
  Host.check(tmp .. "/good.csv")
  Host.write(tmp .. "/short.csv", { "name,n", "a,1", "b" })
  Test.raises(function() Host.check(tmp .. "/short.csv") end, "short.csv does not pass: ")
  Host.write(tmp .. "/open.CSV", { "name,n", "\"a,1" })
  Test.raises(function() Host.check(tmp .. "/open.CSV") end, "open.CSV does not pass: ")
  Host.write(tmp .. "/good.tsv", { "name\tn", "a,b\t1" })
  Host.check(tmp .. "/good.tsv")
  -- A type with no check is refused by name before any read; a dotted directory gives its file no type.
  Test.raises(function() Host.check(tmp .. "/notes.txt") end, "notes.txt: no check for this type; it checks .tl, .json")
  Test.raises(function() Host.check(tmp .. "/a.json/Makefile") end, "Makefile: no check for this type")
  Test.raises(function() Host.check(tmp .. "/none.json") end, "host: read: ")
end

--- The helpers a snippet composes, named for the commands they do as: find, read, edit, grep, sed, wc, sort, uniq; each
--- raises where it fails, so a snippet needs no assert.
local function test_the_helpers_do_as_their_commands_do(tmp: string)
  assert(Fs.mkdirs(tmp .. "/d/sub"))
  Host.write(tmp .. "/d/a.tl", { "local x = 1", "-- TODO one" })
  Host.write(tmp .. "/d/sub/b.tl", "-- TODO two\nlast")
  Host.write(tmp .. "/d/c.md", {})
  local files = Host.find(tmp .. "/d", ".tl")
  assert(#files == 2 and files[1] == tmp .. "/d/a.tl" and files[2] == tmp .. "/d/sub/b.tl", table.concat(files, " "))
  assert(#Host.find(tmp .. "/d") == 3 and Host.read(tmp .. "/d/c.md") == "")
  local lines = Host.lines(tmp .. "/d/sub/b.tl")
  assert(#lines == 2 and lines[2] == "last")
  local hits = Host.grep("TODO", files, true)
  assert(#hits == 2 and hits[2].path == files[2] and hits[2].line == 1 and hits[2].text == "-- TODO two")
  assert(#Host.grep("^local %a+", files) == 1)
  assert(#Host.find(tmp .. "/d/", "") == 3 and Host.find(tmp .. "/d/")[1] == files[1])
  Host.write(tmp .. "/d/crlf.txt", "a\r\nb\r\n")
  assert(Host.lines(tmp .. "/d/crlf.txt")[1] == "a" and assert(Host.grep("a$", { tmp .. "/d/crlf.txt" })[1]).text == "a")
  -- Host.write writes text: raw bytes (a digest) are refused, and nothing is written.
  Test.raises(function() Host.write(tmp .. "/d/raw.txt", "ok\255") end, "byte 3 is not UTF-8 text")
  assert(not Fs.status(tmp .. "/d/raw.txt")!.exists)
  Host.write(tmp .. "/d/utf8.txt", "caf\u{E9}")
  Test.raises(function() Host.grep("[a", files) end, "host: grep: [a: ")
  Test.raises(function() Host.grep("x", { tmp .. "/nope" }) end, "host: grep: ")
  Test.raises(function() Host.read(tmp .. "/nope") end, "host: read: ")
  Test.raises(function() Host.find(tmp .. "/nope") end, "host: find: ")
  -- grep finds no line past the last newline.
  assert(#Host.grep("^$", { tmp .. "/d/crlf.txt" }) == 0)
  -- edit replaces text that is in the file once, keeps CRLF, and changes nothing where any edit misses.
  Host.write(tmp .. "/d/e.txt", "one teh\r\ntwo\r\n")
  assert(Host.edit(tmp .. "/d/e.txt", { { old = "teh", new = "the" }, { old = "two", new = "2" } }) == 2)
  assert(Host.read(tmp .. "/d/e.txt") == "one the\r\n2\r\n", Host.read(tmp .. "/d/e.txt"))
  Test.raises(function()
    Host.edit(tmp .. "/d/e.txt", { { old = "one", new = "1" }, { old = "nope", new = "x" } })
  end,
    "host: edit: Could not find edits[2] in " .. tmp .. "/d/e.txt. The old must match exactly")
  Test.raises(function() Host.edit(tmp .. "/d/e.txt", { { old = "\n", new = "" } }) end, "Found more than one occurrence")
  Test.raises(function() Host.edit(tmp .. "/d/nope", { { old = "a", new = "b" } }) end, "host: edit: ")
  assert(Host.read(tmp .. "/d/e.txt") == "one the\r\n2\r\n")
  Test.raises(function()
    Host.edit(tmp .. "/d/e.txt", { { old = "one", new = "1" }, { old = "one the", new = "x" } })
  end,
    "Two edits overlap")
  Test.raises(function() Host.edit(tmp .. "/d/e.txt", {}) end, "at least one replacement")
  -- A list built up is typed with Host.Replacement; a link's file is edited, and the link kept.
  local edits: mut {Host.Replacement} = {}
  edits[#edits + 1] = { old = "2", new = "two" }
  assert(Fs.symlink("e.txt", tmp .. "/d/link.txt"))
  assert(Host.edit(tmp .. "/d/link.txt", edits) == 1 and Host.read(tmp .. "/d/e.txt") == "one the\r\ntwo\r\n")
  local target, _ = Fs.readlink(tmp .. "/d/link.txt")
  assert(target == "e.txt", target)
end

--- A snippet reads and changes a repository through Host.git_*, with no git program: a commit of one file leaves the
--- other changes alone, a diff is the working tree against HEAD, and the files of `.git` are not written.
local function test_git_calls_commit_one_file_and_guard_dot_git(tmp: string)
  local sys = require("cosmic.sys")
  local Git = require("cosmic.git")
  local root = tmp .. "/repo"
  assert(Fs.mkdirs(root .. "/.git/objects"))
  assert(Fs.mkdirs(root .. "/.git/refs/heads"))
  assert(Fs.write(root .. "/.git/HEAD", "ref: refs/heads/main\n"))
  assert(Fs.write(root .. "/.git/config", "[core]\n\trepositoryformatversion = 0\n\tbare = false\n" ..
      "[user]\n\tname = Test\n\temail = test@example.com\n"))
  assert(Fs.write(root .. "/a.txt", "one\n"))
  assert(Fs.write(root .. "/b.txt", "two\n"))
  local who: Git.Person = { name = "Test", email = "test@example.com", time = 1767225900, tz = "+0000" }
  local repo = assert(Git.open(root))
  assert(repo:add({ "a.txt", "b.txt" }))
  assert(repo:commit({ message = "first", author = who, committer = who }))
  local here = assert(sys.getcwd())
  assert(sys.chdir(root))
  local ok, why = pcall(function()
    Host.write("a.txt", "one\nmore\n")
    Host.write("b.txt", "two\nmore\n")
    Host.write("c.txt", "new\n")
    local status = Host.git_status()
    assert(#status.unstaged == 2 and status.untracked[1] == "c.txt", "status")
    local diff = Host.git_diff({ "a.txt" })
    assert(diff:find("+more", 1, true) ~= nil and diff:find("a/a.txt", 1, true) ~= nil and
        diff:find("b.txt", 1, true) == nil, diff)
    Host.git_add({ "a.txt" })
    local oid = Host.git_commit("a: add more")
    local log = Host.git_log(2)
    assert(#log == 2 and log[1]!.oid == oid and log[1]!.message == "a: add more\n", "log")
    local after = Host.git_status()
    assert(#after.staged == 0 and #after.unstaged == 1 and after.unstaged[1]!.path == "b.txt", "left alone")
    local raised, message = pcall(Host.write, ".git/config", "[alias]\n")
    assert(raised == false and tostring(message):find("inside .git", 1, true) ~= nil, tostring(message))
    raised, message = pcall(Host.edit, "sub/../.git/hooks/pre-commit", { { old = "a", new = "b" } })
    assert(raised == false and tostring(message):find("inside .git", 1, true) ~= nil, tostring(message))
  end)
  assert(sys.chdir(here))
  assert(ok, tostring(why))
end
