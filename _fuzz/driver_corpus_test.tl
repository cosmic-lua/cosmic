-- Corpus-replay and FUZZ_SAVE-write behavior of the fuzz driver.
-- The generated-loop mechanics (shrinking, budget, isolation, ...)
-- stay in `driver_test.tl`; this file holds only tests that read or
-- write files under `FUZZ_CORPUS_DIR`, which every test here points
-- at its own per-test directory under TEST_TMPDIR.

local check = require("cosmic.check")
local driver = require("_fuzz.driver")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local source = require("_fuzz.source")

local saved_corpus = env.get("FUZZ_CORPUS_DIR")
local saved_save = env.get("FUZZ_SAVE")
local saved_seed = env.get("FUZZ_SEED")

-- Every test restores every driver-visible env var it touched, so a
-- later test in the same file starts from the ambient environment.
local function restore()
  if saved_corpus then
    assert(env.set("FUZZ_CORPUS_DIR", saved_corpus))
  else
    assert(env.unset("FUZZ_CORPUS_DIR"))
  end
  if saved_save then
    assert(env.set("FUZZ_SAVE", saved_save))
  else
    assert(env.unset("FUZZ_SAVE"))
  end
  if saved_seed then
    assert(env.set("FUZZ_SEED", saved_seed))
  else
    assert(env.unset("FUZZ_SEED"))
  end
end

-- Write `bytes` under `<TEST_TMPDIR>/<name>/<basename>`, creating
-- the property directory the corpus code will read from.
local function seed_corpus_file(name: string, basename: string, bytes: string): string
  local dir = fs.join(check.must(env.get("TEST_TMPDIR")), name)
  assert(fs.make_dirs(dir))
  local path = fs.join(dir, basename)
  assert(fs.write(path, bytes))
  return path
end

local function test_no_corpus_dir_is_silent()
  assert(env.set("FUZZ_CORPUS_DIR", check.must(env.get("TEST_TMPDIR"))))
  local opts: driver.Options = {
    name = "no_corpus_here",
    iters = 4,
    gen = function(_: source.Recorder): string return "x" end,
    check = function(_: string): boolean, string return true, "" end,
  }
  local ok, msg = driver.run_unisolated(opts)
  restore()
  assert(ok, "an empty corpus is not a failure: " .. msg)
  assert(msg:find("iterations", 1, true), "generated loop must have run: " .. msg)
  assert(not msg:find("corpus=", 1, true), "no corpus tokens expected: " .. msg)
end
test_no_corpus_dir_is_silent()

local function test_corpus_entry_failure_is_reported()
  assert(env.set("FUZZ_CORPUS_DIR", check.must(env.get("TEST_TMPDIR"))))
  local bad = "boom"
  local sha = hash.sha256_hex(bad)
  seed_corpus_file("corpus_entry_failure", sha, bad)
  local opts: driver.Options = {
    name = "corpus_entry_failure",
    iters = 4,
    gen = function(_: source.Recorder): string return "x" end,
    check = function(input: string): boolean, string
      if input == bad then return false, "boom detected" end
      return true, ""
    end,
  }
  local ok, msg = driver.run_unisolated(opts)
  restore()
  assert(not ok, "corpus failure must fail the run: " .. msg)
  assert(msg:find("corpus=" .. sha, 1, true), "corpus basename missing: " .. msg)
  assert(msg:find("input(base64)=", 1, true), "base64 missing: " .. msg)
  assert(msg:find("boom detected", 1, true), "detail missing: " .. msg)
  assert(not msg:find("iteration=", 1, true),
    "no generated-loop token expected: " .. msg)
  assert(not msg:find("seed=", 1, true),
    "no generated-loop token expected: " .. msg)
  assert(not msg:find("draws=", 1, true),
    "no generated-loop token expected: " .. msg)
end
test_corpus_entry_failure_is_reported()

local function test_corpus_runs_before_generated_in_sorted_order()
  assert(env.set("FUZZ_CORPUS_DIR", check.must(env.get("TEST_TMPDIR"))))
  -- Basenames chosen to sort deterministically: "aaaa..." precedes
  -- "bbbb...". The generated loop would ALSO fail on any input, so
  -- the returned message must name the FIRST corpus entry — not the
  -- second, not a generated iteration.
  local first_name = ("a"):rep(64)
  local second_name = ("b"):rep(64)
  seed_corpus_file("corpus_ordering", first_name, "first")
  seed_corpus_file("corpus_ordering", second_name, "second")
  local opts: driver.Options = {
    name = "corpus_ordering",
    iters = 4,
    gen = function(_: source.Recorder): string return "generated" end,
    check = function(_: string): boolean, string
      return false, "everything fails"
    end,
  }
  local ok, msg = driver.run_unisolated(opts)
  restore()
  assert(not ok, "expected failure: " .. msg)
  assert(msg:find("corpus=" .. first_name, 1, true),
    "first-sorted corpus entry must be reported: " .. msg)
  assert(not msg:find("corpus=" .. second_name, 1, true),
    "second corpus entry must NOT be reported: " .. msg)
  assert(not msg:find("iteration=", 1, true),
    "generated loop must not have been reached: " .. msg)
