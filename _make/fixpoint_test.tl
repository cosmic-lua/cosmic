#!/usr/bin/env cosmic
-- The fixpoint: a `--make`-built cosmic builds cosmic again, and the
-- second generation equals the third byte for byte.
--
-- This is the branch's headline claim, and until now it was verified
-- only by hand -- so a regression to the artifact pipeline, the payload
-- generator, or the base selection would have shipped silently and the
-- property that names the branch would have rotted first. Both historic
-- silent-payload losses (3d dropped tl.lua and the type tree, 3h
-- dropped every compiled `_cli/**` and `_make/**` module) had exactly
-- this shape: the binary built, booted, and failed only when something
-- first required the missing piece.
--
-- Why gen2 AND gen3. gen2 proves the product WORKS. gen3 proves the
-- process CONVERGES, which is a different claim and the one that
-- actually broke: embedding onto the running cosmic left the stripped
-- base's bytes behind as dead space, so each generation grew ~3.5 MB
-- (12.2 -> 15.8 -> 19.3, measured). Every generation booted fine. Only
-- comparing two of them says so.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local hash = require("cosmic.hash")
local spawn = require("cosmic.child")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local repo = fs.abspath(".")
local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN") or "o/bin", "cosmic"))

--- Where the legacy pipeline stages a dependency, if it has.
---
--- The generator reads its pinned inputs from `o/3p/**`, which is where
--- `--make fetch` puts them; CI provisions the same bytes through the
--- older Makefile path into `o/staged/<dep>/<ver>-<sha>/`. Seeding
--- across keeps this lane OFFLINE -- it runs unchanged in the
--- no-network job -- and the coupling is deliberate: while both
--- pipelines are live (audit 030), something has to know they carry the
--- same bytes, and a test that fails loudly is the right thing to be
--- holding that knowledge.
--- @param dep string The dependency directory under o/staged
--- @param name string The file to find inside the staged version dir
--- @return string|nil The staged path
local function staged(dep: string, name: string): string | nil
  local base = fs.join(repo, "o/staged", dep)
  if not fs.isdir(base) then
    return nil
  end
  local found: string = nil
  fs.walk(base, function(path: string, entry: string): fs.WalkAction
      if entry == name and not found then
        found = path
      end
      return nil
    end)
  return found
end

--- Copy one file, creating the destination's directory.
local function copy(from: string, to: string)
  local body = check.must(fs.read(from))
  assert(fs.makedirs(fs.dirname(to)))
  assert(fs.write(to, body))
  local st = fs.stat(from)
  if st then
    fs.chmod(to, (st as fs_types.Stat):mode() & tonumber("777", 8)) -- cast: mixed-representation Stat
  end
end

