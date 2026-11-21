--- [`build.refusals`] as the tool shows it: a project with one module refused for what it holds and two files that
--- require it, run through `cosmic fix` and a whole `cosmic test`. Each says the refusal first, the dependents in one
--- line and how many of each, rather than a line for each dependent in the order they compiled.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which this test starts.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The project under `tmp`: `a.tl` refused for a return of the wrong type, `b.tl` requiring it, and `b_test.tl`
--- requiring `b`.
local function project(tmp: string): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/a.tl", 'local record a\nend\nfunction a.f(): integer\n  return "x"\nend\nreturn a\n'))
  assert(Fs.write(root .. "/b.tl",
    'local a = require("a")\nlocal record b\nend\nfunction b.g(): integer\n  return a.f()\nend\nreturn b\n'))
  assert(Fs.write(root .. "/b_test.tl",
    'local b = require("b")\nlocal function test_g()\n  assert(b.g() == 1)\nend\n'))
  return root
end

--- Runs the program with `args` in `root`, unsandboxed (a sandbox nested in this test's own may be refused where the
--- host nests only two deep), and answers what it said on stdout and stderr together.
local function ran(root: string, tmp: string, args: {string}): Child.Result, string
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["TMPDIR"] = tmp
  local started = this_program.program(args, {
    cwd = root, env = env, stdout = "capture", stderr = "stdout", process_group = true, timeout_ns = Clock.seconds(120),
  })
  local result, trouble = Child.run(started.argv, started.options)
  local done = assert(result, trouble)
  return done, done.stdout or ""
end

--- Raises unless `text` holds each of `words`, each after the one before, naming the first it lacks.
local function in_order(text: string, words: {string})
  local at = 1
  for _, word in ipairs(words) do
    local found = text:find(word, at, true)
    assert(found ~= nil, word .. " is not in order in: " .. text)
    at = found + #word
  end
end

local function test_fix_shows_the_refusal_first_and_its_dependents_in_one_line(tmp: string)
  local root = project(tmp)
  local result, text = ran(root, tmp, { "fix", "b.tl" })
  assert(not result.ok, text)
  in_order(text, { "a.tl:4:10:", "not compiled, since each requires a refused module, directly or through another: b.tl, b_test.tl",
    "1 file refused on its own, 2 not compiled because they require one", "fix: " })
  assert(not text:find("b.tl: not compiled: it requires a", 1, true), text)
end

local function test_a_whole_test_run_counts_the_files_refused_and_those_that_require_one(tmp: string)
  local root = project(tmp)
  local result, text = ran(root, tmp, { "test" })
  assert(result.code == 4, text)
  in_order(text, { "test: FAIL  a.tl: the compiler refused it", "a.tl:4:10:",
    "test: FAIL  not compiled, since each requires a refused module, directly or through another: b.tl, b_test.tl",
    "test: 1 file refused on its own, 2 not compiled because they require one", "test: 3 of 3 tests failed" })
  assert(not text:find("b_test.tl: not compiled: it requires b", 1, true), text)
end

--- The project under `tmp`: `a.tl`, `b.tl` requiring it and `c.tl` requiring `b`, each with one finding of its own in the
--- body of a function, and `d.tl`, which requires `a` and has none.
local function chain(tmp: string): string
  local root = tmp .. "/chain"
  assert(Fs.mkdirs(root))
  local function module(name: string, head: string, calls: string): string
    return head .. "local record " .. name .. "\nend\nfunction " .. name .. ".f(n: integer): integer\n  local x = n or 4\n" ..
      "  return " .. calls .. "\nend\nreturn " .. name .. "\n"
  end
  assert(Fs.write(root .. "/a.tl", module("A", "", "x")))
  assert(Fs.write(root .. "/b.tl", module("B", 'local A = require("a")\n', "A.f(x)")))
  assert(Fs.write(root .. "/c.tl", module("C", 'local B = require("b")\n', "B.f(x)")))
  assert(Fs.write(root .. "/d.tl",
    'local A = require("a")\nlocal record D\nend\nfunction D.f(n: integer): integer\n  return A.f(n)\nend\nreturn D\n'))
  return root
end

--- A chain of modules with a finding each is told whole in one run of `fix` and of `test`: a run that told only the first
--- would take one round of edits for each module of the chain.
local function test_one_run_tells_the_findings_of_a_chain_of_modules_that_require_one_another(tmp: string)
  local root = chain(tmp)
  for _, verb in ipairs({ "fix", "test" }) do
    local result, text = ran(root, tmp, { verb })
    assert(not result.ok, text)
    in_order(text, { "a.tl:4:13:", "(condition_type)", "b.tl:5:13:", "(condition_type)", "c.tl:5:13:", "(condition_type)",
      "not compiled, since each requires a refused module, directly or through another: d.tl; it was checked all the same, " ..
        "and has no finding of its own",
      "3 files refused on their own, 1 not compiled because it requires one" })
  end
end
