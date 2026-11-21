--- The launcher `cosmic release --launcher` writes, run in a project of
--- its own whose release, and whose `curl`, are shell stand-ins: what is
--- held is the script's own part. Nothing downloaded runs or is cached
--- unless its sha256 is the pin's, the release runs where the launcher
--- was called with its arguments and exit status, and `COSMIC_TOOL` runs
--- another cosmic or is refused, never passed over for the pin's.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Test = require("cosmic.test")
local pinned_launcher = require("build.pinned_launcher")

--- The host's programs the script and the stand-ins call, each granted
--- where a host has it, under /bin or /usr/bin.
Test.policy{
  grants = {
    { path = "/bin/sh", letters = "r" }, { path = "/usr/bin/sh", letters = "r" },
    { path = "/bin/dirname", letters = "r" }, { path = "/usr/bin/dirname", letters = "r" },
    { path = "/bin/sed", letters = "r" }, { path = "/usr/bin/sed", letters = "r" },
    { path = "/bin/wc", letters = "r" }, { path = "/usr/bin/wc", letters = "r" },
    { path = "/bin/tr", letters = "r" }, { path = "/usr/bin/tr", letters = "r" },
    { path = "/bin/cut", letters = "r" }, { path = "/usr/bin/cut", letters = "r" },
    { path = "/bin/sha256sum", letters = "r" }, { path = "/usr/bin/sha256sum", letters = "r" },
    { path = "/bin/shasum", letters = "r" }, { path = "/usr/bin/shasum", letters = "r" },
    { path = "/bin/mkdir", letters = "r" }, { path = "/usr/bin/mkdir", letters = "r" },
    { path = "/bin/rm", letters = "r" }, { path = "/usr/bin/rm", letters = "r" },
    { path = "/bin/mv", letters = "r" }, { path = "/usr/bin/mv", letters = "r" },
    { path = "/bin/cp", letters = "r" }, { path = "/usr/bin/cp", letters = "r" },
    { path = "/bin/chmod", letters = "r" }, { path = "/usr/bin/chmod", letters = "r" },
    { path = "/bin/sleep", letters = "r" }, { path = "/usr/bin/sleep", letters = "r" },
    { path = "/bin/touch", letters = "r" }, { path = "/usr/bin/touch", letters = "r" },
  },
  env = { "PATH" },
  requires = { "path:/bin/sh" },
}

--- A release that says where it ran, with what words and under which
--- `COSMIC_TOOL`, and exits with `TOOL_STATUS`.
local release_source = [[#!/bin/sh
printf 'release in %s:' "$(pwd -P)"
for word in "$@"; do printf ' [%s]' "$word"; done
printf ' tool=%s\n' "${COSMIC_TOOL-unset}"
exit "${TOOL_STATUS:-0}"
]]

--- Bytes that are not the pin's: run, they leave the file `$RAN_OTHER`.
local other_source = [[#!/bin/sh
touch "$RAN_OTHER"
]]

local commit = string.rep("a", 40)

--- The three pin lines for `commit`'s release, whose binary is `digest`.
local function pin_text(digest: string): string
  return commit .. "\nhttps://github.com/cosmic-lua/cosmic/releases/download/next-" .. commit ..
    "/cosmic\n" .. digest .. "\n"
end

--- What a test runs the launcher in.
local record Project
  --- The physical path of the test's directory, as `pwd -P` prints it.
  tmp: string
  --- The launcher, `<tmp>/a project/bin/<name>`: a space in its path, so
  --- a word split anywhere shows.
  launcher: string
  --- The release the pin names, which the stand-in `curl` serves.
  release: string
  --- The sha256 of `release`.
  digest: string
  --- Where the launcher caches `release`.
  cached: string
  --- The file the stand-in `curl` adds a line to at each call.
  calls: string
end

--- A project under `tmp` with the launcher as `bin/<name>`, the pin of a
--- stand-in release beside it, and a `curl` on a PATH of its own that
--- writes `$DOWNLOAD_SOURCE` wherever it is asked to, whatever the URL.
--- Where `$WRONG_ONCE` names a file that is there, that `curl` removes
--- the file and writes the other bytes, succeeding, as a transfer cut
--- short without an error would.
local function project(tmp: string, name?: string): Project
  local at = assert(Fs.absolute(tmp))
  local bin = at .. "/a project/bin"
  local called = name or "cosmic"
  assert(Fs.mkdirs(bin) and Fs.mkdirs(at .. "/fake bin") and Fs.mkdirs(at .. "/elsewhere"))
  assert(Fs.write(bin .. "/" .. called, (assert(pinned_launcher.script(called))), 0x1ed))
  local digest = Hash.hex_sha256(release_source)
  assert(Fs.write(bin .. "/" .. called .. ".pin", pin_text(digest)))
  assert(Fs.write(at .. "/release", release_source, 0x1ed))
  assert(Fs.write(at .. "/other", other_source, 0x1ed))
  assert(Fs.write(at .. "/fake bin/curl", [[#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output=$2; shift 2; else shift; fi
done
echo call >> "$CALLS"
if [ -n "${WRONG_ONCE:-}" ] && [ -e "$WRONG_ONCE" ]; then
  rm -f "$WRONG_ONCE"
  cp "$OTHER_SOURCE" "$output"
  exit 0
fi
cp "$DOWNLOAD_SOURCE" "$output"
]], 0x1ed))
  return { tmp = at, launcher = bin .. "/" .. called, release = at .. "/release", digest = digest,
    cached = at .. "/xdg/cosmic/bootstrap/cosmic-" .. digest, calls = at .. "/calls" }
