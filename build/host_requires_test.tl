--- The table of what a test may require of its host (build.host_requires):
--- how a name is read and refused, what class each has, and what a probe
--- of this host answers.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local host_requires = require("build.host_requires")
local type test_sandbox_probe = require("build.test_sandbox_probe")

--- A run's probes with a stand-in for the runner's sandbox probe.
local function host_with(answer: test_sandbox_probe.Answer, path?: string): host_requires.Host
  return host_requires.new({ sandbox = function(): test_sandbox_probe.Answer return answer end,
    path = path })
end

--- The one answer for `name` of `host`.
local function ask(host: host_requires.Host, name: string): host_requires.Answer
  local answers = host_requires.answer(host, { name })
  assert(#answers == 1)
  return answers[1]
end

--- Every name of the table, and each form that takes an argument, is read.
local function test_every_name_parses()
  for _, name in ipairs(host_requires.names) do
    local text = name
    if name == "path" then text = "path:/etc/hostname" end
    if name == "program" then text = "program:sh" end
    local spec, why = host_requires.parse(text)
    assert(spec ~= nil, why)
    assert(spec.base == name)
  end
  local spec = assert(host_requires.parse("landlock:3"))
  assert(spec.base == "landlock" and spec.argument == "3")
  assert(assert(host_requires.parse("landlock")).argument == "")
  assert(assert(host_requires.parse("path:/a:b")).argument == "/a:b", "a colon in a path stays in it")
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
    local spec, why = host_requires.parse(case[1])
    assert(spec == nil, string.format("%q was read", case[1]))
    assert(why:find(case[2], 1, true), string.format("%q: %s", case[1], why))
    local answer = ask(host_requires.new(), case[1])
    assert(answer.kind == "refused" and answer.key == "" and answer.why == why)
    assert(host_requires.class(case[1]) == nil)
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
    assert(host_requires.class(name) == "platform", name)
  end
  for _, name in ipairs({ "root", "path:/etc", "program:sh" }) do
    assert(host_requires.class(name) == "host", name)
  end
end

--- Off Linux every Linux requirement is n/a with no probe asked; on it,
--- none is: what the host refuses is skipped, never n/a.
local function test_a_platform_absence_is_n_a_and_a_host_absence_skipped()
  local asked = 0
  local host = host_requires.new({ sandbox = function(): test_sandbox_probe.Answer
    asked = asked + 1
    return { ok = false, why = "refused here", broken = false }
  end })
  local sandbox = ask(host, "sandbox")
  if confine.sandbox_platform() then
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
  if not confine.sandbox_platform() then return end
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
  if not confine.sandbox_platform() then return end
  local asked = 0
  local host = host_requires.new({ sandbox = function(): test_sandbox_probe.Answer
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
  if not confine.sandbox_platform() then return end
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
  if confine.sandbox_platform() then
    assert((ask(host, "proc").kind == "present") == (Fs.is_dir("/proc/self") == true))
  end
end

--- `nest` needs what `userns` does, and where it is present so is that.
local function test_nest_implies_userns()
  if not confine.sandbox_platform() then return end
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
  assert(Fs.write(program, "#!/bin/sh\necho one\n", tonumber("755", 8)))
  local first = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:cosmic-tool")
  assert(first.kind == "present" and first.key:match("^sha256:%x+$"), first.why)
  assert(ask(host_with({ ok = true, why = "", broken = false }, bin), "program:cosmic-tool").key == first.key)
  assert(Fs.write(program, "#!/bin/sh\necho two\n", tonumber("755", 8)))
  local second = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:cosmic-tool")
  assert(second.kind == "present" and second.key ~= first.key)
  local missing = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:cosmic-other")
  assert(missing.kind == "skipped" and missing.key == "")
  assert(Fs.write(bin .. "/plain", "data", tonumber("644", 8)))
  local plain = ask(host_with({ ok = true, why = "", broken = false }, bin), "program:plain")
  assert(plain.kind == "skipped", "a file that cannot run is no program")
end
