local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local ZigPrune = require("cosmic_ci.zig_prune")
local ZigRestat = require("cosmic_ci.zig_restat")
local sys = require("cosmic.sys")

local name <const> = string.rep("a", 32)

--- A record of `path` under `prefix` (flags `flags`, 0 when absent),
--- with the stat and digest the file at `file` has now.
local function record(file: string, prefix: integer, path: string, flags?: integer): string
  local stat = assert(sys.stat(file))
  local digest = stat.kind == "dir" and string.rep("\0", 16) or
    ZigPrune.siphash128(ZigPrune.key, (assert(Fs.read(file))))
  return string.pack("<i8i8i8", stat.size, stat.ino, stat.mtime * 1000000000 + stat.mtime_ns) ..
    digest .. string.char((prefix << 2) | (flags or 0)) .. path .. "\0"
end

--- `path` given a new inode, keeping its bytes and its mtime: what a
--- restore from a tarball does to every file. The copy is made while
--- the old file still holds its inode, so the two cannot share one.
local function restored(path: string, bytes?: string)
  local stat = assert(sys.stat(path))
  assert(Fs.write(path .. ".new", bytes or (assert(Fs.read(path)))))
  assert(sys.utimensat(path .. ".new", nil, nil, stat.mtime, stat.mtime_ns))
  assert(Fs.rename(path .. ".new", path))
  assert((assert(sys.stat(path))).ino ~= stat.ino)
end

--- A project cache, a global one and a tree, each with a file the one
--- manifest of the project cache lists.
local function layout(tmp: string): string, string, string
  local project, shared, tree = tmp .. "/zig-cache", tmp .. "/zig-global", tmp .. "/tree"
  for _, dir in ipairs({ project .. "/h", project .. "/o/1", shared .. "/h", tree }) do
    assert(Fs.mkdirs(dir))
  end
  return project, shared, tree
end

