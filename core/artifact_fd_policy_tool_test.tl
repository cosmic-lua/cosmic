--- A link swapped between the check that refuses the program's artifact
--- descriptor and the call that acts changes nothing under a policy
--- either (build/artifact_fd_fixture.tl): a `tool` test, as
--- core/artifact_fd_tool_test.tl's are, in a module of its own since the
--- policy's grants are held by Landlock (`requires`), which the other
--- tests there do not need.

local ArtifactFd = require("build.artifact_fd_fixture")
local searchable = require("build.searchable")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } },
  requires = { "landlock" } }

--- Under a promises filter, which fails openat2 with ENOSYS
--- (core/promises.c): the check holds without it, judging the walk it
--- makes part by part (`walk_without_descriptor_links`) rather than a
--- name resolved again after the call. "fattr" lets the chmod through.
local function test_a_link_swapped_after_the_check_changes_nothing_under_promises(tmp: string)
  local relaunch = ArtifactFd.relaunch_or_skip()
  -- A root runner's policy child is a user of its own, which owns none of
  -- these: the test's directory is opened to it. The core, in a cache
  -- of the host's, is not this test's to chmod.
  local core = sys.stat(ArtifactFd.program_of(relaunch))
  if sys.getuid() == 0 and (core == nil or core.mode & 5 ~= 5) then
    Test.skip("the core " .. ArtifactFd.program_of(relaunch) .. " is not open to the user a root runner's " ..
        "policy child runs as")
    return
  end
  searchable.share(searchable.open(tmp))
  ArtifactFd.swapped_link_changes_nothing(tmp, { promises = { "fattr" }, grants = {
    { path = ArtifactFd.program_of(relaunch), letters = "rx" }, { path = tmp, letters = "rwc" } } })
end
