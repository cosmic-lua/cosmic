--- The patch applier (`build/patch.tl`), run on trees built here.
local Fs = require("cosmic.fs")
local Patch = require("build.patch")
local sys = require("cosmic.sys")

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

local function record(file: string, find: string, replace: string): string
  return "file: " .. file .. "\nnote: a test\n--- find\n" .. find ..
    "\n--- replace\n" .. replace .. "\n--- end\n"
end

local function test_records_are_applied_to_a_copy(dir: string)
  checkout(dir .. "/root", { ["src/a.h"] = "#define X 1\n#define Y 2\n" },
    { ["01-x.txt"] = record("src/a.h", "#define X 1", "#define X 3") })
  assert(Patch.tree(dir .. "/root", "lib", dir .. "/out"))
  assert(Fs.read(dir .. "/out/src/a.h") == "#define X 3\n#define Y 2\n")
  assert(Fs.read(dir .. "/root/vendor/lib/src/a.h") == "#define X 1\n#define Y 2\n",
    "the vendored tree itself was edited")
end

local function test_no_patch_directory_leaves_the_copy_pristine(dir: string)
  checkout(dir .. "/root", { ["src/a.h"] = "same\n" })
  assert(Patch.tree(dir .. "/root", "lib", dir .. "/out"))
  assert(Fs.read(dir .. "/out/src/a.h") == "same\n")
  assert(Fs.read(dir .. "/out/PIN") ~= nil)
end

--- A file keeps its permission bits, which a patched one keeps too; one
--- its owner cannot write is still written whole. (Whether anything was
--- synced is not seen here.)
local function test_a_copy_keeps_each_files_mode(dir: string)
  checkout(dir .. "/root", { ["run.sh"] = "echo old\n", ["plain.h"] = "x\n",
    ["fixed.h"] = "y\n" },
    { ["01-run.txt"] = record("run.sh", "echo old", "echo new") })
  assert(Fs.chmod(dir .. "/root/vendor/lib/run.sh", 0x1ed))
  assert(Fs.chmod(dir .. "/root/vendor/lib/plain.h", 0x180))
  assert(Fs.chmod(dir .. "/root/vendor/lib/fixed.h", 0x124))
  assert(Patch.tree(dir .. "/root", "lib", dir .. "/out"))
  assert(assert(Fs.stat(dir .. "/out/run.sh")).mode & 0x1ff == 0x1ed)
  assert(assert(Fs.stat(dir .. "/out/plain.h")).mode & 0x1ff == 0x180)
  assert(assert(Fs.stat(dir .. "/out/fixed.h")).mode & 0x1ff == 0x124)
  assert(Fs.read(dir .. "/out/fixed.h") == "y\n")
  assert(Fs.read(dir .. "/out/run.sh") == "echo new\n")
end

--- A file that cannot be written fails the tree, naming the path.
local function test_an_unwritable_file_fails_the_tree(dir: string)
  checkout(dir .. "/root", { ["a.h"] = "x\n" })
  assert(Fs.mkdirs(dir .. "/out/a.h"))
  local ok, err = Patch.tree(dir .. "/root", "lib", dir .. "/out")
  assert(not ok and err:find(dir .. "/out/a.h", 1, true), err)
end

local function test_a_find_must_match_exactly_once(dir: string)
  checkout(dir .. "/none", { ["src/a.h"] = "abc\n" },
    { ["01-missing.txt"] = record("src/a.h", "xyz", "q") })
  local ok, err = Patch.tree(dir .. "/none", "lib", dir .. "/out-none")
  assert(not ok and err:find("01-missing.txt", 1, true) and
    err:find("found 0 matches", 1, true), err)

  checkout(dir .. "/twice", { ["src/a.h"] = "abc\nabc\n" },
    { ["01-twice.txt"] = record("src/a.h", "abc", "q") })
  ok, err = Patch.tree(dir .. "/twice", "lib", dir .. "/out-twice")
  assert(not ok and err:find("01-twice.txt", 1, true) and
    err:find("found 2 matches", 1, true), err)
end

--- Matches may overlap: "aa" occurs twice in "aaa", and is refused.
local function test_overlapping_matches_count_twice()
  local parsed = assert(Patch.parse(record("a", "aa", "b"), "r"))
  local out, err = Patch.apply("aaa", parsed, "r")
  assert(out == nil and err:find("found 2 matches", 1, true), err)
end

--- A record whose bytes hold a `---` line names a fence of its own.
local function test_a_fence_header_lets_a_record_hold_the_default_fence(dir: string)
  local body = "--- find\nold\n"
  checkout(dir .. "/root", { ["doc.txt"] = body },
    { ["01-fence.txt"] = "fence: +++\nfile: doc.txt\nnote: a test\n+++ find\n" ..
      "--- find\nold\n+++ replace\n--- find\nnew\n+++ end\n" })
  assert(Patch.tree(dir .. "/root", "lib", dir .. "/out"))
  assert(Fs.read(dir .. "/out/doc.txt") == "--- find\nnew\n")
end

--- An empty replace block deletes the find's bytes.
local function test_an_empty_replace_deletes()
  local parsed = assert(Patch.parse(
    "file: a\nnote: n\n--- find\ncut\n--- replace\n--- end\n", "r"))
  assert(parsed.replace == "")
  assert(Patch.apply("keep cut keep", parsed, "r") == "keep  keep")
end

