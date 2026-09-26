--- `test.verdict_key` is what a test's cached verdict stands or falls on:
--- a wrong key could let a broken test's old, unrelated verdict answer for
--- it, silently skipping it forever. These pin the two ways that could
--- happen -- two different inputs hashing to the same key, and a changed
--- read not being noticed -- directly against the key-building function
--- itself, without needing a compiled tree or a work database to reach it
--- through.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")
local test = require("build.test")
local type Declared = require("build.inputs").Declared

--- The environment a worker is given, which a key over a variable reads.
local _inputs: Declared = { env = { "*" } }

local function test_selection_is_exact_or_at_a_directory_boundary()
  assert(test.matches("build.test_test", "build.test_test", "build/test_test.tl"))
  assert(test.matches("build/test_test.tl", "build.test_test", "build/test_test.tl"))
  assert(test.matches("./build", "build.test_test", "build/test_test.tl"))
  assert(test.matches("./build/", "build.test_test", "build/test_test.tl"))
  assert(test.matches(".", "build.test_test", "build/test_test.tl"))
  assert(test.matches("./", "build.test_test", "build/test_test.tl"))
  assert(not test.matches("", "build.test_test", "build/test_test.tl"))
  assert(not test.matches("/", "build.test_test", "build/test_test.tl"))
  assert(not test.matches("test_test", "build.test_test", "build/test_test.tl"))
  assert(not test.matches("build/test", "build.test_test", "build/test_test.tl"))
  assert(not test.matches("build", "builder.other_test", "builder/other_test.tl"))
end

local function test_a_selector_is_printed_as_one_shell_word()
  assert(test.shell_word("build/test_test.tl:test_x") == "build/test_test.tl:test_x")
  assert(test.shell_word("a b/c_test.tl:t") == "'a b/c_test.tl:t'")
  assert(test.shell_word("it's_test.tl:t") == "'it'\\''s_test.tl:t'")
  assert(test.shell_word("-x_test.tl:t") == "./-x_test.tl:t")
  assert(test.shell_word("-a b_test.tl:t") == "'./-a b_test.tl:t'")
  assert(test.shell_word("$x_test.tl:t") == "'$x_test.tl:t'")
  assert(test.shell_word("") == "''")
end

local function test_a_selector_can_name_one_test_of_one_module()
  local path, file = "build.test_test", "build/test_test.tl"
  assert(test.selects("build/test_test.tl:test_a", path, file, "test_a"))
  assert(test.selects("./build/test_test.tl:test_a", path, file, "test_a"))
  assert(test.selects("build.test_test:test_a", path, file, "test_a"))
  assert(not test.selects("build/test_test.tl:test_a", path, file, "test_b"))
  assert(not test.selects("build/test_test.tl:test_a", path, file, "test_ab"))
  assert(test.selects("build/test_test.tl", path, file, "test_b"))
  -- A named test is looked for in one module, never under a directory.
  assert(not test.matches("build:test_a", path, file))
  assert(not test.matches(".:test_a", path, file))
  assert(test.matches("build/test_test.tl:test_a", path, file))
  assert(test.selects("cosmic/hash_example.tl:hex_sha256", "cosmic.hash_example",
    "cosmic/hash_example.tl", "hex_sha256"))
  assert(test.selects("cosmic/hash_example.tl:Example.hex_sha256", "cosmic.hash_example",
    "cosmic/hash_example.tl", "hex_sha256"))
  assert(not test.selects("cosmic/hash_example.tl:Example.hex_sha256",
    "cosmic.hash_example", "cosmic/hash_example.tl", "digest"))
end

local function test_only_a_name_after_the_last_colon_names_a_test()
  assert(test.selects("a:b/c_test.tl:test_a", "a:b.c_test", "a:b/c_test.tl", "test_a"))
  assert(not test.selects("a:b/c_test.tl:test_a", "a:b.c_test", "a:b/c_test.tl", "test_b"))
  -- Anything else after the last `:` leaves the selector a path whole:
  -- each one selects the module it spells, and not another's.
  for _, whole in ipairs({ "C:\\dir\\x_test.tl", "a:b/c_test.tl", ":test_a",
                           "x_test.tl:", "x_test.tl:Other.a", "x_test.tl:1a" }) do
    assert(test.selects(whole, "x_test", whole, "test_a"), whole)
    assert(not test.matches(whole, "x_test", "x_test.tl"), whole)
  end
end

