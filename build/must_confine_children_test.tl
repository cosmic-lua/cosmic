--- The children of the end-to-end tests of [`confine.must_confine`] (build/must_confine_test.tl and
--- build/must_confine_sandboxed_test.tl). A spawn `must_confine` refuses fails every running stand-in, the one that runs a
--- test included, so each case runs in a process of its own, which makes its stand-ins with [`confine.call`] and prints what
--- each ended with, a line `name=ok` or `name=<what it raised>`. A test module with no test: it only registers them.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local confine = require("build.confine")
local test_child = require("build.test_child")

local record must_confine_children
end

--- The line of what `ran` ended with, named `name`.
local function said(name: string, ran: confine.Ran): string
  if ran.ok then return name .. "=ok" end
  return name .. "=" .. tostring(ran.produced)
end

--- More paths than a sandbox unveils, which `must_confine` refuses to start a process with, whatever the kernel allows.
local function too_many(tmp: string): mut {string}
  local many: mut {string} = {}
  for i = 1, confine.unveil_max + 1 do many[#many + 1] = tmp .. "/many" .. tostring(i) end
  return many
end

--- Starts that `must_confine` refuses: a process given more paths than a sandbox unveils, which a test passed over and
--- one that raised besides; and a process started with a sandbox of its own that does not unveil and take the network. The words are the stand-in program and a directory the child may change.
test_child.register("refusals", function(args: {string}): integer
  local probe, tmp = args[1], args[2]
  if probe == nil or tmp == nil then return 2 end
  local many = too_many(tmp)
  print(said("passed_over", confine.call(function(...: any): any...
    confine.must_confine({ reads = many })
    local ran, _ = Child.run({ probe, "write " .. tmp .. "/ran ran" })
    confine.confine(nil)
    assert(ran == nil, "an unconfined process ran in its place")
  end, nil, { tmp })))
  assert(Fs.stat(tmp .. "/ran") == nil, "nothing runs in its place")
  print(said("raised_too", confine.call(function(...: any): any...
    confine.must_confine({ reads = many })
    local _, _ = Child.run({ probe, "exit 0" })
    confine.confine(nil)
    error("its own failure")
  end, nil, { tmp })))
  print(said("offline_alone", confine.call(function(...: any): any...
    confine.must_confine({ reads = { probe } })
    local _, _ = Child.run({ probe, "exit 0" }, { sandbox = { offline = true } })
    confine.confine(nil)
  end, nil, { tmp })))
  return 0
end)

--- A start in a root of its own where the worker is held by a Landlock ruleset: the module the variable
--- [`confine.held_variable`] names, which the test gives the child.
test_child.register("held", function(args: {string}): integer
  local probe, tmp = args[1], args[2]
  if probe == nil or tmp == nil then return 2 end
  print(said("confined", confine.call(function(...: any): any...
    confine.confine({ reads = { probe } })
    local ran, _ = Child.run({ probe, "write " .. tmp .. "/ran ran" })
    confine.confine(nil)
    assert(ran == nil, "an unconfined process ran in its place")
  end, nil, { tmp })))
  print(said("own_sandbox", confine.call(function(...: any): any...
    local ran, _ = Child.run({ probe, "exit 0" }, { sandbox = { unveil = { reads = { probe } }, offline = true } })
    assert(ran == nil, "a process started in a root of its own")
  end, nil, { tmp })))
  return 0
end)

--- What `COSMIC_SANDBOX` says: a confine of more paths than a sandbox unveils falls back to an unconfined process
--- unless the mode is "must".
test_child.register("mode", function(args: {string}): integer
  local probe, tmp = args[1], args[2]
  if probe == nil or tmp == nil then return 2 end
  local many = too_many(tmp)
  many[#many + 1] = probe
  print(said("fell_back", confine.call(function(...: any): any...
    confine.confine({ reads = many })
    local ran = assert(Child.run({ probe, "exit 0" }))
    confine.confine(nil)
    assert(ran.ok, "the process it fell back to did not run")
  end, nil, { tmp })))
  return 0
end)

--- Where the kernel confines a process, one under `must_confine` runs held to what was declared -- not seeing what it was
--- not given -- or is refused. The words are the stand-in program, a directory the child may change, a file beside it that
--- the process reads, and a file it was not given.
test_child.register("confined", function(args: {string}): integer
  local probe, tmp, data, hidden = args[1], args[2], args[3], args[4]
  if probe == nil or tmp == nil or data == nil or hidden == nil then return 2 end
  print(said("confined", confine.call(function(...: any): any...
    confine.must_confine({ reads = { data, probe } })
    local ran, _ = Child.run({ probe, "exists " .. hidden .. " 3; copy " .. data .. " " .. tmp .. "/out; " ..
        "present /proc/self/net/dev && grep-count /proc/self/net/dev : || exit 0" },
      { cwd = tmp, stdout = "capture" })
    confine.confine(nil)
    if ran == nil then return end
    assert(ran.code == 0, "the confined process exited " .. tostring(ran.code))
    local out = assert(Fs.read(tmp .. "/out"))
    assert(out == "in" and (ran.stdout == "" or ran.stdout == "1\n"), out .. tostring(ran.stdout))
  end, nil, { tmp })))
  return 0
end)

--- Where the platform has no sandbox: a process under `must_confine` is refused, and one under `confine` with more paths
--- than a sandbox unveils falls back and runs.
test_child.register("unsandboxed", function(args: {string}): integer
  local probe, tmp = args[1], args[2]
  if probe == nil or tmp == nil then return 2 end
  print(said("refused", confine.call(function(...: any): any...
    confine.must_confine({ reads = { probe } })
    local _, _ = Child.run({ probe, "exit 0" })
    confine.confine(nil)
  end, nil, { tmp })))
  local many = too_many(tmp)
  many[#many + 1] = probe
  print(said("fell_back", confine.call(function(...: any): any...
    confine.confine({ reads = many })
    local ran = assert(Child.run({ probe, "exit 0" }))
    confine.confine(nil)
    assert(ran.ok, "the process it fell back to did not run")
  end, nil, { tmp })))
  return 0
end)

return must_confine_children
