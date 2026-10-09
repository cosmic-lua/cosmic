--- The cases of the verbs' command-line contract (build/verbs_tool_test.tl)
--- that read this program's store beyond their module's closure: help
--- and docs, which read every module's docs, and the verbs run in this
--- process ([`build.invoke`]), which read every module's rows.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local verb_cases = require("build.verb_cases")
local verb_list = require("build.verb_list")
local verbs_fixture = require("build.verbs_fixture")
local String = require("cosmic.string")
local build_paths = require("build.paths")

--- The tool itself, whose core a program `build` writes runs on, the CA
--- bundle `refresh` reads, and what bin/zig reads to find or fetch zig.
--- `store`: the verbs it runs in this process ([`build.invoke`]) read
--- every module's rows.
Test.policy{
  profiles = { "cosmic" },
  grants = {
    { path = "o/bin", letters = "rx" },
    { path = "vendor/cacert/cacert.pem", letters = "r" },
    { path = "o/cosmic.db", letters = "r" },
  },
  env = { "ALL_PROXY", "COSMIC_BOOTSTRAP", "COSMIC_BOOTSTRAP_ATTEMPTS", "COSMIC_BOOTSTRAP_VERIFY",
    "COSMIC_ZIG", "COSMIC_ZIG_CACHE", "COSMIC_ZIG_GLOBAL_CACHE", "CURL_CA_BUNDLE", "HTTPS_PROXY",
    "HTTP_PROXY", "NO_PROXY", "SSL_CERT_DIR", "SSL_CERT_FILE", "all_proxy", "http_proxy",
    "https_proxy", "no_proxy" },
}

--- `root`'s build directory ([`build.paths`]), made, with `root` made
--- first where it is not there yet.
local function build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

--- The vendored bundle, which `refresh` reads with no network; the
--- tree's root is where a test module loads.
local bundle = assert(Fs.absolute("vendor/cacert/cacert.pem"))

local cases = verb_cases.cases(bundle)

--- Asserts each verb whose cases run in this process passes and fails its case,
--- each run ending in its verdict line.
local function ends_in_a_verdict(tmp: string)
  local tree = verbs_fixture.write_tree(tmp)
  -- `db` passes once the tree has a database.
  local _ = verbs_fixture.expect(tree, "build", { "build" }, 0)
  for _, verb in ipairs(Cli.order) do
    local case = cases[verb]
    if case ~= nil and verbs_fixture.in_process(verb) then
      local _ = verbs_fixture.expect(tree, verb, case.pass, 0)
      local fail = case.fail
      if fail is {string} then
        local dir = case.fail_in ~= nil and tmp .. "/" .. case.fail_in or tree
        local _ = verbs_fixture.expect(dir, verb, fail, 1)
      end
    end
  end
end

local function test_every_verb_ends_in_a_verdict(tmp: string)
  ends_in_a_verdict(tmp)
end

local function test_help_takes_a_verb(tmp: string)
  local _ = verbs_fixture.expect(tmp, "help", { "help", "test" }, 0)
  local _ = verbs_fixture.expect(tmp, "help", { "test", "--help" }, 0)
  local _ = verbs_fixture.expect(tmp, "help", { "db", "-h" }, 0)
  local _ = verbs_fixture.expect(tmp, "help", { "help", "--standalone" }, 0)
  -- Anywhere on the verb's line, before a "--".
  local late = verbs_fixture.expect(tmp, "help", { "test", "good", "--jobs", "2", "--help" }, 0).stdout or ""
  assert(late:find("`cosmic test", 1, true), late)
  local _ = verbs_fixture.expect(tmp, "help", { "sql", "SELECT 1", "-h" }, 0)
  -- Not after a "--": there "-h" is the statement, which fails as SQL.
  local _ = verbs_fixture.expect(tmp, "sql", { "sql", "--", "-h" }, 1)
  local refused = verbs_fixture.expect(tmp, "help", { "help", "tset" }, 2)
  local out = refused.stdout or ""
  assert(out:find("help: FAIL (no such verb: tset)", 1, true), out)
end