local function test_a_refused_name_is_shown_the_nearest_names_first()
  local near = test.nearest("test_rows", { "test_b", "test_rows_escaped", "test_a",
    "test_row" })
  assert(table.concat(near, " ") == "test_rows_escaped test_row test_a test_b",
    table.concat(near, " "))
  local many: {string} = {}
  for i = 1, 12 do many[i] = string.format("test_%02d", i) end
  near = test.nearest("test_12x", many)
  assert(#near == 10 and near[1] == "test_12" and near[2] == "test_10", near[2])
end

local function test_identical_inputs_produce_the_same_stable_key(tmp: string)
  local path = tmp .. "/a.txt"
  assert(Fs.write(path, "hello"))
  local reads: {observations.Observation} = {
    { kind = "o", path = path, answer = Hash.hex_sha256("hello") },
  }
  local verdict_key1 = test.verdict_key(tmp, {}, "mod.tl name", "modkey",
    "runtime", reads, {})
  local key1, stable1 = verdict_key1.key, verdict_key1.stable
  assert(stable1)
  local verdict_key2 = test.verdict_key(tmp, {}, "mod.tl name", "modkey",
    "runtime", reads, {})
  local key2, stable2 = verdict_key2.key, verdict_key2.stable
  assert(stable2)
  assert(key1 == key2)
end

--- A shared key names nothing of where the tree is: two checkouts of
--- the same content, made at different paths and times -- so every file
--- has its own inode and modification time -- key the same reads alike,
--- and a verdict one reached stands in the other. Each one's own key
--- still holds the stats whole, so a file touched there changes it; and
--- what either holds changing changes both.
local function test_two_checkouts_of_the_same_content_share_a_key(tmp: string)
  local function checkout(root: string): {observations.Observation}
    assert(Fs.mkdirs(root .. "/d"))
    assert(Fs.write(root .. "/f", "same"))
    assert(Fs.write(root .. "/d/g", "also the same"))
    return {
      { kind = "o", path = root .. "/f", answer = "" },
      { kind = "s", path = root .. "/f", answer = "" },
      { kind = "s", path = root .. "/d", answer = "" },
      { kind = "d", path = root .. "/d", answer = "" },
      { kind = "u", path = root .. "/d", answer = "" },
    }
  end
  local first, second = tmp .. "/first", tmp .. "/second"
  local first_reads = checkout(first)
  assert(Time.sleep_ns(10000000))
  local second_reads = checkout(second)
  local function reach(root: string, reads: {observations.Observation}): test.VerdictKey
    local reached = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", reads, {})
    assert(reached.stable)
    return reached
  end
  local function key(root: string, reads: {observations.Observation}): string
    return reach(root, reads).shared
  end
  local reached = key(first, first_reads)
  assert(key(second, second_reads) == reached, "another checkout of the same content")
  assert(reach(second, second_reads).key ~= reach(first, first_reads).key,
    "each checkout's own key holds its stats whole")
  local own = reach(second, second_reads).key
  assert(Time.sleep_ns(10000000))
  assert(Fs.write(second .. "/f", "same"))
  assert(reach(second, second_reads).key ~= own, "a file touched in the checkout")
  assert(key(second, second_reads) == reached, "is the same file to its siblings")
  assert(Fs.write(second .. "/d/g", "changed"))
  assert(key(second, second_reads) ~= reached, "a file a confined process was given")
  assert(Fs.write(second .. "/d/g", "also the same"))
  assert(key(second, second_reads) == reached)
  assert(Fs.write(second .. "/f", "diff"))
  assert(key(second, second_reads) ~= reached, "a file the test read")
end

local function test_a_changed_content_read_is_unstable(tmp: string)
  local path = tmp .. "/a.txt"
  assert(Fs.write(path, "hello"))
  local reads: {observations.Observation} = {
    { kind = "o", path = path, answer = Hash.hex_sha256("something else") },
  }
  local stable = test.verdict_key(tmp, {}, "mod.tl name", "modkey",
    "runtime", reads, {}).stable
  assert(not stable)
end

local function test_a_changed_stat_read_is_unstable(tmp: string)
  local path = tmp .. "/a.txt"
  assert(Fs.write(path, "hello"))
  local reads: {observations.Observation} = {
    { kind = "s", path = path, answer = "not a real stat answer" },
  }
  local stable = test.verdict_key(tmp, {}, "mod.tl name", "modkey",
    "runtime", reads, {}).stable
  assert(not stable)
end

local function test_distinct_ids_never_share_a_key(tmp: string)
  local key1 = test.verdict_key(tmp, {}, "path1 name1", "modkey", "runtime", {}, {}).key
  local key2 = test.verdict_key(tmp, {}, "path2 name2", "modkey", "runtime", {}, {}).key
  assert(key1 ~= key2)
end

local function test_distinct_module_keys_never_share_a_key(tmp: string)
  local key1 = test.verdict_key(tmp, {}, "path name", "modkey1", "runtime", {}, {}).key
  local key2 = test.verdict_key(tmp, {}, "path name", "modkey2", "runtime", {}, {}).key
  assert(key1 ~= key2)
end

local function test_distinct_runtimes_never_share_a_key(tmp: string)
  local key1 = test.verdict_key(tmp, {}, "path name", "modkey", "runtime1", {}, {})
  local key2 = test.verdict_key(tmp, {}, "path name", "modkey", "runtime2", {}, {})
  assert(key1.key ~= key2.key)
  assert(key1.shared ~= key2.shared, "nor a shared one")
end

local function test_distinct_read_sets_never_share_a_key(tmp: string)
  local a = tmp .. "/a.txt"
  local b = tmp .. "/b.txt"
  assert(Fs.write(a, "hello"))
  assert(Fs.write(b, "hello"))
  local reads_a: {observations.Observation} = {
    { kind = "o", path = a, answer = Hash.hex_sha256("hello") },
  }
  local reads_b: {observations.Observation} = {
    { kind = "o", path = b, answer = Hash.hex_sha256("hello") },
  }
  local key1 = test.verdict_key(tmp, {}, "path name", "modkey", "runtime", reads_a, {}).key
  local key2 = test.verdict_key(tmp, {}, "path name", "modkey", "runtime", reads_b, {}).key
  assert(key1 ~= key2)
end

--- Regression: generation 2's header line was a raw
--- `id .. " " .. module_key .. " " .. runtime`, unescaped -- two distinct
--- triples whose fields concatenate to the same string collided on the
--- same key. Every real caller only ever passes a fixed-width hex digest
--- for module_key and runtime, so this was never reachable in practice,
--- but nothing in verdict_key itself enforced that. Generation 3 frames
--- the header through the same key_part hex-encoding every read line
--- already uses.
local function test_header_fields_do_not_collide_across_their_boundary(tmp: string)
  local key1 = test.verdict_key(tmp, {}, "foo bar", "baz", "r", {}, {}).key
  local key2 = test.verdict_key(tmp, {}, "foo", "bar baz", "r", {}, {}).key
  assert(key1 ~= key2)

  local key3 = test.verdict_key(tmp, {}, "id", "baz", "r", {}, {}).key
  local key4 = test.verdict_key(tmp, {}, "id", "ba", "zr", {}, {}).key
  assert(key3 ~= key4)
end

--- A test whose inputs are not keyable must never stand: an unhashable
--- input -- a spawned process -- or a read outside the tree it cannot
--- account for as its own scratch output makes `keyable` false, which
--- `finish` ANDs into `record_run`'s `cacheable?` so the verdict is
--- stored as unstable and the test runs again regardless. An
--- environment read is keyable: its answer enters the key instead.
local function test_an_environment_read_is_keyable(tmp: string)
  local reads: {observations.Observation} = { { kind = "e", path = "HOME", answer = "" } }
  assert(test.keyable(tmp, tmp .. "/scratch", reads))
end

local function test_a_spawned_process_is_not_keyable(tmp: string)
  local reads: {observations.Observation} =
    { { kind = "p", path = "/bin/true", answer = "" } }
  assert(not test.keyable(tmp, tmp .. "/scratch", reads))
end

--- A declared process is: its caller read what it would.
local function test_a_declared_process_is_keyable(tmp: string)
  local reads: {observations.Observation} =
    { { kind = "h", path = "/bin/true", answer = "" } }
  assert(test.keyable(tmp, tmp .. "/scratch", reads))
end

local function test_a_network_request_is_not_keyable(tmp: string)
  local reads: {observations.Observation} =
    { { kind = "x", path = "https://example.com/", answer = "" } }
  assert(not test.keyable(tmp, tmp .. "/scratch", reads))
end

local function test_a_read_outside_the_tree_is_not_keyable(tmp: string)
  local reads: {observations.Observation} =
    { { kind = "o", path = "/etc/hostname", answer = "" } }
  assert(not test.keyable(tmp, tmp .. "/scratch", reads))
end

local function test_a_read_under_root_is_keyable(tmp: string)
  local reads: {observations.Observation} =
    { { kind = "o", path = tmp .. "/a.txt", answer = "" } }
  assert(test.keyable(tmp, tmp .. "/scratch", reads))
end

local function test_a_read_under_scratch_is_keyable(tmp: string)
  local root = tmp .. "/root"
  local scratch = tmp .. "/scratch"
  local reads: {observations.Observation} =
    { { kind = "o", path = scratch .. "/out.txt", answer = "" } }
  assert(test.keyable(root, scratch, reads))
end

local function test_a_read_under_a_directory_the_test_made_is_keyable(tmp: string)
  local root = tmp .. "/root"
  local scratch = tmp .. "/scratch"
  local made = "/tmp/cosmic-made-XXXXXX"
  local reads: {observations.Observation} = {
    { kind = "m", path = made, answer = "" },
    { kind = "o", path = made .. "/out.txt", answer = "" },
  }
  assert(test.keyable(root, scratch, reads))
end

--- `Fs.mkdirs` stats a directory before the "m" observation that
--- creates it, so a read of a directory a test is about to make for
--- itself must be keyable even though the "m" observation for it comes
--- later in the list.
local function test_a_read_before_the_m_that_made_its_directory_is_keyable(tmp: string)
  local root = tmp .. "/root"
  local scratch = tmp .. "/scratch"
  local made = "/tmp/cosmic-made-XXXXXX"
  local reads: {observations.Observation} = {
    { kind = "s", path = made, answer = "" },
    { kind = "m", path = made, answer = "" },
  }
  assert(test.keyable(root, scratch, reads))
end

--- A stat and an lstat of one path resolve it apart: a stat follows a
--- link in the test's own directory to the tree's file it leads to,
--- while an lstat reads the link itself, the test's own. Resolved alike,
--- the lstat would be keyed as the tree file's, which is no link, and
--- the verdict would never stand.
local function test_a_stat_and_an_lstat_of_one_link_are_resolved_apart(tmp: string)
  local real = assert(sys.realpath(tmp))
  local root, own = real .. "/root", real .. "/own"
  assert(Fs.mkdirs(root))
  assert(Fs.mkdirs(own))
  assert(Fs.write(root .. "/f", "tree"))
  assert(Fs.symlink(root .. "/f", own .. "/link"))
  local resolving: observations.Resolving = { tree = root, own = { own } }
  local run = observations.call(function()
    assert(sys.stat(own .. "/link"))
    assert(sys.lstat(own .. "/link"))
  end, nil, resolving)
  assert(run.passed, run.message)
  assert(test.keyable(root, own, run.reads))
  local reached = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", run.reads, {})
  assert(reached.stable, "the verdict of a stat and an lstat of one link is not kept")
  assert(Fs.write(root .. "/f", "the tree's file, grown"))
  local grown = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", run.reads, {})
  assert(not grown.stable, "the stat of the tree's file is not keyed")
end

--- A test that asks where the program is keys that it answered, not
--- where: what the program is, the runtime identity keys, and a
--- verdict one copy of it reached stands under another copy at another
--- path, as ci/fixtures/identity_test.tl's "application" run needs of
--- another artifact over the same core and basis.
local function test_where_the_program_is_is_no_input_to_a_key(tmp: string)
  local root = assert(sys.realpath(tmp))
  local program = assert(sys.executable())
  local run = observations.call(function()
    assert(sys.executable() == program)
  end, nil, { tree = root, own = {} })
  assert(run.passed, run.message)
  local asked = false
  for _, observation in ipairs(run.reads) do
    if observation.kind == "b" then
      asked = true
      assert(observation.answer == "ok", "the program's path is noted: " .. observation.answer)
    end
  end
  assert(asked, "the program's path is not observed")
  assert(test.keyable(root, root .. "/scratch", run.reads))
  local reached = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", run.reads, {})
  assert(reached.stable, "a verdict that asked where the program is is not kept")
end

local function test_a_read_under_root_o_is_keyable(tmp: string)
  local scratch = tmp .. "/scratch"
  local reads: {observations.Observation} =
    { { kind = "o", path = tmp .. "/o/some/file", answer = "" } }
  assert(test.keyable(tmp, scratch, reads))
end

--- What the build writes under o/ is keyed by its bytes when a test
--- opens it: the shipped database a whole-tree check reads, the tool,
--- anything else there. A build that rewrites one lets the verdict
--- fall; the working database, which every run rewrites, holds none.
local function test_the_builds_output_enters_the_key(tmp: string)
  assert(Fs.mkdirs(tmp .. "/o/bin"))
  local unread = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", {}, {}).key
  for _, relative in ipairs({ "o/cosmic.db", "o/bin/cosmic", "o/carried.db", "o/scratch" }) do
    local path = tmp .. "/" .. relative
    assert(Fs.write(path, "first"))
    local function key_over(kind: string): test.VerdictKey
      return test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime",
        { { kind = kind, path = path, answer = "" } }, {})
    end
    local keyed = key_over("o")
    assert(keyed.stable and keyed.key ~= unread and keyed.shared ~= unread,
      relative .. " did not enter the key")
    local stated = key_over("s")
    assert(stated.stable and stated.key ~= unread, relative .. "'s stat did not enter the key")
    -- The same size, written again: its times moved, not its stat's key.
    assert(Fs.write(path, "FIRST"))
    assert(key_over("o").key ~= keyed.key, "a rewritten " .. relative .. " kept its key")
    assert(key_over("s").key == stated.key, relative .. "'s stat keyed its times")
  end
  assert(Fs.write(tmp .. "/o/build.db", "first"))
  for _, relative in ipairs({ "o/build.db", "o/build.db-wal" }) do
    local k = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime",
      { { kind = "o", path = tmp .. "/" .. relative, answer = "" } }, {})
    assert(not k.stable, "a read of " .. relative .. " let the verdict be kept")
  end
