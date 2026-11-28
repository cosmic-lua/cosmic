--- The key of a run of `cosmic fix --check` over a tree ([`build.fix.verdict`]) changes with each thing the run reads:
--- a file's bytes, its mode, a new file, a link, the tool, the command line, the environment and what git answers. The
--- variables a shell sets for itself leave it as it was, and the keys kept come back.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Verdict = require("build.fix.verdict")

Test.policy{}

--- What a run reads where its command line, environment and git's answers are these.
local record Run
  mut argv: {string}
  environment: mut {string: string}
  mut git: string
end

--- A tree under `tmp` with two files, and a stand-in tool beside it: its root, the tool, and what a run reads.
local function tree(tmp: string): string, string, Run
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/src"))
  assert(Fs.write(root .. "/src/a.tl", "return 1\n"))
  assert(Fs.write(root .. "/README.md", "A tree.\n"))
  assert(Fs.mkdirs(root .. "/.git"))
  assert(Fs.write(root .. "/.git/HEAD", "ref: refs/heads/main\n"))
  assert(Fs.write(tmp .. "/tool", "tool bytes"))
  return root, tmp .. "/tool", { argv = { "fix", "--check", "." }, environment = { HOME = "/home/a", PWD = root },
    git = "base 0123" }
end

--- The key of a run at `root` with `tool`, reading `run`.
local function key(root: string, tool: string, run: Run): string
  local got, why = Verdict.key({ root = root, argv = run.argv, environment = run.environment, tool = tool, git = run.git })
  assert(got ~= nil, why)
  return got
end

local function test_each_input_changes_the_key(tmp: string)
  local root, tool, run = tree(tmp)
  local first = key(root, tool, run)
  assert(#first == 64)
  assert(key(root, tool, run) == first, "the same inputs give the same key")
  local seen: mut {string: string} = { [first] = "the first" }
  local function differs(what: string)
    local now = key(root, tool, run)
    assert(seen[now] == nil, what .. " gives the key " .. (seen[now] or "") .. " gave")
    seen[now] = what
  end
  assert(Fs.write(root .. "/src/a.tl", "return 2\n"))
  differs("a file's bytes")
  assert(Fs.chmod(root .. "/src/a.tl", 0x1ed))
  differs("a file's mode")
  assert(Fs.write(root .. "/src/b.tl", ""))
  differs("a new empty file")
  assert(Fs.mkdirs(root .. "/empty"))
  differs("a new empty directory")
  assert(Fs.symlink("src/a.tl", root .. "/link"))
  differs("a link")
  assert(Fs.write(tool, "other tool bytes"))
  differs("the tool")
  run.argv = { "fix", "--check" }
  differs("the command line")
  run.environment["COSMIC_CEILINGS_BASE"] = "abc"
  differs("a variable")
  run.git = "base 4567"
  differs("what git answers")
end

local function test_git_and_the_shells_own_variables_leave_the_key(tmp: string)
  local root, tool, run = tree(tmp)
  local first = key(root, tool, run)
  assert(Fs.write(root .. "/.git/HEAD", "ref: refs/heads/other\n"))
  run.environment["PWD"] = "/elsewhere"
  run.environment["OLDPWD"] = "/before"
  run.environment["SHLVL"] = "3"
  run.environment["COSMIC_FIX_VERDICT"] = "0"
  assert(key(root, tool, run) == first)
end

local function test_a_key_kept_is_held_and_the_oldest_drop(tmp: string)
  local path = tmp .. "/verdicts"
  local function hex(n: integer): string return string.format("%064x", n) end
  assert(not Verdict.held(path, hex(1)), "no file holds no key")
  for n = 1, 10 do
    local kept, why = Verdict.keep(path, hex(n))
    assert(kept, why)
  end
  assert(Verdict.held(path, hex(10)) and Verdict.held(path, hex(3)))
  assert(not Verdict.held(path, hex(2)) and not Verdict.held(path, hex(1)), "only the last 8 are kept")
  assert(Verdict.keep(path, hex(3)))
  assert(Verdict.keep(path, hex(11)))
  assert(Verdict.held(path, hex(3)), "a key kept again is the newest")
  assert(not Verdict.held(path, hex(4)))
end

local function test_only_zero_turns_it_off()
  assert(Verdict.off({ COSMIC_FIX_VERDICT = "0" }))
  assert(not Verdict.off({ COSMIC_FIX_VERDICT = "1" }) and not Verdict.off({}))
end