local function test_a_malformed_record_is_refused_by_name()
  for _, case in ipairs({
    { "note: n\n--- find\na\n--- replace\nb\n--- end\n", "expected a 'file: ' line" },
    { "file: a\n--- find\na\n--- replace\nb\n--- end\n", "expected a 'note: ' line" },
    { "file: a\nnote: \n--- find\na\n--- replace\nb\n--- end\n", "the note says nothing" },
    { "file: a\nnote: n\na\n--- replace\nb\n--- end\n", "no '--- find' line" },
    { "file: a\nnote: n\n--- find\na\nb\n--- end\n", "no '--- replace' line" },
    { "file: a\nnote: n\n--- find\na\n--- replace\nb\n", "no '--- end' line" },
    { "file: a\nnote: n\n--- find\n--- replace\nb\n--- end\n", "the find block is empty" },
  }) do
    local parsed, err = Patch.parse(case[1], "bad.txt")
    assert(parsed == nil and err:find("bad.txt", 1, true) and
      err:find(case[2], 1, true), case[2] .. ": " .. err)
  end
end

--- Records apply in their names' order, each to what the one before
--- left, and a file in the patch directory not ending in .txt is none.
local function test_records_apply_in_name_order_and_only_txt_counts(dir: string)
  checkout(dir .. "/root", { ["a.h"] = "one\n" }, {
    ["02-second.txt"] = record("a.h", "two", "three"),
    ["01-first.txt"] = record("a.h", "one", "two"),
    ["03-ignored.orig"] = record("a.h", "three", "four"),
  })
  assert(Patch.tree(dir .. "/root", "lib", dir .. "/out"))
  assert(Fs.read(dir .. "/out/a.h") == "three\n", Fs.read(dir .. "/out/a.h"))
end

--- The directory a tree is prepared into is named by its contents: the
--- applier, every vendored file and every record. Unchanged, it is found
--- again as it stands; any one changed, it is another directory.
local function test_a_prepared_tree_is_named_by_its_contents(dir: string)
  local root = dir .. "/root"
  checkout(root, { ["a.h"] = "one\n" }, { ["01.txt"] = record("a.h", "one", "two") })
  local cache = dir .. "/cache"
  local first = assert(Patch.prepare(root, "lib", cache, "applier"))
  assert(Fs.read(first .. "/a.h") == "two\n")
  -- A tree found again is not written again.
  assert(Fs.write(first .. "/marker", "kept"))
  assert(Patch.prepare(root, "lib", cache, "applier") == first)
  assert(Fs.read(first .. "/marker") == "kept")

  assert(Patch.prepare(root, "lib", cache, "another applier") ~= first)
  assert(Fs.write(root .. "/vendor/lib/a.h", "one\n\n"))
  local vendored = assert(Patch.prepare(root, "lib", cache, "applier"))
  assert(vendored ~= first and Fs.read(vendored .. "/a.h") == "two\n\n")
  assert(Fs.write(root .. "/patch/lib/01.txt", record("a.h", "one", "three")))
  local recorded = assert(Patch.prepare(root, "lib", cache, "applier"))
  assert(recorded ~= vendored and Fs.read(recorded .. "/a.h") == "three\n\n")

  -- Another checkout of the same tree names the same directory.
  local other = dir .. "/other"
  checkout(other, { ["a.h"] = "one\n\n" }, { ["01.txt"] = record("a.h", "one", "three") })
  assert(Patch.prepare(other, "lib", cache, "applier") == recorded)
end

--- A tree whose record fails leaves nothing at its name.
local function test_a_failed_tree_leaves_nothing_behind(dir: string)
  local root = dir .. "/root"
  checkout(root, { ["a.h"] = "one\n" }, { ["01.txt"] = record("a.h", "absent", "x") })
  local cache = dir .. "/cache"
  local made, err = Patch.prepare(root, "lib", cache, "applier")
  assert(made == nil and err:find("found 0 matches", 1, true), err)
  assert(#assert(Fs.list(cache)) == 0, "a failed tree left something in the cache")
end

--- Every vendored tree with a PIN, in name order.
local function test_names_are_the_pinned_trees(dir: string)
  assert(Fs.mkdirs(dir .. "/vendor/b"))
  assert(Fs.write(dir .. "/vendor/b/PIN", "x"))
  assert(Fs.mkdirs(dir .. "/vendor/a"))
  assert(Fs.write(dir .. "/vendor/a/PIN", "x"))
  assert(Fs.mkdirs(dir .. "/vendor/unpinned"))
  local names = assert(Patch.names(dir))
  assert(#names == 2 and names[1] == "a" and names[2] == "b")
end

--- A link is not upstream source: neither it nor what it names is
--- copied, and a loop of them stops nothing. An empty directory is.
local function test_links_are_left_out_and_empty_directories_kept(dir: string)
  checkout(dir .. "/root", { ["a.h"] = "x\n" })
  assert(Fs.write(dir .. "/outside", "not the tree's"))
  assert(sys.symlink(dir .. "/outside", dir .. "/root/vendor/lib/linked.h"))
  assert(sys.symlink(".", dir .. "/root/vendor/lib/loop"))
  assert(Fs.mkdirs(dir .. "/root/vendor/lib/empty"))
  assert(Patch.tree(dir .. "/root", "lib", dir .. "/out"))
  assert(Fs.exists(dir .. "/out/linked.h") == false)
  assert(Fs.exists(dir .. "/out/loop") == false)
  assert(assert(Fs.stat(dir .. "/out/empty")).kind == "dir")
  assert(Fs.read(dir .. "/out/a.h") == "x\n")
end