end

--- A file under o/ that test after test opens is remembered for the
--- run by what `stat` says of it, and read again once it is rewritten.
local function test_the_builds_output_is_read_again_once_rewritten(tmp: string)
  assert(Fs.mkdirs(tmp .. "/o/bin"))
  local path = tmp .. "/o/bin/cosmic"
  assert(Fs.write(path, "first"))
  local parts: {string:string} = {}
  local reads: {observations.Observation} = { { kind = "o", path = path, answer = "" } }
  local first = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, parts)
  assert(test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, parts).key ==
    first.key)
  assert(Fs.write(path, "second, longer"))
  local rewritten = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, parts)
  assert(rewritten.key ~= first.key, "a rewritten file answered from the first read")
  local fresh = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, {})
  assert(fresh.key == rewritten.key)
  -- Rewritten to the same size and given its modification time back,
  -- as `cp -p` leaves it: its change time still moved.
  local before = assert(sys.stat(path))
  local function changed(): string
    local st = assert(sys.stat(path))
    return st.ctime .. "." .. st.ctime_ns
  end
  local was = changed()
  repeat
    -- In place, as `cp -p` writes: the same inode.
    local fd = assert(Fs.open_write(path))
    assert(Fs.put(fd, "SECOND, LONGER"))
    assert(Fs.close(fd))
  until changed() ~= was
  assert(assert(sys.stat(path)).ino == before.ino)
  assert(sys.utimensat(path, nil, nil, before.mtime, before.mtime_ns))
  local same_size = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, parts)
  assert(same_size.key ~= rewritten.key, "a same-size rewrite answered from the memo")
