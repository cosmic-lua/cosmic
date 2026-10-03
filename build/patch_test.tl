--- The patch applier ([`build/patch.tl`]), run on trees built here.
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
--- its owner cannot write is still written whole.
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
--- patched tree as written. Unchanged, it is found again as it stands;
--- any byte of it changed, it is another directory.
local function test_a_prepared_tree_is_named_by_its_contents(dir: string)
  local root = dir .. "/root"
  checkout(root, { ["a.h"] = "one\n" }, { ["01.txt"] = record("a.h", "one", "two") })
  local cache = dir .. "/cache"
  local first = assert(Patch.prepare(root, "lib", cache))
  assert(Fs.read(first .. "/a.h") == "two\n")
  -- A tree found again is not written again.
  assert(Fs.write(first .. "/marker", "kept"))
  assert(Patch.prepare(root, "lib", cache) == first)
  assert(Fs.read(first .. "/marker") == "kept")

  assert(Fs.write(root .. "/vendor/lib/a.h", "one\n\n"))
  local vendored = assert(Patch.prepare(root, "lib", cache))
  assert(vendored ~= first and Fs.read(vendored .. "/a.h") == "two\n\n")
  assert(Fs.write(root .. "/patch/lib/01.txt", record("a.h", "one", "three")))
  local recorded = assert(Patch.prepare(root, "lib", cache))
  assert(recorded ~= vendored and Fs.read(recorded .. "/a.h") == "three\n\n")
  local mode = assert(sys.stat(root .. "/vendor/lib/a.h")).mode & 0x1ff
  assert(sys.chmod(root .. "/vendor/lib/a.h", mode ~ 0x40))
  local moded = assert(Patch.prepare(root, "lib", cache))
  assert(moded ~= recorded, "a file's mode changed and its tree kept its name")
  assert(sys.chmod(root .. "/vendor/lib/a.h", mode))

  -- Another checkout of the same tree names the same directory.
  local other = dir .. "/other"
  checkout(other, { ["a.h"] = "one\n\n" }, { ["01.txt"] = record("a.h", "one", "three") })
  assert(Patch.prepare(other, "lib", cache) == recorded)
end

