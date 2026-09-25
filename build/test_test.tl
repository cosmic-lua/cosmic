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
local observations = require("build.filesystem_observations")
local test = require("build.test")

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
  local key1 = test.verdict_key(tmp, {}, "path name", "modkey", "runtime1", {}, {}).key
  local key2 = test.verdict_key(tmp, {}, "path name", "modkey", "runtime2", {}, {}).key
  assert(key1 ~= key2)
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

local function test_a_read_under_root_o_is_keyable(tmp: string)
  local scratch = tmp .. "/scratch"
  local reads: {observations.Observation} =
    { { kind = "o", path = tmp .. "/o/some/file", answer = "" } }
  assert(test.keyable(tmp, scratch, reads))
end

--- The shipped database is the one file under o/ a verdict is keyed
--- on: a whole-tree check reads it, so a build that rewrites it must
--- let that verdict fall. Any other file under o/ enters no key.
local function test_the_shipped_database_enters_the_key(tmp: string)
  assert(Fs.mkdirs(tmp .. "/o"))
  local db = tmp .. "/o/cosmic.db"
  local other = tmp .. "/o/build.db"
  assert(Fs.write(db, "first"))
  assert(Fs.write(other, "first"))
  local function key_over(path: string): string, boolean
    local k = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime",
      { { kind = "o", path = path, answer = Hash.hex_sha256("first") } }, {})
    return k.key, k.stable
  end
  local unread = test.verdict_key(tmp, {}, "mod.tl name", "modkey", "runtime", {}, {}).key
  local keyed, stable = key_over(db)
  assert(stable and keyed ~= unread, "o/cosmic.db did not enter the key")
  assert(Fs.write(db, "second"))
  local _, still = key_over(db)
  assert(not still, "a rewritten o/cosmic.db let the verdict stand")
  assert(Fs.write(other, "second"))
  local elsewhere, other_stable = key_over(other)
  assert(other_stable and elsewhere == unread,
    "a file under o/ but the shipped database entered the key")
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
