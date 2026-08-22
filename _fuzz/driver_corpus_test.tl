--- Corpus behavior of the fuzz driver: replay before generation, and
--- the opt-in save path. Every test points FUZZ_CORPUS_DIR at its own
--- directory under TEST_TMPDIR, so nothing here touches a committed
--- corpus, and every test runs through driver.run_unisolated, so none
--- enters the isolation/crash path.

local check = require("cosmic.check")
local codec = require("cosmic.codec")
local driver = require("_fuzz.driver")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local source = require("_fuzz.source")

local saved_corpus_dir = env.get("FUZZ_CORPUS_DIR")
local saved_save = env.get("FUZZ_SAVE")

-- The corpus reads FUZZ_CORPUS_DIR and FUZZ_SAVE from the process
-- environment, so every test that touches them puts the ambient values
-- back.
local function restore()
  if saved_corpus_dir then
    assert(env.set("FUZZ_CORPUS_DIR", saved_corpus_dir))
  else
    assert(env.unset("FUZZ_CORPUS_DIR"))
  end
  if saved_save then
    assert(env.set("FUZZ_SAVE", saved_save))
  else
    assert(env.unset("FUZZ_SAVE"))
  end
end

-- A corpus root of this test's own, under TEST_TMPDIR, pointed at by
-- FUZZ_CORPUS_DIR. Returns the root; one property's directory under it
-- is <root>/<property name>. Saving starts off in every test, whatever
-- the ambient environment says, so a test that means to write says so.
local function corpus_root(label: string): string
  local root = fs.join(env.get_or("TEST_TMPDIR", "."), label)
  assert(fs.make_dirs(root))
  assert(env.set("FUZZ_CORPUS_DIR", root))
  assert(env.unset("FUZZ_SAVE"))
  return root
end

-- Put `bytes` in the corpus of property `name` under `root`, at
-- `basename`. The driver never demands that the name be the real
-- digest, which is what lets a test pin replay order by choosing one.
local function seed_corpus_file(root: string, name: string, basename: string,
    bytes: string)
  local dir = fs.join(root, name)
  assert(fs.make_dirs(dir))
  assert(fs.write(fs.join(dir, basename), bytes))
end

