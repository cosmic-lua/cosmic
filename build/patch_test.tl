--- The patch applier (core/patch.c), run on trees built here: the
--- installed o/tool/patch, which a boot writes beside the cores.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local observations = require("build.filesystem_observations")

-- What these tests start is the tree's patch.
observations.confine({ reads = { "o/tool/patch" } })

--- The installed applier, or nil in a tree no boot has built: the
--- portable suite tests a fresh `git archive` of the tree, where nothing
--- under o/ was built, so no test here can run it. In a booted tree --
--- one with its cores under o/core -- a missing applier is a failure.
local function applier(): string | nil
  local root = assert(Fs.absolute("."))
  local path = root .. "/o/tool/patch"
  if Fs.exists(path) then
    return path
  end
  assert(not Fs.exists(root .. "/o/core"), path .. " is missing; run bin/zig build boot")
  return nil
end

--- A checkout at `root` with one vendored tree, `lib`, holding `files`,
--- and the patch records `records` for it (none when nil).
local function checkout(root: string, files: {string: string}, records?: {string: string})
  assert(Fs.mkdirs(root .. "/vendor/lib/src"))
  assert(Fs.write(root .. "/vendor/lib/PIN", "url https://example.invalid/lib.tar\n"))
  for name, data in pairs(files) do
    assert(Fs.write(root .. "/vendor/lib/" .. name, data))
  end
  if records ~= nil then
    assert(Fs.mkdirs(root .. "/patch/lib"))
    for name, data in pairs(records) do
      assert(Fs.write(root .. "/patch/lib/" .. name, data))
    end
  end
end

--- Runs the applier on `pin` into `out`: its exit code and stderr.
local function apply(tool: string, pin: string, out: string): integer, string
  local result = assert(Child.run({ tool, pin, out },
    { stdout = "capture", stderr = "capture" }))
  return result.code or -1, result.stderr or ""
end

local function record(file: string, find: string, replace: string): string
  return "file: " .. file .. "\nnote: a test\n--- find\n" .. find ..
    "\n--- replace\n" .. replace .. "\n--- end\n"
end

local function test_records_found_from_the_pin_are_applied(dir: string)
  local tool = applier()
  if tool == nil then return end
  checkout(dir .. "/root", { ["src/a.h"] = "#define X 1\n#define Y 2\n" },
    { ["01-x.txt"] = record("src/a.h", "#define X 1", "#define X 3") })
  local code, err = apply(tool, dir .. "/root/vendor/lib/PIN", dir .. "/out")
  assert(code == 0, err)
  assert(Fs.read(dir .. "/out/src/a.h") == "#define X 3\n#define Y 2\n")
  assert(Fs.read(dir .. "/root/vendor/lib/src/a.h") == "#define X 1\n#define Y 2\n",
    "the vendored tree itself was edited")
end

local function test_no_patch_directory_leaves_the_copy_pristine(dir: string)
  local tool = applier()
  if tool == nil then return end
  checkout(dir .. "/root", { ["src/a.h"] = "same\n" })
  local code, err = apply(tool, dir .. "/root/vendor/lib/PIN", dir .. "/out")
  assert(code == 0, err)
  assert(Fs.read(dir .. "/out/src/a.h") == "same\n")
  assert(Fs.read(dir .. "/out/PIN") ~= nil)
end

local function test_a_find_must_match_exactly_once(dir: string)
  local tool = applier()
  if tool == nil then return end
  checkout(dir .. "/none", { ["src/a.h"] = "abc\n" },
    { ["01-missing.txt"] = record("src/a.h", "xyz", "q") })
  local code, err = apply(tool, dir .. "/none/vendor/lib/PIN", dir .. "/out-none")
  assert(code == 1 and err:find("01-missing.txt", 1, true), err)

  checkout(dir .. "/twice", { ["src/a.h"] = "abc\nabc\n" },
    { ["01-twice.txt"] = record("src/a.h", "abc", "q") })
  code, err = apply(tool, dir .. "/twice/vendor/lib/PIN", dir .. "/out-twice")
  assert(code == 1 and err:find("01-twice.txt", 1, true), err)
end

--- A record whose bytes hold a `---` line names a fence of its own.
local function test_a_fence_header_lets_a_record_hold_the_default_fence(dir: string)
  local tool = applier()
  if tool == nil then return end
  local body = "--- find\nold\n"
  checkout(dir .. "/root", { ["doc.txt"] = body },
    { ["01-fence.txt"] = "fence: +++\nfile: doc.txt\nnote: a test\n+++ find\n" ..
      "--- find\nold\n+++ replace\n--- find\nnew\n+++ end\n" })
  local code, err = apply(tool, dir .. "/root/vendor/lib/PIN", dir .. "/out")
  assert(code == 0, err)
  assert(Fs.read(dir .. "/out/doc.txt") == "--- find\nnew\n")
end

local function test_a_path_not_shaped_like_a_vendored_pin_is_refused(dir: string)
  local tool = applier()
  if tool == nil then return end
  checkout(dir .. "/root", { ["src/a.h"] = "x\n" })
  assert(Fs.write(dir .. "/root/vendor/lib/NOTPIN", "x\n"))
  for _, pin in ipairs({
    dir .. "/root/vendor/lib/NOTPIN",
    dir .. "/root/lib/PIN",
    "PIN",
  }) do
    local code, err = apply(tool, pin, dir .. "/out")
    assert(code == 1 and err:find("expected <root>/vendor/<name>/PIN", 1, true), pin .. ": " .. err)
  end
end

--- Records apply in their names' order, each to what the one before
--- left, and a file in the patch directory not ending in .txt is none.
local function test_records_apply_in_name_order_and_only_txt_counts(dir: string)
  local tool = applier()
  if tool == nil then return end
  checkout(dir .. "/root", { ["a.h"] = "one\n" }, {
    ["02-second.txt"] = record("a.h", "two", "three"),
    ["01-first.txt"] = record("a.h", "one", "two"),
    ["03-ignored.orig"] = record("a.h", "three", "four"),
  })
  local code, err = apply(tool, dir .. "/root/vendor/lib/PIN", dir .. "/out")
  assert(code == 0, err)
  assert(Fs.read(dir .. "/out/a.h") == "three\n", Fs.read(dir .. "/out/a.h"))
end
