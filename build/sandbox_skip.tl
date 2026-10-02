--- How a test says ([`Test.skip`]) the host refused it what only Linux
--- gives -- the sandbox it is about, or a device every Linux worker is
--- given (build.confine's `runtime_paths`: /dev/full) -- and when it
--- says nothing: where the platform has no such thing at all
--- ([`confine.sandbox_platform`]) -- anything but Linux, which alone has
--- user namespaces, Landlock, a subreaper and /dev/full -- there is
--- nothing to check, the kernel part of every key
--- pins the platform, and the test returns silently, a pass that may
--- stand. On Linux a refusal is this host's (root, which nests a sandbox
--- only two deep; a container's seccomp profile; user namespaces turned
--- off; a sandbox that gave no /dev/full), so the test is skipped, which
--- a run held to sandboxing fails.

local confine = require("build.confine")
local Test = require("cosmic.test")

local record sandbox_skip
end

--- Says the running test is skipped for `why`, cut to its first line,
--- where the platform could have given the sandbox this host refused;
--- elsewhere, nothing.
function sandbox_skip.refused(why: string)
  if not confine.sandbox_platform() then return end
  local line = why:match("^[^\n]*")
  Test.skip(line ~= "" and line or "the host refused the sandbox")
end

--- Says the running test is skipped as `refused` does, for a run of
--- `cosmic test` it started that printed `text` and sandboxed no
--- worker: the line of `text` that says why.
function sandbox_skip.nested(text: string)
  local why = text:match("no worker can be sandboxed here[^\n(]*[^\n( ]") or
    text:match("[^\n]*unsandboxed[^\n]*") or text
  sandbox_skip.refused("the run it started sandboxed no worker: " .. why)
end

return sandbox_skip
