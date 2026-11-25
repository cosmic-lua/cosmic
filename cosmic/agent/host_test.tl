--- What a snippet reads of the library from the binary's docs, with no call to the agent.
local Host = require("cosmic.agent.host")
local Test = require("cosmic.test")

-- Host.docs reads the docs of the store, which a test holds none of.
Test.policy{ store_text = true }

local Fs = require("cosmic.fs")

--- The modules are a line each, the start of what each is for, but the agent's own and tooling's.
local function test_the_modules_a_snippet_may_require_are_listed_short()
  local modules = Host.modules({
    { module = "cosmic.fs", text = "Files and\n directories.", closed = "" },
    { module = "cosmic.web.route", text = "Routes.", closed = "" },
    { module = "cosmic.test", text = "Tests.", closed = "" },
    { module = "cosmic.long", text = string.rep("word ", 40), closed = "" },
    { module = "cosmic.bare", text = "", closed = "" },
    { module = "cosmic.comma", text = string.rep("a", 80) .. " b, ccccccccccc", closed = "" },
    { module = "cosmic.wide", text = string.rep("\u{e9}", 60), closed = "" },
  })
  local lines: mut {string} = {}
  for line in modules:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(#lines == 5 and lines[1] == "cosmic.fs: Files and directories." and lines[3] == "cosmic.bare", modules)
  assert(lines[4] == "cosmic.comma: " .. string.rep("a", 80) .. " b...", modules)
  -- With no space to cut at, the cut ends at a character's end.
  assert(lines[5] == "cosmic.wide: " .. string.rep("\u{e9}", 44) .. "...", modules)
  assert(#lines[2] <= 90 + #"cosmic.long: " and lines[2]:sub(-7) == "word...", modules)
end

--- With no index given, the modules are this binary's own, read from its docs: a line each, sorted, none of the
--- agent's own or tooling's; and a prompt that offers run lists them so.
local function test_the_modules_are_read_from_the_binarys_own_docs()
  local modules = Host.modules()
  assert(modules:find("host: modules: ", 1, true) == nil, modules)
  local names: mut {string} = {}
  for name in modules:gmatch("cosmic%.([%w_]+)[^\n]*") do names[#names + 1] = name end
  local seen: mut {string: boolean} = {}
  for _, name in ipairs(names) do seen[name] = true end
  -- A test's store holds the docs of its import closure alone: what this one requires is among them.
  assert(seen["fs"] == true and seen["json"] == true, modules)
  assert(seen["agent"] == nil and seen["test"] == nil and seen["store"] == nil, modules)
  local sorted = Host.sort(names)
  assert(table.concat(sorted, " ") == table.concat(names, " "), modules)
  local Prompt = require("cosmic.agent.prompt")
  local Tools = require("cosmic.agent.tools")
  local built = Prompt.build("/w", {}, { tools = { assert(Tools.find(Tools.all(), "run")) } })
  assert(built:find("<cosmic_modules>", 1, true) ~= nil and built:find(modules, 1, true) ~= nil, built)
end

--- Where the docs cannot be read, or nothing is asked, docs say so, as a string to print, and raise nothing.
local function test_docs_say_why_there_are_none()
  assert(Host.docs("zzqqxx"):find("host: docs: ", 1, true) == 1)
  assert(Host.docs("  ") == "host: docs: name a module, a function or words to search for")
end

--- The helpers a snippet composes, named for the commands they do as: find, cat, grep, sed, wc, sort, uniq; each
--- raises where it fails, so a snippet needs no assert.
local function test_the_helpers_do_as_their_commands_do(tmp: string)
  assert(Fs.mkdirs(tmp .. "/d/sub"))
  Host.write(tmp .. "/d/a.tl", { "local x = 1", "-- TODO one" })
  Host.write(tmp .. "/d/sub/b.tl", "-- TODO two\nlast")
  Host.write(tmp .. "/d/c.md", {})
  local files = Host.find(tmp .. "/d", ".tl")
  assert(#files == 2 and files[1] == tmp .. "/d/a.tl" and files[2] == tmp .. "/d/sub/b.tl", table.concat(files, " "))
  assert(#Host.find(tmp .. "/d") == 3 and Host.cat(tmp .. "/d/c.md") == "")
  local lines = Host.lines(tmp .. "/d/sub/b.tl")
  assert(#lines == 2 and lines[2] == "last")
  assert(Host.wc(tmp .. "/d/a.tl") == 2 and Host.wc(tmp .. "/d/sub/b.tl") == 1 and Host.wc(tmp .. "/d/c.md") == 0)
  local hits = Host.grep("TODO", files, true)
  assert(#hits == 2 and hits[2].path == files[2] and hits[2].line == 1 and hits[2].text == "-- TODO two")
  assert(#Host.grep("^local %a+", files) == 1)
  -- sed replaces every match, a capture or plain text, and leaves a file of none alone.
  assert(Host.sed(tmp .. "/d/a.tl", "(%a+) = 1", "%1 = 2") == 1 and Host.cat(tmp .. "/d/a.tl") == "local x = 2\n-- TODO one\n")
  assert(Host.sed(tmp .. "/d/a.tl", "x = 2.", "%y", true) == 0)
  assert(Host.sed(tmp .. "/d/a.tl", "x = 2", "50% x", true) == 1 and Host.lines(tmp .. "/d/a.tl")[1] == "local 50% x")
  Test.raises(function() Host.sed(tmp .. "/d/a.tl", "[a", "x") end, "host: sed: ")
  local ranked = Host.top(Host.uniq({ "b", "a", "b", "c", "a" }), 2)
  assert(#ranked == 2 and ranked[1].key == "a" and ranked[1].count == 2 and ranked[2].key == "b")
  assert(table.concat(Host.sort({ "b", "a" }), ",") == "a,b")
  local by_path = Host.sort({ "f0 b.md", "0a a.md", "0a c.md" }, function(l: string): string
    return l:match("%S+$") or l
  end)
  assert(table.concat(by_path, ",") == "0a a.md,f0 b.md,0a c.md", table.concat(by_path, ","))
  -- Records sort by a key, those of one key in their order, and the list given is left as it was.
  local items = { { id = "b", n = 1 }, { id = "a", n = 2 }, { id = "b", n = 3 } }
  local sorted = Host.sort_by(items, function(i: { id: string, n: integer }): string return i.id end)
  assert(sorted[1]!.n == 2 and sorted[2]!.n == 1 and sorted[3]!.n == 3 and items[1]!.n == 1 and #sorted == 3)
  sorted[#sorted + 1] = { id = "c", n = 4 }
  assert(#Host.top({ a = 1 }, -1) == 0 and #Host.find(tmp .. "/d/", "") == 3 and Host.find(tmp .. "/d/")[1] == files[1])
  Host.write(tmp .. "/d/crlf.txt", "a\r\nb\r\n")
  assert(Host.lines(tmp .. "/d/crlf.txt")[1] == "a" and assert(Host.grep("a$", { tmp .. "/d/crlf.txt" })[1]).text == "a")
  Test.raises(function() Host.grep("[a", files) end, "host: grep: [a: ")
  Test.raises(function() Host.grep("x", { tmp .. "/nope" }) end, "host: grep: ")
  Test.raises(function() Host.cat(tmp .. "/nope") end, "host: cat: ")
  Test.raises(function() Host.find(tmp .. "/nope") end, "host: find: ")
  -- grep finds no line past the last newline; sed anchors at each line, and keeps CRLF and the last newline.
  assert(#Host.grep("^$", { tmp .. "/d/crlf.txt" }) == 0)
  Host.write(tmp .. "/d/two.txt", "a\r\na\nb")
  assert(Host.sed(tmp .. "/d/two.txt", "^a$", "c") == 2 and Host.cat(tmp .. "/d/two.txt") == "c\r\nc\nb")
  assert(Host.exists(tmp .. "/d/two.txt") and not Host.exists(tmp .. "/d/nope") and not Host.exists(tmp .. "/nope/x"))
end

--- sqlite runs a statement or, with no values, a script, and raises "host: sqlite: " where it fails; sha256
--- prints a file's hex digest.
local function test_sqlite_and_sha256_do_as_their_commands_do(tmp: string)
  local db = tmp .. "/n.db"
  assert(#Host.sqlite(db, "create table t (k text, v); insert into t values ('a', 1.5)") == 0)
  assert(#Host.sqlite(db, "insert into t values (?1, ?2)", { "b", false }) == 0)
  local rows = Host.sqlite(db, "select k, v from t order by k")
  assert(#rows == 2 and rows[1]["k"] == "a" and rows[1]["v"] == 1.5 and rows[2]["v"] == 0)
  local bad = Test.raises(function() Host.sqlite(db, "select ?1", { { 1 } }) end, "value 1 is a table")
  assert(bad:find("host: sqlite: ", 1, true) ~= nil, bad)
  Test.raises(function() Host.sqlite(db, "create table u (x); nonsense") end, "host: sqlite: ")
  Test.raises(function() Host.sqlite(tmp .. "/nope/x.db", "select 1") end, "host: sqlite: ")
  Host.write(tmp .. "/x.txt", "abc")
  assert(Host.sha256(tmp .. "/x.txt") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  Test.raises(function() Host.sha256(tmp .. "/nope") end, "host: sha256: ")
end