-- A property that fails on every input it is handed.
local function always_fails(name: string, seen: {string}): driver.Options
  return {
    name = name,
    iters = 4,
    gen = function(src: source.Recorder): string
      return driver.bytes(src, 8)
    end,
    check = function(input: string): boolean, string
      seen[#seen + 1] = input
      return false, "always fails"
    end,
  }
end

local function test_no_corpus_dir_is_silent()
  local root = corpus_root("no-corpus")
  local seen: {string} = {}
  local ok, msg = driver.run_unisolated(always_fails("no_corpus", seen))
  restore()
  check.equal(ok, false, "the generated loop should still fail")
  check.truthy(not msg:find("corpus=", 1, true),
    "a missing corpus dir must report nothing about a corpus: " .. msg)
  check.truthy(msg:find("iteration=", 1, true), "iteration missing: " .. msg)
  check.truthy(not fs.is_dir(fs.join(root, "no_corpus")),
    "replay must not create the corpus directory it probed for")
end
test_no_corpus_dir_is_silent()

local function test_corpus_entry_failure_is_reported()
  local root = corpus_root("entry-failure")
  local bad = "stored-bad-input"
  seed_corpus_file(root, "entry_failure", hash.sha256_hex(bad), bad)
  local seen: {string} = {}
  local ok, msg = driver.run_unisolated(always_fails("entry_failure", seen))
  restore()
  check.equal(ok, false, "a failing corpus entry must fail the run")
  check.truthy(msg:find("corpus=" .. hash.sha256_hex(bad), 1, true),
    "corpus basename missing: " .. msg)
  check.truthy(msg:find("input(base64)=" .. codec.encode_base64(bad), 1, true),
    "corpus bytes missing: " .. msg)
  check.truthy(not msg:find("iteration=", 1, true), "replay has no iteration: " .. msg)
  check.truthy(not msg:find("seed=", 1, true), "replay has no seed: " .. msg)
  check.truthy(not msg:find("draws=", 1, true), "replay has no draw count: " .. msg)
  check.equal(seen[1], bad, "the stored input must be checked first")
end
test_corpus_entry_failure_is_reported()

local function test_corpus_runs_before_generated_in_sorted_order()
  local root = corpus_root("sorted-order")
  local first = ("a"):rep(64)
  local second = ("b"):rep(64)
  -- The first-sorted entry fails; the second would pass, and so would
  -- nothing else — the generated loop fails on every input too, so only
  -- replay order can decide which failure is reported.
  seed_corpus_file(root, "sorted_order", first, "fails")
  seed_corpus_file(root, "sorted_order", second, "holds")
  local ok, msg = driver.run_unisolated({
      name = "sorted_order",
      iters = 4,
      gen = function(src: source.Recorder): string
        return driver.bytes(src, 8)
      end,
      check = function(input: string): boolean, string
        return input == "holds", "not the passing input"
      end,
    })
  restore()
  check.equal(ok, false, "the first corpus entry must fail the run")
  check.truthy(msg:find("corpus=" .. first, 1, true),
    "the first-sorted corpus entry should be reported: " .. msg)
  check.truthy(not msg:find("corpus=" .. second, 1, true),
    "replay must stop at the first failure: " .. msg)
  check.truthy(not msg:find("iteration=", 1, true),
    "the corpus must be checked before any generated input: " .. msg)
end
test_corpus_runs_before_generated_in_sorted_order()

-- A property that fails on a generated input the shrinker cannot make
-- any smaller: the generator ignores its source, so the minimized input
-- is that exact string whatever the ambient FUZZ_SEED is.
local function fails_on(name: string, input: string): driver.Options
  return {
    name = name,
    iters = 4,
    gen = function(_src: source.Recorder): string
      return input
    end,
    check = function(_input: string): boolean, string
      return false, "always fails"
    end,
  }
end

local function test_fuzz_save_writes_content_addressed()
  local root = corpus_root("save-writes")
  assert(env.set("FUZZ_SAVE", "1"))
  local stored = "corpus-worthy-input"
  local ok, msg = driver.run_unisolated(fails_on("save_writes", stored))
  restore()
  check.equal(ok, false, "the property must fail for anything to be saved")
  local found = check.must(fs.find(fs.join(root, "save_writes"),
      {recursive = false, sorted = true}))
  check.equal(#found, 1, "exactly one corpus file should have been written")
  local bytes = check.must(fs.read(found[1]))
  check.equal(bytes, stored, "the saved bytes must be the minimized input")
  check.equal(fs.basename(found[1]), hash.sha256_hex(bytes),
    "the corpus filename must be the digest of its own bytes")
  local encoded = msg:match("input%(base64%)=(%S+) draws=")
  check.truthy(encoded ~= nil, "no base64 input in the failure message: " .. msg)
  check.equal(bytes, check.must(codec.decode_base64(encoded)),
    "the saved bytes must be the input the failure message reports")
end
test_fuzz_save_writes_content_addressed()

local function test_fuzz_save_unset_writes_nothing()
  for _, setting in ipairs({"unset", "0"}) do
    local root = corpus_root("save-off-" .. setting)
    if setting == "unset" then
      assert(env.unset("FUZZ_SAVE"))
    else
      assert(env.set("FUZZ_SAVE", setting))
    end
    local seen: {string} = {}
    local ok = driver.run_unisolated(always_fails("save_off", seen))
    restore()
    check.equal(ok, false, "the property must fail for a save to be possible")
    check.truthy(not fs.is_dir(fs.join(root, "save_off")),
      "FUZZ_SAVE=" .. setting .. " must write nothing")
  end
end
test_fuzz_save_unset_writes_nothing()

local function test_fuzz_save_is_idempotent()
  local root = corpus_root("save-idempotent")
  local dir = fs.join(root, "save_idempotent")
  assert(env.set("FUZZ_SAVE", "1"))
  local stored = "found-twice"
  assert(not driver.run_unisolated(fails_on("save_idempotent", stored)))
  local after_first = check.must(fs.find(dir, {recursive = false, sorted = true}))
  check.equal(#after_first, 1, "the first run should write one corpus file")
  local first_bytes = check.must(fs.read(after_first[1]))
  -- The second run replays what the first stored, so it fails on the
  -- corpus entry rather than on a generated input — and saves nothing,
  -- because only the generated branch saves.
  assert(not driver.run_unisolated(fails_on("save_idempotent", stored)))
  restore()
  local after_second = check.must(fs.find(dir, {recursive = false, sorted = true}))
  check.equal(#after_second, 1, "re-finding the same bug must not grow the corpus")
  check.equal(after_second[1], after_first[1], "the corpus path should be stable")
  check.equal(check.must(fs.read(after_second[1])), first_bytes,
    "the stored bytes should be unchanged")
end
test_fuzz_save_is_idempotent()
