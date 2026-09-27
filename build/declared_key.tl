--- A sandboxed test's verdict key: a digest of what the test was given
--- (`build.test_sandbox`), computed before it runs, from its declared
--- inputs alone (`build.test_inputs`), rather than of what it was seen
--- to read. A sandboxed worker can read nothing else, so a key over all
--- of it holds everything its verdict is a function of, and a verdict
--- under it stands with no observation to replay.
---
--- The key is the digest of
---
--- - the test: its module's path and its name (`id`);
--- - what runs it: the runtime identity -- the core's digest, its
---   platform and configuration, and the Teal and Lua pins -- the
---   digest of the binary's data tables and the `sandboxed` mark
---   (`runtime`), and the compiler (`compiler`, `build.work`'s
---   `Identities`), which compiled every module of the closure and is
---   what build.teal loads as bytecode;
--- - the module's key (`build.importer`), over its import graph's
---   sources, the standard library's included, and the compiler;
--- - the declaration itself, as `test_inputs.canonical` spells it;
--- - the contents of every input it declares or is given by default:
---   each file of its import closure; each path of the tree it `reads`
---   and the fuzz corpora, a file by its contents and a directory by
---   its listing and every entry's contents beneath it; o/bin when it
---   declares `tool`; the projection, o/cosmic.db, when it declares
---   `store`; and each `host` path;
--- - the environment its worker is given (`test_sandbox.environment`):
---   the pinned variables and the declared ones, all of them for `"*"`.
---
--- The host caches it declares are not: they are content-addressed,
--- and never change a result (`build.caches`). A test that declares
--- `network` has no key that holds what it reached, and always runs.
---
--- Nothing in a key names where the tree is -- a path of it is keyed by
--- its name there, and a variable's value by `observations.tree_name`
--- -- so another checkout of the same content reaches the same key, and
--- a verdict is shared by it alone (`build.shared_verdicts`).
---
--- Files are hashed once a run, and a file whose `lstat` says the same
--- as when the build staged it is not read at all: `Digests` remembers
--- each hash by what `lstat` said of the file, seeded with the build's
--- staged hashes (`build.work`).

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")
local test_inputs = require("build.test_inputs")

local record declared_key
  --- What a run knows of the files it keys, kept for the run.
  record Digests
    root: string
    --- Each file's hash by its absolute path, with what `lstat` said of
    --- it when it was hashed: `signature` .. "\0" .. hex sha256.
    hashed: {string:string}
    --- The paths of `hashed` this run looked up, which `kept` answers.
    used: {string:boolean}
    --- While set, each answer by what asked for it: the whole
    --- selection of a run keys its tests before any of them starts, so
    --- one answer serves them all. Nil after, when each asks again.
    snapshot: {string:string}
    --- How many files were read to be hashed, and the time spent keying.
    read: integer
    spent_ns: integer
  end

  --- What one test's key is made of.
  record Spec
    id: string
    --- What names the tests whose specs are the same but for `id`:
    --- their module's path.
    group: string
    module_key: string
    runtime: string
    compiler: string
    --- The module's declaration, as `test_inputs.canonical` spells it.
    declaration: string
    effective: test_inputs.Effective
    --- The environment its worker is given.
    environment: {string:string}
  end
end

--- A file modified this recently may be modified again within the same
--- timestamp tick, which `lstat` would not tell: hashed again rather
--- than remembered, as `build.work` stages it.
local settle_ns <const> = 2 * 1000 * 1000 * 1000

--- What `lstat` says of a file that its hash is remembered by: what the
--- build's stage keeps of it too (`build.work`).
local function signature(st: sys.Stat): string
  return tostring(st.size) .. " " .. tostring(st.mtime * 1000000000 + st.mtime_ns) .. " " ..
    tostring(st.ino) .. " " .. tostring(st.dev)
end

--- A run's digests of the tree at `root`, seeded with `remembered`, what
--- `kept` answered in an earlier run -- absolute path, what `lstat` said,
--- sha256 -- and with `staged`: each staged file's hash and what its
--- stage recorded of it, as `build.work`'s tables hold them -- path,
--- size, mtime_ns, ino, dev, sha256 -- by path of the tree; a row with
--- no modification time was staged unsettled, and is not trusted.
function declared_key.digests(root: string, staged?: {{string}},
                              remembered?: {{string}}): declared_key.Digests
  local hashed: {string:string} = {}
  for _, row in ipairs(remembered or {}) do hashed[row[1]] = row[2] .. "\0" .. row[3] end
  for _, row in ipairs(staged or {}) do
    if row[3] ~= "" then
      hashed[root .. "/" .. row[1]] = row[2] .. " " .. row[3] .. " " .. row[4] .. " " .. row[5] ..
        "\0" .. row[6]
    end
  end
  return { root = root, hashed = hashed, used = {}, read = 0, spent_ns = 0 }
