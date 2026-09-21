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
