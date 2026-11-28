local Diff = require("cosmic.diff")
local Fs = require("cosmic.fs")
local Patch = require("cosmic.patch")

--- A generator of integers in [1, n], the same for a seed on every host.
local function drawer(seed: integer): function(integer): integer
  local state = seed
  return function(n: integer): integer
    state = (state * 1103515245 + 12345) % 2147483648
    return (state // 65536) % n + 1
  end
end

--- An entry that turns `old` into `new` at `name`.
local function modify(name: string, old: string, new: string): Diff.Entry
  return { kind = "modify", old_name = name, new_name = name, hunks = Diff.lines(old, new) }
end

local function read(path: string): string
  return assert(Fs.read(path))
end

--- Whether the patch is refused as a failure.
local function refused(root: string, entries: {Diff.Entry}, opts?: Patch.Options): boolean
  local result, why = Patch.apply(root, entries, opts)
  return result == nil and why.message ~= ""
end

local function is_missing(path: string): boolean
  return not assert(Fs.status(path)).exists
end

--- A patch of all four kinds changes the tree, and its reverse restores the tree.
local function test_apply_changes_the_tree_and_the_reverse_restores_it(tmp: string)
  assert(Fs.write(tmp .. "/keep.txt", "a\nb\nc\n"))
  assert(Fs.write(tmp .. "/gone.txt", "x\ny\n"))
  assert(Fs.write(tmp .. "/old.txt", "m\nn\n"))
  assert(Fs.write(tmp .. "/run.sh", "echo 1\n", 0x1ed))
  local entries: {Diff.Entry} = {
    modify("keep.txt", "a\nb\nc\n", "a\nB\nc\n"),
    { kind = "create", new_name = "deep/er/new.txt", hunks = Diff.lines("", "fresh\n") },
    { kind = "delete", old_name = "gone.txt", hunks = Diff.lines("x\ny\n", "") },
    { kind = "rename", old_name = "old.txt", new_name = "moved.txt", hunks = Diff.lines("m\nn\n", "m\nN\n") },
    { kind = "modify", old_name = "run.sh", new_name = "run.sh", old_mode = "100755", new_mode = "100644", hunks = {} },
  }
  local result = assert(Patch.apply(tmp, entries))
  assert(result.applied and result.written)
  assert(#result.files == 5)
  assert(read(tmp .. "/keep.txt") == "a\nB\nc\n")
  assert(read(tmp .. "/deep/er/new.txt") == "fresh\n")
  assert(is_missing(tmp .. "/gone.txt"))
  assert(is_missing(tmp .. "/old.txt"))
  assert(read(tmp .. "/moved.txt") == "m\nN\n")
  assert(assert(Fs.stat(tmp .. "/run.sh")).mode & 0x1ff == 0x1a4)
  local back = assert(Patch.apply(tmp, entries, { reverse = true }))
  assert(back.applied and back.written)
  assert(read(tmp .. "/keep.txt") == "a\nb\nc\n")
  assert(read(tmp .. "/gone.txt") == "x\ny\n")
  assert(read(tmp .. "/old.txt") == "m\nn\n")
  assert(is_missing(tmp .. "/moved.txt"))
  assert(is_missing(tmp .. "/deep/er/new.txt"))
  assert(assert(Fs.stat(tmp .. "/run.sh")).mode & 0x1ff == 0x1ed)
end

--- A hunk that does not fit leaves every file as it was, the ones before it too.
local function test_a_reject_writes_nothing(tmp: string)
  assert(Fs.write(tmp .. "/one.txt", "1\n2\n3\n"))
  assert(Fs.write(tmp .. "/two.txt", "other\ntext\n"))
  local entries: {Diff.Entry} = {
    modify("one.txt", "1\n2\n3\n", "1\ntwo\n3\n"),
    modify("two.txt", "p\nq\n", "p\nQ\n"),
  }
  local result = assert(Patch.apply(tmp, entries))
  assert(not result.applied and not result.written)
  assert(#assert(result.files[1]).rejects == 0)
  assert(#assert(result.files[2]).rejects == 1)
  assert(read(tmp .. "/one.txt") == "1\n2\n3\n")
  assert(read(tmp .. "/two.txt") == "other\ntext\n")
end

--- A dry run says what would happen and writes nothing.
local function test_a_dry_run_writes_nothing(tmp: string)
  assert(Fs.write(tmp .. "/f.txt", "a\n"))
  local result = assert(Patch.apply(tmp, { modify("f.txt", "a\n", "b\n") }, { dry_run = true }))
  assert(result.applied and not result.written)
  assert(read(tmp .. "/f.txt") == "a\n")
end

--- A missing file and a file in the way are problems of the entry, and nothing is written.
local function test_missing_and_present_files_are_problems(tmp: string)
  assert(Fs.write(tmp .. "/there.txt", "t\n"))
  local missing = assert(Patch.apply(tmp, { modify("nope.txt", "a\n", "b\n") }))
  assert(not missing.applied)
  assert(assert(assert(missing.files[1]).problem):find("no file", 1, true) ~= nil)
  local clash = assert(Patch.apply(tmp, { { kind = "create", new_name = "there.txt", hunks = Diff.lines("", "n\n") } }))
  assert(not clash.applied)
  assert(assert(assert(clash.files[1]).problem):find("already there", 1, true) ~= nil)
  assert(read(tmp .. "/there.txt") == "t\n")
end

--- Entries may depend on each other: a file made, then changed, then moved.
local function test_entries_see_each_other(tmp: string)
  local entries: {Diff.Entry} = {
    { kind = "create", new_name = "a.txt", hunks = Diff.lines("", "1\n") },
    modify("a.txt", "1\n", "1\n2\n"),
    { kind = "rename", old_name = "a.txt", new_name = "b.txt", hunks = {} },
  }
  local result = assert(Patch.apply(tmp, entries))
  assert(result.applied and result.written)
  assert(is_missing(tmp .. "/a.txt"))
  assert(read(tmp .. "/b.txt") == "1\n2\n")
end

--- A name that leaves the root, or is no plain relative name, is a failure and writes nothing.
local function test_names_outside_the_root_fail(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root"))
  assert(Fs.write(tmp .. "/outside.txt", "a\n"))
  local bad = { "../outside.txt", "/etc/passwd", "a/../../outside.txt", "dir\\f", "c:f", "", ".", "a\0b" }
  for _, name in ipairs(bad) do
    local entry = modify(name, "a\n", "b\n")
    assert(refused(tmp .. "/root", { entry }), name)
  end
  assert(read(tmp .. "/outside.txt") == "a\n")
  -- the names before a bad one are not written either
  assert(Fs.write(tmp .. "/root/ok.txt", "a\n"))
  assert(refused(tmp .. "/root", { modify("ok.txt", "a\n", "b\n"), modify("../outside.txt", "a\n", "b\n") }))
  assert(read(tmp .. "/root/ok.txt") == "a\n")
end

--- A link on the path is never followed, to read or to write.
local function test_a_link_on_the_path_fails(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root"))
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  assert(Fs.write(tmp .. "/elsewhere/f.txt", "a\n"))
  assert(Fs.symlink(tmp .. "/elsewhere", tmp .. "/root/dir"))
  assert(refused(tmp .. "/root", { modify("dir/f.txt", "a\n", "b\n") }))
  assert(refused(tmp .. "/root", { { kind = "create", new_name = "dir/new.txt", hunks = Diff.lines("", "x\n") } }))
  assert(read(tmp .. "/elsewhere/f.txt") == "a\n")
  assert(is_missing(tmp .. "/elsewhere/new.txt"))
  -- a link as the file itself
  assert(Fs.symlink(tmp .. "/elsewhere/f.txt", tmp .. "/root/f.txt"))
  assert(refused(tmp .. "/root", { modify("f.txt", "a\n", "b\n") }))
  assert(read(tmp .. "/elsewhere/f.txt") == "a\n")
  -- the root itself may be a link
  assert(Fs.symlink(tmp .. "/elsewhere", tmp .. "/rootlink"))
  assert(assert(Patch.apply(tmp .. "/rootlink", { modify("f.txt", "a\n", "b\n") })).applied)
  assert(read(tmp .. "/elsewhere/f.txt") == "b\n")
end

--- A patch that makes a link or a submodule is refused.
local function test_modes_of_links_and_submodules_are_refused(tmp: string)
  for _, mode in ipairs({ "120000", "160000" }) do
    local entry: Diff.Entry = { kind = "create", new_name = "l", new_mode = mode, hunks = Diff.lines("", "target\n") }
    assert(refused(tmp, { entry }), mode)
  end
  assert(is_missing(tmp .. "/l"))
end

--- A parsed git patch applies, and its names go through `strip`.
local function test_a_parsed_patch_applies(tmp: string)
  assert(Fs.write(tmp .. "/f.txt", "a\nb\n"))
  local text = "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n" ..
    "diff --git a/n.txt b/n.txt\nnew file mode 100755\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+new\n"
  local entries = assert(Diff.parse(text, { strip = 1 }))
  local result = assert(Patch.apply(tmp, entries))
  assert(result.applied)
  assert(read(tmp .. "/f.txt") == "a\nB\n")
  assert(read(tmp .. "/n.txt") == "new\n")
  assert(assert(Fs.stat(tmp .. "/n.txt")).mode & 0x1ff == 0x1ed)
  -- unstripped, the names are under a/ and b/, which are not there
  local unstripped = assert(Diff.parse(text))
  local missing = assert(Patch.apply(tmp, unstripped))
  assert(not missing.applied)
end

--- Random trees, edited and patched and unpatched, come back as they were.
local function test_random_trees_round_trip(tmp: string)
  local draw = drawer(77)
  for round = 1, 40 do
    local root = tmp .. "/r" .. tostring(round)
    assert(Fs.mkdirs(root))
    local old: mut {string: string} = {}
    local new: mut {string: string} = {}
    local entries: mut {Diff.Entry} = {}
    for i = 1, draw(4) do
      local name = "d" .. tostring(draw(2)) .. "/f" .. tostring(i) .. ".txt"
      local lines: mut {string} = {}
      for _ = 1, draw(30) do lines[#lines + 1] = "line " .. tostring(draw(8)) end
      local before = table.concat(lines, "\n") .. "\n"
      local after = before
      if draw(2) == 1 then
        local at = draw(#lines)
        local edited: mut {string} = {}
        for k, line in ipairs(lines) do
          edited[k] = if k == at then "changed " .. tostring(draw(100)) else line end
        end
        after = table.concat(edited, "\n") .. "\n"
      end
      old[name] = before
      new[name] = after
      assert(Fs.mkdirs(root .. "/" .. name:match("^[^/]+")!))
      assert(Fs.write(root .. "/" .. name, before))
      if before ~= after then entries[#entries + 1] = modify(name, before, after) end
    end
    local result = assert(Patch.apply(root, entries))
    assert(result.applied and result.written, tostring(round))
    for name, text in pairs(new) do assert(read(root .. "/" .. name) == text, name) end
    assert(assert(Patch.apply(root, entries, { reverse = true })).applied)
    for name, text in pairs(old) do assert(read(root .. "/" .. name) == text, name) end
  end
end

--- Names built from hostile parts never change anything outside the root, whatever the patch says.
local function test_hostile_names_never_reach_outside_the_root(tmp: string)
  local draw = drawer(2026)
  assert(Fs.mkdirs(tmp .. "/root/sub"))
  assert(Fs.mkdirs(tmp .. "/outside"))
  assert(Fs.write(tmp .. "/outside/secret", "s\n"))
  assert(Fs.write(tmp .. "/root/f", "a\n"))
  assert(Fs.symlink(tmp .. "/outside", tmp .. "/root/out"))
  assert(Fs.symlink("../outside", tmp .. "/root/rel"))
  assert(Fs.symlink(tmp .. "/outside/secret", tmp .. "/root/sub/secret"))
  local pieces = { "..", ".", "", "out", "rel", "sub", "secret", "f", "outside", "root", "x", "/", "\\", "~" }
  for _ = 1, 400 do
    local parts: mut {string} = {}
    for _ = 1, draw(5) do parts[#parts + 1] = assert(pieces[draw(#pieces)]) end
    local name = table.concat(parts, "/")
    local kinds: {Diff.Kind} = { "modify", "create", "delete", "rename", "copy" }
    local kind = assert(kinds[draw(5)])
    local entry: Diff.Entry = if kind == "create"
      then { kind = kind, new_name = name, hunks = Diff.lines("", "pwned\n") }
      elseif kind == "delete" then { kind = kind, old_name = name, hunks = {} }
      else { kind = kind, old_name = name, new_name = (if draw(2) == 1 then name else "moved" end), hunks = {} } end
    local _ = refused(tmp .. "/root", { entry })
    assert(read(tmp .. "/outside/secret") == "s\n", name)
    assert(assert(Fs.list(tmp .. "/outside"))[1] == "secret" and #assert(Fs.list(tmp .. "/outside")) == 1, name)
  end
end

--- Two spellings of one name are one file: the second entry sees the first.
local function test_spellings_of_a_name_are_one_file(tmp: string)
  assert(Fs.write(tmp .. "/f", "1\n2\n3\n"))
  local entries: {Diff.Entry} = { modify("f", "1\n2\n3\n", "one\n2\n3\n"), modify("./f", "one\n2\n3\n", "one\n2\nthree\n") }
  assert(assert(Patch.apply(tmp, entries)).applied)
  assert(read(tmp .. "/f") == "one\n2\nthree\n")
  local made: {Diff.Entry} = {
    { kind = "create", new_name = "g", hunks = Diff.lines("", "x\n") },
    { kind = "delete", old_name = ".//g", hunks = Diff.lines("x\n", "") },
  }
  assert(assert(Patch.apply(tmp, made)).applied)
end

--- A file and a directory of one name in one patch are a problem found before anything is written.
local function test_a_file_and_a_directory_clash_before_any_write(tmp: string)
  local entries: {Diff.Entry} = {
    { kind = "create", new_name = "other", hunks = Diff.lines("", "o\n") },
    { kind = "create", new_name = "a", hunks = Diff.lines("", "x\n") },
    { kind = "create", new_name = "a/b", hunks = Diff.lines("", "y\n") },
  }
  local result = assert(Patch.apply(tmp, entries))
  assert(not result.applied and not result.written)
  assert(is_missing(tmp .. "/other") and is_missing(tmp .. "/a"))
  local reversed: {Diff.Entry} = { assert(entries[3]), assert(entries[2]) }
  assert(not assert(Patch.apply(tmp, reversed)).applied)
  assert(is_missing(tmp .. "/a"))
end

--- Undoing a copy removes the copy and leaves the source.
local function test_undoing_a_copy_removes_the_copy(tmp: string)
  assert(Fs.write(tmp .. "/src", "s\n"))
  local copy: {Diff.Entry} = { { kind = "copy", old_name = "src", new_name = "dup", hunks = {} } }
  assert(assert(Patch.apply(tmp, copy)).applied)
  assert(read(tmp .. "/dup") == "s\n" and read(tmp .. "/src") == "s\n")
  assert(assert(Patch.apply(tmp, copy, { reverse = true })).applied)
  assert(is_missing(tmp .. "/dup") and read(tmp .. "/src") == "s\n")
end

--- An entry with a name missing, and a name inside `.git`, are failures, not crashes.
local function test_odd_entries_fail_cleanly(tmp: string)
  assert(refused(tmp, { { kind = "rename", old_name = "a", hunks = {} } }))
  assert(refused(tmp, { { kind = "create", hunks = {} } }))
  assert(refused(tmp, { { kind = "modify", hunks = {} } }))
  assert(refused(tmp, { { kind = "delete", hunks = {} } }))
  assert(refused(tmp, { { kind = "create", new_name = ".git/hooks/pre-commit", hunks = Diff.lines("", "x\n") } }))
  assert(refused(tmp, { { kind = "create", new_name = "sub/.GIT/config", hunks = Diff.lines("", "x\n") } }))
  assert(is_missing(tmp .. "/.git"))
end

--- A patch that makes 2000 directories, then removes them again, keeps no more than a few open: the
--- descriptor limit is not met half way through the write.
local function test_thousands_of_directories_do_not_run_out_of_descriptors(tmp: string)
  local entries: mut {Diff.Entry} = {}
  for i = 1, 2000 do
    local name = string.format("d%04d/sub/f.txt", i)
    entries[#entries + 1] = { kind = "create", new_name = name, hunks = Diff.lines("", "n" .. tostring(i) .. "\n") }
  end
  local result = assert(Patch.apply(tmp, entries))
  assert(result.applied and result.written)
  assert(read(tmp .. "/d0001/sub/f.txt") == "n1\n")
  assert(read(tmp .. "/d2000/sub/f.txt") == "n2000\n")
  local back = assert(Patch.apply(tmp, entries, { reverse = true }))
  assert(back.applied and back.written)
  assert(is_missing(tmp .. "/d0001/sub/f.txt") and is_missing(tmp .. "/d2000/sub/f.txt"))
end