--- Copy the working tree into `dest`, minus everything generated.
---
--- `git ls-files` would be the precise answer and is not available: the
--- test lane grants no host executables. Pruning `o/` and dotfiles gets
--- the same set for this repo, and a stray untracked file only makes
--- the copy larger, never the assertion weaker.
--- @param dest string Directory to populate
local function copy_tree(dest: string)
  assert(fs.makedirs(dest))
  local failure: string = nil
  fs.walk(repo, function(path: string, entry: string,
        st: fs_types.WalkStat): fs.WalkAction
      local rel = path:sub(#repo + 2)
      if entry:sub(1, 1) == "." or rel == "o" then
        return "skip"
      end
      if not st:is_file() then
        return nil
      end
      local body = fs.read(path)
      if not body then
        failure = "cannot read " .. rel
        return "stop"
      end
      local out = fs.join(dest, rel)
      if not fs.makedirs(fs.dirname(out)) or not fs.write(out, body) then
        failure = "cannot write " .. rel
        return "stop"
      end
      return nil
    end)
  assert(not failure, failure)
end

--- Seed a copied tree with the pinned bytes `--make fetch` would land.
--- @param dest string The copied tree's root
--- @return boolean True when every pinned input was found
local function seed_pins(dest: string): boolean
  local want: {{string, string, string}} = {
    {"tl", "tl.lua", "o/3p/tl/tl.lua"},
    {"cosmos", "make", "o/3p/cosmos/make"},
    {"cosmos", "lua", "o/3p/cosmos/lua"},
  }
  for _, w in ipairs(want) do
    -- Prefer this tree's own `o/3p` when a developer has run
    -- `--make fetch`; fall back to what the Makefile staged.
    local direct = fs.join(repo, w[3])
    local from = fs.isfile(direct) and direct or staged(w[1], w[2])
    if not from then
      return false
    end
    copy(from as string, fs.join(dest, w[3])) -- cast: scalar narrowing after the guard
  end
  return true
end

--- Run `cosmic --make build` in `dir` with `bin`, returning code and output.
---
--- The environment is named rather than inherited, and COSMIC_MAKE is
--- deliberately absent: letting the binary extract its own `/zip/make`
--- is what a user with nothing but this artifact gets, so that is the
--- path worth exercising.
--- @param bin string The cosmic to build WITH
--- @param dir string The tree to build
--- @return integer, string Exit code and combined output
local function build_with(bin: string, dir: string): integer, string
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "TMPDIR=" .. tmpdir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
    -- No `COSMIC_VERSION`, deliberately: the stamp is declared by the
    -- tree (`.version`, written by `generation`), which is what makes
    -- this a fixpoint over COMMITTED inputs rather than one that also
    -- depends on two builds being handed the same environment. That
    -- precondition used to be real and unrecorded -- it held only
    -- because both generations happened to be stamped the same way.
  }
  local h = check.must(spawn.spawn({bin, "--make", "build"},
      {cwd = dir, env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

--- Run a built cosmic with argv, returning code and combined output.
local function run(bin: string, ...: string): integer, string
  local argv: {string} = {bin}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "TMPDIR=" .. tmpdir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  local h = check.must(spawn.spawn(argv, {env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

--- Build one generation from a fresh copy of the tree.
--- @param label string Names the working directory
--- @param with string The cosmic to build with
--- @return string The path to the produced binary
local function generation(label: string, with: string): string
  local dir = fs.join(tmpdir, "fixpoint-" .. label)
  fs.rmrf(dir)
  copy_tree(dir)
  -- The version as a tree input. `copy_tree` skips dotfiles, so this is
  -- the copy's own declaration and never the developer's.
  assert(fs.write(fs.join(dir, ".version"),
      'return { cosmic = "fixpoint" }\n'))
  assert(seed_pins(dir), "seeding should succeed once the guard has passed")
  local code, out = build_with(with, dir)
  assert(code == 0, label .. ": --make build should succeed:\n" .. out)
  local built = fs.join(dir, "o/bin/cosmic")
  assert(fs.isfile(built), label .. ": no artifact at o/bin/cosmic:\n" .. out)
  return built
end

-- Both halves need the pinned inputs. Skipping when they are absent
-- keeps a cold checkout usable; in CI they are always there, because
-- the lane runs after the ordinary build.
if not check.needs("a built cosmic at " .. cosmic, fs.isfile(cosmic)) then
  os.exit(2)
end
if not check.needs("staged or fetched pins to seed from",
  staged("tl", "tl.lua") ~= nil or
  fs.isfile(fs.join(repo, "o/3p/tl/tl.lua"))) then
  os.exit(2)
end

-- gen2: the product works. Every check here is a capability the binary
-- only has if its payload arrived -- running a `.tl` needs tl.lua,
-- `--check types` needs the type tree AND the `.tl` sources,
-- `--docs` needs the index, `--version` needs the stamp, and `--make`
-- needs both the rules file and the embedded engine.
local gen2 = generation("gen2", cosmic)

local function test_the_product_is_a_cosmic()
  local script = fs.join(tmpdir, "fixpoint-script.tl")
  assert(fs.write(script,
      'local s = require("cosmic.string")\nprint(s.trim("  ok  "))\n'))

  local code, out = run(gen2, script)
  assert(code == 0 and out:find("ok", 1, true),
    "gen2 must run a .tl script (needs tl.lua): " .. out)

  code, out = run(gen2, "--check", "types", script)
  assert(code == 0,
    "gen2 must type-check (needs .types/** and .tl/**): " .. out)

  code, out = run(gen2, "--docs", "fs")
  assert(code == 0 and out:find("filesystem", 1, true),
    "gen2 must answer --docs (needs the index): " .. out)

  code, out = run(gen2, "--version")
  assert(code == 0 and out:find("fixpoint", 1, true),
    "gen2 must carry the version the TREE declared, with no " ..
    "COSMIC_VERSION in its build environment: " .. out)
end
test_the_product_is_a_cosmic()

-- gen3: the process converges. Built from a fresh copy of the same
-- tree, by gen2, with the same stamp -- so anything but equality is a
-- regression in the build, not a difference in the inputs.
local function test_the_fixpoint_converges()
  local gen3 = generation("gen3", gen2)
  local a = check.must(fs.read(gen2))
  local b = check.must(fs.read(gen3))
  assert(#a == #b, string.format(
      "gen2 and gen3 differ in size: %d vs %d (+%d). A growing fixpoint " ..
      "is not one -- check whether the artifact is being embedded onto " ..
      "the previous generation instead of onto its declared base.",
      #a, #b, #b - #a))
  assert(hash.sha256_hex(a) == hash.sha256_hex(b),
    "gen2 and gen3 are the same size but different bytes")
end
test_the_fixpoint_converges()

print("all fixpoint tests passed")
