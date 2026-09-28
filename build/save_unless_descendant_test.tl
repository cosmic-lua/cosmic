--- .github/scripts/save-unless-descendant.sh, which says whether a push
--- to main saves one of ci.yml's caches from the key of the newest
--- entry a lookup found. The cases here need no git: an empty key (no
--- entry, or a lookup that failed), a key saved before keys named a
--- commit, and one saved from this very commit are answered from the
--- key alone. The fetch and the ancestry test need a remote, which a
--- test has not.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The script under test, and the system's `sh` and tools, which run it.
Test.needs{ reads = { ".github/scripts/save-unless-descendant.sh" }, system = true }

-- By its whole path: a process the test starts elsewhere finds it.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/save-unless-descendant.sh"))

local SHA <const> = "2896be7f0c3b1a2e9d8f7a6b5c4d3e2f1a0b9c8d"
local PREFIX <const> = "verdicts-linux-x86_64-0123456789abcdef-fedcba9876543210-"

--- What the script writes to $GITHUB_OUTPUT for `key`, run for this
--- commit, `SHA`, from a directory that is no repository; and what it
--- says on standard output.
local function answer(key: string): string, string
  local dir = assert(Fs.mkdtemp("cosmic-save-unless-descendant-test-"))
  local env: {string:string} = { PATH = Env.get("PATH") or "/usr/bin:/bin",
    GITHUB_SHA = SHA, GITHUB_OUTPUT = dir .. "/output" }
  local result = assert(Child.run({ "/bin/sh", SCRIPT, key },
    { env = env, cwd = dir, stdout = "capture", stderr = "capture", timeout_ms = 30000 }))
  assert(result.ok, (result.stdout or "") .. (result.stderr or ""))
  local output = Fs.read(dir .. "/output") or ""
  assert(Fs.remove_tree(dir))
  return output, result.stdout or ""
end

--- No entry, or a lookup that failed, which leave the key empty alike:
--- nothing newer stands in the way.
local function test_an_empty_key_saves()
  local output, said = answer("")
  assert(output == "save=true\n", output)
  assert(said:find("lookup failed", 1, true) ~= nil, said)
end

--- A key saved before keys named a commit ends in the run and attempt
--- alone: the script cannot tell, and says so.
local function test_a_key_that_names_no_commit_is_unknown()
  for _, key in ipairs({ PREFIX .. "36358036690-1", "compiles-linux-x86_64-36358036690-2",
      PREFIX .. SHA:sub(1, 39) .. "-1-1", PREFIX .. SHA:upper() .. "-1-1" }) do
    local output = answer(key)
    assert(output == "save=unknown\n", key .. ": " .. output)
  end
end

--- An entry saved from this commit (an earlier attempt of its run)
--- is no newer: the script saves without asking git.
local function test_an_entry_of_this_commit_saves()
  for _, key in ipairs({ PREFIX .. SHA .. "-36358036690-2",
      "compiles-linux-x86_64-" .. SHA .. "-36358036690-1" }) do
    local output = answer(key)
    assert(output == "save=true\n", key .. ": " .. output)
  end
end