local function test_help_lists_each_option_a_verb_parses(tmp: string)
  for verb, command in pairs(Cli.verbs) do
    local options = command.spec or {}
    local out = verbs_fixture.expect(tmp, "help", { "help", verb }, 0).stdout or ""
    for name, entry in pairs(options) do
      assert(entry is Flags.Option and entry.about ~= nil and entry.about ~= "",
        verb .. " " .. name .. " says nothing of what it does")
      local shown = entry.value ~= nil and name .. " <" .. entry.value .. ">" or name
      assert(out:find("\n  " .. shown .. " ", 1, true), verb .. ": " .. out)
    end
  end
  -- `cosmic docs` asked nothing lists the modules there are.
  local index = verbs_fixture.expect(tmp, "docs", { "docs" }, 0).stdout or ""
  assert(index:find("\ncosmic.fs  ", 1, true), index)
  -- It shows the options under the verb's field too.
  local docs = verbs_fixture.expect(tmp, "docs", { "docs", "Cli.test" }, 0).stdout or ""
  assert(docs:find("\n  options:\n", 1, true) and docs:find("\n    --jobs <n> ", 1, true) and
      docs:find("\n    --all ", 1, true), docs)
  -- And a search finds a verb by what one of its options does, though
  -- no doc comment says it: "launcher" is only in `build --host`'s.
  local found = verbs_fixture.expect(tmp, "docs", { "docs", "native", "launcher" }, 0).stdout or ""
  assert(found:find("Cli.build", 1, true), found)
  -- Its words may be split between the prose and the options.
  local split = verbs_fixture.expect(tmp, "docs", { "docs", "timeout", "processor" }, 0).stdout or ""
  assert(split:find("Cli.test", 1, true), split)
  -- A word joined by "_" is those words in a row, as FTS5 reads it, and
  -- the verb's own name counts, as it does in the index.
  local joined = verbs_fixture.expect(tmp, "docs", { "docs", "COSMIC_TEST_TIMEOUT" }, 0).stdout or ""
  assert(joined:find("Cli.test", 1, true), joined)
  local named = verbs_fixture.expect(tmp, "docs", { "docs", "cli", "launcher" }, 0).stdout or ""
  assert(named:find("Cli.build", 1, true), named)
  -- A word neither holds finds no verb.
  local none = verbs_fixture.expect(tmp, "docs", { "docs", "launcher", "zzzqqq" }, 1).stdout or ""
  assert(not none:find("Cli.build", 1, true), none)
end

local function test_help_of_a_verb_is_that_verb_alone(tmp: string)
  local one = verbs_fixture.expect(tmp, "help", { "help", "test" }, 0).stdout or ""
  assert(one:find("`cosmic test ", 1, true), one)
  assert(not one:find("`cosmic fix ", 1, true), one)
  assert(not one:find("cosmic -- a runtime", 1, true), one)
  local e = verbs_fixture.expect(tmp, "help", { "help", "-e" }, 0).stdout or ""
  assert(e:find("`cosmic -e", 1, true), e)
  assert(not e:find("`cosmic test ", 1, true), e)
  -- Every verb's text opens with its synopsis, then what it takes and
  -- how it ends.
  for _, verb in ipairs(Cli.order) do
    local out = verbs_fixture.expect(tmp, "help", { "help", verb }, 0).stdout or ""
    assert(out:sub(1, 8) == "`cosmic ", verb .. ": " .. out)
    assert(out:find("\n\nTakes ", 1, true) or out:find("\n\nPrints only", 1, true), verb .. ": " .. out)
  end
end

