--- `cosmic test --bench --against <old>`: times the benches the selectors choose on two binaries and says, of
--- each, whether the new one is faster, slower or the same. Each binary runs its own copy of the chosen test files,
--- copied out of the checkout into a directory of its own with the tree modules they require and the testdata/
--- they name, so each side's `require("cosmic.*")` is its own built-in standard library. A file of cosmic/ is copied
--- to stdlib/, since a tree's cosmic/ is cosmic's own (its names are shown as they are in the checkout).
---
--- Each round runs one `cosmic test --bench --json` child of each side, the two alternating which goes first, and
--- keeps each bench's fastest batch of the child as the round's sample; [`Bench.compare`] pairs the rounds. Each
--- side sizes its own batches. The old binary must know `--bench`.
local Bench = require("cosmic.bench")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local logger = require("build.logger")
local plural = require("build.plural")
local log = logger.log

local record test_against
  --- The rounds `--against` runs unless `--rounds` says otherwise.
  DEFAULT_ROUNDS: integer
  --- The fewest rounds that give a band.
  MIN_ROUNDS: integer

  --- What a compare run asks.
  record Ask
    --- The checkout's root.
    root: string
    --- The selectors, relative to `root`: files, directories, or a file and a bench's name (`file:bench_x`).
    selectors: {string}
    --- The old side's binary, a path or a name on PATH.
    old: string
    --- The new side's binary; nil for this program.
    binary?: string
    --- The rounds, at least six.
    rounds: integer
    --- The least length of one child's batch.
    target_ms: integer
    --- One JSON object per bench in place of the table.
    json: boolean
  end
end

test_against.DEFAULT_ROUNDS = 20
test_against.MIN_ROUNDS = 6

--- The batches each child times; the round keeps the fastest.
local CHILD_BATCHES <const> = 3

--- What a side runs and where.
local record Side
  label: string
  binary: string
  argv: {string}
  env: {string: string}
  fds: {integer: integer | string}
  root: string
  --- Each bench's ns per operation, a sample a round, by the name the child prints.
  samples: mut {string: mut {number}}
  --- Each bench's batch size and bytes, from its last child.
  sizes: mut {string: integer}
  bytes: mut {string: integer}
end

--- What is copied to each side: the files under their paths there, and what each copied test file was.
local record Copy
  --- Source path (relative to the root) to the path in the copy.
  files: mut {string: string}
  --- The order the files were found in.
  order: mut {string}
  --- Path in the copy of each chosen test file to its path in the checkout.
  back: mut {string: string}
  --- The child's selectors, in the copy's paths.
  selectors: mut {string}
end

local function has_bench(text: string): boolean
  return text:find("\nlocal function bench_", 1, true) ~= nil or text:sub(1, 21) == "local function bench_"
end

--- Where a file of the checkout goes in the copy: cosmic/ is cosmic's own, so its files go to stdlib/.
local function placed(path: string): string
  if path:sub(1, 7) == "cosmic/" then return "stdlib/" .. path:sub(8) end
  return path
end

local function skip_dir(_: string, name: string, kind: Fs.Kind): boolean
  return kind == "dir" and (name:sub(1, 1) == "." or name == "o" or name == "testdata")
end