end

local function test_a_relative_path_is_keyable(tmp: string)
  local reads: {observations.Observation} =
    { { kind = "o", path = "cosmic/fs.tl", answer = "" } }
  assert(test.keyable(tmp, tmp .. "/scratch", reads))
end

--- An environment variable a test read is part of its verdict key: a
--- different recorded answer for the same variable produces a
--- different key, and an answer that no longer matches the live
--- environment turns `stable` false, exactly as a changed file hash
--- does for an "o" read.
local function test_an_environment_answer_is_part_of_the_key(tmp: string)
  local reads_a: {observations.Observation} =
    { { kind = "e", path = "COSMIC_TEST_ENV_KEY", answer = "ok one" } }
  local reads_b: {observations.Observation} =
    { { kind = "e", path = "COSMIC_TEST_ENV_KEY", answer = "ok two" } }
  local key_a = test.verdict_key(tmp, {}, "path name", "modkey", "runtime", reads_a, {}).key
  local key_b = test.verdict_key(tmp, {}, "path name", "modkey", "runtime", reads_b, {}).key
  assert(key_a ~= key_b)
end

local function test_a_changed_environment_answer_is_unstable(tmp: string)
  local reads: {observations.Observation} =
    { { kind = "e", path = "COSMIC_TEST_ENV_KEY", answer = "ok not the live value" } }
  local stable = test.verdict_key(tmp, {}, "path name", "modkey", "runtime", reads, {}).stable
  assert(not stable)