--- Bare `cosmic help` is an index, not the text of every verb.
local function test_help_is_a_short_index_of_every_verb(tmp: string)
  local all = verbs_fixture.expect(tmp, "help", { "help" }, 0).stdout or ""
  local lines = 0
  for _ in all:gmatch("\n") do lines = lines + 1 end
  assert(lines < 60, lines .. " lines:\n" .. all)
  for _, verb in ipairs(Cli.order) do
    local command = Cli.verbs[verb]
    assert(all:find(command.usage .. "  ", 1, true), verb .. " is not in the index:\n" .. all)
    assert(all:find(command.about, 1, true), verb .. " has no line:\n" .. all)
  end
  -- A usage follows the word that names its verb, or what is typed
  -- where a verb has no word of its own.
  for _, line in ipairs({ "\n  cosmic test [selector...]  ", "\n  cosmic <file.tl> [args]  ",
      "\n  cosmic --standalone <file.tl> [args]  ", "\n  cosmic -e '<chunk>' [args]  ",
      "\n  cosmic --version  ", "\n  cosmic bom  " }) do
    assert(all:find(line, 1, true), line .. ":\n" .. all)
  end
  for _, pointer in ipairs({ "cosmic help <verb>", "cosmic help exit", "cosmic docs <module>",
      "cosmic.removed" }) do
    assert(all:find(pointer, 1, true), pointer .. ":\n" .. all)
  end
  assert(not all:find("--jobs", 1, true), all)
  local bare = verbs_fixture.expect(tmp, "help", {}, 0).stdout or ""
  assert(all:find("\nhelp: PASS %(22 verbs") or all:find("\nhelp: PASS (", 1, true), all)
  assert(all:find("(print stays)", 1, true), all)
  local asked = verbs_fixture.expect(tmp, "help", { "help", "--help" }, 0).stdout or ""
  assert(asked:find("\nMore:\n", 1, true), asked)
  assert(bare:find("\nMore:\n", 1, true) and bare:find("\nQuick tools:\n", 1, true), bare)
end

--- The index names the guides to start from, each by a `cosmic docs`
--- command that shows it, ahead of the verbs.
local function test_help_starts_from_the_guides(tmp: string)
  local all = verbs_fixture.expect(tmp, "help", { "help" }, 0).stdout or ""
  local verbs = assert(all:find("\nRunning code:\n", 1, true), all)
  for _, guide in ipairs({ "doc.guides.quickstart", "doc.guides.project" }) do
    local at = all:find("`cosmic docs " .. guide .. "`", 1, true)
    assert(at ~= nil and at < verbs, guide .. ":\n" .. all)
    local page = verbs_fixture.expect(tmp, "docs", { "docs", guide }, 0).stdout or ""
    assert(String.starts_with(page, guide .. " ("), page)
  end
end

--- `cosmic help test` says what a test is and how to run one before
--- how verdicts and compiles are kept and how the tree is found.
local function test_help_of_test_leads_with_writing_one(tmp: string)
  local out = verbs_fixture.expect(tmp, "help", { "help", "test" }, 0).stdout or ""
  local caching = assert(out:find("COSMIC_VERDICT_CACHE", 1, true), out)
  for _, first in ipairs({ "`<name>_test.tl`", "`<name>_example.tl`", "doc/guides/",
      "\n    local function test_", "tally_test.tl:test_words" }) do
    local at = out:find(first, 1, true)
    assert(at ~= nil and at < caching, first .. ":\n" .. out)
  end
  assert(caching < assert(out:find("COSMIC_TREE", 1, true), out), out)
end

