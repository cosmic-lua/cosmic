#!/usr/bin/env cosmic
-- Tests for _make.stamp: per-tool identity instead of the whole binary.
--
-- Two properties carry the design. The stamps must MOVE when a tool's
-- inputs move (a pin bump, a tool-module edit) and HOLD otherwise --
-- write-if-changed, so an unmoved tool never invalidates the graph.
-- And the BOOT list must stay honest: it is a measured fact about what
-- a spawned cosmic loads, so a live child ratchets it here and a new
-- startup require fails this file instead of silently escaping every
-- stamp.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local graph = require("_make.graph")
local project = require("_make.project")
local stamp = require("_make.stamp")
local spawn = require("cosmic.child")
local types = require("_make.types")

local type Project = types.Project

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

-- The boot ratchet spawns the built binary; without one the file skips
-- whole, the same trade every engine-driving test makes (see
-- build_test): a cold checkout stays usable, CI treats absence as
-- provisioning broken.
local cosmic_bin = fs.abspath(fs.join(os.getenv("TEST_BIN") or "o/bin", "cosmic"))
if not check.needs("a built cosmic at " .. cosmic_bin, fs.isfile(cosmic_bin)) then
  os.exit(check.EXIT_SKIP)
end

--- Build a fixture tree and scan it.
local function fixture(name: string, files: {string: string}): Project
  local root = fs.join(tmpdir, "stamp-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  local proj = check.must(project.scan(root))
  return proj
end

--- Run fn with cwd inside dir, restoring it afterward.
local function in_dir<T>(dir: string, fn: function(): T): T
  local cwd = check.must(fs.getcwd())
  assert(fs.chdir(dir))
  local got = fn()
  assert(fs.chdir(cwd))
  return got
end

local app = fixture("app", {
    ["main.tl"] = "print('x')\n",
    ["db/init.tl"] = "return {}\n",
  })

-- Materialize writes one stamp per tool, before make could need it,
-- and the facts file names no COSMIC_DEP: the stamps ARE the tool
-- prerequisite now, so a leftover assignment would be a second,
-- coarser answer to the same question.
local function test_materialize_writes_every_stamp()
  in_dir(app.root, function(): boolean
      assert(check.must(graph.materialize(app, "/bin/cosmic")))
      for _, tool in ipairs(stamp.TOOLS) do
        local body = check.must(fs.read(stamp.path_of(tool)))
        assert(body:find(tool .. " ", 1, true) == 1
          or body:find("binary ", 1, true) == 1,
          tool .. ": unexpected stamp: " .. body)
      end
      local facts = check.must(fs.read("o/project.mk"))
      assert(not facts:find("COSMIC_DEP", 1, true),
        "the facts must not re-introduce the binary as the tool")
      return true
    end)
end
test_materialize_writes_every_stamp()

-- Write-if-changed: a second materialize with nothing moved must not
-- touch a stamp's mtime, or every graph rule re-runs on every verb --
-- the cascade this module exists to end, reintroduced by its own
-- bookkeeping.
local function test_unmoved_stamps_keep_their_mtime()
  in_dir(app.root, function(): boolean
      assert(check.must(graph.materialize(app, "/bin/cosmic")))
      local probe = stamp.path_of("compile")
      assert(fs.utimensat(probe, 0, 0, 0, 0))
      assert(check.must(graph.materialize(app, "/bin/cosmic")))
      local sec = check.must(fs.stat(probe)):mtim()
      assert(sec == 0, "an unmoved stamp must not be rewritten")
      return true
    end)
end
test_unmoved_stamps_keep_their_mtime()

-- Identity is a pure function of its inputs: same tool, same pins,
-- same binary, same bytes.
local function test_identity_is_deterministic()
  in_dir(app.root, function(): boolean
      local a = stamp.identity("compile", {}, "/bin/cosmic")
      local b = stamp.identity("compile", {}, "/bin/cosmic")
      assert(a == b, "identity must be stable")
      return true
    end)
end
test_identity_is_deterministic()

-- A pin is part of every tool's identity: it names the runtime base
-- and the vendored compiler, which no /zip byte of the running binary
-- reflects. Different pin bytes, different stamp.
local function test_pins_move_the_stamp()
  local pinned = fixture("pins", {
      ["main.tl"] = "print('x')\n",
      ["3p/dep/dep_pin.tl"] = "return { version = \"1\" }\n",
    })
  local first = in_dir(pinned.root, function(): string
      return stamp.identity("compile", {"3p/dep/dep_pin.tl"}, "/bin/cosmic")
    end)
  assert(fs.write(fs.join(pinned.root, "3p/dep/dep_pin.tl"),
      "return { version = \"2\" }\n"))
  local second = in_dir(pinned.root, function(): string
      return stamp.identity("compile", {"3p/dep/dep_pin.tl"}, "/bin/cosmic")
    end)
  assert(first ~= second, "a pin bump must move every stamp")
end
test_pins_move_the_stamp()

-- A root that is not embedded means the binary carries no per-tool
-- identity to read, and the answer is the honest coarse one, not a
-- stamp over a partial closure.
local function test_a_missing_root_yields_no_closure()
  assert(stamp.closure_of({"no.such.module"}) == nil,
    "a missing root must refuse, so identity falls back to the binary")
end
test_a_missing_root_yields_no_closure()

-- The ratchet: BOOT_MODULES is a measured fact, so measure it. A live
-- child dumps package.loaded; every loaded module that resolves to a
-- /zip file must be in the list, or a new startup require has escaped
-- every stamp -- the silent under-approximation this file exists to
-- refuse. (Names with no /zip file are the C bindings and the Lua
-- stdlib; the pins vouch for those.)
local function test_boot_list_covers_a_live_child()
  local script = fs.join(tmpdir, "stamp-dump.lua")
  assert(fs.write(script, "local ks = {}\n" ..
      "for k in pairs(package.loaded) do ks[#ks+1] = k end\n" ..
      "table.sort(ks)\nprint(table.concat(ks, \"\\n\"))\n"))
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "TMPDIR=" .. tmpdir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  local h = check.must(spawn.spawn({cosmic_bin, script}, {env = env}))
  local r = check.must(h:wait())
  assert(r.ok, "the child must run: " .. (r.stderr or ""))
  local listed: {string: boolean} = {}
  for _, name in ipairs(stamp.BOOT_MODULES) do
    listed[name] = true
  end
  for name in (r.stdout or ""):gmatch("[^\n]+") do
    local zipped = "/zip/" .. name:gsub("%.", "/") .. ".lua"
    assert(listed[name] or not fs.isfile(zipped),
      name .. " is loaded at boot but missing from BOOT_MODULES; " ..
      "add it in _make/stamp.tl or every stamp under-approximates")
  end
end
test_boot_list_covers_a_live_child()

print("all stamp tests passed")
