#!/usr/bin/env cosmic
-- Tests for _make.seed: the pass that fills o/_types/types_gen from
-- the fetched pins before any generator's import closure compiles.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local project = require("_make.project")
local seed = require("_make.seed")
local types = require("_make.types")

local type Project = types.Project

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Same fixture builder as `_make/project_test.tl`'s.
local function fixture(name: string, files: {string: string}): Project
  local root = fs.join(tmpdir, "seed-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.make_dirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  if not fs.is_file(fs.join(root, "main.tl"))
  and not fs.is_file(fs.join(root, "main.lua")) then
    assert(fs.write(fs.join(root, ".cosmicignore"), ""))
  end
  return check.must(project.scan(root))
end

-- The real testdata/hello model, not a lookalike: it owns no
-- `_types/types_gen.tl`, so it never seeds.
local function test_should_seed_is_false_with_no_types_generator()
  local proj = check.must(project.scan(fs.absolute_path("_make/testdata/hello")))
  assert(not seed.should_seed(proj), "hello has no _types/types_gen.tl")
end

-- Owns the generator and has not produced its output yet: seeds, and
-- stops once the real output exists -- the model never changes here,
-- only the disk answer does.
local function test_should_seed_true_until_the_real_output_exists()
  local proj = fixture("should", {
      ["_types/types_gen.tl"] = "-- stub\n",
    })
  assert(seed.should_seed(proj), "owns the generator, output absent")
  assert(fs.make_dirs(fs.join(proj.root, "o/_types/types_gen")))
  assert(not seed.should_seed(proj), "the real output already exists")
end

-- A leftover SEED_DIR outliving an invocation killed before `sources`'s
-- own cleanup call is not proof cleanup ever ran -- even with the real
-- output already present, `should_seed` must still say yes so the next
-- invocation re-seeds rather than trusting a possibly-partial leftover.
local function test_should_seed_true_with_leftover_seed_dir()
  local proj = fixture("leftover", {
      ["_types/types_gen.tl"] = "-- stub\n",
    })
  assert(fs.make_dirs(fs.join(proj.root, "o/_types/types_gen")))
  assert(not seed.should_seed(proj), "the real output already exists")
  assert(fs.make_dirs(fs.join(proj.root, seed.SEED_DIR)))
  assert(seed.should_seed(proj), "leftover SEED_DIR means cleanup never ran")
end

-- `run` populates SEED_DIR from the generator itself, then promotes it
-- straight into TYPES_GEN_DIR -- the one path every project's compile
-- include list already hardcodes, so an interpreted searcher's on-demand
-- compile (never just the one generator-script compile `closure_argv`
-- flags explicitly) sees the seed too. SEED_DIR is gone once `run`
-- returns; `cleanup` is then a no-op on the path it would have cleared.
local function test_run_populates_and_promotes_to_types_gen_dir()
  local proj = fixture("run", {
      ["_types/types_gen.tl"] = 'local fs = require("cosmic.fs")\n'
      .. 'assert(fs.make_dirs(arg[1]))\n'
      .. 'assert(fs.write(fs.join(arg[1], "stub.txt"), "seeded\\n"))\n',
    })
  local cwd = check.must(fs.cwd())
  assert(fs.set_cwd(proj.root))
  local ok, err = seed.run(proj, cosmic)
  assert(ok, err)
  assert(not fs.is_present(seed.SEED_DIR), "SEED_DIR is promoted away, not left behind")
  local stub = fs.join(seed.TYPES_GEN_DIR, "stub.txt")
  assert(fs.is_file(stub), "the promoted dir carries the generator's own output")
  assert(check.must(fs.read(stub)) == "seeded\n", "with the generator's own output")
  local cok, cerr = seed.cleanup()
  assert(cok, cerr)
  assert(not fs.is_present(seed.SEED_DIR), "cleanup is a no-op once run already promoted it")
  assert(fs.set_cwd(cwd))
end

print("all seed tests passed")
