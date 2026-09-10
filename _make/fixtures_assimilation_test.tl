#!/usr/bin/env cosmic
--- requires: ape-assimilation
--- reads: _make/artifact.tl
--- Linux assimilation fixture, split from fixtures_test so unsupported
--- local hosts can report the exact unavailable capability without hiding
--- the portable fixture coverage beside it.

local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")

local cosmic = fs.absolute_path(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local make_bin = fs.absolute_path(os.getenv("COSMIC_MAKE") or "o/make")
check.needs("the make engine at " .. make_bin, fs.is_file(make_bin))

local function test_hello_is_fat_when_built_under_an_assimilated_copy()
  local sim_elf = fs.join(tmpdir, "simboot", "cosmic")
  assert(fs.make_dirs(fs.dirname(sim_elf)))
  assert(fs.copy(cosmic, sim_elf .. ".ape"))
  assert(fs.copy(cosmic, sim_elf))
  assert(fs.write(sim_elf .. ".pin", "test\n"))
  -- Through /bin/sh, like bin/cosmic: spawning an APE directly bypasses
  -- the shell trampoline that implements --assimilate.
  local h = check.must(child.start({"/bin/sh", "-c",
        sim_elf .. " --assimilate"}))
  local r = check.must(h:wait())
  assert((r.code or 128) == 0,
    "assimilate should succeed: " .. (r.stderr or ""))
  local reshaped = check.must(fs.read(sim_elf))
  assert(reshaped:sub(1, 2) ~= "MZ", "copy should now be a native image")

  local root = fs.join(tmpdir, "fixtures", "assimilated-hello")
  assert(fs.make_dirs(fs.dirname(root)))
  assert(fs.copy_tree(fs.join("_make", "testdata", "hello"), root))
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "COSMIC_MAKE=" .. make_bin,
    "TMPDIR=" .. tmpdir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  h = check.must(child.start({sim_elf, "--make", "build"},
      {cwd = root, env = env}))
  r = check.must(h:wait())
  local out = (r.stdout or "") .. (r.stderr or "")
  assert((r.code or 128) == 0,
    "build under the assimilated copy should pass:\n" .. out)
  local built = check.must(fs.read(fs.join(root, "o/bin/hello")))
  assert(built:sub(1, 2) == "MZ",
    "artifact should be the fat APE base, got: " .. built:sub(1, 4))
end

print("assimilation fixture test passed")