end

--- What of `digests` a later run is to remember, as `digests` takes it:
--- each file this run looked up whose hash it holds, by path, sorted.
function declared_key.kept(digests: declared_key.Digests): {{string}}
  local out: {{string}} = {}
  for path in pairs(digests.used) do
    local was = digests.hashed[path]
    local said, hash = (was or ""):match("^([^\0]*)\0(%x+)$")
    if said ~= nil then out[#out + 1] = { path, said, hash } end
  end
  table.sort(out, function(a: {string}, b: {string}): boolean return a[1] < b[1] end)
  return out
end

--- Starts answering each question once, for a selection of a run.
function declared_key.freeze(digests: declared_key.Digests)
  digests.snapshot = {}
end

--- Stops: from here each question is asked of the tree again.
function declared_key.thaw(digests: declared_key.Digests)
  digests.snapshot = nil
end

--- The hex sha256 of the regular file at `path`, which `st` describes,
--- from `digests` where it was hashed at the same `lstat`.
local function contents(digests: declared_key.Digests, path: string, st: sys.Stat): string
  local said = signature(st)
  digests.used[path] = true
  local was = digests.hashed[path]
  if was ~= nil and was:sub(1, #said + 1) == said .. "\0" then return was:sub(#said + 2) end
  local data, _ = Fs.read(path)
  digests.read = digests.read + 1
  if data == nil then return "unreadable" end
  local hash = Hash.hex_sha256(data)
  if st.mtime * 1000000000 + st.mtime_ns < Time.now_ns() - settle_ns then
    digests.hashed[path] = said .. "\0" .. hash
  end
  return hash
end

--- What one entry is, for its line in a key: "missing", "file" and its
--- contents' hash -- "file+x" when anyone may run it -- "link" and its
--- target, unfollowed, "dir" or "other". `follow` describes what a link
--- at `path` itself leads to, as a bind of it does.
local function entry(digests: declared_key.Digests, path: string, follow: boolean): string, string
  local st, _ = (follow and sys.stat or sys.lstat)(path)
  if st == nil then return "missing", "missing" end
  if st.kind == "file" then
    local runnable = st.mode & 73 ~= 0 -- 0o111
    return "file", (runnable and "file+x " or "file ") .. contents(digests, path, st)
  elseif st.kind == "link" then
    local target, _ = sys.readlink(path)
    return "link", "link " .. (target or "unreadable")
  elseif st.kind == "dir" then
    return "dir", "dir"
  end
  return "other", "other"
end

--- Remembered in `digests.snapshot`, while there is one, under `tag`.
local function once(digests: declared_key.Digests, tag: string,
                    compute: function(): string): string
  local snapshot = digests.snapshot
  if snapshot == nil then return compute() end
  local answer = snapshot[tag]
  if answer == nil then
    answer = compute()
    snapshot[tag] = answer
  end
  return answer
end

--- What `path` holds, followed where it is a link, as a sandbox binds
--- it: an entry's answer, or for a directory "dir" and the digest of
--- every entry beneath it, links unfollowed, in name order -- each by
--- its name beneath `path`, what it is and what it holds.
local function tree(digests: declared_key.Digests, path: string): string
  return once(digests, "t\0" .. path, function(): string
    local kind, answer = entry(digests, path, true)
    if kind ~= "dir" then return answer end
    local lines: {string} = {}
    local function walk(directory: string, prefix: string, depth: integer)
      local listed, trouble = sys.readdir(directory)
      if listed == nil then
        lines[#lines + 1] = prefix .. "\0unlisted " .. trouble
        return
      end
      local names: {string} = {}
      for name in pairs(listed) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        local here = directory .. "/" .. name
        local named = prefix == "" and name or (prefix .. "/" .. name)
        local _, said = entry(digests, here, false)
        lines[#lines + 1] = named .. "\0" .. said
        if said == "dir" then
          -- Deeper than a walk goes is keyed as what could not be seen.
          if depth >= 128 then
            lines[#lines + 1] = named .. "\0too deep"
          else
            walk(here, named, depth + 1)
          end
        end
      end
    end
    walk(path, "", 0)
    return "dir " .. Hash.hex_sha256(table.concat(lines, "\n"))
  end)
end

--- What a path outside the tree holds, as a key keeps it: a file by its
--- contents, and anything else by what it is.
-- TODO: key a host directory by what it holds -- /usr's entries' stamps
-- take half a second to walk, every run -- once something cheaper
-- answers for it (a package database's stamp, or a digest the host
-- keeps): today a directory is keyed by its name alone, and a verdict
-- stands across an update of what it holds, as it does across one of
-- the kernel.
local function host(digests: declared_key.Digests, path: string): string
  return once(digests, "h\0" .. path, function(): string
    local _, answer = entry(digests, path, true)
    return answer
  end)
end

--- `relative`, a path of the tree as a declaration names it, as
--- `test_inputs.plain` spells it, and where it is under the tree: ""
--- for one that names no place in it, which a sandbox does not give
--- either.
local function of_tree(digests: declared_key.Digests, relative: string): string, string
  local plain = test_inputs.plain(relative)
  if plain == "." then return plain, digests.root end
  if plain:sub(1, 1) == "/" or plain == ".." or plain:sub(1, 3) == "../" then return plain, "" end
  return plain, digests.root .. "/" .. plain
end

--- The digest of what a test of `spec` is given, but for its name.
local inputs_of: function(declared_key.Digests, declared_key.Spec): string

--- The key of the test `spec` describes, over what `digests` finds now.
function declared_key.compute(digests: declared_key.Digests,
                              spec: declared_key.Spec): string
  local started = Time.monotonic_ns()
  -- All but the test's name is its module's, and the same for each of
  -- its tests: digested once, while a snapshot holds.
  local inputs = once(digests, "m\0" .. spec.group, function(): string
    return inputs_of(digests, spec)
  end)
  local key = Hash.hex_sha256("declared-1\n" .. observations.key_part("i", spec.id, "") .. "\n" ..
    inputs)
  digests.spent_ns = digests.spent_ns + (Time.monotonic_ns() - started)
  return key
end

--- The digest of what `spec`'s test is given, but for its name.
inputs_of = function(digests: declared_key.Digests, spec: declared_key.Spec): string
  local part = observations.key_part
  local effective = spec.effective
  local lines: {string} = {
    part("m", spec.module_key, ""),
    part("runtime", spec.runtime, ""),
    part("compiler", spec.compiler, ""),
    part("declaration", spec.declaration, ""),
  }
  local files: {string} = {}
  for file in pairs(effective.files) do files[#files + 1] = file end
  table.sort(files)
  for _, file in ipairs(files) do
    local plain, path = of_tree(digests, file)
    local answer = path ~= "" and once(digests, "f\0" .. path, function(): string
      local _, said = entry(digests, path, true)
      return said
    end) or "outside"
    lines[#lines + 1] = part("f", plain, answer)
  end
  local reads: {string} = {}
  for _, read in ipairs(effective.reads) do reads[#reads + 1] = read end
  if effective.tool then reads[#reads + 1] = "o/bin" end
  -- TODO: key the projection a worker attaches whatever it declares
  -- by what of it the worker can query, once it is a store derived from
  -- the closure (the TODO in test_sandbox.plan): today a test that
  -- queries the whole projection through `cosmic.store` without
  -- declaring `store` reads rows its key does not hold -- the other
  -- modules' -- where only the closure's are keyed.
  if effective.store then reads[#reads + 1] = "o/cosmic.db" end
  table.sort(reads)
  local seen: {string:boolean} = {}
  for _, read in ipairs(reads) do
    local plain, path = of_tree(digests, read)
    if not seen[plain] then
      seen[plain] = true
      lines[#lines + 1] = part("r", plain, path ~= "" and tree(digests, path) or "outside")
    end
  end
  local hosts: {string} = {}
  for _, path in ipairs(effective.host) do hosts[#hosts + 1] = test_inputs.plain(path) end
  table.sort(hosts)
  for _, path in ipairs(hosts) do
    if not seen[path] then
      seen[path] = true
      lines[#lines + 1] = part("h", path, host(digests, path))
    end
  end
  local names: {string} = {}
  for name in pairs(spec.environment) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    lines[#lines + 1] = part("e", name,
      observations.tree_name(spec.environment[name], digests.root))
  end
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- Whether a test of `effective` has a key at all: one that reaches the
--- network does not, whatever it reached being no input a key holds.
-- TODO: key a test that declares only loopback hosts (127.0.0.1, ::1,
-- localhost), which reach nothing past its own sandbox, once the
-- sandbox keeps such a worker offline (the TODO in test_sandbox.plan):
-- today it is given the host's network, and runs every time.
function declared_key.keyable(effective: test_inputs.Effective): boolean
  return next(effective.network) == nil
end

return declared_key
