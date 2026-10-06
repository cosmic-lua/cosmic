--- The table of what a test may require of its host (build.host_requires):
--- how a name is read and refused, what class each has, and what a probe
--- of this host answers.

local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local confine = require("build.confine")
local host_names = require("build.host_names")
local host_requires = require("build.host_requires")

--- A run's probes with a stand-in for the runner's sandbox probe.
local function host_with(answer: host_requires.Sandbox, path?: string, system?: {string}): host_requires.Host
  return host_requires.new({ sandbox = function(): host_requires.Sandbox return answer end,
    path = path,
    system = system or (path ~= nil and { path, (Fs.absolute(path)) } or nil) })
end

--- The one answer for `name` of `host`.
local function ask(host: host_requires.Host, name: string): host_requires.Answer
  local answers = host_requires.answer(host, { name })
  assert(#answers == 1)
  return answers[1]
end

--- Every name of the table, and each form that takes an argument, is read.
local function test_every_name_parses()
  for _, name in ipairs(host_names.names) do
    local text = name
    if name == "path" then text = "path:/etc/hostname" end
    if name == "program" then text = "program:sh" end
    local spec, why = host_names.parse(text)
    assert(spec ~= nil, why)
    assert(spec.base == name)
  end
  local spec = assert(host_names.parse("landlock:3"))
  assert(spec.base == "landlock" and spec.argument == "3")
  assert(assert(host_names.parse("landlock")).argument == "")
  assert(assert(host_names.parse("path:/a:b")).argument == "/a:b", "a colon in a path stays in it")
end

--- Each way a name is wrong is refused with a message naming its rule.
local function test_a_bad_name_is_refused_naming_the_rule()
  local cases: {{string}} = {
    { "sandbxo", "unknown requirement" },
    { "", "unknown requirement" },
    { "Sandbox", "unknown requirement" },
    { "landlock:", "positive integer" },
    { "landlock:0", "positive integer" },
    { "landlock:03", "positive integer" },
    { "landlock:x", "positive integer" },
    { "landlock:-1", "positive integer" },
    { "landlock:1.5", "positive integer" },
    { "landlock:12345", "positive integer" },
    { "path:etc/hostname", "absolute path" },
    { "path:", "absolute path" },
    { "path", "needs an argument" },
    { "program", "needs an argument" },
    { "program:", "no \"/\"" },
    { "program:/bin/sh", "no \"/\"" },
    { "program:a/b", "no \"/\"" },
    { "sandbox:1", "takes no argument" },
    { "proc:", "takes no argument" },
    { "root:yes", "takes no argument" },
  }
  for _, case in ipairs(cases) do
    local spec, why = host_names.parse(case[1])
    assert(spec == nil, string.format("%q was read", case[1]))
    assert(why:find(case[2], 1, true), string.format("%q: %s", case[1], why))
    local answer = ask(host_requires.new(), case[1])
    assert(answer.kind == "refused" and answer.key == "" and answer.why == why)
    assert(host_names.class(case[1]) == nil)
  end
end

--- A refused name is refused whatever the host and the platform, and
--- answers beside the others rather than ending the list.
local function test_a_refused_name_answers_beside_the_others()
  local answers = host_requires.answer(host_requires.new(), { "bogus", "root", "path:rel" })
  assert(#answers == 3)
  assert(answers[1].kind == "refused" and answers[1].name == "bogus")
  assert(answers[2].name == "root" and answers[2].kind ~= "refused")
  assert(answers[3].kind == "refused")
end

--- The class of each name: what only some platforms have, and what any
--- host may lack.
local function test_classes()
  for _, name in ipairs({ "sandbox", "landlock", "landlock:2", "userns", "nest", "own_proc", "proc",
      "portable" }) do
    assert(host_names.class(name) == "platform", name)
  end
  for _, name in ipairs({ "root", "path:/etc", "program:sh" }) do
    assert(host_names.class(name) == "host", name)
  end
end

--- Off Linux every Linux requirement is n/a with no probe asked; on it,
--- none is: what the host refuses is skipped, never n/a.
local function test_a_platform_absence_is_n_a_and_a_host_absence_skipped()
  local asked = 0
  local host = host_requires.new({ sandbox = function(): host_requires.Sandbox
    asked = asked + 1
    return { ok = false, why = "refused here", broken = false }
  end })
  local sandbox = ask(host, "sandbox")
  if assert(sys.uname()).sysname == "Linux" then
    assert(sandbox.kind == "skipped" and sandbox.why == "refused here" and asked == 1)
    assert(ask(host, "landlock:9999").kind == "skipped", "an ABI no kernel has is skipped, not n/a")
    assert(ask(host, "proc").kind ~= "na")
  else
    assert(sandbox.kind == "na" and asked == 0, "no probe is asked where the platform has none")
    for _, name in ipairs({ "landlock", "userns", "nest", "own_proc", "proc" }) do
      assert(ask(host, name).kind == "na", name)
    end
  end
  assert(ask(host, "path:/no/such/path/cosmic").kind == "skipped", "a host's absence is skipped")
  assert(ask(host, "program:cosmic-no-such-program").kind == "skipped")
end

--- A requirement present carries the text its key holds and no reason; one
--- absent carries a reason and no key.
local function test_present_has_a_key_and_absent_a_reason()
  local host = host_with({ ok = true, why = "", broken = false })
  for _, name in ipairs({ "sandbox", "landlock", "userns", "nest", "own_proc", "proc", "portable", "root",
      "path:/proc/self" }) do
    local answer = ask(host, name)
    if answer.kind == "present" then
      assert(answer.key ~= "" and answer.why == "", name)
    else
      assert(answer.key == "" and answer.why ~= "", name .. ": " .. answer.kind)
    end
  end
end

--- The sandbox probe answers `sandbox` on Linux: an ok is present, a
--- refusal skipped, and a defect or a missing probe raises, never passes.
local function test_sandbox_follows_the_runners_probe()
  if not (assert(sys.uname()).sysname == "Linux") then Test.skip("only Linux has this probe") end
  assert(ask(host_with({ ok = true, why = "", broken = false }), "sandbox").kind == "present")
  local refused = ask(host_with({ ok = false, why = "no userns", broken = false }), "sandbox")
  assert(refused.kind == "skipped" and refused.why == "no userns")
  local ok, trouble = pcall(ask, host_with({ ok = false, why = "defect", broken = true }), "sandbox")
  assert(not ok and tostring(trouble):find("defect", 1, true), tostring(trouble))
  local no_ok, no_probe = pcall(ask, host_requires.new(), "sandbox")
  assert(not no_ok and tostring(no_probe):find("sandbox probe", 1, true), tostring(no_probe))
end

--- A probe runs once a host, however many times the name is asked.
local function test_each_probe_runs_once_per_host()
  if not (assert(sys.uname()).sysname == "Linux") then Test.skip("only Linux has this probe") end
  local asked = 0
  local host = host_requires.new({ sandbox = function(): host_requires.Sandbox
    asked = asked + 1
    return { ok = true, why = "", broken = false }
  end })
  local answers = host_requires.answer(host, { "sandbox", "sandbox", "proc" })
  local _ = ask(host, "sandbox")
  assert(asked == 1 and answers[1] == answers[2])
end

--- Landlock follows the kernel's ABI: `landlock:N` is present up to it,
--- and what a key holds is that number.
local function test_landlock_is_held_to_the_kernels_abi()
  if not (assert(sys.uname()).sysname == "Linux") then Test.skip("only Linux has this probe") end
  local host = host_requires.new()
  local abi, _ = confine.landlock_abi()
  if abi == nil then
    assert(ask(host, "landlock").kind == "skipped")
    return
  end
  local at = ask(host, "landlock:" .. abi)
  assert(at.kind == "present" and at.key == "abi=" .. abi)
  assert(ask(host, "landlock").kind == "present")
  assert(ask(host, "landlock:" .. (abi + 1)).kind == "skipped")
  assert(ask(host, "landlock:" .. (abi + 1)).why:find("below", 1, true))
end

--- `root` follows the run's user, and `proc` the mount.
local function test_root_and_proc_follow_the_host()
  local host = host_requires.new()
  assert((ask(host, "root").kind == "present") == (sys.getuid() == 0))
  if assert(sys.uname()).sysname == "Linux" then
    assert((ask(host, "proc").kind == "present") == (Fs.is_dir("/proc/self") == true))
  end
end

--- `nest` needs what `userns` does, and where it is present so is that.
local function test_nest_implies_userns()
  if not (assert(sys.uname()).sysname == "Linux") then Test.skip("only Linux has this probe") end
  local host = host_requires.new()
  if ask(host, "nest").kind == "present" then
    assert(ask(host, "userns").kind == "present")
  end
end

--- `path:` is present for a file, keyed by its contents, and for a
--- directory; absent for neither.
local function test_a_path_is_keyed_by_its_contents(tmp: string)
  local file = tmp .. "/needed"
  assert(Fs.write(file, "one"))
  local first = ask(host_requires.new(), "path:" .. file)
  assert(first.kind == "present" and first.key:match("^sha256:%x+$"), first.key)
  assert(Fs.write(file, "two"))
  local second = ask(host_requires.new(), "path:" .. file)
  assert(second.kind == "present" and second.key ~= first.key, "a changed file keeps its key")
  assert(Fs.write(file, "one"))
  assert(ask(host_requires.new(), "path:" .. file).key == first.key)
  local dir = ask(host_requires.new(), "path:" .. tmp)
  assert(dir.kind == "present" and dir.key == "dir")
  local gone = ask(host_requires.new(), "path:" .. tmp .. "/gone")
  assert(gone.kind == "skipped" and gone.why:find("does not exist", 1, true))
end

--- `program:` is looked up on the search list and keyed by the digest of
--- the file it finds, so a different program of the name is a different key.
local function test_a_program_is_keyed_by_the_file_it_finds(tmp: string)
  local bin = tmp .. "/bin"
  assert(Fs.mkdirs(bin))
  local program = bin .. "/cosmic-tool"
  assert(Fs.write(program, "echo one\n", tonumber("755", 8)))
  local first = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:cosmic-tool")
  assert(first.kind == "present" and first.key:match("^sha256:%x+$"), first.key)
  assert(ask(host_with({ ok = true, why = "", broken = false }, bin), "program:cosmic-tool").key == first.key)
  assert(Fs.write(program, "echo two\n", tonumber("755", 8)))
  local second = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:cosmic-tool")
  assert(second.kind == "present" and second.key ~= first.key)
  local missing = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:cosmic-other")
  assert(missing.kind == "skipped" and missing.key == "")
  assert(Fs.write(bin .. "/plain", "data", tonumber("644", 8)))
  local plain = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:plain")
  assert(plain.kind == "skipped", "a file that cannot run is no program")
end

--- A FIFO or a device is refused naming the rule, and the probe returns
--- rather than waiting on a read that never ends; a directory is "dir"; a
--- link into /proc is "present", not read.
local function test_a_path_is_keyed_by_what_it_is(tmp: string)
  local pipe = tmp .. "/pipe"
  assert(sys.mkfifo(pipe, tonumber("600", 8)))
  local fifo = ask(host_requires.new(), "path:" .. pipe)
  assert(fifo.kind == "skipped" and fifo.why:find("fifo", 1, true) and fifo.why:find("no key can hold", 1, true),
    fifo.why)
  assert(assert(sys.symlink(pipe, tmp .. "/to-pipe")))
  assert(ask(host_requires.new(), "path:" .. tmp .. "/to-pipe").kind == "skipped", "a link is followed")
  if Fs.exists("/dev/zero") == true then
    local zero = ask(host_requires.new(), "path:/dev/zero")
    assert(zero.kind == "skipped" and zero.why:find("char", 1, true), zero.why)
  end
  if assert(sys.uname()).sysname == "Linux" and Fs.exists("/proc/self/status") == true then
    assert(assert(sys.symlink("/proc/self/status", tmp .. "/to-proc")))
    local linked = ask(host_requires.new(), "path:" .. tmp .. "/to-proc")
    assert(linked.kind == "present" and linked.key == "present", linked.key)
    assert(ask(host_requires.new(), "path:/proc/self/status").key == "present")
  end
  local dir = ask(host_requires.new(), "path:" .. tmp)
  assert(dir.kind == "present" and dir.key == "dir")
end

--- A script is keyed by its interpreter beside it, so a changed one moves
--- the key.
local function test_a_script_is_keyed_with_its_interpreter(tmp: string)
  local bin = tmp .. "/bin"
  assert(Fs.mkdirs(bin))
  local interpreter = bin .. "/interp"
  assert(Fs.write(interpreter, "#!/bin/sh\n", tonumber("755", 8)))
  assert(Fs.write(bin .. "/script", "#!" .. interpreter .. "\n", tonumber("755", 8)))
  local host = host_with({ ok = true, why = "", broken = false }, bin)
  local first = ask(host, "program:script")
  assert(first.kind == "present" and first.key:find(";interpreter=sha256:", 1, true), first.key)
  assert(Fs.write(interpreter, "#!/bin/sh\n# changed\n", tonumber("755", 8)))
  local second = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:script")
  assert(second.key ~= first.key)
  -- env's options and assignments are skipped to the program it runs, which
  -- is keyed, with env itself, beside the script.
  assert(Fs.write(bin .. "/env", "env\n", tonumber("755", 8)))
  assert(Fs.write(bin .. "/env-script", "#!" .. bin .. "/env -S -u HOME X=1 interp -v\n",
    tonumber("755", 8)))
  local through_env = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:env-script")
  assert(through_env.key:find(";interpreter=sha256:%x+;runs=sha256:%x+$"), through_env.key)
  assert(Fs.write(interpreter, "#!/bin/sh\n# changed again\n", tonumber("755", 8)))
  local changed = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:env-script")
  assert(changed.key ~= through_env.key, "the program env runs is keyed")
end

--- Each answer carries its class.
local function test_an_answer_carries_its_class()
  local answers = host_requires.answer(host_requires.new(), { "root", "proc", "bogus" })
  assert(answers[1].class == "host" and answers[2].class == "platform" and answers[3].class == "host")
end

--- A portable artifact is `runtime_context` "portable-v1", and where this
--- is not one `portable` is n/a; one that is present has an artifact to start
--- again.
local function test_portable_is_a_portable_artifact()
  local portable = Store.meta("runtime_context") == "portable-v1"
  local answer = ask(host_requires.new({ portable = portable }), "portable")
  assert(answer.kind == "present" or answer.kind == "na", answer.kind)
  assert((answer.kind == "present") == portable)
  if answer.kind == "present" then assert(answer.key == "artifact") end
  -- A native start is the context's say, whatever this run is.
  assert(ask(host_requires.new(), "portable").kind == "na")
  assert(ask(host_requires.new({ portable = false }), "portable").kind == "na")
end

--- The settings `userns` reads, standing in for the host's.
local function settings(files: {string:string}): host_requires.Host
  return host_requires.new({ read = function(path: string): host_requires.Read
    local text = files[path]
    if text == nil then
      return { data = "", why = path .. ": No such file or directory", missing = true }
    end
    return { data = text, why = "", missing = false }
  end })
end

local limit_file <const> = "/proc/sys/user/max_user_namespaces"
local clone_file <const> = "/proc/sys/kernel/unprivileged_userns_clone"
local apparmor_file <const> = "/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
local status_file <const> = "/proc/self/status"
local with_admin <const> = "Name:\tx\nCapEff:\t000001ffffffffff\n"
local without_admin <const> = "Name:\tx\nCapEff:\t0000000000000000\n"

--- `userns` follows the limit, and the two switches for a process without
--- CAP_SYS_ADMIN, whatever its user; the key is the same wherever the limit.
local function test_userns_follows_the_settings()
  if not (assert(sys.uname()).sysname == "Linux") then Test.skip("only Linux has this probe") end
  if Fs.exists("/proc/self") ~= true then Test.skip("this host has no /proc/self") end
  local function userns(files: {string:string}): host_requires.Answer
    return ask(settings(files), "userns")
  end
  local ok = userns({ [limit_file] = "64300\n", [status_file] = without_admin })
  assert(ok.kind == "present" and ok.key == "allowed", ok.why)
  assert(userns({ [limit_file] = "7\n", [status_file] = without_admin }).key == "allowed")
  local none = userns({ [limit_file] = "0\n", [status_file] = with_admin })
  assert(none.kind == "skipped" and none.why:find("is 0", 1, true))
  local clone = userns({ [limit_file] = "9", [clone_file] = "0\n", [status_file] = without_admin })
  assert(clone.kind == "skipped" and clone.why:find("unprivileged_userns_clone", 1, true))
  local apparmor = userns({ [limit_file] = "9", [apparmor_file] = "1\n", [status_file] = without_admin })
  assert(apparmor.kind == "skipped" and apparmor.why:find("apparmor", 1, true))
  -- A process holding CAP_SYS_ADMIN is bound by neither switch.
  assert(userns({ [limit_file] = "9", [clone_file] = "0", [apparmor_file] = "1",
    [status_file] = with_admin }).kind == "present")
  assert(userns({ [limit_file] = "9", [clone_file] = "1", [apparmor_file] = "0",
    [status_file] = without_admin }).kind == "present")
  local missing = userns({ [status_file] = without_admin })
  assert(missing.kind == "skipped" and missing.why:find("not built in", 1, true))
end

--- A setting that is there and says no number, or a status with no `CapEff`,
--- raises, as neither is an absence.
local function test_a_setting_that_cannot_be_read_raises()
  if not (assert(sys.uname()).sysname == "Linux") then Test.skip("only Linux has this probe") end
  if Fs.exists("/proc/self") ~= true then Test.skip("this host has no /proc/self") end
  local garbled, why = pcall(ask, settings({ [limit_file] = "many\n", [status_file] = without_admin }), "userns")
  assert(not garbled and tostring(why):find("holds no number", 1, true), tostring(why))
  local no_caps, caps_why = pcall(ask, settings({ [limit_file] = "9", [status_file] = "Name:\tx\n" }), "userns")
  assert(not no_caps and tostring(caps_why):find("CapEff", 1, true), tostring(caps_why))
  -- A read that fails for any reason but the file's absence is a defect.
  local denied = host_requires.new({ read = function(path: string): host_requires.Read
    return { data = "", why = path .. ": Permission denied", missing = false }
  end })
  local unreadable, trouble = pcall(ask, denied, "userns")
  assert(not unreadable and tostring(trouble):find("cannot be read", 1, true), tostring(trouble))
end

--- `check` accepts the Linux-class names, a leg's promises having made them
--- safe, and refuses repeats and a `path:` or `program:` the worker could
--- not use; a /proc grant covers the files beneath it only.
local function test_check_refuses_what_the_worker_could_not_use()
  local inputs: host_names.Inputs = { host = { "/proc/self/status", "/etc/hosts" },
    system = true, env = { "PATH" } }
  assert(host_names.check({ "root", "program:jq", "path:/etc/hosts", "portable" }, inputs))
  for _, name in ipairs({ "sandbox", "landlock", "landlock:3", "userns", "nest", "own_proc", "proc" }) do
    assert(host_names.check({ name }, inputs), name)
  end
  local cases: {{any}} = {
    { { "root", "root" }, "written twice" },
    { { "nope" }, "unknown requirement" },
    { { "path:/etc/passwd" }, "needs a host grant of the path" },
  }
  for _, case in ipairs(cases) do
    local found, why = host_names.check(case[1] as {string}, inputs)
    assert(not found and why:find(case[2] as string, 1, true) ~= nil, tostring(why))
  end
  assert(host_names.check({ "path:/proc/self/status" }, { host = { "/proc" } }))
  assert(not host_names.check({ "path:/procfs/x" }, { host = { "/proc" } }))
  assert(not host_names.check({ "program:jq" }, { system = true }))
  assert(not host_names.check({ "program:jq" }, { env = { "PATH" } }))
  assert(host_names.check({ "program:jq" }, { system = true, env = { "PATH" } }))
end

--- A run's promises are names the table accepts, written with commas; a
--- leg that promises Landlock of a version promises every version below it,
--- and no other name stands in for one.
local function test_promises_are_read_and_matched_by_name()
  local read = assert(host_names.read_promises("sandbox,landlock:3,nest"))
  assert(#read == 3 and read[2] == "landlock:3")
  assert(#assert(host_names.read_promises("")) == 0)
  for _, bad in ipairs({ "nope", "sandbox,sandbox", "sandbox,", "path:rel", "landlock:0" }) do
    local found, why = host_names.read_promises(bad)
    assert(found == nil and why ~= nil, bad)
  end
  assert(host_names.promised(read, "nest") and host_names.promised(read, "sandbox"))
  assert(host_names.promised(read, "landlock") and host_names.promised(read, "landlock:2") and
      host_names.promised(read, "landlock:3"))
  assert(not host_names.promised(read, "landlock:4"))
  assert(not host_names.promised(read, "proc") and not host_names.promised(read, "userns"))
  assert(not host_names.promised({ "landlock" }, "landlock:2"))
  assert(host_names.promised({ "path:/etc/hosts" }, "path:/etc/hosts"))
  assert(not host_names.promised({ "path:/etc/hosts" }, "path:/etc/passwd"))
end

--- A program found only outside the system's paths is one a worker with
--- the profile "system" cannot run: absent, though the runner finds it.
local function test_a_program_outside_the_systems_paths_is_absent(tmp: string)
  assert(Fs.mkdirs(tmp .. "/bin"))
  assert(Fs.write(tmp .. "/bin/elsewhere-tool", "x\n"))
  assert(Fs.chmod(tmp .. "/bin/elsewhere-tool", tonumber("755", 8) as integer))
  local answer = ask(host_with({ ok = true, why = "", broken = false }, tmp .. "/bin", { "/nonexistent-system" }),
    "program:elsewhere-tool")
  assert(answer.kind == "skipped" and answer.why:find("outside the system's paths", 1, true), answer.why)
  if Fs.exists("/bin/sh") == true then
    assert(ask(host_with({ ok = true, why = "", broken = false }, "/bin"), "program:sh").kind == "present")
  end
end

--- A platform that is not Linux has none of Linux's requirements: n/a
--- without a probe, whatever the host has, and a host requirement is
--- still asked.
local function test_a_platform_that_is_not_linux_is_not_applicable()
  local host = host_requires.new({ linux = false })
  local answers = host_requires.answer(host, { "proc", "nest", "landlock:2", "root" })
  for i = 1, 3 do
    assert(answers[i].kind == "na" and answers[i].class == "platform", answers[i].name)
  end
  assert(answers[4].class == "host" and answers[4].kind ~= "na")
end