--- The test files with a bench under `dir` (relative to `root`, "." for the root).
local function bench_files(root: string, dir: string): {string}
  local base = if dir == "." then root else root .. "/" .. dir end
  local found = assert(Fs.walk(base, { skip = skip_dir }))
  local out: mut {string} = {}
  for _, rel in ipairs(found) do
    if rel:sub(-8) == "_test.tl" then
      local text, _ = Fs.read(base .. "/" .. rel)
      if text ~= nil and has_bench(text) then
        out[#out + 1] = if dir == "." then rel else dir .. "/" .. rel end
      end
    end
  end
  return out
end

--- Adds `path` to `copy` and what it requires of the tree and the testdata/ it names, once each.
local function add(root: string, copy: Copy, path: string)
  if copy.files[path] ~= nil then return end
  copy.files[path] = placed(path)
  copy.order[#copy.order + 1] = path
  if path:sub(1, 9) == "testdata/" then return end
  local text = assert(Fs.read(root .. "/" .. path))
  for name in text:gmatch('require%("([%w_%.]+)"%)') do
    if name:sub(1, 7) ~= "cosmic." then
      local module = name:gsub("%.", "/") .. ".tl"
      local there, _ = Fs.status(root .. "/" .. module)
      if there ~= nil and there.exists and not there.is_dir then add(root, copy, module) end
    end
  end
  for dir in text:gmatch('"(testdata/[%w_%-%.]+)') do
    local there, _ = Fs.status(root .. "/" .. dir)
    if there ~= nil and there.exists then add(root, copy, dir) end
  end
end

--- What the selectors choose, or nil and why.
local function chosen(ask: test_against.Ask): Copy?, string
  local copy: Copy = { files = {}, order = {}, back = {}, selectors = {} }
  local selectors = if #ask.selectors == 0 then { "." } else ask.selectors end
  for _, selector in ipairs(selectors) do
    local path, name = selector:match("^(.+):(bench_[%w_]*)$")
    path = path or selector
    local there, _ = Fs.status(ask.root .. "/" .. path)
    if there == nil or not there.exists then
      return nil, "--against takes test files and directories of the tree, and " .. selector .. " is neither"
    end
    local files = if there.is_dir then bench_files(ask.root, path) else { path } end
    for _, file in ipairs(files) do
      add(ask.root, copy, file)
      copy.back[placed(file)] = file
      local selected = placed(file) .. (if name ~= nil then ":" .. name else "" end)
      copy.selectors[#copy.selectors + 1] = selected
    end
  end
  if #copy.selectors == 0 then
    return nil, "--against: no bench in " .. table.concat(selectors, ", ")
  end
  return copy, ""
end

--- A binary named by a path or found on PATH, as an absolute path.
local function resolved(path: string): string?, string
  if path:find("/", 1, true) == nil then
    local found, why = Proc.find(path)
    if found == nil then return nil, path .. " is not on PATH: " .. tostring(why) end
    path = found
  end
  local whole, why = Fs.absolute(path)
  if whole == nil then return nil, path .. ": " .. tostring(why) end
  local there, _ = Fs.status(whole)
  if there == nil or not there.exists or there.is_dir then return nil, whole .. " is not a file" end
  return whole, ""
end

local function side(label: string, binary: string, argv: {string}, env: {string: string},
                    fds: {integer: integer | string}, tmp: string, root: string, copy: Copy): Side
  local into = tmp .. "/" .. label
  for _, from in ipairs(copy.order) do
    local to = into .. "/" .. assert(copy.files[from])
    assert(Fs.mkdirs(Fs.dirname(to)))
    local there = assert(Fs.status(root .. "/" .. from))
    if there.is_dir then
      assert(Fs.copy_tree(root .. "/" .. from, to))
    else
      assert(Fs.write(to, assert(Fs.read(root .. "/" .. from))))
    end
  end
  local whole: mut {string: string} = Env.all()
  for name, value in pairs(env) do whole[name] = value end
  -- Each side builds its copy into a directory of its own under `tmp`, so removing `tmp` removes the builds.
  whole["COSMIC_BUILD_HOME"] = tmp .. "/" .. label .. "-build"
  return { label = label, binary = binary, argv = argv, env = whole, fds = fds, root = into, samples = {},
    sizes = {}, bytes = {} }
end

--- Runs `s`'s `cosmic test --bench --json` with `words` after it, and returns its stdout, or raises with what it said.
local function child(s: Side, words: {string}): string
  local argv: mut {string} = {}
  for _, word in ipairs(s.argv) do argv[#argv + 1] = word end
  for _, word in ipairs({ "test", "--bench", "--json" }) do argv[#argv + 1] = word end
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local result, why = Child.run(argv, { cwd = s.root, env = s.env, fds = s.fds, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(600) })
  if result == nil then
    error("test: --against: cannot start the " .. s.label .. " cosmic " .. s.binary .. ": " .. tostring(why), 0)
  end
  if not result.ok then
    local how = if result.timed_out then "ran past 600 s"
      elseif result.code ~= nil then "exited " .. tostring(result.code)
      else "was ended by signal " .. tostring(result.signal) end
    error(string.format("test: --against: the %s cosmic %s %s in %s; a bench may use what that binary lacks, " ..
        "or it may not know --bench:\n%s%s", s.label, s.binary, how, s.root, result.stdout or "", result.stderr or ""), 0)
  end
  return result.stdout or ""
end

--- Adds each bench's fastest batch of one child's output to `s`'s samples.
local function take(s: Side, output: string)
  for text in output:gmatch("[^\n]+") do
    if text:sub(1, 1) == "{" then
      local row, _ = Json.decode_object(text)
      if row ~= nil then
        local name, best = Json.string_of(row["name"]), Json.number_of(row["best"])
        if name ~= nil and best ~= nil then
          local list = s.samples[name] or {}
          list[#list + 1] = best
          s.samples[name] = list
          s.sizes[name] = Json.integer_of(row["n"]) or 1
          s.bytes[name] = Json.integer_of(row["bytes"]) or 0
        end
      end
    end
  end
end

--- The name of a bench as the checkout has it, from its name in the copy.
local function shown(copy: Copy, name: string): string
  local path, bench = name:match("^(.+):([%w_]+)$")
  if path == nil or bench == nil then return name end
  return (copy.back[path] or path) .. ":" .. bench
end

local function compare(ask: test_against.Ask, copy: Copy, old: Side, new: Side)
  local words: mut {string} = { "--rounds", tostring(CHILD_BATCHES), "--target-ms", tostring(ask.target_ms) }
  for _, selector in ipairs(copy.selectors) do words[#words + 1] = selector end
  -- One untimed child each builds its copy and warms the page cache, so a binary that cannot run fails first.
  child(new, words)
  child(old, words)
  local tty = Proc.is_tty(2)
  for round = 1, ask.rounds do
    if tty then
      local _, _ = Fs.put(Fs.stderr, string.format("\rtest: --against: round %d/%d", round, ask.rounds))
    end
    local order = if round % 2 == 1 then { new, old } else { old, new } end
    for _, s in ipairs(order) do take(s, child(s, words)) end
  end
  if tty then local _, _ = Fs.put(Fs.stderr, "\r\27[K") end
  local names: mut {string} = {}
  for name in pairs(new.samples) do names[#names + 1] = name end
  table.sort(names)
  local width = 32
  for _, name in ipairs(names) do width = math.max(width, #shown(copy, name)) end
  if not ask.json then print(Bench.compared_header(ask.rounds, width)) end
  for _, name in ipairs(names) do
    local old_samples, new_samples = old.samples[name], new.samples[name]
    if old_samples == nil or #old_samples ~= ask.rounds then
      error("test: --against: the old cosmic " .. old.binary .. " timed " .. name .. " in " ..
          tostring(if old_samples == nil then 0 else #old_samples end) .. " of " .. plural.count(ask.rounds, "round"), 0)
    end
    local label = shown(copy, name)
    local compared = Bench.compare(
      Bench.timing(label, old.sizes[name] or 1, old_samples, old.bytes[name]),
      Bench.timing(label, new.sizes[name] or 1, assert(new_samples), new.bytes[name]))
    print(if ask.json then Bench.compared_record(compared, old.binary, new.binary)
      else Bench.compared_line(compared, width) end)
  end
end

--- Runs the compare `ask` asks for and returns the exit code: 0 when both sides timed every bench, 2 for a
--- command line it refuses, 1 when a side failed.
function test_against.run(ask: test_against.Ask): integer
  if ask.rounds < test_against.MIN_ROUNDS then
    log:complain("test: --against needs at least " .. plural.count(test_against.MIN_ROUNDS, "round") .. " for its band")
    return 2
  end
  local copy, why = chosen(ask)
  if copy == nil then
    log:complain("test: " .. why)
    return 2
  end
  local old_path, old_trouble = resolved(ask.old)
  if old_path == nil then
    log:complain("test: --against " .. old_trouble)
    return 2
  end
  local new_binary: string
  local new_argv: {string}
  local new_env: {string: string} = {}
  local new_fds: {integer: integer | string} = {}
  if ask.binary ~= nil then
    local path, trouble = resolved(ask.binary)
    if path == nil then
      log:complain("test: --binary " .. trouble)
      return 2
    end
    new_binary, new_argv = path, { path }
  else
    local launched, launch_trouble = Proc.relaunch()
    if launched == nil then
      log:complain("test: --against: cannot start this cosmic again: " .. tostring(launch_trouble))
      return 1
    end
    -- Named as this program names itself, not by the core the relaunch starts.
    local named, _ = Proc.executable()
    new_binary = named or assert(launched.argv[1])
    new_argv, new_env, new_fds = launched.argv, launched.env, launched.fds
  end
  local tmp, failure = Fs.mkdtemp("cosmic-against-")
  if tmp == nil then
    log:complain("test: --against: cannot make a temporary directory: " .. tostring(failure))
    return 1
  end
  local ok, err = pcall(function()
    local new = side("new", new_binary, new_argv, new_env, new_fds, tmp, ask.root, copy)
    local old = side("old", old_path, { old_path }, {}, {}, tmp, ask.root, copy)
    compare(ask, copy, old, new)
  end)
  local removed, left = Fs.remove_tree(tmp)
  if not removed then
    log:complain("test: --against: cannot remove " .. tmp .. ": " .. tostring(left))
  end
  if not ok then
    log:complain(tostring(err))
    return 1
  end
  return 0
end

return test_against
