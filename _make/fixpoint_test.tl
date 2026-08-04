#!/usr/bin/env cosmic
-- The fixpoint: a `--make`-built cosmic builds cosmic again, and the
-- second generation equals the third byte for byte.
--
-- Gated here because nothing else notices it break: a regression in
-- the artifact pipeline, the payload generator, or the base selection
-- ships silently otherwise. A dropped payload has a characteristic
-- shape -- lose `tl.lua` and the type tree, or every compiled `_cli/**`
-- and `_make/**` module, and the binary still builds and still boots,
-- failing only when something first requires the missing piece.
--
-- Why gen2 AND gen3. gen2 proves the product WORKS; gen3 proves the
-- process CONVERGES, which is a separate claim and the easier one to
-- lose. Embedding onto the running cosmic leaves the stripped base's
-- bytes behind as dead space, so each generation grows ~3.5 MB (12.2 ->
-- 15.8 -> 19.3, measured) while every generation boots fine. Only
-- comparing two of them says so.
--
-- Gated behind COSMIC_FIXPOINT=1: two full `--make build`s cost ~83s,
-- more than every other test combined, and paying that on each `--make
-- test` (and again in `--make ci`'s coverage stage, the one
-- instrumented test run) taxed every developer loop for claims CI
-- already asserts per push on the REAL artifact: pr.yml's build lane
-- cmp's a second build (convergence, which catches the growth bug
-- above) and a clean-tree rebuild at another path (cold buildability,
-- reproducibility), and the converged gate plus the smoke lane
-- exercise the product. What stays unique here is the one-command
-- version of the whole story -- run it when touching the artifact
-- pipeline (_make/artifact, embed_gen, base selection):
-- `COSMIC_FIXPOINT=1 bin/cosmic --make test _make/fixpoint_test.tl`.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local hash = require("cosmic.hash")
local spawn = require("cosmic.child")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local repo = fs.abspath(".")
local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN") or "o/bin", "cosmic"))

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
    -- The Teal SOURCE too: `_types/types_gen.tl` extracts the `tl` shim
    -- from it, and a generation unit runs before the graph, so a copy
    -- without it fails before the first compile.
    {"tl", "tl.tl", "o/3p/tl/tl.tl"},
    {"cosmos", "make", "o/3p/cosmos/make"},
    -- Every base the generator names, not just the default one: seeding
    -- a subset only moves the failure to the next missing line.
    {"cosmos", "lua", "o/3p/cosmos/lua"},
    {"cosmos", "lua-debug", "o/3p/cosmos/lua-debug"},
  }
  for _, w in ipairs(want) do
    -- `o/3p` is where `--make fetch` unpacks a pin, and the ONLY
    -- place this looks: a fallback to some second location nothing
    -- writes (`o/staged/**` is the retired candidate) is not a
    -- fallback, it is a branch that can only ever return nil.
    local from = fs.join(repo, w[3])
    if not fs.isfile(from) then
      return false
    end
    copy(from, fs.join(dest, w[3]))
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
    -- depends on two builds being handed the same environment -- an
    -- unrecorded precondition that holds only while both generations
    -- happen to be stamped the same way.
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

-- Opt-in: this test builds the repo twice (~83s), so it stays out of
-- the default `--make test` / `--make ci` run; the header names the CI
-- steps that assert the same claims per push. `check.needs` is wrong
-- here -- it hard-fails when `CI` is set, and the gate lane runs in CI
-- and must be able to skip this test rather than fail on its absence.
if os.getenv("COSMIC_FIXPOINT") ~= "1" then
  print("skip: COSMIC_FIXPOINT=1 not set (this test runs two full " ..
    "builds; opt in when touching the artifact pipeline)")
  os.exit(check.EXIT_SKIP)
end

-- Both halves need the pinned inputs. Skipping when they are absent
-- keeps a cold checkout usable; in CI they are always there, because
-- the lane runs after the ordinary build.
if not check.needs("a built cosmic at " .. cosmic, fs.isfile(cosmic)) then
  os.exit(check.EXIT_SKIP)
end
if not check.needs("fetched pins to seed from",
  fs.isfile(fs.join(repo, "o/3p/tl/tl.lua"))) then
  os.exit(check.EXIT_SKIP)
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
