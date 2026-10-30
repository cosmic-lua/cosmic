--- `check-islands` type-checks each bootstrap script by running it with `--help`, and
--- names the ones the running driver's Teal refuses.
local Fs = require("cosmic.fs")
local Islands = require("cosmic_ci.islands")
local Env = require("cosmic.env")
local Test = require("cosmic.test")

-- The check starts the running driver again, as build_paths_test does.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A shell script whose `exec` runs `file` standalone on the bootstrap, as the wrappers of `bin/` and `eval/` do.
local function wrapper(file: string): string
  return '#!/bin/sh\n# runs ' .. file .. ' with bin/cosmic-bootstrap, quoted here\nset -eu\nroot=.\n' ..
    'exec "$root/bin/cosmic-bootstrap" --standalone "$root/' .. file .. '" "$@"\n'
end

--- A checkout at `tmp` holding the list `paths` and the files `files`
--- (path to text).
local function checkout(tmp: string, paths: string, files: {string:string}): string
  local root = tmp .. "/checkout"
  assert(Fs.mkdirs(root .. "/ci"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/bin"))
  assert(Fs.mkdirs(root .. "/eval"))
  assert(Fs.write(root .. "/ci/islands.txt", paths))
  for path, text in pairs(files) do
    assert(Fs.mkdirs(root .. "/" .. (path:match("^(.*)/[^/]*$") or "")))
    assert(Fs.write(root .. "/" .. path, text))
  end
  return root
end

local function test_the_list_is_one_path_a_line_without_comments()
  local paths = Islands.paths("# why\n\nbuild/a.tl  # trailing\n  build/b.tl\nci/\n")
  assert(#paths == 3 and paths[1] == "build/a.tl" and paths[2] == "build/b.tl" and paths[3] == "ci/",
    table.concat(paths, ","))
end

--- The scripts `paths` name, each run by a wrapper `bin/<its name>`.
local function run_by_bin(paths: {string}): {Islands.Script}
  local scripts: mut {Islands.Script} = {}
  for _, path in ipairs(paths) do
    scripts[#scripts + 1] = { path = path, wrappers = { "bin/" .. (path:match("([%w_]+)%.tl$") or path) } }
  end
  return scripts
end

--- A clean script passes and a script the new grammar refuses fails by name, with the compiler's complaint: a syntax
--- error and a type error. The scripts are run, with `--help`, as the bootstrap runs them.
local function test_a_script_is_checked_and_run_with_help(tmp: string)
  local marker = tmp .. "/ran"
  local root = checkout(tmp, "", {
    ["build/ok.tl"] = 'local Fs = require("cosmic.fs")\nassert(Fs.write("' .. marker .. '", "ran"))\nreturn function(_: {string}): integer return 0 end\n',
    ["build/syntax.tl"] = "local x: integer =\n",
    ["build/typed.tl"] = 'local x: integer = "a"\nprint(x)\n',
  })
  local report = Islands.check(root, run_by_bin({ "build/ok.tl", "build/syntax.tl", "build/typed.tl" }), Env.all())
  local complaints, checked = report.complaints, report.checked
  assert(checked == 3, tostring(checked))
  assert(#complaints == 2, table.concat(complaints, "\n"))
  local syntax, typed = assert(complaints[1]), assert(complaints[2])
  assert(syntax:find("build/syntax.tl (run by bin/syntax): ", 1, true) == 1, syntax)
  assert(syntax:find("build/syntax.tl:2:", 1, true) ~= nil, syntax)
  assert(typed:find("build/typed.tl (run by bin/typed): ", 1, true) == 1, typed)
  assert(typed:find("(not_assignable)", 1, true) ~= nil, typed)
  assert(typed:find("use only APIs of the pinned release, or move the pin", 1, true) ~= nil, typed)
  assert(Fs.read(marker) == "ran", "the clean script was not run")
end

--- A script that prints its usage and exits with `status`.
local function exiting(status: integer): string
  return 'print("usage")\nreturn function(_: {string}): integer\n  return ' .. tostring(status) .. "\nend\n"
end

--- A script that checks clean and then stops for another reason is no clean script: its exit status is held to what its
--- `--help` gives ([`Islands.help_exits`], 0 for a script the table does not name).
local function test_a_script_that_fails_for_another_reason_is_a_complaint(tmp: string)
  local root = checkout(tmp, "", {
    ["build/crash.tl"] = 'error("no such module")\n',
    ["build/exits.tl"] = exiting(7),
    ["build/perf.tl"] = exiting(1),
    ["build/paths.tl"] = exiting(0),
  })
  local report = Islands.check(root, run_by_bin({ "build/crash.tl", "build/exits.tl", "build/perf.tl", "build/paths.tl" }), Env.all())
  local complaints = report.complaints
  assert(#complaints == 3, table.concat(complaints, "\n"))
  assert(assert(complaints[1]):find("build/crash.tl (run by bin/crash): exited 1 with --help, not 0: ", 1, true) == 1 and
      assert(complaints[1]):find("no such module", 1, true) ~= nil, complaints[1])
  assert(assert(complaints[2]):find("build/exits.tl (run by bin/exits): exited 7 with --help, not 0", 1, true) == 1, complaints[2])
  -- perf.tl gives 1 as it does; paths.tl, which gives 1 too, giving 0 is not what the table says.
  assert(assert(complaints[3]):find("build/paths.tl (run by bin/paths): exited 0 with --help, not 1", 1, true) == 1, complaints[3])
  -- The hint for a status says how to accept it, not to move the pin.
  local exits = assert(complaints[2])
  assert(exits:find("if --help is meant to exit 7, add it to Islands.help_exits (ci/cosmic_ci/islands.tl)", 1, true) ~= nil, exits)
  assert(exits:find("move the pin", 1, true) == nil, exits)
end

--- A script the new grammar's checker refuses and the fork's would let by is the point of the check: a write to a
--- view.
local function test_a_write_to_a_view_is_a_complaint(tmp: string)
  local root = checkout(tmp, "", {
    ["build/view.tl"] = 'local lines: {string} = {}\nlines[#lines + 1] = "x"\nprint(#lines)\n',
  })
  local report = Islands.check(root, run_by_bin({ "build/view.tl" }), Env.all())
  assert(#report.complaints == 1 and assert(report.complaints[1]):find("(view_written)", 1, true) ~= nil,
    table.concat(report.complaints, "\n"))
end

local function test_a_script_that_is_not_there_is_a_complaint(tmp: string)
  local root = checkout(tmp, "", {})
  local report = Islands.check(root, run_by_bin({ "build/gone.tl" }), Env.all())
  assert(report.checked == 1 and #report.complaints == 1, table.concat(report.complaints, "\n"))
  assert(assert(report.complaints[1]):find("build/gone.tl (run by bin/gone): is not there", 1, true) == 1, report.complaints[1])
end

--- A wrapper of `eval/` is found with no list naming it, and the complaint names it as well as its script.
local function test_a_script_of_a_new_wrapper_is_named_with_its_wrapper(tmp: string)
  local root = checkout(tmp, "", {
    ["build/zig.tl"] = "return 1\n",
    ["eval/new"] = wrapper("eval/new.tl"),
    ["eval/new.tl"] = 'local x: integer = "a"\nprint(x)\n',
  })
  local scripts = assert(Islands.scripts(root))
  local report = Islands.check(root, scripts, Env.all())
  assert(#report.complaints == 1, table.concat(report.complaints, "\n"))
  local complaint = assert(report.complaints[1])
  assert(complaint:find("^eval/new.tl %(run by eval/new%): ") and complaint:find("eval/new.tl:1:", 1, true), complaint)
end

local function test_the_scripts_are_those_the_wrappers_run(tmp: string)
  local root = checkout(tmp, "", {
    ["bin/zig"] = wrapper("build/zig.tl"),
    ["bin/cosmic-bootstrap"] = '#!/bin/sh\nexec "$cached" "$@"\n# cosmic-bootstrap\n',
    ["bin/zig.pin"] = "9.9.9\nsha256\n",
    ["build/launcher.tl"] = "-- standalone(root, \"build/commented.tl\", args), a comment\n",
    [".github/scripts/build.sh"] = wrapper("build/paths.tl"),
    ["ci/run-local"] = wrapper("ci/not_scanned.tl"),
    ["vendor/x/run"] = wrapper("vendor/not_scanned.tl"), ["build/zig.tl"] = 'standalone(root, "build/patch.tl", args)\nstandalone(root, "build/zig_fetch.tl", args)\n',
    ["eval/check/kv"] = wrapper("eval/check/grade.tl"),
    ["eval/check/pack"] = wrapper("eval/check/grade.tl"),
    ["eval/README.md"] = 'run `bin/cosmic-bootstrap --standalone "$root/eval/nothing.tl"`\n',
    ["eval/round.tl"] = 'local built = system.run({ root .. "/bin/cosmic-bootstrap", "--standalone",\n  root .. "/build/paths.tl", root })\n',
    ["build/ref.tl"] = 'return { "/bin/cosmic-bootstrap", "compile", "/cache key" }\n',
  })
  local scripts = assert(Islands.scripts(root))
  local seen: mut {string} = {}
  for _, script in ipairs(scripts) do
    seen[#seen + 1] = script.path .. " <- " .. table.concat(script.wrappers, ",")
  end
  assert(table.concat(seen, "\n") == table.concat({
    "build/patch.tl <- build/zig.tl",
    "build/paths.tl <- .github/scripts/build.sh,eval/round.tl",
    "build/zig.tl <- bin/zig",
    "build/zig_fetch.tl <- build/zig.tl",
    "eval/check/grade.tl <- eval/check/kv,eval/check/pack",
  }, "\n"), table.concat(seen, "\n"))
end

--- A line that runs the bootstrap in a form the check cannot read would leave its file unchecked: refused, naming it, and
--- so is none at all.
local function test_a_wrapper_in_another_form_is_refused_and_none_at_all_is_too(tmp: string)
  local root = checkout(tmp, "", {
    ["build/zig.tl"] = "return 1\n",
    ["bin/odd"] = '#!/bin/sh\nbin/cosmic-bootstrap --standalone eval/odd.tl\n',
  })
  local scripts, why = Islands.scripts(root)
  assert(scripts == nil, "a wrapper in another form was accepted")
  assert(why:find("^bin/odd:2: runs a file standalone on bin/cosmic%-bootstrap in a form check%-islands cannot read") ~= nil, why)
  assert(Fs.remove(root .. "/bin/odd"))
  scripts, why = Islands.scripts(root)
  assert(scripts == nil, "no wrapper was accepted")
  assert(why:find("no file of the checkout runs", 1, true) ~= nil, why)
end

--- B1: a `standalone(` call of build/zig.tl whose file is not a string literal on its line (the name on the next line,
--- or in a variable) would drop the file out of the check silently; every call site is counted, a comment is not one.
local function test_a_call_of_zig_that_is_not_read_is_refused(tmp: string)
  local root = checkout(tmp, "", { ["bin/zig"] = wrapper("build/zig.tl"), ["build/zig.tl"] = "return 1\n" })
  local forms = {
    'local r = standalone(root,\n  "build/zig_fetch.tl", words)\n',
    'local script = "build/zig_fetch.tl"\nlocal r = standalone(root, script, words)\n',
  }
  for _, form in ipairs(forms) do
    assert(Fs.write(root .. "/build/zig.tl", "-- standalone(root, \"build/x.tl\", words)\nlocal function standalone(a: string)\nend\n" .. form))
    local scripts, why = Islands.scripts(root)
    assert(scripts == nil, "a call that is not read was accepted: " .. form)
    assert(why:find("^build/zig.tl:%d+: calls standalone%( with a file that is not a string literal") ~= nil, why)
  end
  assert(Fs.write(root .. "/build/zig.tl", "-- standalone(root, \"build/x.tl\", words)\nstandalone(root, \"build/zig_fetch.tl\", w)\n"))
  local scripts = assert(Islands.scripts(root))
  assert(#scripts == 2 and assert(scripts[2]).path == "build/zig_fetch.tl", "the comment counted as a call")
end

--- B2: a file of bin/ or eval/ that names the bootstrap is read whatever its first line says, and refused when it does
--- not say which file it runs.
local function test_a_file_of_bin_that_names_the_bootstrap_is_read_whatever_its_first_line(tmp: string)
  local root = checkout(tmp, "", { ["build/zig.tl"] = "return 1\n" })
  local forms = { "set -eu\nexec bin/cosmic-bootstrap \"$@\"\n", "#!/usr/bin/env cosmic\nexec bin/cosmic-bootstrap eval/x.tl\n" }
  for _, form in ipairs(forms) do
    assert(Fs.write(root .. "/bin/runner", form))
    local scripts, why = Islands.scripts(root)
    assert(scripts == nil, "a file with no wrapper form was skipped: " .. form)
    assert(why:find("^bin/runner:%d: names bin/cosmic%-bootstrap without %-%-standalone") ~= nil, why)
  end
  -- Without a shebang, and in the form the wrappers use, it is a wrapper like any other.
  assert(Fs.write(root .. "/bin/runner", 'exec "$root/bin/cosmic-bootstrap" --standalone "$root/eval/x.tl" "$@"\n'))
  local scripts = assert(Islands.scripts(root))
  assert(#scripts == 1 and assert(scripts[1]).path == "eval/x.tl" and assert(scripts[1]).wrappers[1] == "bin/runner", "not read")
end

--- B3: a runner outside bin/ and eval/ is found too, and one in a form that cannot be read is refused naming its file;
--- ci/ is the one directory left out (compiled by the driver's own tests).
local function test_a_runner_anywhere_in_the_checkout_is_found_or_refused(tmp: string)
  local root = checkout(tmp, "", { ["build/zig.tl"] = "return 1\n", ["tools/run"] = wrapper("tools/x.tl") })
  local scripts = assert(Islands.scripts(root))
  assert(#scripts == 1 and assert(scripts[1]).path == "tools/x.tl" and assert(scripts[1]).wrappers[1] == "tools/run", "not found")
  assert(Fs.write(root .. "/tools/other.tl", '-- cosmic-bootstrap, in a comment\nlocal b = "bin/cosmic-bootstrap"\nsystem.run({ b, "--standalone", path })\n'))
  local refused, why = Islands.scripts(root)
  assert(refused == nil and why:find("^tools/other.tl:2: runs a file standalone", 1) ~= nil, tostring(why))
end

--- A script the pinned release runs and ci/strict-files.txt leaves out is named.
local function test_a_script_missing_from_the_strict_files_is_named()
  local scripts: {Islands.Script} = { { path = "eval/a.tl", wrappers = { "eval/a" } }, { path = "eval/b.tl", wrappers = { "eval/b", "eval/c" } } }
  local missing = Islands.unlisted(scripts, { "eval/a.tl" })
  assert(#missing == 1 and missing[1] == "eval/b.tl (run by eval/b, eval/c)", table.concat(missing, ","))
  assert(#Islands.unlisted(scripts, { "eval/a.tl", "eval/b.tl" }) == 0)
end

local function test_the_command_fails_for_a_refused_script_a_listed_one_and_a_missing_list(tmp: string)
  -- The wrappers run build/zig.tl, which runs build/patch.tl; each prints usage and exits as the real script does with
  -- `--help`.
  local files: mut {string:string} = {
    ["bin/zig"] = wrapper("build/zig.tl"),
    ["eval/result"] = wrapper("eval/result.tl"),
    ["build/zig.tl"] = 'local note = \'standalone(root, "build/patch.tl", args)\'\nprint(note)\n' .. exiting(0),
    ["ci/strict-files.txt"] = "# the files run with no ceiling\nbuild/zig.tl\nbuild/patch.tl\neval/result.tl\n",
    ["build/patch.tl"] = exiting(Islands.help_exits["build/patch.tl"] or 0),
    ["eval/result.tl"] = exiting(Islands.help_exits["eval/result.tl"] or 0),
    ["ci/cosmic-driver.pin"] = "0123456789abcdef0123456789abcdef01234567\nurl\ndigest\n",
  }
  local root = checkout(tmp, "# nothing is listed\n", files)
  assert(Islands.command({ root }) == 0)
  assert(Fs.write(root .. "/build/zig.tl", "return\n  =\n"))
  assert(Islands.command({ root }) == 1)
  assert(Fs.write(root .. "/build/zig.tl", exiting(0)))
  assert(Fs.write(root .. "/ci/strict-files.txt", "build/zig.tl\n"))
  assert(Islands.command({ root }) == 1)
  assert(Fs.write(root .. "/ci/strict-files.txt", "build/zig.tl\neval/result.tl\n"))
  assert(Fs.write(root .. "/ci/islands.txt", "build/zig.tl\n"))
  assert(Islands.command({ root }) == 1)
  assert(Fs.remove(root .. "/ci/islands.txt"))
  assert(Islands.command({ root }) == 2)
end
