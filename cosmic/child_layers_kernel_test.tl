--- [`Sandbox.intersect`] against the kernel: for pairs of layers drawn at
--- random, a child held by the one and then restricting itself by the
--- other ([`Sandbox.restrict`]), and a child [`Child.start`] holds to
--- both by `layers`, are each refused exactly what the intersection
--- leaves out, path by path and letter by letter.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local searchable = require("build.searchable")
local ChildPolicy = require("build.child_policy_fixture")

--- The temporary directory, and this program, which the child runs.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  env = { "TMPDIR" },
  requires = { "sandbox" },
}

--- The child: with "stack" it restricts itself first by the grants that
--- follow "--" ("path=letters"); then, for each directory before "--",
--- it says whether it may read and write the file `f` there, and make a
--- directory there.
local PROBE <const> = [[
local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")
return function(argv: {string}): integer
  local dirs: mut {string} = {}
  local grants: mut {Sandbox.Grant} = {}
  local after = false
  for i = 2, #argv do
    local word = assert(argv[i])
    if word == "--" then
      after = true
    elseif after then
      local path, letters = word:match("^(.*)=(%a+)$")
      grants[#grants + 1] = { path = assert(path), letters = assert(letters) }
    else
      dirs[#dirs + 1] = word
    end
  end
  if argv[1] == "stack" then
    local held, why = Sandbox.restrict({ grants = grants })
    if not held then
      print("restrict: " .. why)
      return 1
    end
  end
  for _, dir in ipairs(dirs) do
    local read, _ = sys.open(dir .. "/f", sys.O_RDONLY)
    if read ~= nil then sys.close(read) end
    local written, _ = sys.open(dir .. "/f", sys.O_WRONLY)
    if written ~= nil then sys.close(written) end
    local made, _ = sys.mkdir(dir .. "/made", 0x1ed)
    local made_it: boolean = made == true
    print(dir .. " r=" .. tostring(read ~= nil) .. " w=" .. tostring(written ~= nil) ..
        " c=" .. tostring(made_it))
  end
  return 0
end
]]

local LETTERS <const>: {string} = { "r", "w", "c", "rw", "rc", "wc", "rwc" }

--- A layer drawn by `pick`: one to three grants, each the index of a
--- directory and its letters.
local record Drawn
  dir: integer
  letters: string
end

local function drawn(pick: function(integer): integer): {Drawn}
  local out: mut {Drawn} = {}
  for _ = 1, pick(3) do
    out[#out + 1] = { dir = pick(3), letters = assert(LETTERS[pick(#LETTERS)]) }
  end
  return out
end

--- The grants of `layer` on `dirs`, after a grant to read `script`
--- and /proc where it is given.
local function grants_of(layer: {Drawn}, dirs: {string}, script?: string): {Sandbox.Grant}
  local out: mut {Sandbox.Grant} = {}
  if script ~= nil then
    out[#out + 1] = { path = script, letters = "r" }
    -- Sandbox.restrict reads /proc to count this process's threads.
    out[#out + 1] = { path = "/proc", letters = "r" }
  end
  for _, grant in ipairs(layer) do
    out[#out + 1] = { path = assert(dirs[grant.dir]), letters = grant.letters }
  end
  return out
end

--- What `met` lets a child do in each of `dirs`, as the probe prints it.
local function predicted(met: Sandbox.Policy, dirs: {string}): string
  local out: mut {string} = {}
  for _, dir in ipairs(dirs) do
    out[#out + 1] = dir .. " r=" .. tostring((Sandbox.allows(met, dir .. "/f", "r"))) ..
      " w=" .. tostring((Sandbox.allows(met, dir .. "/f", "w"))) ..
      " c=" .. tostring((Sandbox.allows(met, dir, "c"))) .. "\n"
  end
  return table.concat(out)
end

--- A fresh tree of three directories under `root`, each with a file `f`
--- every user may read and write.
local function tree(root: string): {string}
  local dirs = { root .. "/a", root .. "/a/b", root .. "/c" }
  for _, dir in ipairs(dirs) do
    assert(Fs.mkdirs(dir))
    searchable.share(dir)
    assert(Fs.write(dir .. "/f", "x"))
    searchable.share(dir .. "/f")
  end
  searchable.share(root)
  return dirs
end

--- The probe's words: the mode, the directories, "--", and the grants of `layer`.
local function words(script: string, mode: string, dirs: {string}, layer: {Sandbox.Grant}): {string}
  local argv: mut {string} = { (assert(Proc.executable())), script, mode }
  for _, dir in ipairs(dirs) do argv[#argv + 1] = dir end
  argv[#argv + 1] = "--"
  for _, grant in ipairs(layer) do
    if grant is Sandbox.Path then argv[#argv + 1] = grant.path .. "=" .. grant.letters end
  end
  return argv
end

--- Runs the probe; skips the test where the host gives no sandbox.
local function probed(argv: {string}, opts: Child.Options): string
  local result, why = Child.run(argv, opts)
  if result == nil then
    assert(ChildPolicy.unsandboxable(tostring(why)), "the start was refused: " .. tostring(why))
    Test.skip(tostring(why))
  end
  local held = assert(result, "Test.skip ends the test where the start is refused")
  assert(held.code == 0, tostring(held.code) .. ": " .. tostring(held.stdout) .. tostring(held.stderr))
  return held.stdout or ""
end

local function test_stacked_layers_hold_what_intersect_says(tmp: string)
  local base = assert(Fs.absolute(searchable.open(tmp)))
  local script = base .. "/probe.tl"
  assert(Fs.write(script, PROBE))
  searchable.share(script)
  -- A fixed seed, so a failure is the same on every run.
  local state = 20261125
  local function pick(n: integer): integer
    state = (state * 1103515245 + 12345) % 2147483648
    return state % n + 1
  end
  for round = 1, 12 do
    local first = drawn(pick)
    local second = drawn(pick)
    -- The kernel holds the child to the first, and the child adds the second.
    local dirs = tree(base .. "/stack" .. tostring(round))
    local want = predicted(assert(Sandbox.intersect({ grants = grants_of(first, dirs) },
      { grants = grants_of(second, dirs) })), dirs)
    local stacked = probed(words(script, "stack", dirs, grants_of(second, dirs)), { timeout_ns = Child.FOREVER,
      cwd = base, stdout = "capture", stderr = "capture", policy = { grants = grants_of(first, dirs, script) } })
    assert(stacked == want, "round " .. tostring(round) .. " stacked:\n" .. stacked .. "intersect:\n" .. want)
    -- The start holds the child to both, met.
    local fresh = tree(base .. "/start" .. tostring(round))
    local fresh_want = predicted(assert(Sandbox.intersect({ grants = grants_of(first, fresh) },
      { grants = grants_of(second, fresh) })), fresh)
    local started = probed(words(script, "start", fresh, {}), { timeout_ns = Child.FOREVER, cwd = base,
      stdout = "capture", stderr = "capture", policy = { grants = grants_of(first, fresh, script) },
      layers = { { grants = grants_of(second, fresh, script) } } })
    assert(started == fresh_want, "round " .. tostring(round) .. " started:\n" .. started .. "intersect:\n" .. fresh_want)
  end
end

--- Layers that name different setup do not meet, and the start says so.
local function test_layers_with_different_setup_are_refused(tmp: string)
  local base = assert(Fs.absolute(searchable.open(tmp)))
  local result, why = Child.run({ (assert(Proc.executable())), "-e", "return 0" },
    { timeout_ns = Child.FOREVER, cwd = base,
      policy = { grants = { { path = base, letters = "r" } }, set_env = { A = "1" } },
      layers = { { grants = { { path = base, letters = "r" } }, set_env = { A = "2" } } } })
  assert(result == nil and why.message:find("layers", 1, true) ~= nil, tostring(why))
end

local function test_an_empty_list_of_layers_raises()
  local ok, err = pcall(function()
    local _, _ = Child.run({ "/bin/true" }, { timeout_ns = Child.FOREVER, layers = {} })
  end)
  assert(not ok and tostring(err):find("layers is empty", 1, true) ~= nil, tostring(err))
end

--- Runs the probe over `dirs` from `cwd` under `opts`' policy and layers.
local function probe_under(script: string, dirs: {string}, cwd: string, policy?: Sandbox.Policy,
                           layers?: {Sandbox.Policy}): string
  return probed(words(script, "start", dirs, {}), { timeout_ns = Child.FOREVER, cwd = cwd, stdout = "capture",
    stderr = "capture", policy = policy, layers = layers })
end

--- A grant of a link in one layer meets the file it names in another,
--- never more than both give: a layer granting a link to a directory the
--- policy does not grant gives nothing there.
local function test_a_link_in_a_layer_meets_what_it_names(tmp: string)
  local base = assert(Fs.absolute(searchable.open(tmp)))
  local script = base .. "/probe.tl"
  assert(Fs.write(script, PROBE))
  searchable.share(script)
  local dirs = tree(base .. "/t")
  -- t/a/link names t/c, which the policy does not grant.
  assert(Fs.symlink(base .. "/t/c", base .. "/t/a/link"))
  local policy: Sandbox.Policy = { grants = { { path = script, letters = "r" }, { path = base .. "/t/a", letters = "rw" } } }
  local layer: Sandbox.Policy = { grants = { { path = script, letters = "r" }, { path = base .. "/t/a/link", letters = "r" } } }
  local out = probe_under(script, { assert(dirs[3]) }, base, policy, { layer })
  assert(out == base .. "/t/c r=false w=false c=false\n", out)
end

--- A relative grant meets an absolute one naming the same directory, and
--- layers alone, with no policy, hold the child.
local function test_a_relative_grant_meets_an_absolute_one(tmp: string)
  local base = assert(Fs.absolute(searchable.open(tmp)))
  local script = base .. "/probe.tl"
  assert(Fs.write(script, PROBE))
  searchable.share(script)
  local dirs = tree(base .. "/t")
  local a = assert(dirs[1])
  local out = probe_under(script, { a }, base .. "/t", nil, {
    { grants = { { path = script, letters = "r" }, { path = "a", letters = "rw" } } },
    { grants = { { path = script, letters = "r" }, { path = a, letters = "r" } } } })
  assert(out == a .. " r=true w=false c=false\n", out)
end