end
test_corpus_runs_before_generated_in_sorted_order()

local function test_fuzz_save_writes_content_addressed()
  local tmpdir = check.must(env.get("TEST_TMPDIR"))
  assert(env.set("FUZZ_CORPUS_DIR", tmpdir))
  assert(env.set("FUZZ_SAVE", "1"))
  assert(env.set("FUZZ_SEED", "1"))
  local opts: driver.Options = {
    name = "save_content_addressed",
    iters = 4,
    gen = function(src: source.Recorder): string
      return driver.bytes(src, 8)
    end,
    check = function(_: string): boolean, string
      return false, "always fails"
    end,
  }
  local ok, _ = driver.run_unisolated(opts)
  assert(not ok, "expected failure")
  local dir = fs.join(tmpdir, "save_content_addressed")
  local files = check.must(fs.find(dir, {recursive = false, sorted = true}))
  assert(#files == 1, ("one corpus file expected, got %d"):format(#files))
  local basename = fs.basename(files[1])
  local bytes = check.must(fs.read(files[1]))
  assert(hash.sha256_hex(bytes) == basename,
    ("basename must be sha256(bytes): got %s vs %s"):format(
      basename, hash.sha256_hex(bytes)))
  restore()
end
test_fuzz_save_writes_content_addressed()

local function test_fuzz_save_unset_writes_nothing()
  local tmpdir = check.must(env.get("TEST_TMPDIR"))
  assert(env.set("FUZZ_CORPUS_DIR", tmpdir))
  assert(env.unset("FUZZ_SAVE"))
  local opts: driver.Options = {
    name = "save_unset_writes_nothing",
    iters = 4,
    gen = function(src: source.Recorder): string
      return driver.bytes(src, 8)
    end,
    check = function(_: string): boolean, string
      return false, "always fails"
    end,
  }
  local ok, _ = driver.run_unisolated(opts)
  assert(not ok, "expected failure")
  local dir = fs.join(tmpdir, "save_unset_writes_nothing")
  assert(not fs.is_dir(dir),
    "no corpus dir should be created when FUZZ_SAVE is unset: " .. dir)

  -- FUZZ_SAVE="0" also writes nothing (only the literal "1" opts in).
  assert(env.set("FUZZ_SAVE", "0"))
  local ok2, _ = driver.run_unisolated(opts)
  assert(not ok2, "expected failure")
  assert(not fs.is_dir(dir),
    "no corpus dir should be created when FUZZ_SAVE=0: " .. dir)
  restore()
end
test_fuzz_save_unset_writes_nothing()

local function test_fuzz_save_is_idempotent()
  local tmpdir = check.must(env.get("TEST_TMPDIR"))
  assert(env.set("FUZZ_CORPUS_DIR", tmpdir))
  assert(env.set("FUZZ_SAVE", "1"))
  assert(env.set("FUZZ_SEED", "1"))
  local opts: driver.Options = {
    name = "save_idempotent",
    iters = 4,
    gen = function(src: source.Recorder): string
      return driver.bytes(src, 8)
    end,
    check = function(_: string): boolean, string
      return false, "always fails"
    end,
  }
  local ok1, _ = driver.run_unisolated(opts)
  assert(not ok1)
  local dir = fs.join(tmpdir, "save_idempotent")
  local files1 = check.must(fs.find(dir, {recursive = false, sorted = true}))
  local bytes1 = check.must(fs.read(files1[1]))

  local ok2, _ = driver.run_unisolated(opts)
  assert(not ok2)
  local files2 = check.must(fs.find(dir, {recursive = false, sorted = true}))
  assert(#files2 == 1,
    ("idempotent write must leave one file, got %d"):format(#files2))
  local bytes2 = check.must(fs.read(files2[1]))
  assert(bytes1 == bytes2, "identical bytes on re-trigger")
  restore()
end
test_fuzz_save_is_idempotent()
