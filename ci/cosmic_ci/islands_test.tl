--- `check-islands` type-checks each file ci/bootstrap-files.txt lists with `--standalone --check`, names the ones the
--- running driver's Teal refuses, and refuses a list that is stale or a run of the pinned binary nothing names.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Islands = require("cosmic_ci.islands")
local Test = require("cosmic.test")

-- The check starts the running driver again, as build_paths_test does.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A checkout at `tmp` holding the files `files` (path to text), with ci/islands.txt empty and a pin. 
local function checkout(tmp: string, given: {string:string}): string
  local root = tmp .. "/checkout"
  assert(Fs.mkdirs(root .. "/ci"))
  local files: mut {string:string} = {}
  for path, text in pairs(given) do files[path] = text end
  files["ci/islands.txt"] = "# nothing is listed\n"
  files["ci/cosmic-driver.pin"] = "0123456789abcdef0123456789abcdef01234567\nurl\ndigest\n"
  for path, text in pairs(files) do
    assert(Fs.mkdirs(root .. "/" .. (path:match("^(.*)/[^/]*$") or "")))
    assert(Fs.write(root .. "/" .. path, text))
  end
  return root
end

--- The list is one path a line: comments, a CR, white space and blank lines are not paths.
local function test_the_list_is_one_path_a_line_without_comments_or_white_space()
  local paths = Islands.paths("# why\n\nbuild/a.tl  # trailing\r\n  build/b.tl \n\t\nci/\n# build/c.tl\n")
  assert(#paths == 3 and paths[1] == "build/a.tl" and paths[2] == "build/b.tl" and paths[3] == "ci/",
    table.concat(paths, ","))
end

--- build/paths.tl is run by the driver's own path (the build directory's resolver), so the list must name it.
local function test_the_resolver_of_the_build_directory_must_be_listed(tmp: string)
  local root = checkout(tmp, { ["ci/bootstrap-files.txt"] = "build/zig.tl\n", ["build/zig.tl"] = "return 1\n", ["build/paths.tl"] = "return 1\n" })
  local files, why = Islands.files(root)
  assert(files == nil and why:find("build/paths.tl is run on the pinned release's binary", 1, true) == 1, tostring(why))
  assert(Fs.write(root .. "/ci/bootstrap-files.txt", "build/zig.tl\nbuild/paths.tl\n"))
  assert(Islands.files(root) ~= nil)
end