end

--- A file of the tree named through a link from outside it, present or
--- not, is the tree's file, keyed by what the read resolved
--- to as the test made it (its "r" observation); a link inside the tree
--- to a file outside it is still outside once resolved, and a read with
--- no resolution recorded is outside.
local function test_a_tree_path_through_a_link_keys_as_the_tree_path(tmp: string)
  local root = assert(Fs.absolute(tmp)) .. "/root"
  local elsewhere = assert(Fs.absolute(tmp)) .. "/elsewhere"
  assert(Fs.mkdirs(root .. "/sub"))
  assert(Fs.mkdirs(elsewhere))
  assert(Fs.write(root .. "/sub/a.txt", "hello"))
  assert(Fs.write(elsewhere .. "/b.txt", "outside"))
  assert(Fs.symlink(root, elsewhere .. "/in"))
  assert(Fs.symlink(elsewhere .. "/b.txt", root .. "/out"))
  local scratch = tmp .. "/scratch"
  for _, name in ipairs({ "sub/a.txt", "sub/missing/c.txt" }) do
    local direct: {observations.Observation} = { { kind = "s", path = root .. "/" .. name,
      answer = observations.stat_answer(root .. "/" .. name) } }
    local through = elsewhere .. "/in/" .. name
    local unresolved: {observations.Observation} = { { kind = "s",
      path = through, answer = direct[1].answer } }
    assert(not test.keyable(root, scratch, unresolved), name)
    local linked: {observations.Observation} = { unresolved[1],
      { kind = "r", path = through, answer = observations.resolution(through) } }
    assert(test.keyable(root, scratch, linked), name)
    local verdict_key1 = test.verdict_key(root, {}, "p n", "m", "r", direct, {})
    local key1, stable1 = verdict_key1.key, verdict_key1.stable
    local verdict_key2 = test.verdict_key(root, {}, "p n", "m", "r", linked, {})
    local key2, stable2 = verdict_key2.key, verdict_key2.stable
    assert(stable1 and stable2 and key1 ~= key2, name)
    -- A later run looks the verdict up from the stored reads, which
    -- carry no answers: it finds the key the run recorded.
    local stored: {observations.Observation} = {
      { kind = "s", path = through, answer = "" },
      { kind = "r", path = through, answer = "" },
    }
    local verdict_later = test.verdict_key(root, {}, "p n", "m", "r", stored, {})
    local later, stable3 = verdict_later.key, verdict_later.stable
    assert(stable3 and later == key2, name)
  end
  local out = elsewhere .. "/in/out"
  assert(not test.keyable(root, scratch, { { kind = "o", path = out, answer = "" },
    { kind = "r", path = out, answer = observations.resolution(out) } }))
  -- A path that climbs is judged by what it resolved to, and without a
  -- resolution (a relative one has none) it is outside.
  local climbing = root .. "/sub/../sub/a.txt"
  assert(observations.resolution(climbing) == root .. "/sub/a.txt")
  assert(not test.keyable(root, scratch, { { kind = "o", path = climbing, answer = "" } }))
  assert(test.keyable(root, scratch, { { kind = "o", path = climbing, answer = "" },
    { kind = "r", path = climbing, answer = observations.resolution(climbing) } }))
  assert(not test.keyable(root, scratch, { { kind = "o", path = "../a.txt", answer = "" } }))
  assert(observations.resolution(root .. "/gone/../sub/a.txt") ==
    root .. "/gone/../sub/a.txt")
