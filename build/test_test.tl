--- `test.verdict_key` is what a test's cached verdict stands or falls on:
--- a wrong key could let a broken test's old, unrelated verdict answer for
--- it, silently skipping it forever. These pin the two ways that could
--- happen -- two different inputs hashing to the same key, and a changed
--- read not being noticed -- directly against the key-building function
--- itself, without needing a compiled tree or a work database to reach it
--- through.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
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

local function test_identical_inputs_produce_the_same_stable_key(tmp: string)
  local path = tmp .. "/a.txt"
  assert(Fs.write(path, "hello"))
  local reads: {observations.Observation} = {
    { kind = "o", path = path, answer = Hash.hex_sha256("hello") },
  }
  local key1, stable1 = test.verdict_key(tmp, {}, "mod.tl name", "modkey",
    "runtime", reads, {})
  assert(stable1)
  local key2, stable2 = test.verdict_key(tmp, {}, "mod.tl name", "modkey",
    "runtime", reads, {})
  assert(stable2)
  assert(key1 == key2)
end

local function test_a_changed_content_read_is_unstable(tmp: string)
  local path = tmp .. "/a.txt"
  assert(Fs.write(path, "hello"))
  local reads: {observations.Observation} = {
    { kind = "o", path = path, answer = Hash.hex_sha256("something else") },
  }
  local _, stable = test.verdict_key(tmp, {}, "mod.tl name", "modkey",
    "runtime", reads, {})
  assert(not stable)
end

local function test_a_changed_stat_read_is_unstable(tmp: string)
  local path = tmp .. "/a.txt"
  assert(Fs.write(path, "hello"))
  local reads: {observations.Observation} = {
    { kind = "s", path = path, answer = "not a real stat answer" },
  }
  local _, stable = test.verdict_key(tmp, {}, "mod.tl name", "modkey",
    "runtime", reads, {})
  assert(not stable)
end

local function test_distinct_ids_never_share_a_key(tmp: string)
  local key1 = test.verdict_key(tmp, {}, "path1 name1", "modkey", "runtime", {}, {})
  local key2 = test.verdict_key(tmp, {}, "path2 name2", "modkey", "runtime", {}, {})
  assert(key1 ~= key2)
end

local function test_distinct_module_keys_never_share_a_key(tmp: string)
  local key1 = test.verdict_key(tmp, {}, "path name", "modkey1", "runtime", {}, {})
  local key2 = test.verdict_key(tmp, {}, "path name", "modkey2", "runtime", {}, {})
  assert(key1 ~= key2)
end

local function test_distinct_runtimes_never_share_a_key(tmp: string)
  local key1 = test.verdict_key(tmp, {}, "path name", "modkey", "runtime1", {}, {})
  local key2 = test.verdict_key(tmp, {}, "path name", "modkey", "runtime2", {}, {})
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
  local key1 = test.verdict_key(tmp, {}, "path name", "modkey", "runtime", reads_a, {})
  local key2 = test.verdict_key(tmp, {}, "path name", "modkey", "runtime", reads_b, {})
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
  local key1 = test.verdict_key(tmp, {}, "foo bar", "baz", "r", {}, {})
  local key2 = test.verdict_key(tmp, {}, "foo", "bar baz", "r", {}, {})
  assert(key1 ~= key2)

  local key3 = test.verdict_key(tmp, {}, "id", "baz", "r", {}, {})
  local key4 = test.verdict_key(tmp, {}, "id", "ba", "zr", {}, {})
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
  local key_a = test.verdict_key(tmp, {}, "path name", "modkey", "runtime", reads_a, {})
  local key_b = test.verdict_key(tmp, {}, "path name", "modkey", "runtime", reads_b, {})
  assert(key_a ~= key_b)
end

local function test_a_changed_environment_answer_is_unstable(tmp: string)
  local reads: {observations.Observation} =
    { { kind = "e", path = "COSMIC_TEST_ENV_KEY", answer = "ok not the live value" } }
  local _, stable = test.verdict_key(tmp, {}, "path name", "modkey", "runtime", reads, {})
  assert(not stable)
end