--- After a restore, a file whose size and mtime held takes its new
--- inode; one whose mtime moved but whose bytes did not (a fresh
--- checkout's) takes its new stat; one whose bytes changed, one gone and
--- a directory are left for zig. The digests, paths and so the output
--- the manifest vouches for are unchanged.
local function test_a_restored_file_takes_its_new_inode(tmp: string)
  local project, shared, tree = layout(tmp)
  assert(Fs.write(project .. "/o/1/a.c", "int a;"))
  assert(Fs.write(tree .. "/b.c", "int b;"))
  assert(Fs.write(tree .. "/c.c", "int c;"))
  assert(Fs.write(tree .. "/gone.c", "int g;"))
  local text = record(project .. "/o/1/a.c", 2, "o/1/a.c") ..
    record(tree .. "/b.c", 4, "b.c") .. record(tree .. "/c.c", 4, "c.c") ..
    record(tree .. "/gone.c", 4, "gone.c") ..
    record(tree, 0, tree, 1) .. "\0"
  assert(Fs.write(project .. "/h/" .. name, text))
  local before = assert(ZigPrune.vouches(name, text))

  restored(project .. "/o/1/a.c")
  local b = assert(sys.stat(tree .. "/b.c"))
  restored(tree .. "/b.c")
  assert(sys.utimensat(tree .. "/b.c", nil, nil, b.mtime + 5, 0))
  assert(Fs.write(tree .. "/c.c", "int C;"))
  assert(sys.utimensat(tree .. "/c.c", nil, nil, b.mtime + 7, 0))
  assert(Fs.remove(tree .. "/gone.c"))

  local result = assert(ZigRestat.restat({ { path = project, prefix = 2 },
    { path = shared, prefix = 3 } }, { [0] = tree, [3] = shared, [4] = tree }))
  assert(result.records == 5 and result.adopted == 1 and result.rehashed == 1 and
      result.left == 3 and result.manifests == 1,
    result.records .. " " .. result.adopted .. " " .. result.rehashed .. " " ..
      result.left .. " " .. result.manifests)
  local after = assert(Fs.read(project .. "/h/" .. name))
  assert(#after == #text)
  assert(ZigPrune.vouches(name, after) == before)
  local records = assert(ZigPrune.records(after))
  for i, path in ipairs({ project .. "/o/1/a.c", tree .. "/b.c" }) do
    local stat = assert(sys.stat(path))
    assert(records[i].inode == stat.ino and records[i].size == stat.size and
        records[i].mtime == stat.mtime * 1000000000 + stat.mtime_ns, path)
  end
  local old = assert(ZigPrune.records(text))
  for i = 3, 5 do
    assert(records[i].inode == old[i].inode and records[i].mtime == old[i].mtime, tostring(i))
  end

  -- What holds already is left as it is: a second pass rewrites nothing.
  local again = assert(ZigRestat.restat({ { path = project, prefix = 2 },
    { path = shared, prefix = 3 } }, { [0] = tree, [3] = shared, [4] = tree }))
  assert(again.adopted == 0 and again.rehashed == 0 and again.manifests == 0)
end

--- Equal size and mtime cannot vouch for the bytes under any prefix or
--- an absolute path. Only the unchanged replacement may adopt its inode.
local function test_changed_bytes_with_preserved_mtime_are_left(tmp: string)
  local project, shared, tree = layout(tmp)
  local roots: {integer:string} = { [0] = tree, [1] = tree, [3] = shared, [4] = tree }
  local files: {string} = {}
  local pieces: {string} = {}
  for prefix = 0, 4 do
    local root = prefix == 2 and project or roots[prefix]
    local path = "input" .. prefix .. ".c"
    local file = root .. "/" .. path
    assert(Fs.write(file, "int a;"))
    files[#files + 1] = file
    pieces[#pieces + 1] = record(file, prefix, path)
  end
  local absolute = tree .. "/absolute.c"
  assert(Fs.write(absolute, "int a;"))
  files[#files + 1] = absolute
  pieces[#pieces + 1] = record(absolute, 0, absolute)
  local unchanged = tree .. "/unchanged.c"
  assert(Fs.write(unchanged, "int a;"))
  pieces[#pieces + 1] = record(unchanged, 4, "unchanged.c")
  local text = table.concat(pieces) .. "\0"
  assert(Fs.write(project .. "/h/" .. name, text))
  for _, file in ipairs(files) do restored(file, "int b;") end
  restored(unchanged)
  local result = assert(ZigRestat.restat({ { path = project, prefix = 2 } }, roots))
  assert(result.records == 7 and result.adopted == 1 and result.rehashed == 0 and
      result.left == 6 and result.manifests == 1)
  local after = assert(Fs.read(project .. "/h/" .. name))
  assert(after:sub(1, #text - #pieces[7] - 1) == text:sub(1, #text - #pieces[7] - 1))
  local records = assert(ZigPrune.records(after))
  assert(records[7].inode == (assert(sys.stat(unchanged))).ino)
end

--- A path's cached digest is compared to each record: manifests from
--- different builds may name the same path with different old contents.
local function test_a_cached_digest_is_compared_to_each_manifest(tmp: string)
  local project, _, tree = layout(tmp)
  local file = tree .. "/input.c"
  -- Both manifests record the one mtime, and the first the inode of a
  -- file that stays: Fs.write replaces a file, so the inode it frees
  -- would otherwise come back as the restore's and the first record
  -- read as unchanged, on a filesystem that reuses inodes.
  local old = tree .. "/old.c"
  assert(Fs.write(old, "int a;"))
  assert(sys.utimensat(old, nil, nil, 1000, 0))
  local first = record(old, 4, "input.c") .. "\0"
  assert(Fs.write(file, "int b;"))
  assert(sys.utimensat(file, nil, nil, 1000, 0))
  local second = record(file, 4, "input.c") .. "\0"
  assert(Fs.write(project .. "/h/" .. name, first))
  local other = string.rep("b", 32)
  assert(Fs.write(project .. "/h/" .. other, second))
  restored(file)
  local result = assert(ZigRestat.restat({ { path = project, prefix = 2 } }, { [4] = tree }))
  assert(result.records == 2 and result.adopted == 1 and result.left == 1 and result.manifests == 1)
  assert(Fs.read(project .. "/h/" .. name) == first)
  local records = assert(ZigPrune.records((assert(Fs.read(project .. "/h/" .. other)))))
  assert(records[1].inode == (assert(sys.stat(file))).ino)
end

--- A file under a prefix no root is named for, zig's lib directory here,
--- is left; an empty manifest and an older zig's `.txt` are passed by;
--- a manifest that does not read as zig's leaves every one as it was.
local function test_what_cannot_be_checked_is_left(tmp: string)
  local project, shared, tree = layout(tmp)
  assert(Fs.write(tree .. "/lib.zig", "pub fn f() void {}"))
  local text = record(tree .. "/lib.zig", 1, "lib.zig") .. "\0"
  assert(Fs.write(project .. "/h/" .. name, text))
  assert(Fs.write(project .. "/h/" .. string.rep("b", 32), ""))
  assert(Fs.write(project .. "/h/" .. string.rep("c", 32) .. ".txt", "0\n"))
  restored(tree .. "/lib.zig")
  local result = assert(ZigRestat.restat({ { path = project, prefix = 2 },
    { path = shared, prefix = 3 } }, { [0] = tree, [4] = tree }))
  assert(result.records == 1 and result.left == 1 and result.manifests == 0)
  local with_lib = assert(ZigRestat.restat({ { path = project, prefix = 2 },
    { path = shared, prefix = 3 } }, { [1] = tree }))
  assert(with_lib.adopted == 1 and with_lib.manifests == 1)

  assert(Fs.write(project .. "/h/" .. string.rep("d", 32), "\1"))
  restored(tree .. "/lib.zig")
  local written = assert(Fs.read(project .. "/h/" .. name))
  local result2, trouble = ZigRestat.restat({ { path = project, prefix = 2 } }, { [1] = tree })
  assert(result2 == nil and trouble:find(string.rep("d", 32), 1, true), trouble)
  assert(Fs.read(project .. "/h/" .. name) == written)
end

--- The command restats the caches it is given, the global one only
--- where there is one, and never fails; where the project cache holds
--- no manifests it has nothing to do.
local function test_the_command_says_what_it_did(tmp: string)
  local code, out, err = ZigRestat.command(tmp .. "/absent", nil, tmp)
  assert(code == 0 and out:find("nothing to restat", 1, true) and err == "", out .. err)
  local project, shared, tree = layout(tmp .. "/seed")
  assert(Fs.write(project .. "/o/1/a.c", "int a;"))
  assert(Fs.write(project .. "/h/" .. name, record(project .. "/o/1/a.c", 2, "o/1/a.c") .. "\0"))
  restored(project .. "/o/1/a.c")
  code, out, err = ZigRestat.command(project, shared, tree)
  assert(code == 0 and err == "", err)
  assert(out == "zig-restat: 1 file listed: 1 given their new inode, 0 re-hashed and " ..
      "taken, 0 left; 1 manifest rewritten\n", out)
  restored(project .. "/o/1/a.c")
  code, out, err = ZigRestat.command(project, nil, tree)
  assert(code == 0 and err == "" and out:find("1 given their new inode", 1, true), out .. err)
end

--- A file of another size is changed whatever its mtime says: left.
local function test_a_file_of_another_size_is_left(tmp: string)
  local project, shared, tree = layout(tmp)
  assert(Fs.write(tree .. "/a.c", "int a;"))
  local text = record(tree .. "/a.c", 4, "a.c") .. "\0"
  assert(Fs.write(project .. "/h/" .. name, text))
  local stat = assert(sys.stat(tree .. "/a.c"))
  assert(Fs.write(tree .. "/a.c.new", "int a, b;"))
  assert(sys.utimensat(tree .. "/a.c.new", nil, nil, stat.mtime, stat.mtime_ns))
  assert(Fs.rename(tree .. "/a.c.new", tree .. "/a.c"))
  local result = assert(ZigRestat.restat({ { path = project, prefix = 2 },
    { path = shared, prefix = 3 } }, { [4] = tree }))
  assert(result.left == 1 and result.adopted == 0 and result.manifests == 0)
  assert(Fs.read(project .. "/h/" .. name) == text)
end

local function test_the_lib_directory_comes_from_zig_env()
  local env = '.{\n    .zig_exe = "/z/zig",\n    .lib_dir = "/z/lib",\n    .std_dir = "/z/lib/std",\n}\n'
  assert(ZigRestat.lib_dir(env) == "/z/lib")
  assert(ZigRestat.lib_dir("") == nil)
  assert(Codec.hex(ZigPrune.key) == "02e9fafee0958155f55a15cb4af40009")
end