--- A clean script passes and a script the new grammar refuses fails by name, with the compiler's complaint: a syntax
--- error and a type error. A script is checked, not run, however it behaves when run.
local function test_a_script_is_checked_and_not_run(tmp: string)
  local marker = tmp .. "/ran"
  local root = checkout(tmp, {
    ["build/ok.tl"] = 'local Fs = require("cosmic.fs")\nassert(Fs.write("' .. marker .. '", "ran"))\nreturn function(_: {string}): integer return 0 end\n',
    ["build/syntax.tl"] = "local x: integer =\n",
    ["build/typed.tl"] = 'local x: integer = "a"\nprint(x)\n',
    ["build/crash.tl"] = 'error("no such module")\n',
    ["build/exits.tl"] = "return function(_: {string}): integer return 7 end\n",
  })
  local report = Islands.check(root, { "build/ok.tl", "build/syntax.tl", "build/typed.tl", "build/crash.tl", "build/exits.tl" }, Env.all())
  local complaints, checked = report.complaints, report.checked
  assert(checked == 5, tostring(checked))
  assert(#complaints == 2, table.concat(complaints, "\n"))
  local syntax, typed = assert(complaints[1]), assert(complaints[2])
  assert(syntax:find("build/syntax.tl (listed in ci/bootstrap-files.txt): ", 1, true) == 1, syntax)
  assert(syntax:find("build/syntax.tl:2:", 1, true) ~= nil, syntax)
  assert(typed:find("build/typed.tl (listed in ci/bootstrap-files.txt): ", 1, true) == 1, typed)
  assert(typed:find("(not_assignable)", 1, true) ~= nil, typed)
  assert(typed:find("use only APIs of the pinned release, or move the pin", 1, true) ~= nil, typed)
  assert(Fs.exists(marker) == false, "a script was run")
end

--- A script the new grammar's checker refuses and the fork's would let by is the point of the check: a write to a
--- view.
local function test_a_write_to_a_view_is_a_complaint(tmp: string)
  local root = checkout(tmp, {
    ["build/view.tl"] = 'local lines: {string} = {}\nlines[#lines + 1] = "x"\nprint(#lines)\n',
  })
  local report = Islands.check(root, { "build/view.tl" }, Env.all())
  assert(#report.complaints == 1 and assert(report.complaints[1]):find("(view_written)", 1, true) ~= nil,
    table.concat(report.complaints, "\n"))
end

--- The list is read, and an entry whose file is gone is refused, so that the list cannot rot.
local function test_a_stale_entry_is_refused(tmp: string)
  local root = checkout(tmp, {
    ["ci/bootstrap-files.txt"] = "# why\nbuild/zig.tl\nbuild/paths.tl\nbuild/gone.tl\n",
    ["build/zig.tl"] = "return 1\n", ["build/paths.tl"] = "return 1\n",
  })
  local files, why = Islands.files(root)
  assert(files == nil, "a stale entry was accepted")
  assert(why:find("ci/bootstrap-files.txt lists build/gone.tl, which is not in the checkout: remove the stale entry", 1, true) == 1, why)
  assert(Fs.write(root .. "/ci/bootstrap-files.txt", "build/zig.tl\nbuild/paths.tl\n"))
  local listed = assert(Islands.files(root))
  assert(#listed == 2 and listed[1] == "build/zig.tl")
end

--- B1: a `standalone(` call of build/zig.tl runs a file on the pinned binary, which the list must hold; one whose file is
--- not a string literal on its line (the name on the next line, or in a variable) is refused, every call site being
--- counted, and a comment is no call.
local function test_the_calls_of_zig_are_listed_and_all_read(tmp: string)
  local root = checkout(tmp, {
    ["ci/bootstrap-files.txt"] = "build/zig.tl\nbuild/paths.tl\n",
    ["build/paths.tl"] = "return 1\n",
    ["build/zig.tl"] = "-- standalone(root, \"build/x.tl\", words)\nlocal function standalone(a: string)\nend\nstandalone(root, \"build/fetch.tl\", w)\n",
  })
  local files, why = Islands.files(root)
  assert(files == nil, "a run not listed was accepted")
  assert(why:find("build/fetch.tl is run on the pinned release's binary", 1, true) == 1, why)
  local forms = {
    'local r = standalone(root,\n  "build/fetch.tl", words)\n',
    'local script = "build/fetch.tl"\nlocal r = standalone(root, script, words)\n',
  }
  for _, form in ipairs(forms) do
    assert(Fs.write(root .. "/build/zig.tl", form))
    files, why = Islands.files(root)
    assert(files == nil, "a call that is not read was accepted: " .. form)
    assert(why:find("^build/zig.tl:%d+: calls standalone%( with a file that is not a string literal") ~= nil, why)
  end
end

--- A project of `ci/` the release's `fix --check` refuses is named, with its findings, and a listed file that is not
--- clean is named by `check`.
local function test_the_release_checks_all_of_ci(tmp: string)
  local root = checkout(tmp, { ["ci/run_local.tl"] = "this is not Teal (", ["ci/fine.tl"] = "local record Fine\nend\nreturn Fine\n" })
  local report = Islands.check(root, { "ci/run_local.tl" }, Env.all())
  assert(report.checked == 1 and #report.complaints == 1, table.concat(report.complaints, "\n"))
  assert(Islands.project(root, Env.all()) ~= nil, "a ci/ the release refuses was accepted")
  assert(Fs.write(root .. "/ci/run_local.tl", "local record Local\nend\nreturn Local\n"))
  local clean = Islands.project(root, Env.all())
  assert(clean == nil, tostring(clean))
  assert(Fs.write(root .. "/ci/unrequired.tl", "local x: integer = \"a\"\nreturn x\n"))
  local refused = assert(Islands.project(root, Env.all()))
  assert(refused:find("unrequired.tl:1:", 1, true) ~= nil, refused)
end

--- A script that type-checks.
local function clean(): string
  return 'print("usage")\nreturn function(_: {string}): integer\n  return 0\nend\n'
end

--- A listed file that is not there is no clean file: the check says why it stopped, though it said no finding.
local function test_a_listed_file_that_is_missing_is_a_complaint(tmp: string)
  local root = checkout(tmp, {})
  local report = Islands.check(root, { "build/missing.tl" }, Env.all())
  assert(#report.complaints == 1, table.concat(report.complaints, "\n"))
  local missing = assert(report.complaints[1])
  assert(missing:find("build/missing.tl (listed in ci/bootstrap-files.txt): exited 1 with --check, not 0: ", 1, true) == 1, missing)
  assert(missing:find("No such file or directory", 1, true) ~= nil, missing)
end

--- Each refusal and the pass, through the command.
local function test_the_command_fails_for_a_refused_script_a_stale_entry_and_a_missing_list(tmp: string)
  local root = checkout(tmp, {
    ["ci/bootstrap-files.txt"] = "build/zig.tl\nbuild/patch.tl\neval/result.tl\nbuild/paths.tl\n",
    ["build/paths.tl"] = clean(),
    ["build/zig.tl"] = 'local note = \'standalone(root, "build/patch.tl", args)\'\nprint(note)\n' .. clean(),
    ["build/patch.tl"] = clean(),
    ["eval/result.tl"] = clean(),
  })
  assert(Islands.verdict(root) == 0)
  assert(Fs.write(root .. "/build/zig.tl", "return\n  =\n"))
  assert(Islands.verdict(root) == 1)
  assert(Fs.write(root .. "/build/zig.tl", clean()))
  assert(Fs.write(root .. "/ci/islands.txt", "build/zig.tl\n"))
  assert(Islands.verdict(root) == 1)
  assert(Fs.write(root .. "/ci/islands.txt", "\n"))
  assert(Fs.write(root .. "/ci/bootstrap-files.txt", "build/zig.tl\nbuild/paths.tl\nbuild/gone.tl\n"))
  assert(Islands.verdict(root) == 1)
  assert(Fs.remove(root .. "/ci/bootstrap-files.txt"))
  assert(Islands.verdict(root) == 1)
  assert(Fs.remove(root .. "/ci/islands.txt"))
  assert(Islands.verdict(root) == 2)
end