end

--- A read through a link outside the tree keys by where the link led
--- when the test read it: a link retargeted since, or during the run,
--- keys differently, or does not stand at all.
local function test_a_retargeted_link_does_not_stand(tmp: string)
  local base = assert(Fs.absolute(tmp))
  local root = base .. "/root"
  assert(Fs.mkdirs(root .. "/a"))
  assert(Fs.mkdirs(root .. "/b"))
  assert(Fs.write(root .. "/a/f", "good"))
  assert(Fs.write(root .. "/b/f", "good"))
  assert(Fs.symlink(root .. "/a", base .. "/link"))
  local read = base .. "/link/f"
  local reads: {observations.Observation} = {
    { kind = "o", path = read, answer = "" },
    { kind = "r", path = read, answer = observations.resolution(read) },
  }
  local verdict_before = test.verdict_key(root, {}, "p n", "m", "r", reads, {})
  local before, stable = verdict_before.key, verdict_before.stable
  assert(stable)
  assert(Fs.remove(base .. "/link"))
  assert(Fs.symlink(root .. "/b", base .. "/link"))
  local still = test.verdict_key(root, {}, "p n", "m", "r", reads, {}).stable
  assert(not still)
  local stored: {observations.Observation} = {
    { kind = "o", path = read, answer = "" },
    { kind = "r", path = read, answer = "" },
  }
  local after = test.verdict_key(root, {}, "p n", "m", "r", stored, {}).key
  assert(after ~= before)
end

--- A path a confined process was given is keyable, and its key follows
--- what it holds.
local function test_a_confined_process_is_keyable_by_what_it_was_given(tmp: string)
  local given = tmp .. "/given"
  assert(Fs.mkdirs(given))
  assert(Fs.write(given .. "/f", "one"))
  local reads: {observations.Observation} = {
    { kind = "u", path = given, answer = "" },
    { kind = "o", path = "/dev/null", answer = "" },
  }
  assert(test.keyable(tmp, tmp .. "/scratch", reads))
  local before = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, {})
  assert(before.stable)
  assert(Fs.write(given .. "/f", "two"))
  local after = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, {})
  assert(after.key ~= before.key, "a changed file the process was given changes the key")
  -- A path first walked after the test started may be of what it became
  -- since: that verdict is not kept.
  local late = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, {},
    Time.monotonic_ns())
  assert(not late.stable, "a path walked after the test started")
  local walked: {string:string} = {}
  local first = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, walked)
  local started = Time.monotonic_ns()
  local again = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, walked,
    started)
  assert(again.stable and again.key == first.key, "a path walked before it started")
end

--- What a test reads of its own process in /proc describes the worker
--- running it, and is no input; another process's is the host's.
local function test_a_read_of_the_tests_own_process_is_keyable(tmp: string)
  assert(test.keyable(tmp, tmp .. "/scratch", {
    { kind = "o", path = "/proc/self/status", answer = "" },
    { kind = "r", path = "/proc/self/status", answer = "/proc/4242/status" },
    { kind = "s", path = "/proc/thread-self/fdinfo/3", answer = "" },
  }))
  -- /proc/self leads to more than the process: the host's root, its
  -- working directory, its environment, its network, and back up.
  for _, path in ipairs({ "/proc/1/status", "/proc/self/root/etc/hostname",
      "/proc/self/cwd/x", "/proc/self/environ", "/proc/self/../1/cmdline",
      "/proc/self/net/tcp", "/proc/self/fd/3", "/proc/self//status" }) do
    assert(not test.keyable(tmp, tmp .. "/scratch", {
      { kind = "o", path = path, answer = "" },
    }), path)
  end
end

