--- What a merge queue's platform leg keeps for a push to main to reuse
--- (README.md's "the queue's result"), `driver.tl queue-stage`: the
--- other half of queue_seed.tl's lookups, which read the API while this
--- only copies files.
---
--- `stage`, a merge_group run's job that passed, copies into
--- $RUNNER_TEMP/seed what a push to main would have saved, and writes
--- there `seed.keys`, a line `<cache>=<key>` for each, the key it saves
--- under: `verdicts` (from $RUNNER_TEMP/verdicts) and `compiles` (from
--- $RUNNER_TEMP/build-cache), each as <X>_PREFIX and <X>_DIGEST, where
--- the digest is not empty and the key is not <X>_RESTORED, the entry the
--- run restored (a job that saves no compiles, ci.yml's `checked`, sets
--- no COMPILES_*); `verdicts-sha`, the verdicts' copy keyed by the commit,
--- <VERDICTS_PREFIX>sha-<SHA>, where the digest is not empty, even where it
--- names the entry restored (the commit's own key is saved on every push
--- to main, for a branch based on it: `driver.tl merge-base`); and
--- `driver-checked` (from $RUNNER_TEMP/driver-checked), the key its marker
--- holds, where the driver check ran and passed; and `zig-build` (from
--- $RUNNER_TEMP/zig-build, as $RUNNER_TEMP/seed-zig/zig-build.tar, an
--- artifact of its own: an artifact keeps no file's mode, and zig's
--- cache holds programs it runs), under ZIG_BUILD_KEY, the restore's
--- primary key, where ZIG_BUILD_EXACT, the prefix of an entry built from
--- this very core and vendor part, does not begin ZIG_BUILD_RESTORED,
--- the entry restored, with that prefix as `zig-build-exact`, which main's
--- `seed` looks up before it saves (a job that saves no zig build
--- outputs, ci.yml's `checked`, sets no ZIG_BUILD_*). An archive that
--- fails keeps none, and the stage goes on: they save only time. The
--- keys written are printed.
---
--- The archive is a ustar tar whose members are `zig-build/` and what is
--- under it, each with its permission bits and modification time, a
--- symbolic link as a link, and every file's bytes. It is read back by
--- `tar -xf` in ci.yml's `seed` job, which has no checkout and no
--- driver, so a tar that tool reads as the tree it archived is what the
--- seed needs. An owner is not kept (the runner extracts as itself), nor
--- is a hard link: its file is archived once for each name, which costs
--- size alone. Anything but a file, a directory and a link is refused,
--- which keeps no archive.
local Archive = require("cosmic.archive")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")

local record QueueStage
  --- What `stage` asks of the world, as one record a test replaces.
  record Host
    --- Text on the step's standard output, as given.
    print: function(text: string)
    --- A line on the step's standard error.
    warn: function(line: string)
    --- Archives the tree at `parent`/`name` to the new file `to`, its
    --- members under `name`. Returns `true, ""`, or `false` and why;
    --- on a failure nothing is left at `to`.
    archive: function(parent: string, name: string, to: string): boolean, string
  end
  stage: function(env: {string:string}, host: Host): integer
  archive_tree: function(parent: string, name: string, to: string): boolean, string
  live: function(): Host
  stage_command: function(argv: {string}): integer
end

local function sorted(names: {string}): {string}
  table.sort(names)
  return names
end

-- A hard link is stored as a separate file for each name (tar's writer has
-- no link entry), which costs size only; zig's caches hold none.
--- Adds the tree at `path` to `writer` as `member`.
local function add(writer: Archive.Writer, path: string, member: string): boolean, string
  local st, why = sys.lstat(path)
  if st == nil then return false, path .. ": " .. why end
  local entry: Stream.EntryOptions = { mode = st.mode & 0xfff, mtime = st.mtime }
  if st.kind == "link" then
    local target, trouble = Fs.readlink(path)
    if target == nil then return false, trouble end
    return writer:add_symlink(member, target, entry)
  elseif st.kind == "file" then
    local reader, trouble = Stream.open(path)
    if reader == nil then return false, trouble end
    entry.size = st.size
    local ok, added = writer:add_file(member, reader, entry)
    local _, _ = reader:close()
    return ok, added
  elseif st.kind == "dir" then
    local names, trouble = Fs.list(path)
    if names == nil then return false, trouble end
    local ok, added = writer:add_dir(member, entry)
    if not ok then return false, added end
    for _, name in ipairs(sorted(names)) do
      ok, added = add(writer, path .. "/" .. name, member .. "/" .. name)
      if not ok then return false, added end
    end
    return true, ""
  end
  return false, path .. ": not a file, directory or symbolic link"
end

function QueueStage.archive_tree(parent: string, name: string, to: string): boolean, string
  local writer, why = Archive.create(to)
  if writer == nil then return false, why end
  local ok, trouble = add(writer, parent .. "/" .. name, name)
  if not ok then
    local _, _ = writer:abort()
    return false, trouble
  end
  return writer:close()
end

function QueueStage.live(): QueueStage.Host
  return {
    print = function(text: string) local _, _ = Fs.put(Fs.stdout, text) end,
    warn = function(line: string) local _, _ = Fs.put(Fs.stderr, line .. "\n") end,
    archive = QueueStage.archive_tree,
  }
end

--- The cache NAME from DIR (under `temp`) into `seed`, keyed by PREFIX
--- and DIGEST unless the digest is empty or the key is RESTORED. Returns
--- the key line it adds, "" where it adds none, or nil and why.
local function entry(temp: string, seed: string, name: string, dir: string,
                     prefix: string, digest: string, restored: string): string | nil, string
  if digest == "" or prefix .. digest == restored then return "", "" end
  local ok, why = Fs.copy_tree(temp .. "/" .. dir, seed .. "/" .. dir)
  if not ok then return nil, why end
  return name .. "=" .. prefix .. digest .. "\n", ""
end

--- The key lines for zig's build outputs, archived to `zig` under KEY
--- unless EXACT begins RESTORED (an entry of this core and vendor part
--- answers already; an empty EXACT begins every key). Never a failure:
--- none kept costs only time.
local function zig_build(host: QueueStage.Host, temp: string, zig: string,
                         key: string, exact: string, restored: string): string
  if key == "" or not Fs.is_dir(temp .. "/zig-build") then return "" end
  if restored:sub(1, #exact) == exact then return "" end
  local tar = zig .. "/zig-build.tar"
  local ok, why = Fs.mkdirs(zig)
  if ok then ok, why = host.archive(temp, "zig-build", tar) end
  if not ok then
    local _, _ = Fs.remove(tar)
    host.warn("queue-stage: " .. why)
    host.warn("warning: the zig build outputs could not be kept: none seeded")
    return ""
  end
  return "zig-build=" .. key .. "\nzig-build-exact=" .. exact .. "\n"
end

function QueueStage.stage(env: {string:string}, host: QueueStage.Host): integer
  local temp = env.RUNNER_TEMP
  if temp == nil or temp == "" then
    host.warn("queue-stage: RUNNER_TEMP is not set")
    return 1
  end
  local function get(name: string): string return env[name] or "" end
  local seed, zig = temp .. "/seed", temp .. "/seed-zig"
  local keys: {string} = {}
  local function failed(why: string): integer
    host.warn("queue-stage: " .. why)
    return 1
  end
  for _, path in ipairs({ seed, zig }) do
    local ok, why = Fs.remove_tree(path)
    if not ok then return failed(why) end
  end
  local ok, why = Fs.mkdirs(seed)
  if not ok then return failed(why) end

  local verdicts_digest = get("VERDICTS_DIGEST")
  local line: string | nil
  line, why = entry(temp, seed, "verdicts", "verdicts", get("VERDICTS_PREFIX"), verdicts_digest,
    get("VERDICTS_RESTORED"))
  if line == nil then return failed(why) end
  keys[#keys + 1] = line
  line, why = entry(temp, seed, "compiles", "build-cache", get("COMPILES_PREFIX"), get("COMPILES_DIGEST"),
    get("COMPILES_RESTORED"))
  if line == nil then return failed(why) end
  keys[#keys + 1] = line
  if verdicts_digest ~= "" and get("SHA") ~= "" then
    if not Fs.is_dir(seed .. "/verdicts") then
      ok, why = Fs.copy_tree(temp .. "/verdicts", seed .. "/verdicts")
      if not ok then return failed(why) end
    end
    keys[#keys + 1] = "verdicts-sha=" .. get("VERDICTS_PREFIX") .. "sha-" .. get("SHA") .. "\n"
  end
  keys[#keys + 1] = zig_build(host, temp, zig, get("ZIG_BUILD_KEY"), get("ZIG_BUILD_EXACT"),
    get("ZIG_BUILD_RESTORED"))
  local marker = Fs.stat(temp .. "/driver-checked/key")
  if marker ~= nil and marker.kind == "file" then
    ok, why = Fs.copy_tree(temp .. "/driver-checked", seed .. "/driver-checked")
    if not ok then return failed(why) end
    local held, trouble = Fs.read(temp .. "/driver-checked/key")
    if held == nil then return failed(trouble) end
    keys[#keys + 1] = "driver-checked=" .. held:gsub("\n+$", "") .. "\n"
  end
  local text = table.concat(keys)
  ok, why = Fs.write(seed .. "/seed.keys", text)
  if not ok then return failed(why) end
  host.print(text)
  return 0
end

function QueueStage.stage_command(_argv: {string}): integer
  return QueueStage.stage(Env.all(), QueueStage.live())
end

return QueueStage