--- A tree is named by what is written, not by what writes it: records
--- that write the same bytes -- a note reworded, a record renamed, or
--- split in two -- name the same directory, so zig, keyed by a source's
--- path, compiles none of it again; the applier's own source is in no
--- key for the same reason.
local function test_records_writing_the_same_bytes_name_the_same_tree(dir: string)
  local root = dir .. "/root"
  checkout(root, { ["a.h"] = "one\n" }, { ["01.txt"] = record("a.h", "one", "three") })
  local cache = dir .. "/cache"
  local first = assert(Patch.prepare(root, "lib", cache))
  assert(Fs.write(root .. "/patch/lib/01.txt",
    "file: a.h\nnote: reworded\n--- find\none\n--- replace\nthree\n--- end\n"))
  assert(Patch.prepare(root, "lib", cache) == first, "a reworded note named another tree")
  assert(Fs.write(root .. "/patch/lib/01.txt", record("a.h", "one", "two")))
  assert(Fs.write(root .. "/patch/lib/02.txt", record("a.h", "two", "three")))
  assert(Patch.prepare(root, "lib", cache) == first, "records split in two named another tree")
  assert(#assert(Fs.list(cache)) == 2, "a tree of the same bytes was written again")
end

--- A tree whose record fails leaves nothing at its name.
local function test_a_failed_tree_leaves_nothing_behind(dir: string)
  local root = dir .. "/root"
  checkout(root, { ["a.h"] = "one\n" }, { ["01.txt"] = record("a.h", "absent", "x") })
  local cache = dir .. "/cache"
  local made, err = Patch.prepare(root, "lib", cache)
  assert(made == nil and err:find("found 0 matches", 1, true), err)
  local left, _ = Fs.list(cache)
  assert(left == nil or #left == 0, "a failed tree left something in the cache")
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
--- copied, and a loop of them stops nothing. An empty directory is
--- copied.
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

--- Fault injection checks the publication boundary on every platform;
--- the native cases below separately exercise Darwin's actual syscall.
local function darwin_flush_case(tmp: string, empty: boolean, fail: boolean)
  local root, cache = tmp .. "/source", tmp .. "/cache"
  if empty then
    assert(Fs.mkdirs(root .. "/vendor/lib/empty"))
  else
    checkout(root, { ["src/a.h"] = "payload\n" })
  end
  local real_uname, real_flush = sys.uname, sys.full_fsync
  local real_sync, real_rename = Fs.fsync, Fs.rename
  local raw, fs = sys as {string:any}, Fs as {string:any}
  local syncs, flushes, owner = 0, 0, -1
  local renamed = false
  raw.uname = function(): sys.Uname
    local names = assert(real_uname())
    names.sysname = "Darwin"
    return names
  end
  fs.fsync = function(fd: integer): boolean, string
    assert(flushes == 0 or renamed, "payload fsync followed the device flush")
    syncs = syncs + 1
    return real_sync(fd)
  end
  raw.full_fsync = function(fd: integer): boolean, string, integer
    flushes, owner = flushes + 1, fd
    assert(syncs > 0 and not renamed, "full flush preceded payload sync or followed rename")
    local st = assert(sys.fstat(fd))
    assert(st.kind == "file", "full flush used a directory descriptor")
    local found = false
    for _, name in ipairs((assert(Fs.list(cache)))) do
      if name:match("^%.scratch%.") then
        local held = assert(Fs.stat(cache .. "/" .. name .. "/owner"))
        local payload = assert(Fs.stat(cache .. "/" .. name .. "/payload"))
        assert(st.dev == payload.dev, "owner is not on the payload filesystem")
        if st.ino == held.ino and st.dev == held.dev then found = true end
      end
    end
    assert(found, "full flush did not use the held scratch owner")
    if fail then return false, "injected full flush failure", sys.EBADF end
    return true, "", 0
  end
  fs.rename = function(from: string, to: string): boolean, string
    assert(flushes == 1 and not fail, "payload published without a successful full flush")
    renamed = true
    return real_rename(from, to)
  end
  local ok, problem = pcall(function(): boolean
    local path, trouble = Patch.prepare(root, "lib", cache)
    assert(flushes == 1, "device flush missing or repeated")
    assert(sys.fstat(owner) == nil, "scratch owner descriptor leaked")
    if fail then
      assert(path == nil and trouble:find("injected full flush failure", 1, true), trouble)
      assert(not renamed, "failed device flush published a tree")
      assert(table.concat(assert(Fs.list(cache)), ",") == ".scratch-gate",
        "failed device flush left a payload or scratch owner")
    else
      assert(path ~= nil and renamed, trouble)
      local before = syncs
      assert(Patch.prepare(root, "lib", cache) == path)
      assert(flushes == 1 and syncs == before, "warm hit flushed again")
    end
    return true
  end)
  raw.uname, raw.full_fsync = real_uname, real_flush
  fs.fsync, fs.rename = real_sync, real_rename
  assert(ok, problem)
end

local function test_darwin_flushes_after_payload_sync_before_publication(tmp: string)
  darwin_flush_case(tmp, false, false)
end

local function test_darwin_flushes_an_empty_payload_through_its_owner(tmp: string)
  darwin_flush_case(tmp, true, false)
end

local function test_darwin_flush_failure_prevents_publication_and_cleans_scratch(tmp: string)
  darwin_flush_case(tmp, false, true)
end

local function test_darwin_empty_payload_flush_failure_prevents_publication(tmp: string)
  darwin_flush_case(tmp, true, true)
end

--- These use the real full_fsync on Darwin, including a payload with
--- no regular file from which a flush descriptor could otherwise come.
local function test_native_preparation_flushes_empty_and_nonempty_payloads(tmp: string)
  checkout(tmp .. "/source", { ["src/a.h"] = "native\n" })
  local tree = assert(Patch.prepare(tmp .. "/source", "lib", tmp .. "/cache"))
  assert(Fs.read(tree .. "/src/a.h") == "native\n")
  assert(Fs.mkdirs(tmp .. "/empty/vendor/lib"))
  local empty = assert(Patch.prepare(tmp .. "/empty", "lib", tmp .. "/empty-cache"))
  assert(#assert(Fs.list(empty)) == 0)
end

local function test_direct_tree_does_not_request_a_device_flush(tmp: string)
  checkout(tmp .. "/source", { ["src/a.h"] = "direct\n" })
  local real = sys.full_fsync
  local raw = sys as {string:any}
  raw.full_fsync = function(): boolean
    error("direct tree requested a device flush")
  end
  local ok, result, trouble = pcall(Patch.tree, tmp .. "/source", "lib", tmp .. "/direct")
  raw.full_fsync = real
  assert(ok and result, trouble or tostring(result))
end