--- A path a confined process was given, first walked after its test
--- started, keeps its reads for the next run to walk first, but not
--- the verdict.
local function test_a_path_walked_late_is_late_not_stable(tmp: string)
  local given = tmp .. "/given"
  assert(Fs.mkdirs(given))
  local reads: {observations.Observation} = { { kind = "u", path = given, answer = "" } }
  local late = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, {},
    Time.monotonic_ns())
  assert(late.late and not late.stable)
  local walked: {string:string} = {}
  local early = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", reads, walked)
  assert(not early.late and early.stable)
end

--- A stat's times and inode are no part of what the tree holds, so the
--- shared key leaves them out, and under o/ a checkout's own key does
--- too. A test that declares it reads them
--- (`observations.reads_stat_times`) is keyed by them in both: a file
--- whose modification time alone moved runs it again, here and in any
--- sibling, where one that did not declare still stands.
local function test_a_declared_test_keys_a_stat_s_times_whole(tmp: string)
  local root = assert(sys.realpath(tmp))
  assert(Fs.mkdirs(root .. "/o"))
  for _, relative in ipairs({ "f", "o/f" }) do
    local path = root .. "/" .. relative
    assert(Fs.write(path, "same"))
    local stat_read: observations.Observation = { kind = "s", path = path, answer = "" }
    local declaration: observations.Observation = { kind = "z", path = "", answer = "" }
    local function keys(): test.VerdictKey, test.VerdictKey
      local undeclared = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime",
        { stat_read }, {})
      local declared = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime",
        { declaration, stat_read }, {})
      return undeclared, declared
    end
    local undeclared, declared = keys()
    local st = assert(sys.stat(path))
    assert(sys.utimensat(path, nil, nil, st.mtime + 1, st.mtime_ns))
    local undeclared_after, declared_after = keys()
    assert(declared_after.key ~= declared.key, relative .. ": a declared test's own key " ..
      "kept a moved modification time out")
    assert(declared_after.shared ~= declared.shared, relative .. ": a declared test's " ..
      "shared key kept a moved modification time out")
    assert(undeclared_after.shared == undeclared.shared, relative .. ": an undeclared " ..
      "test's shared key holds a modification time")
    if relative == "o/f" then
      assert(undeclared_after.key == undeclared.key, "an undeclared test's own key holds " ..
        "the time of a file under o/")
    end
    -- The access time, which a read moves, no key holds, a declared
    -- one's included: a key over it would fall to the test's own reads.
    -- Setting it moves the change time too, so it is set to before the
    -- modification time and then moved by a read alone, as relatime
    -- does and strictatime, where the filesystem keeps access times.
    assert(sys.utimensat(path, st.atime - 10, 0, nil, nil))
    local undeclared_set, declared_set = keys()
    assert(Fs.read(path))
    local undeclared_read, declared_read = keys()
    assert(declared_read.key == declared_set.key, relative .. ": a declared test's key " ..
      "holds the access time")
    assert(undeclared_read.key == undeclared_set.key, relative .. ": an undeclared " ..
      "test's key holds the access time")
  end
end

--- A declared test that opened a file of the tree may have read its
--- times through the descriptor (an `fstat`), which is not logged: the
--- file's stat is keyed whole beside its bytes.
local function test_a_declared_test_keys_the_stat_of_each_file_it_opened(tmp: string)
  local root = assert(sys.realpath(tmp))
  local path = root .. "/f"
  assert(Fs.write(path, "same"))
  local reads: {observations.Observation} = {
    { kind = "z", path = "", answer = "" }, { kind = "o", path = path, answer = "" } }
  local before = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", reads, {})
  local st = assert(sys.stat(path))
  assert(sys.utimensat(path, nil, nil, st.mtime + 1, st.mtime_ns))
  local after = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", reads, {})
  assert(after.shared ~= before.shared, "an opened file's times entered no declared key")
end

--- A declared test's confined process may read the times of what it
--- was given under the tree: each such path is keyed by the stamps of
--- everything beneath it too, not only by its contents, so a file
--- beneath it whose modification time alone moved runs the test again.
local function test_a_declared_test_keys_the_times_a_confined_process_was_given(tmp: string)
  local root = assert(sys.realpath(tmp))
  assert(Fs.mkdirs(root .. "/given"))
  local file = root .. "/given/f"
  assert(Fs.write(file, "same"))
  local given: observations.Observation = { kind = "u", path = root .. "/given", answer = "" }
  local declaration: observations.Observation = { kind = "z", path = "", answer = "" }
  local function keys(): test.VerdictKey, test.VerdictKey
    return test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", { given }, {}),
      test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", { declaration, given },
        {})
  end
  local undeclared, declared = keys()
  local st = assert(sys.stat(file))
  assert(sys.utimensat(file, nil, nil, st.mtime + 1, st.mtime_ns))
  local undeclared_after, declared_after = keys()
  assert(declared_after.key ~= declared.key, "a declared key kept a given path's times out")
  assert(declared_after.shared ~= declared.shared,
    "a declared shared key kept a given path's times out")
  assert(undeclared_after.shared == undeclared.shared,
    "an undeclared shared key holds a given path's times")
