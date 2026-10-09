local Fs = require("cosmic.fs")
local Predicate = require("cosmic_ci.fs_predicate")
local Fixture = require("cosmic_ci.fixture")
local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")

-- Copies a whole directory tree to `to`, which must not exist yet,
-- matching identity_test.tl's own [`copy_tree`].
local function copy_tree(label: string, from: string, to: string)
  local copied, trouble = Fs.copy_tree(from, to)
  assert(copied, label .. ": " .. trouble)
end

local function require_file(path: string)
  assert(assert(Fs.stat(path)).kind == "file",
    "portable runtime build: prebuilt input is missing: " .. path)
end

-- The id and name of the single target whose uname fields match this host.
-- Both come from one row, so they cannot mismatch.
local function host_target_row(targets_path: string, work: string,
                               diagnostics: string): string, string
  local function host_uname(flag: string, label: string): string
    local answer = Fixture.run("uname-" .. label,
      { "/usr/bin/env", "uname", flag }, work, diagnostics)
    return (assert(Fixture.small(answer.out, 256):match("^(%S+)"),
      "uname " .. flag .. " produced no output"))
  end
  local sysname = host_uname("-s", "sysname")
  local arch = host_uname("-m", "arch")
  local found_id: string | nil = nil
  local found_name: string | nil = nil
  for line in Fixture.read(targets_path):gmatch("[^\n]+") do
    local id, _configuration, _kind, name, uname_os, uname_arch = line:match(
      "^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
    assert(id and name and uname_os and uname_arch,
      "invalid generated target record: " .. line)
    if uname_os == sysname and uname_arch == arch then
      assert(found_id == nil, "multiple generated targets match this host")
      found_id, found_name = id, name
    end
  end
  assert(found_id and found_name, "no generated target matches this host: " ..
      sysname .. " " .. arch)
  return found_id, found_name
end

-- Assembly always supplies prebuilt cores and all input paths.
local record RuntimeSetup
end

--- The files of the tree at `root`, relative to it and sorted, that the
--- module at `entry` (relative too) requires by a literal name, and
--- theirs in turn, `entry` among them: `a.b` is `a/b.tl`, or
--- `a/b/init.tl`. A `cosmic.*` module is the runtime's own, carried in
--- its database, and a name with no file in the tree is none of the
--- tree's, so neither is followed.
function RuntimeSetup.closure(root: string, entry: string): {string}
  local seen: {string:boolean} = {}
  local out: {string} = {}
  local function visit(relative: string)
    if seen[relative] then return end
    seen[relative] = true
    out[#out + 1] = relative
    for name in Fixture.read(root .. "/" .. relative):gmatch("require%(%s*\"([%w_%.]+)\"%s*%)") do
      if name ~= "cosmic" and name:sub(1, 7) ~= "cosmic." then
        local base = name:gsub("%.", "/")
        for _, candidate in ipairs({ base .. ".tl", base .. "/init.tl" }) do
          if Predicate.exists(root .. "/" .. candidate) then
            visit(candidate)
            break
          end
        end
      end
    end
  end
  visit(entry)
  table.sort(out)
  return out
end

--- Writes `out`, a tar of each of `files` beneath `root`, at its path
--- relative to it, in order, each with its mode and time: the writer is
--- `deterministic`, so every time is written as 0 and the same files make
--- the same bytes wherever and whenever the checkout was made, and a
--- fixture that declares the tar ([`Test.policy`]'s host grant) is keyed by what
--- it holds alone.
function RuntimeSetup.pack(root: string, files: {string}, out: string)
  local collected = Stream.collect()
  local writer = Tar.writer(collected, { deterministic = true })
  for _, relative in ipairs(files) do
    local st = assert(Fs.stat(root .. "/" .. relative))
    assert(writer:add_file(relative, Fixture.read(root .. "/" .. relative),
      { mode = st.mode & 0x1ff, mtime = st.mtime }))
  end
  assert(writer:close())
  Fixture.write(out, collected:result())
end

function RuntimeSetup.build(root: string, prebuilt: string, writer: string,
                            database: string, out: string, tmp: string): string
  local output_exists = Predicate.exists(out)
  assert(not output_exists, "runtime fixture output already exists: " .. out)

  local diagnostics = tmp .. "/logs"
  Fixture.mkdir(diagnostics)

  Fixture.assert_executable(writer)
  assert(assert(Fs.stat(database)).kind == "file",
    "portable runtime build: portable database is missing: " .. database)

  local targets_path = prebuilt .. "/targets.tsv"
  local release_cores = prebuilt .. "/core"
  local hooked_cores = prebuilt .. "/portable-fixture/core"
  local sanitized_core = prebuilt .. "/portable-fixture/sanitized/cosmic-core"
  require_file(targets_path)
  require_file(sanitized_core)
  local targets = Fixture.targets(targets_path)
  for _, target in ipairs(targets) do
    require_file(release_cores .. "/" .. target.name .. "/cosmic-core")
    require_file(hooked_cores .. "/" .. target.name .. "/cosmic-core")
  end

  Fixture.mkdir(out .. "/hooked-build")
  copy_tree("copy-hooked-cores", hooked_cores, out .. "/hooked-build/core")
  Fixture.copy(targets_path, out .. "/hooked-build/targets.tsv")
  Fixture.mkdir(out .. "/sanitized-build/sanitized")
  Fixture.copy(sanitized_core, out .. "/sanitized-build/sanitized/cosmic-core")
  Fixture.copy(database, out .. "/old.db")
  Fixture.copy(database, out .. "/new.db")
  Fixture.copy(database, out .. "/basis.db")
  Fixture.copy(database, out .. "/missing.db")
  Fixture.run("prepare-databases", { writer, root .. "/test/portable/tool.tl",
    "prepare-databases", out .. "/old.db", out .. "/new.db",
    out .. "/basis.db", out .. "/missing.db" }, root, diagnostics)

  Fixture.run("write-release", { writer, root .. "/test/portable/tool.tl",
    "write-runtime-fixture", targets_path, release_cores, out .. "/old.db",
    out .. "/runtime.release" }, root, diagnostics)
  Fixture.run("write-old", { writer, root .. "/test/portable/tool.tl",
    "write-runtime-fixture", targets_path, out .. "/hooked-build/core",
    out .. "/old.db", out .. "/runtime.old", "test" }, root, diagnostics)
  Fixture.run("write-new", { writer, root .. "/test/portable/tool.tl",
    "write-runtime-fixture", targets_path, out .. "/hooked-build/core",
    out .. "/new.db", out .. "/runtime.new", "test" }, root, diagnostics)
  Fixture.run("write-basis", { writer, root .. "/test/portable/tool.tl",
    "write-runtime-fixture", targets_path, out .. "/hooked-build/core",
    out .. "/basis.db", out .. "/runtime.basis", "test" }, root, diagnostics)
  Fixture.run("write-missing", { writer, root .. "/test/portable/tool.tl",
    "write-runtime-fixture", targets_path, out .. "/hooked-build/core",
    out .. "/missing.db", out .. "/runtime.missing", "test" }, root,
    diagnostics)

  -- A fixture-only fourth manifest entry binds the real host sanitized core.
  -- Its synthetic uname tuple is deliberately unreachable from the launcher;
  -- the identity test executes that raw core with descriptors 8 and 9
  -- populated from this manifest entry, exercising the production startup
  -- contract without making sanitized the ordinary shell selection.
  local target_id, target = host_target_row(targets_path, root, diagnostics)
  local sanitized_name = "sanitized-" .. target
  local sanitized_targets_path = out .. "/sanitized-targets.tsv"
  Fixture.write(sanitized_targets_path, Fixture.read(targets_path) ..
      target_id .. "\t2\tsanitized\t" .. sanitized_name ..
      "\tFixture\tSanitized\n")
  Fixture.mkdir(out .. "/sanitized-cores")
  for _, release_target in ipairs(targets) do
    Fixture.mkdir(out .. "/sanitized-cores/" .. release_target.name)
    Fixture.copy(
      out .. "/hooked-build/core/" .. release_target.name .. "/cosmic-core",
      out .. "/sanitized-cores/" .. release_target.name .. "/cosmic-core")
  end
  Fixture.mkdir(out .. "/sanitized-cores/" .. sanitized_name)
  Fixture.copy(out .. "/sanitized-build/sanitized/cosmic-core",
    out .. "/sanitized-cores/" .. sanitized_name .. "/cosmic-core")
  Fixture.run("write-sanitized", { writer, root .. "/test/portable/tool.tl",
    "write-runtime-fixture", sanitized_targets_path,
    out .. "/sanitized-cores", out .. "/old.db", out .. "/runtime.sanitized",
    "test" }, root, diagnostics)
  Fixture.write(out .. "/sanitized-target-id", target_id .. "\n")
  Fixture.write(out .. "/sanitized-target", target .. "\n")
  Fixture.write(out .. "/sanitized-core-name", sanitized_name .. "\n")

  -- Every raw core gets one byte flipped: the byte at 0-indexed offset
  -- 128 becomes "X" (0x58). In 1-indexed Lua substring terms, the
  -- prefix is indices 1..128, the replaced byte is index 129, and the
  -- suffix resumes at index 130.
  Fixture.mkdir(out .. "/incompatible-cores")
  for _, one in ipairs(targets) do
    local from = out .. "/hooked-build/core/" .. one.name .. "/cosmic-core"
    local to = out .. "/incompatible-cores/" .. one.name .. "/cosmic-core"
    Fixture.mkdir(out .. "/incompatible-cores/" .. one.name)
    local bytes = Fixture.read(from)
    local corrupted = bytes:sub(1, 128) .. "X" .. bytes:sub(130)
    Fixture.write(to, corrupted)
  end
  Fixture.run("write-incompatible", { writer, root .. "/test/portable/tool.tl",
    "write-runtime-fixture", targets_path, out .. "/incompatible-cores",
    out .. "/new.db", out .. "/runtime.incompatible", "test" }, root,
    diagnostics)

  -- tool.tl's own prepare-artifacts derives the hashes, the prefixes and
  -- the deterministic runtime.corrupt-<target> corruptions.
  Fixture.run("prepare-artifacts", { writer, root .. "/test/portable/tool.tl",
    "prepare-artifacts", out, targets_path }, root, diagnostics)

  Fixture.copy(root .. "/ci/testdata/portable/retained_probe.tl",
    out .. "/probe.tl")
  Fixture.copy(root .. "/ci/testdata/portable/runtime_test.tl",
    out .. "/runtime_test.tl")
  Fixture.copy(root .. "/ci/testdata/portable/cmd/hello/main.tl",
    out .. "/hello_main.tl")
  Fixture.copy(root .. "/ci/testdata/portable/cmd/second/main.tl",
    out .. "/second_main.tl")

  -- What the fixtures would otherwise read of the candidate's tree, which
  -- a sandboxed fixture is given none of (ci/fixtures/*_test.tl's
  -- [`Test.policy`]): test/portable/tool.tl with the modules of the tree it
  -- requires. It is one file, a tar a fixture unpacks where it writes
  -- ([`Fixture.unpack`]), so its declaration names one path whatever the
  -- closure holds, and its key moves only with what the tar holds.
  RuntimeSetup.pack(root, RuntimeSetup.closure(root, "test/portable/tool.tl"),
    out .. "/tool.tar")

  -- Normalize every finished artifact to an executable mode. Some helpers set
  -- it already, but callers should not depend on which helper produced a file.
  for _, name in ipairs({ "runtime.release", "runtime.old", "runtime.new",
      "runtime.basis", "runtime.missing", "runtime.sanitized",
      "runtime.incompatible" }) do
    assert(Fs.chmod(out .. "/" .. name, 0x1ed))
  end
  for _, one in ipairs(targets) do
    assert(Fs.chmod(out .. "/runtime.corrupt-" .. one.name, 0x1ed))
  end
  -- And every raw core a fixture runs as it is: a sandboxed fixture is
  -- given this directory to read and run, not to change a mode in.
  for _, one in ipairs(targets) do
    assert(Fs.chmod(out .. "/hooked-build/core/" .. one.name .. "/cosmic-core", 0x1ed))
    assert(Fs.chmod(out .. "/sanitized-cores/" .. one.name .. "/cosmic-core", 0x1ed))
  end
  assert(Fs.chmod(out .. "/sanitized-cores/" .. sanitized_name .. "/cosmic-core", 0x1ed))
  assert(Fs.chmod(out .. "/sanitized-build/sanitized/cosmic-core", 0x1ed))

  Fixture.copy(targets_path, out .. "/targets.tsv")
  for _, name in ipairs({ "runtime.release", "runtime.old", "runtime.new",
      "runtime.basis", "runtime.missing", "runtime.sanitized",
      "runtime.incompatible", "targets.tsv" }) do
    require_file(out .. "/" .. name)
  end
  return out
end

return RuntimeSetup
