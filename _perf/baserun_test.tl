-- The structural wall against over-capture: `_perf/baserun.tl`'s value
-- is entirely in what its manifest root does NOT contain. A root that
-- also answered `cosmic.*` would put the tree's library on both sides
-- of the release compare and let a real regression cancel out, and
-- nothing about the manifest's bytes would look wrong. So the test
-- that matters here enumerates the constructed root and demands
-- exactly `_perf` and `o`, and `o` exactly `_perf`.

local baserun = require("_perf.baserun")
local check = require("cosmic.check")
local fs = require("cosmic.fs")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- The basenames directly inside a directory, sorted.
--- @param dir string The directory to list
--- @return {string} The entry basenames
local function entries(dir: string): {string}
  local found = check.must(fs.find(dir,
      {max_depth = 1, include_dirs = true, sorted = true}))
  local out: {string} = {}
  for _, p in ipairs(found) do
    out[#out + 1] = fs.basename(p)
  end
  return out
end

--- Render a name list for an assertion message.
--- @param names {string} The names
--- @return string Comma-joined
local function render(names: {string}): string
  return "{" .. table.concat(names, ", ") .. "}"
end

local function test_ensure_root_writes_a_manifest_rooted_at_treeroot()
  local root = fs.join(tmpdir, "manifest")
  assert(fs.make_dirs(root))
  local manifest = check.must(baserun.ensure_root(root, "o"))
  assert(manifest == fs.join(root, "o", "perf", "tree.modules"),
    "manifest landed at " .. manifest)
  local text = check.must(fs.read(manifest))
  local want = "root " .. fs.absolute_path(fs.join(root, "o", "perf", "treeroot"))
  assert(text:find(want .. "\n", 1, true) == 1,
    "manifest roots elsewhere:\n" .. text)
  assert(text:find("\nbuild o\n", 1, true), "no build line:\n" .. text)
end
test_ensure_root_writes_a_manifest_rooted_at_treeroot()

local function test_the_root_holds_perf_and_nothing_else()
  local root = fs.join(tmpdir, "scoped")
  assert(fs.make_dirs(root))
  check.must(baserun.ensure_root(root, "o"))
  local base = fs.join(root, "o", "perf", "treeroot")
  local top = entries(base)
  assert(#top == 2 and top[1] == "_perf" and top[2] == "o",
    "the root must hold exactly {_perf, o}; got " .. render(top))
  local built = entries(fs.join(base, "o"))
  assert(#built == 1 and built[1] == "_perf",
    "the root's build dir must hold exactly {_perf}; got " .. render(built))
end
test_the_root_holds_perf_and_nothing_else()

local function test_ensure_root_is_idempotent()
  local root = fs.join(tmpdir, "twice")
  assert(fs.make_dirs(root))
  local first = check.must(baserun.ensure_root(root, "o"))
  local second = check.must(baserun.ensure_root(root, "o"))
  assert(first == second, "manifest path moved: " .. first .. " vs " .. second)
  local base = fs.join(root, "o", "perf", "treeroot")
  local top = entries(base)
  assert(#top == 2, "a second call added entries: " .. render(top))
  local link = check.must(fs.readlink(fs.join(base, "_perf")))
  assert(link == fs.absolute_path(fs.join(root, "_perf")),
    "the tree link points at " .. link)
end
test_ensure_root_is_idempotent()

local function test_argv_puts_modules_before_the_entry()
  local a = baserun.argv("BIN", "M.modules", {"--only", "time"})
  local want = {"BIN", "--modules", "M.modules", "o/_perf/run.lua", "--only", "time"}
  assert(#a == #want, "argv length " .. tostring(#a))
  for i, w in ipairs(want) do
    assert(a[i] == w, "argv[" .. tostring(i) .. "] = " .. tostring(a[i]) ..
      ", want " .. w)
  end
end
test_argv_puts_modules_before_the_entry()

local function test_argv_with_no_extras_ends_at_the_entry()
  local a = baserun.argv("BIN", "M.modules", {})
  assert(#a == 4, "argv length " .. tostring(#a))
  assert(a[4] == "o/_perf/run.lua", "entry is " .. tostring(a[4]))
end
test_argv_with_no_extras_ends_at_the_entry()
