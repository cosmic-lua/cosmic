--- The cases of the verbs' command-line contract (build/verbs_tool_test.tl)
--- that read this program's store beyond their module's closure: help
--- and docs, which read every module's docs, and the verbs run in this
--- process (`build.invoke`), which read every module's rows.

local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local observations = require("build.filesystem_observations")
local verbs_fixture = require("build.verbs_fixture")

--- The tool itself, whose core a program `build` writes runs on, the CA
--- bundle `refresh` reads, and what bin/zig reads to find or fetch zig.
--- `store`: the verbs it runs in this process (`build.invoke`) read
--- every module's rows.
Test.needs{
  reads = { "vendor/cacert/cacert.pem" },
  env = { "ALL_PROXY", "COSMIC_BOOTSTRAP", "COSMIC_BOOTSTRAP_ATTEMPTS", "COSMIC_BOOTSTRAP_VERIFY",
    "COSMIC_ZIG", "COSMIC_ZIG_CACHE", "COSMIC_ZIG_GLOBAL_CACHE", "CURL_CA_BUNDLE", "HTTPS_PROXY",
    "HTTP_PROXY", "NO_PROXY", "SSL_CERT_DIR", "SSL_CERT_FILE", "all_proxy", "http_proxy",
    "https_proxy", "no_proxy" },
  tool = true,
  store = true,
}

local function test_every_verb_ends_in_a_verdict(tmp: string)
  verbs_fixture.ends_in_a_verdict(tmp, verbs_fixture.in_process)
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
  for verb, options in pairs(Cli.options) do
    local out = verbs_fixture.expect(tmp, "help", { "help", verb }, 0).stdout or ""
    for name, entry in pairs(options) do
      assert(entry is Flags.Option and entry.about ~= nil and entry.about ~= "",
        verb .. " " .. name .. " says nothing of what it does")
      local shown = entry.value ~= nil and name .. " <" .. entry.value .. ">" or name
      assert(out:find("\n  " .. shown .. " ", 1, true), verb .. ": " .. out)
    end
  end
  local all = verbs_fixture.expect(tmp, "help", { "help" }, 0).stdout or ""
  assert(all:find("\n  --jobs <n> ", 1, true), all)
  -- `cosmic docs` shows them under the verb's field too.
  -- Asked nothing, it lists the modules there are.
  local index = verbs_fixture.expect(tmp, "docs", { "docs" }, 0).stdout or ""
  assert(index:find("\ncosmic.fs  ", 1, true), index)
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
  local all = verbs_fixture.expect(tmp, "help", { "help" }, 0).stdout or ""
  assert(all:find("`cosmic test ", 1, true), all)
  assert(all:find("`cosmic fix ", 1, true), all)
  local e = verbs_fixture.expect(tmp, "help", { "help", "-e" }, 0).stdout or ""
  assert(e:find("`cosmic -e", 1, true), e)
  assert(not e:find("`cosmic test ", 1, true), e)
  -- Every verb's help is one entry, its synopsis first: one paragraph
  -- before the verdict, where the whole surface is a blank line apart.
  for _, verb in ipairs(Cli.order) do
    local out = verbs_fixture.expect(tmp, "help", { "help", verb }, 0).stdout or ""
    local body = out:match("^(.-)\n+help: ") or ""
    assert(body:sub(1, 8) == "`cosmic " and not body:find("\n\n", 1, true), verb .. ": " .. out)
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
  assert(one:find("o/bin/hi,", 1, true) and not one:find("bye", 1, true), one)
  assert(Fs.exists(tree .. "/o/bin/hi"))
  assert(not Fs.exists(tree .. "/o/bin/bye"))
  local refused = verbs_fixture.expect(tree, "build", { "build", "cmd/hi", "lib" }, 1)
  assert((refused.stderr or ""):find("no cmd/<name>/main.tl under lib", 1, true), refused.stderr)
  local _ = verbs_fixture.expect(tree, "build", { "build", "cmd" }, 0)
  assert(Fs.exists(tree .. "/o/bin/bye"))
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

local function test_db_takes_paths_to_narrow_it(tmp: string)
  local tree = write_programs(tmp)
  local _ = verbs_fixture.expect(tree, "build", { "build" }, 0)
  local narrowed = verbs_fixture.expect(tree, "db", { "db", "./lib/" }, 0).stdout or ""
  assert(narrowed:find("rows about lib in 2 databases", 1, true), narrowed)
  -- lib/reader.tl is one module and one staged file.
  assert(narrowed:find("\n +1  modules\n"), narrowed)
  assert(narrowed:find("\n +1  files\n"), narrowed)
  -- and one row of `parsed`, a table keyed only by its source's hash.
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
  assert(Fs.mkdirs(tmp .. "/o"))
  local garbage = string.rep("not a database. ", 16)
  assert(Fs.write(tmp .. "/o/build.db", garbage))
  local staged = verbs_fixture.expect(tmp, "db", { "db" }, 1)
  assert((staged.stderr or ""):find("file is not a database", 1, true), staged.stderr)
  local asked = ""
  local c = observations.capture(function()
    asked = verbs_fixture.expect(tmp, "sql", { "sql", "SELECT 1" }, 0).stdout or ""
    local _ = verbs_fixture.expect(tmp, "sql", { "sql", "--no-such-flag" }, 2)
  end)
  assert(c.ok, tostring(c.produced))
  assert(asked:find("^1\n1\n"), asked)
  -- Observed paths are resolved: /var/... is /private/var/... on macOS.
  local real = assert(Fs.absolute(tmp))
  for _, read in ipairs(c.reads) do
    local under = read.path:sub(1, #tmp) == tmp or read.path:sub(1, #real) == real
    assert(not (read.kind == "d" and under), "sql listed " .. read.path)
  end
  assert(Fs.read(tmp .. "/o/build.db") == garbage)
  local names = assert(Fs.list(tmp .. "/o"))
  assert(#names == 1, table.concat(names, " "))
end
