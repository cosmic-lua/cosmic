--- .github/scripts/branch-scope.sh, which ci.yml's `scope` job runs to
--- decide whether a branch push runs the merge queue's scope (`full`)
--- or the light one, and the list it reads, .github/scripts/branch-scope.txt.
--- What is held: the list names what a light run leaves unproved (the
--- failures that reached the merge queue alone: a driver the pin does
--- not outrun, a core, vendor or build input, the harness's epoch) and
--- what ci.yml's caches hash of them, so the two cannot drift; a change
--- to docs, or to a test no list names, runs light; and the script's
--- answer is `full` wherever it cannot tell.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Test = require("cosmic.test")

--- The script and its list, the actions whose hashes the list is held to
--- (ci.yml's own hashes, in the driver check's key, are read from it),
--- and the exact files the list names, which must exist.
Test.policy{
  profiles = { "system" },
  grants = {
    { path = ".github/", letters = "r" },
    { path = "/bin/sh", letters = "r" },
    { path = "ci/cosmic_ci/orchestration.tl", letters = "r" },
    { path = "build.zig", letters = "r" },
    { path = "build.zig.zon", letters = "r" },
    { path = "build/zig.tl", letters = "r" },
    { path = "build/harness_epoch.tl", letters = "r" },
    { path = "build/artifact.tl", letters = "r" },
    { path = "build/embed.tl", letters = "r" },
    { path = "build/boot.tl", letters = "r" },
    { path = "build/reboot.tl", letters = "r" },
    { path = "build/launcher.tl", letters = "r" },
    { path = "build/paths.tl", letters = "r" },
    { path = "build/host_names.tl", letters = "r" },
    { path = "build/host_requires.tl", letters = "r" },
    { path = "core/ares_config.h", letters = "r" },
    { path = "core/curl_config.h", letters = "r" },
    { path = "core/mbedtls_cosmic_config.h", letters = "r" },
  },
  env = { "PATH" },
  requires = { "path:/bin/sh", "program:jq" },
}

local SCRIPT <const> = ".github/scripts/branch-scope.sh"
local LIST <const> = ".github/scripts/branch-scope.txt"

--- Runs `branch-scope.sh match` on `files` (a path a line), answering
--- the line it printed, or "" where it exits 1: no path is one.
local function matched(tmp: string, files: {string}): string
  local input = tmp .. "/files"
  assert(Fs.write(input, table.concat(files, "\n") .. "\n"))
  local result = assert(Child.run({ "/bin/sh", "-c", 'exec /bin/sh "$0" match <"$1"', SCRIPT, input },
    { stdout = "capture", stderr = "capture" }))
  assert(result.code == 0 or result.code == 1, "match exits " .. tostring(result.code) .. ": " .. tostring(result.stderr))
  if result.code == 1 then return "" end
  local line = (result.stdout or ""):gsub("\n$", "")
  return line
end

--- A path the glob `pattern` of a hash (`**` any depth, `*` a name's
--- part) names.
local function sample(pattern: string): string
  return (pattern:gsub("%*%*", "x/y"):gsub("%*", "z"))
end

--- The quoted patterns of the `hashFiles(...)` in `text` that follows
--- `after`, in order.
local function hashed(text: string, after: string): {string}
  local from = assert(text:find(after, 1, true), "no " .. after)
  local arguments = assert(text:match("hashFiles%((.-)%)", from), "no hashFiles after " .. after)
  local out: {string} = {}
  for pattern in arguments:gmatch("'([^']+)'") do out[#out + 1] = pattern end
  assert(#out > 0, "no pattern after " .. after)
  return out
end

--- What the zig caches' keys hash (the `vendor` and `core` parts of the
--- action cache-names), and the driver check's key, are inputs to the
--- very builds and checks a light run leaves out; a change to one that
--- the list does not name would reach the queue alone. A pattern a hash
--- takes back (`!`) is one the list takes back too.
local function test_the_list_names_what_the_caches_and_the_driver_check_hash(tmp: string)
  local action = assert(Fs.read(".github/actions/cache-names/action.yml"))
  local ci = assert(Fs.read(".github/workflows/ci.yml"))
  local patterns: {string} = {}
  for _, part in ipairs({ "VENDOR:", "CORE:" }) do
    for _, pattern in ipairs(hashed(action, part)) do patterns[#patterns + 1] = pattern end
  end
  for _, pattern in ipairs(hashed(ci, 'key: "driver-checked-v2-${{ matrix.name }}-')) do
    -- The workflow's own file is the only one of .github/workflows the
    -- list names: another workflow is no input to a leg.
    patterns[#patterns + 1] = pattern
  end
  local count = 0
  for _, pattern in ipairs(patterns) do
    count = count + 1
    local negated = pattern:sub(1, 1) == "!"
    local path = sample(negated and pattern:sub(2) or pattern)
    local got = matched(tmp, { path })
    if negated then
      assert(got == "", pattern .. " is hashed apart from the zig build, and the list names " .. got)
    else
      assert(got ~= "", pattern .. " is hashed into a cache or the driver check's key, and the list names no " .. path)
    end
  end
  assert(count >= 20, "the caches' patterns were not read: " .. count)
end

--- The list's exact entries (those with no `*`) name files that exist,
--- so a rename cannot leave one that moves nothing; and its one harness
--- entry is the epoch file orchestration.tl's `harness_moved` compares.
local function test_the_lists_files_exist()
  local seen = 0
  local epoch = false
  for line in (assert(Fs.read(LIST))):gmatch("[^\n]+") do
    local entry = line:gsub("#.*$", ""):match("^%s*(%S+)")
    if entry ~= nil and not entry:find("*", 1, true) and entry:sub(1, 1) ~= "!" then
      seen = seen + 1
      local stat = Fs.stat(entry)
      assert(stat ~= nil and stat.kind == "file", LIST .. " names " .. entry .. ", which is no file")
      if entry == "build/harness_epoch.tl" then epoch = true end
    end
  end
  assert(seen >= 15, "too few files read: " .. seen)
  assert(epoch, "the list does not name the harness's epoch file")
  local orchestration = assert(Fs.read("ci/cosmic_ci/orchestration.tl"))
  assert(orchestration:find('local epoch_file <const> = "build/harness_epoch.tl"', 1, true),
    "orchestration.tl compares another file for the harness than the list names")
end

--- The escapes that began this: PR #3176 (a new test requirement name the
--- pinned driver did not know, in build/, ci/ and the epoch file) failed
--- in the queue's alpine leg alone. Each class of change that makes a
--- light run's narrowing unsound selects the full scope, and a change
--- that leaves what the legs run alone does not.
local function test_a_branch_push_runs_full_where_a_light_run_would_leave_the_change_unproved(tmp: string)
  local full: {{string}} = {
    { "ci/cosmic_ci/orchestration.tl" },
    { "ci/fixtures/format_test.tl" },
    { "ci/cosmic-driver.pin" },
    { "bin/zig.pin" },
    { ".github/workflows/ci.yml" },
    { ".github/scripts/leg-container.sh" },
    { ".github/actions/cosmic-driver/action.yml" },
    { "build.zig" },
    { "vendor/lua/lapi.c" },
    { "patch/zig-lib/0001.patch" },
    { "core/syscalls.c" },
    { "core/cosmic.h" },
    { "test/portable/probe.c" },
    { "build/harness_epoch.tl" },
    { "build/host_requires.tl" },
    { "build/embed.tl" },
    -- #3176's change, which a light run passed: build.zig, the
    -- artifact format, the epoch file and ci/ among its files.
    { "AGENTS.md", "build.zig", "build/artifact.tl", "build/boot.tl", "build/embed.tl",
      "build/harness_epoch.tl", "build/host_requires.tl", "ci/cosmic_ci/orchestration.tl", "doc/testing.md" },
    -- A file moved out of a listed path is a change to it too (the
    -- script reads a rename's old name).
    { "README.md", "ci/old.tl" },
  }
  for _, files in ipairs(full) do
    assert(matched(tmp, files) ~= "", "a branch push of " .. table.concat(files, " ") .. " runs light")
  end
  local light: {{string}} = {
    { "doc/testing.md" },
    { "README.md", "AGENTS.md", "ci/README.md", "doc/guides/portable-runtime.md" },
    { "cosmic/fs.tl", "cosmic/fs_test.tl" },
    { "build/analyzer_test.tl", "build/docs.tl" },
    { "core/socket_test.tl" },
    { "vendor/tzdata/zoneinfo/UTC", "vendor/cacert/cacert.pem" },
    { "vendor/lua/README.md" },
    { ".github/workflows/prerelease.yml", ".github/PULL_REQUEST_TEMPLATE.md" },
  }
  for _, files in ipairs(light) do
    assert(matched(tmp, files) == "", "a branch push of " .. table.concat(files, " ") .. " runs full: " .. matched(tmp, files))
  end
  assert(matched(tmp, {}) == "", "a push of no file runs full")
  assert(matched(tmp, { "doc/a.md", "ci/cosmic_ci/driver.tl" }) == "ci/cosmic_ci/driver.tl ci/*",
    "the first path the list names, and the pattern that does, are the answer: " .. matched(tmp, { "doc/a.md", "ci/cosmic_ci/driver.tl" }))
end

--- Runs `branch-scope.sh decide` with a `gh` that answers `answer` (or
--- fails, where it is nil), answering the `scope`, `base` and the log's
--- line.
local function decided(tmp: string, answer: string | nil): string, string, string
  local bin = tmp .. "/bin"
  assert(Fs.mkdirs(bin))
  if answer ~= nil then
    assert(Fs.write(tmp .. "/compare.json", answer))
    assert(Fs.write(bin .. "/gh", '#!/bin/sh\n[ "$1 $2" = "api repos/o/r/compare/main...abc123" ] || exit 9\ncat "' ..
        tmp .. '/compare.json"\n', 0x1ed))
  else
    assert(Fs.write(bin .. "/gh", "#!/bin/sh\necho 'HTTP 502' >&2\nexit 1\n", 0x1ed))
  end
  local output = tmp .. "/output"
  assert(Fs.write(output, ""))
  local env = Env.all()
  env["PATH"] = bin .. ":" .. (env["PATH"] or "/usr/bin:/bin")
  env["GITHUB_OUTPUT"] = output
  local result = assert(Child.run({ "/bin/sh", SCRIPT, "decide", "o/r", "abc123" },
    { env = env, stdout = "capture", stderr = "capture" }))
  assert(result.ok, "decide fails the run: " .. tostring(result.stderr))
  local text = assert(Fs.read(output))
  local scope, base = text:match("^scope=(%S*)\nbase=(%S*)\n$")
  assert(scope ~= nil and base ~= nil, "decide wrote " .. text)
  local line = (result.stdout or ""):gsub("\n$", "")
  return scope, base, line
end

local BASE <const> = string.rep("a1", 20)

--- `scope` and `base` for the branch's change: `full` and the main
--- commit it grew from where the list names a file of it, else `light`
--- and no base; and `full` on the safe side wherever the script cannot
--- tell, a base it cannot name being `unknown`, which `harness_moved`
--- takes as moved.
local function test_the_scope_job_answers_full_wherever_it_cannot_tell(tmp: string)
  local function compare(files: {{string: string}}, base: string | nil): string
    local merge: {string: any} = {}
    if base ~= nil then merge["sha"] = base end
    return (assert(Json.encode({ merge_base_commit = merge, files = files })))
  end
  local scope, base, said = decided(tmp .. "/1", compare({ { filename = "doc/a.md" }, { filename = "ci/x.tl" } }, BASE))
  assert(scope == "full" and base == BASE, "a change to ci/: " .. scope .. " " .. base)
  assert(said:find("ci/x.tl ci/*", 1, true), "the log names the path and pattern: " .. said)
  scope, base = decided(tmp .. "/2", compare({ { filename = "doc/a.md" }, { filename = "cosmic/x.tl" } }, BASE))
  assert(scope == "light" and base == "", "a change to nothing the list names: " .. scope .. " " .. base)
  scope = decided(tmp .. "/3", compare({ { filename = "ci/new.tl", previous_filename = "cosmic/old.tl" } }, BASE))
  assert(scope == "full", "a file moved into a listed path")
  scope = decided(tmp .. "/4", compare({ { filename = "cosmic/new.tl", previous_filename = "core/old.c" } }, BASE))
  assert(scope == "full", "a file moved out of a listed path")
  scope, base = decided(tmp .. "/5", nil)
  assert(scope == "full" and base == "unknown", "a compare that fails: " .. scope .. " " .. base)
  scope, base = decided(tmp .. "/6", "not json")
  assert(scope == "full" and base == "unknown", "an answer that is no JSON: " .. scope .. " " .. base)
  local many: {{string: string}} = {}
  for i = 1, 300 do many[i] = { filename = "doc/" .. i .. ".md" } end
  scope, base = decided(tmp .. "/7", compare(many, BASE))
  assert(scope == "full" and base == BASE, "300 files, which GitHub stops listing at: " .. scope)
  scope, base = decided(tmp .. "/8", compare({ { filename = "ci/x.tl" } }, nil))
  assert(scope == "full" and base == "unknown", "a change with no merge base named: " .. scope .. " " .. base)
end
