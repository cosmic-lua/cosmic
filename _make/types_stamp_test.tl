#!/usr/bin/env cosmic
-- The generated-types stamp: `o/_types/types_gen` sits first on every
-- compile include path but is GENERATED, cleared and rewritten by every
-- graph verb -- so freshness has to hang off a content-addressed stamp
-- (`_make.generate`'s stamp_types), not the directory's own mtimes.
-- These tests pin both halves: the make-layer behavior (a byte change
-- recompiles a file that never imports the generator; a no-op build
-- recompiles nothing) and the stamp file's own contract (a real digest
-- for real declarations, the "empty" sentinel for a project without
-- any).

local cenv = require("cosmic.env")
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local mk = require("_make")
local child = require("cosmic.child")

local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

-- The engine, by the same rule the code uses: COSMIC_MAKE names it,
-- else the copy `--make` extracts from its own binary.
local make_bin = fs.abspath(os.getenv("COSMIC_MAKE")
  or "o/make")
check.needs("the make engine at " .. make_bin, fs.is_file(make_bin))

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "typestamp-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.make_dirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  assert(fs.write(fs.join(root, ".cosmicignore"), ""))
  return root
end

--- `cosmic --make …` inside dir, with the engine named.
local function make(dir: string, ...: string): integer, string
  local argv: {string} = {cosmic, "--make"}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "COSMIC_MAKE=" .. make_bin,
    "TMPDIR=" .. tmpdir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  local h = check.must(child.start(argv, {cwd = dir, env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

--- One in-process `--make build` against root, restoring cwd after.
local function build_in_process(root: string): integer
  local cwd = check.must(fs.cwd())
  assert(cenv.set("COSMIC_MAKE_ROOT", root))
  assert(cenv.set("COSMIC_MAKE", make_bin))
  local code = mk.run({"build"})
  assert(cenv.unset("COSMIC_MAKE_ROOT"))
  assert(cenv.unset("COSMIC_MAKE"))
  assert(fs.chdir(cwd))
  return code
end

--- A stand-in types generator whose output bytes carry `version`.
local function gen_script(version: string): string
  return "local fs = require('cosmic.fs')\nlocal out = arg[1]\n" ..
  "assert(fs.make_dirs(out))\nassert(fs.write(fs.join(out, 'gen.d.tl'), '-- " ..
  version .. "'))\n"
end

-- The make layer: a types byte change recompiles a file that never
-- imports the generator, while an unchanged second build recompiles
-- nothing. Subprocess builds, deliberately -- each is a fresh process,
-- so the generator really reruns and only the stamp decides freshness.
local function test_a_types_gen_change_recompiles_unrelated_files()
  local recompiled = "compile o/cmd/tool/main.lua"
  local root = fixture("typesgate", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["_types/types_gen.lua"] = gen_script("v1"),
    })
  local code1, out1 = make(root, "build")
  assert(code1 == 0 and out1:find(recompiled, 1, true),
    "the first build compiles main.tl: " .. out1)

  local code2, out2 = make(root, "build")
  assert(code2 == 0 and not out2:find(recompiled, 1, true),
    "an unchanged second build must not recompile main.tl: " .. out2)

  -- OUTPUT changes (a stand-in for a cosmos pin bump); main.tl imports
  -- nothing from it, so only the include-path hazard explains a recompile.
  assert(fs.write(fs.join(root, "_types/types_gen.lua"), gen_script("v2")))
  local code3, out3 = make(root, "build")
  assert(code3 == 0 and out3:find(recompiled, 1, true),
    "a real types change must recompile an unrelated file too: " .. out3)
end
test_a_types_gen_change_recompiles_unrelated_files()

-- The stamp itself, for a project WITH generated types: a real,
-- hex-shaped digest, not the sentinel. In-process so the digesting code
-- runs under this test's own coverage.
local function test_stamp_is_a_content_digest()
  local root = fixture("digest", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
      ["_types/types_gen.lua"] = gen_script("v1"),
    })
  assert(build_in_process(root) == 0, "build should succeed")
  local stamp = check.must(fs.read(fs.join(root, "o/_types/types_gen.stamp")))
  assert(stamp:match("^%x+\n$") and #stamp == 65,
    "the stamp holds one sha256 hex digest line, got: " .. stamp)
end
test_stamp_is_a_content_digest()

-- And for a project with NO types generator: the sentinel, so the
-- compile prerequisite always resolves to a real file. The output
-- directory pre-exists but is empty -- the digest must treat "empty
-- directory" exactly like "no directory".
local function test_stamp_sentinel_without_generated_types()
  local root = fixture("sentinel", {
      ["cmd/tool/main.tl"] = "print('tool')\n",
    })
  assert(fs.make_dirs(fs.join(root, "o/_types/types_gen")))
  assert(build_in_process(root) == 0, "build should succeed")
  local stamp = check.must(fs.read(fs.join(root, "o/_types/types_gen.stamp")))
  assert(stamp == "empty\n",
    "an empty generated-types dir digests to the sentinel, got: " .. stamp)
end
test_stamp_sentinel_without_generated_types()