end

--- A test that digests a path of the tree (`sys.tree_digest`) is keyed
--- by what the walk answers, once, not by a read of each entry: a file
--- beneath it whose contents change runs it again, and, walked by its
--- stamps, one whose modification time alone moved does, in its shared
--- key too, declared or not.
local function test_a_tree_digest_of_the_tree_is_keyed_by_its_walk(tmp: string)
  local root = assert(sys.realpath(tmp))
  assert(Fs.mkdirs(root .. "/walked/deeper"))
  local file = root .. "/walked/deeper/f"
  assert(Fs.write(file, "before"))
  local resolving: observations.Resolving = { tree = root, own = {} }
  for _, contents in ipairs({ true, false }) do
    local captured = observations.capture(function()
      assert(sys.tree_digest(root .. "/walked", contents))
    end, resolving)
    assert(captured.ok, tostring(captured.produced))
    local walks = 0
    for _, read in ipairs(captured.reads) do
      if read.kind == "g" or read.kind == "j" then
        walks = walks + 1
        assert(read.kind == (contents and "g" or "j"), read.kind)
      end
    end
    assert(walks == 1, "a walk noted " .. tostring(walks) .. " times")
    -- As a stored run gives its reads back: without their answers, each
    -- walked again for the key.
    local stored = assert(observations.decode(observations.encode(captured.reads)))
    local function key(reads: {observations.Observation}): test.VerdictKey
      return test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", reads, {})
    end
    local before = key(stored)
    assert(key(captured.reads).stable, "a walk of what did not change is unstable")
    assert(key(captured.reads).key == before.key, "a walk keyed apart from its answer")
    if contents then
      assert(Fs.write(file, "after!"))
      local after = key(stored)
      assert(after.key ~= before.key, "a file's contents beneath a walk entered no key")
      assert(after.shared ~= before.shared, "a file's contents entered no shared key")
      assert(not key(captured.reads).stable, "a walk that answers otherwise now stands")
    else
      local st = assert(sys.stat(file))
      assert(sys.utimensat(file, nil, nil, st.mtime + 1, st.mtime_ns))
      local after = key(stored)
      assert(after.key ~= before.key, "a walk's stamps entered no key")
      assert(after.shared ~= before.shared, "a walk's stamps entered no shared key")
    end
  end
end

--- The walk a key makes of a path a confined process was given is the
--- key's own, not the test's: a capture around it notes no digest.
local function test_the_walk_a_key_makes_is_none_of_the_tests(tmp: string)
  local root = assert(sys.realpath(tmp))
  assert(Fs.mkdirs(root .. "/given"))
  local captured = observations.capture(function()
    observations.unveiled_answer(root .. "/given", root)
    observations.digest_answer(root .. "/given", true)
  end, { tree = root, own = {} })
  assert(captured.ok, tostring(captured.produced))
  for _, read in ipairs(captured.reads) do
    assert(read.kind ~= "g" and read.kind ~= "j" and read.kind ~= "s",
      "the key's walk was noted " .. read.kind)
  end
end

--- A walk goes beneath what a read of one path does not: a walk of the
--- test's own process in /proc reaches its threads, and one of a
--- constant device by its stamps reads its times, neither of which a
--- key holds.
local function test_a_walk_outside_the_tree_is_never_keyable(tmp: string)
  for _, kind in ipairs({ "g", "j" }) do
    for _, path in ipairs({ "/proc/self/task", "/proc/self/status", "/dev/null" }) do
      assert(not test.keyable(tmp, tmp .. "/scratch", {
        { kind = kind, path = path, answer = "" },
      }), kind .. " " .. path)
    end
  end
end

--- A walk of a path ending in "/" follows a link its last name is: the
--- key walks the same, so the verdict stands.
local function test_a_walk_through_a_trailing_slash_is_keyed_as_asked(tmp: string)
  local root = assert(sys.realpath(tmp))
  assert(Fs.mkdirs(root .. "/target"))
  assert(Fs.write(root .. "/target/f", "held"))
  assert(sys.symlink("target", root .. "/link"))
  local captured = observations.capture(function()
    assert(sys.tree_digest(root .. "/link/", true))
  end, { tree = root, own = {} })
  assert(captured.ok, tostring(captured.produced))
  local keyed = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", captured.reads, {})
  assert(keyed.stable, "a walk through a trailing slash was keyed as another")
  -- Walked once a run: a walk first made after the test started is late.
  local walks: {string:string} = {}
  local late = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", captured.reads,
    walks, Time.monotonic_ns())
  assert(late.late and not late.stable, "a walk made after the test started stood")
  local again = test.verdict_key(root, {}, "mod.tl name", "modkey", "runtime", captured.reads,
    walks)
  assert(again.stable and again.key == late.key, "a walk remembered keys otherwise")
end