end

--- Runs the launcher with `args` in `cwd`, with `extra` in its environment.
local function run(p: Project, cwd: string, args: {string}, extra?: {string:string}): Child.Result
  local env: mut {string:string} = {
    PATH = p.tmp .. "/fake bin:" .. assert(Env.get("PATH")), XDG_CACHE_HOME = p.tmp .. "/xdg",
    CALLS = p.calls, DOWNLOAD_SOURCE = p.release, OTHER_SOURCE = p.tmp .. "/other",
    RAN_OTHER = p.tmp .. "/ran other",
  }
  for name, value in pairs(extra or {}) do env[name] = value end
  local argv = { p.launcher }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, { cwd = cwd, env = env, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(20) })
  return (assert(result, trouble))
end

--- How many times the stand-in `curl` was called.
local function downloads(p: Project): integer
  local _, count = (Fs.read(p.calls) or ""):gsub("call\n", "")
  return count
end

--- The names in the launcher's cache, sorted, a partial file's among them.
local function cache_names(p: Project): string
  local names: mut {string} = {}
  for _, name in ipairs(Fs.list(p.tmp .. "/xdg/cosmic/bootstrap") or {}) do
    names[#names + 1] = name
  end
  table.sort(names)
  return table.concat(names, " ")
end

--- A cold run downloads the release, caches it by its digest and runs it
--- in the caller's directory with the arguments as given, answering its
--- exit status; a warm run downloads nothing.
local function test_it_fetches_once_then_runs_the_release_where_it_was_called(tmp: string)
  local p = project(tmp)
  local cwd = p.tmp .. "/elsewhere"
  local result = run(p, cwd, { "fix", "two words", "" }, { TOOL_STATUS = "7" })
  assert(result.code == 7, tostring(result.stderr))
  assert(result.stdout == "release in " .. cwd .. ": [fix] [two words] [] tool=unset\n", tostring(result.stdout))
  assert(downloads(p) == 1 and cache_names(p) == "cosmic-" .. p.digest, cache_names(p))
  local again = run(p, p.tmp, { "test" })
  assert(again.code == 0 and again.stdout == "release in " .. p.tmp .. ": [test] tool=unset\n",
    tostring(again.stdout) .. tostring(again.stderr))
  assert(again.stderr == "", tostring(again.stderr))
  assert(downloads(p) == 1, "a warm run downloaded")
end

--- The pin a launcher reads is the one named after it, so two launchers
--- in one directory keep a pin each.
local function test_a_launcher_reads_the_pin_named_after_it(tmp: string)
  local p = project(tmp, "cosmic-next")
  assert(Fs.exists(p.launcher .. ".pin") == true)
  local result = run(p, p.tmp, { "test" })
  assert(result.code == 0 and result.stdout == "release in " .. p.tmp .. ": [test] tool=unset\n",
    tostring(result.stdout) .. tostring(result.stderr))
  assert(Fs.remove(p.launcher .. ".pin"))
  local without = run(p, p.tmp, { "test" })
  assert(without.code == 1 and without.stdout == "", tostring(without.stdout))
  assert(tostring(without.stderr):find("no pin at " .. p.launcher .. ".pin", 1, true), tostring(without.stderr))
end

--- A download whose sha256 is not the pin's is not run, not cached and
--- leaves no partial file, however the transfer ended.
local function test_a_download_that_is_not_the_pin_s_never_runs(tmp: string)
  local p = project(tmp)
  local result = run(p, p.tmp, { "test" }, { DOWNLOAD_SOURCE = p.tmp .. "/other", COSMIC_TOOL_ATTEMPTS = "1" })
  assert(result.code == 1 and result.stdout == "", tostring(result.stdout) .. tostring(result.stderr))
  assert(tostring(result.stderr):find("the pin says " .. p.digest, 1, true), tostring(result.stderr))
  assert(Fs.exists(p.tmp .. "/ran other") == false, "bytes that are not the pin's were run")
  assert(cache_names(p) == "", cache_names(p))
end

--- A transfer that ends early without an error is tried again, and the
--- release that then arrives whole runs.
local function test_a_download_of_other_bytes_is_tried_again(tmp: string)
  local p = project(tmp)
  assert(Fs.write(p.tmp .. "/wrong once", ""))
  local result = run(p, p.tmp, { "test" }, { WRONG_ONCE = p.tmp .. "/wrong once" })
  assert(result.code == 0 and result.stdout == "release in " .. p.tmp .. ": [test] tool=unset\n",
    tostring(result.stdout) .. tostring(result.stderr))
  assert(tostring(result.stderr):find("retrying in 2s", 1, true), tostring(result.stderr))
  assert(downloads(p) == 2 and cache_names(p) == "cosmic-" .. p.digest, cache_names(p))
  assert(Fs.exists(p.tmp .. "/ran other") == false, "bytes that are not the pin's were run")
end

--- A pin that is not a commit, the release of that commit in
--- cosmic-lua/cosmic and a sha256, a line each, is refused before
--- anything is downloaded.
local function test_a_pin_of_another_shape_is_refused(tmp: string)
  local p = project(tmp)
  local good = pin_text(p.digest)
  local url = "https://github.com/cosmic-lua/cosmic/releases/download/next-" .. commit .. "/cosmic"
  local refused: {string} = {
    "",
    good .. "\n",
    commit .. "\n" .. url .. "\n",
    commit:sub(1, 39) .. "\n" .. url .. "\n" .. p.digest .. "\n",
    commit:upper() .. "\n" .. url .. "\n" .. p.digest .. "\n",
    commit .. "\n" .. url .. "\n" .. p.digest:sub(1, 63) .. "\n",
    commit .. "\n" .. url .. "\n" .. p.digest:sub(1, 63) .. "g\n",
    commit .. "\nhttps://github.com/someone/cosmic/releases/download/next-" .. commit .. "/cosmic\n" ..
      p.digest .. "\n",
    commit .. "\nhttps://github.com/cosmic-lua/cosmic/releases/download/next-" .. string.rep("b", 40) ..
      "/cosmic\n" .. p.digest .. "\n",
    commit .. "\nhttp://github.com/cosmic-lua/cosmic/releases/download/next-" .. commit .. "/cosmic\n" ..
      p.digest .. "\n",
    commit .. "\n" .. url .. "/../other\n" .. p.digest .. "\n",
  }
  for at, text in ipairs(refused) do
    assert(Fs.write(p.launcher .. ".pin", text))
    local result = run(p, p.tmp, { "test" })
    assert(result.code == 1 and result.stdout == "",
      "pin " .. tostring(at) .. " was taken: " .. tostring(result.stdout))
    assert(tostring(result.stderr):find(p.launcher .. ".pin", 1, true), tostring(result.stderr))
  end
  assert(downloads(p) == 0, "a refused pin reached a download")
  assert(Fs.write(p.launcher .. ".pin", (good:gsub("next%-", "20261018-"))))
  local dated = run(p, p.tmp, { "test" })
  assert(dated.code == 0, tostring(dated.stderr))
end

--- `COSMIC_TOOL` names the cosmic that runs in place of the pin's:
--- nothing is downloaded, and a relative name reaches the cosmic as an
--- absolute path, for the launchers it starts from other directories.
local function test_cosmic_tool_runs_in_place_of_the_pin_s(tmp: string)
  local p = project(tmp)
  local standin = p.tmp .. "/elsewhere/built cosmic"
  assert(Fs.write(standin, release_source, 0x1ed))
  local result = run(p, p.tmp, { "test", "x y" }, { COSMIC_TOOL = "elsewhere/built cosmic", TOOL_STATUS = "3" })
  assert(result.code == 3, tostring(result.stderr))
  assert(result.stdout == "release in " .. p.tmp .. ": [test] [x y] tool=" .. standin .. "\n",
    tostring(result.stdout))
  assert(downloads(p) == 0 and cache_names(p) == "", "a stand-in run fetched the pin's")
end

--- A `COSMIC_TOOL` that cannot run is an error, never a reason to run the
--- pin's: a name that is no executable file, the launcher itself, which
--- would start itself without end, and any name beside
--- `COSMIC_TOOL_VERIFY`, which asks for a digest-checked cosmic.
local function test_cosmic_tool_that_cannot_stand_in_is_refused(tmp: string)
  local p = project(tmp)
  -- The pin's release is cached, so a fall back to it would run and exit 0.
  assert(run(p, p.tmp, { "test" }).code == 0)
  assert(Fs.write(p.tmp .. "/plain file", release_source, 0x1a4))
  assert(Fs.write(p.tmp .. "/standin", release_source, 0x1ed))
  local link = p.tmp .. "/link to the launcher"
  assert(Fs.symlink(p.launcher, link))
  local cases: {{string}} = {
    { p.tmp .. "/missing", "", "is not an executable file" },
    { p.tmp .. "/plain file", "", "is not an executable file" },
    { p.tmp .. "/elsewhere", "", "is not an executable file" },
    { p.launcher, "", "is this launcher" },
    { link, "", "is this launcher" },
    { p.tmp .. "/standin", "1", "COSMIC_TOOL and COSMIC_TOOL_VERIFY are both set" },
  }
  for _, case in ipairs(cases) do
    local tool, verify, why = assert(case[1]), assert(case[2]), assert(case[3])
    local result = run(p, p.tmp, { "test" }, { COSMIC_TOOL = tool, COSMIC_TOOL_VERIFY = verify })
    assert(result.code == 1 and result.stdout == "", tool .. " ran: " .. tostring(result.stdout))
    assert(tostring(result.stderr):find(why, 1, true), tostring(result.stderr))
  end
end

--- `COSMIC_TOOL_VERIFY` checks a cache the launcher did not fill: a file
--- there whose sha256 is not the pin's, or a link, is removed and the
--- release fetched afresh, and what a link named is left as it was.
local function test_verify_replaces_a_cached_file_that_is_not_the_pin_s(tmp: string)
  local p = project(tmp)
  assert(Fs.mkdirs(Fs.dirname(p.cached)))
  assert(Fs.write(p.cached, other_source, 0x1ed))
  local result = run(p, p.tmp, { "test" }, { COSMIC_TOOL_VERIFY = "1" })
  assert(result.code == 0 and result.stdout == "release in " .. p.tmp .. ": [test] tool=unset\n",
    tostring(result.stdout) .. tostring(result.stderr))
  assert(Fs.exists(p.tmp .. "/ran other") == false, "a cached file that is not the pin's was run")
  assert(downloads(p) == 1 and assert(Fs.read(p.cached)) == release_source)
  assert(Fs.remove(p.cached))
  assert(Fs.symlink(p.tmp .. "/other", p.cached))
  local linked = run(p, p.tmp, { "test" }, { COSMIC_TOOL_VERIFY = "1" })
  assert(linked.code == 0, tostring(linked.stderr))
  assert(Fs.exists(p.tmp .. "/ran other") == false, "what a cached link named was run")
  assert(downloads(p) == 2 and assert(Fs.read(p.tmp .. "/other")) == other_source)
  assert(assert(Fs.read(p.cached)) == release_source)
  local kept = run(p, p.tmp, { "test" }, { COSMIC_TOOL_VERIFY = "1" })
  assert(kept.code == 0 and downloads(p) == 2, "a cached file that is the pin's was fetched again")
end

--- A cached file that cannot run, as a run cut off before its chmod
--- leaves it, is fetched again, and a directory at its name is refused
--- with nothing downloaded into it.
local function test_a_cached_file_that_cannot_run_is_fetched_again(tmp: string)
  local p = project(tmp)
  assert(Fs.mkdirs(Fs.dirname(p.cached)))
  assert(Fs.write(p.cached, release_source, 0x1a4))
  local result = run(p, p.tmp, { "test" })
  assert(result.code == 0 and downloads(p) == 1, tostring(result.stderr))
  assert(Fs.remove(p.cached))
  assert(Fs.mkdirs(p.cached))
  local refused = run(p, p.tmp, { "test" })
  assert(refused.code == 1 and refused.stdout == "", tostring(refused.stdout))
  assert(tostring(refused.stderr):find("is a directory", 1, true), tostring(refused.stderr))
  assert(downloads(p) == 1 and #assert(Fs.list(p.cached)) == 0, "a download landed in the directory")
end

--- The launcher's name is written into the script, so a name a shell
--- would read as more than a word is refused.
local function test_a_name_a_shell_would_read_is_refused()
  for _, name in ipairs({ "", ".", "..", "a b", "-x", "a/b", "$x", "a'b", "a\"b", "a\nb", "a;b", "a@b" }) do
    local text, why = pinned_launcher.script(name)
    assert(text == nil and why ~= "", name .. " was taken")
  end
  for _, name in ipairs({ "cosmic", "cosmic-next", "cosmic_1.sh", ".cosmic" }) do
    local text = assert(pinned_launcher.script(name))
    assert(text:sub(1, 10) == "#!/bin/sh\n", name)
    assert(text:find("pin=$here/" .. name .. ".pin\n", 1, true), name)
    assert(text:find("@NAME@", 1, true) == nil, name)
  end
end