--- What each verb's spec says of it (build/verb_spec.tl) is what `cosmic
--- help <verb>` prints: what it takes, and how a bare verb exits.
local function test_help_prints_what_each_spec_says(tmp: string)
  for _, spec in ipairs(verb_list.specs()) do
    local out = verbs_fixture.expect(tmp, "help", { "help", spec.name }, 0).stdout or ""
    -- Help wraps what the specs say, so it is read with its lines joined.
    local joined = " " .. out:gsub("%s+", " ") .. " "
    assert(joined:find(spec.takes, 1, true), spec.name .. ": takes")
    if spec.exits ~= nil then
      assert(joined:find(spec.exits, 1, true), spec.name .. ": exits")
    end
  end
  local exit = verbs_fixture.expect(tmp, "help", { "help", "exit" }, 0).stdout or ""
  local joined = " " .. exit:gsub("%s+", " ") .. " "
  for _, spec in ipairs(verb_list.specs()) do
    if spec.exits ~= nil then
      assert(joined:find(spec.exits, 1, true), spec.name .. ": exits")
    end
  end
end

--- A tree with two programs and a module that reads a file.
local function write_programs(tmp: string): string
  local tree = tmp .. "/programs"
  local main = "return function(): integer\n  return 0\nend\n"
  for _, name in ipairs({ "hi", "bye" }) do
    assert(Fs.mkdirs(tree .. "/cmd/" .. name))
    assert(Fs.write(tree .. "/cmd/" .. name .. "/main.tl", main))
  end
  assert(Fs.mkdirs(tree .. "/lib"))
  assert(Fs.write(tree .. "/lib/reader.tl", "local Fs = require(\"cosmic.fs\")\nreturn Fs.read\n"))
  return tree
end

local function test_build_takes_paths_to_narrow_it(tmp: string)
  local tree = write_programs(tmp)
  local one = verbs_fixture.expect(tree, "build", { "build", "./cmd/hi/" }, 0).stdout or ""
  assert(one:find(build_dir(tree) .. "/bin/hi,", 1, true) and not one:find("bye", 1, true), one)
  assert(Fs.exists(build_dir(tree) .. "/bin/hi"))
  assert(not Fs.exists(build_dir(tree) .. "/bin/bye"))
  local refused = verbs_fixture.expect(tree, "build", { "build", "cmd/hi", "lib" }, 1)
  assert((refused.stderr or ""):find("no cmd/<name>/main.tl under lib", 1, true), refused.stderr)
  local _ = verbs_fixture.expect(tree, "build", { "build", "cmd" }, 0)
  assert(Fs.exists(build_dir(tree) .. "/bin/bye"))
end

local function test_uses_takes_paths_to_narrow_it(tmp: string)
  local tree = write_programs(tmp)
  local _ = verbs_fixture.expect(tree, "build", { "build" }, 0)
  local narrowed = verbs_fixture.expect(tree, "uses", { "uses", "Fs.read", "lib" }, 0).stdout or ""
  assert(narrowed:find("lib/reader.tl:2:", 1, true), narrowed)
  assert(not narrowed:find("cosmic/", 1, true), narrowed)
  local all = verbs_fixture.expect(tree, "uses", { "uses", "Fs.read" }, 0).stdout or ""
  assert(all:find("lib/reader.tl:2:", 1, true), all)
  local none = verbs_fixture.expect(tree, "uses", { "uses", "Fs.read", "cmd" }, 1).stdout or ""
  assert(none:find("nothing under cmd refers to 'Fs.read'", 1, true), none)
end

--- `uses` marks each link, and names what it links to: a symbol by its
--- module and name, a module by its name alone, a file by its path and
--- anchor.
local function test_uses_prints_each_link_it_finds(tmp: string)
  local tree = write_programs(tmp)
  assert(Fs.write(tree .. "/notes.md", "# Usage\n"))
  assert(Fs.write(tree .. "/lib/waves.tl", table.concat({
    "--- Waves at people.",
    "local record waves",
    "end",
    "",
    "--- Waves.",
    "function waves.go(): string",
    "  return \"\"",
    "end",
    "",
    "return waves",
    "",
  }, "\n")))
  assert(Fs.write(tree .. "/lib/links.tl", table.concat({
    "local waves = require(\"lib.waves\")",
    "-- [`waves.go`], [`lib.waves`] and [the notes](../notes.md#usage).",
    "return waves.go",
    "",
  }, "\n")))
  local _ = verbs_fixture.expect(tree, "build", { "build" }, 0)
  local function printed(query: string): string
    return verbs_fixture.expect(tree, "uses", { "uses", query }, 0).stdout or ""
  end
  local go = printed("waves.go")
  assert(go:find("lib/links.tl:2: link lib.waves go\n", 1, true), go)
  assert(go:find("lib/links.tl:3: lib.waves go\n", 1, true), go)
  local module = printed("lib.waves")
  assert(module:find("lib/links.tl:2: link lib.waves\n", 1, true), module)
  assert(printed("waves"):find("lib/links.tl:2: link lib.waves\n", 1, true))
  local notes = printed("notes.md#usage")
  assert(notes:find("lib/links.tl:2: link notes.md#usage\n", 1, true), notes)
end

--- The verdict counts one file as one file.
local function test_fix_says_one_file_not_one_files(tmp: string)
  local tree = verbs_fixture.write_tree(tmp)
  local one = verbs_fixture.expect(tree, "fix", { "fix", "good/ok_test.tl" }, 0).stdout or ""
  assert(one:find("fix: PASS (1 file, 0 fixed", 1, true), one)
  local two = verbs_fixture.expect(tree, "fix",
    { "fix", "good/ok_test.tl", "bad/no_test.tl" }, 0).stdout or ""
  assert(two:find("fix: PASS (2 files, 0 fixed", 1, true), two)
end

local function test_db_takes_paths_to_narrow_it(tmp: string)
  local tree = write_programs(tmp)
  local _ = verbs_fixture.expect(tree, "build", { "build" }, 0)
  local narrowed = verbs_fixture.expect(tree, "db", { "db", "./lib/" }, 0).stdout or ""
  assert(narrowed:find("rows about lib in 2 databases", 1, true), narrowed)
  -- lib/reader.tl is one module and one staged file.
  assert(narrowed:find("\n +1  modules\n"), narrowed)
  assert(narrowed:find("\n +1  files\n"), narrowed)
  -- And one row of `parsed`, a table keyed only by its source's hash.
  assert(narrowed:find("\n +1  parsed\n"), narrowed)
  assert(not narrowed:find("builds, latest first", 1, true), narrowed)
  assert(not narrowed:find("pages", 1, true), narrowed)
  local whole = verbs_fixture.expect(tree, "db", { "db" }, 0).stdout or ""
  assert(whole:find("in 2 databases", 1, true) and whole:find("builds, latest first", 1, true),
    whole)
  local none = verbs_fixture.expect(tree, "db", { "db", "nowhere" }, 1).stdout or ""
  assert(none:find("no row is about nowhere", 1, true), none)
end

--- `sql` reads o/ and nothing else: it never lists a directory of the
--- tree, and never checks the tool is as new as the tree, which would
--- stage it, not even after refusing its command line. Here that check
--- would fail: the directory is cosmic's own tree, structurally, and
--- its working database will not open.
local function test_sql_never_stages_the_tree(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/importer.tl", ""))
  assert(build_dir(tmp))
  local garbage = string.rep("not a database. ", 16)
  assert(Fs.write(build_dir(tmp) .. "/build.db", garbage))
  local staged = verbs_fixture.expect(tmp, "db", { "db" }, 1)
  assert((staged.stderr or ""):find("file is not a database", 1, true), staged.stderr)
  -- Every listing `sql` makes, through [`cosmic.sys`]'s shared table,
  -- which `Fs` lists through: it runs in-process.
  local listed: {string} = {}
  local calls = sys as {string:any}
  local readdir = calls.readdir as function(any...): any...
  calls.readdir = function(...: any): any...
    local given: any = ...
    if given is string then
      local here, _ = sys.getcwd()
      listed[#listed + 1] = given:sub(1, 1) == "/" and given or (here or "") .. "/" .. given
    end
    return readdir(...)
  end
  local ok, asked = pcall(function(): string
    local said = verbs_fixture.expect(tmp, "sql", { "sql", "SELECT 1" }, 0).stdout or ""
    local _ = verbs_fixture.expect(tmp, "sql", { "sql", "--no-such-flag" }, 2)
    return said
  end)
  calls.readdir = readdir
  assert(ok, tostring(asked))
  assert((asked as string):find("^1\n1\n"), asked as string)
  -- A path may be named resolved: /var/... is /private/var/... on macOS.
  local real = assert(Fs.absolute(tmp))
  for _, path in ipairs(listed) do
    local under = String.starts_with(path, tmp) or String.starts_with(path, real)
    assert(not under, "sql listed " .. path)
  end
  assert(Fs.read(build_dir(tmp) .. "/build.db") == garbage)
  local names = assert(Fs.list(build_dir(tmp)))
  assert(#names == 1, table.concat(names, " "))
end

--- `db` counts the closures' stores under o/stores, and not the store of
--- no module beside them (build/test.tl's `base_name`).
local function test_db_counts_the_closure_stores_alone(tmp: string)
  local tree = write_programs(tmp)
  local _ = verbs_fixture.expect(tree, "build", { "build" }, 0)
  assert(Fs.mkdirs(build_dir(tree) .. "/stores"))
  assert(Fs.write(build_dir(tree) .. "/stores/" .. ("a"):rep(64) .. ".db", "abc"))
  assert(Fs.write(build_dir(tree) .. "/stores/base-" .. ("b"):rep(64) .. ".db", "defgh"))
  local whole = verbs_fixture.expect(tree, "db", { "db" }, 0).stdout or ""
  assert(whole:find("1 closure store, 3 bytes", 1, true), whole)
end
