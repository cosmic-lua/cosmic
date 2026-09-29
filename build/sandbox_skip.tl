--- How a test of the sandbox says the host refused it the sandbox it is
--- about (`Test.skip`), and when it says nothing: where the platform
--- has no such sandbox at all -- anything but Linux, which alone has
--- user namespaces, Landlock and a subreaper -- there is nothing to
--- check, the kernel part of every key pins the platform, and the test
--- returns silently, a pass that may stand. On Linux a refusal is this
--- host's (root, which nests a sandbox only two deep; a container's
--- seccomp profile; user namespaces turned off), so the test is
--- skipped, which a run held to sandboxing fails.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")

local record sandbox_skip
end

--- The platform's name (`uname`'s sysname), or why none could be had.
local function platform(): string | nil, string
  local names, trouble = sys.uname()
  if names == nil then return nil, trouble end
  return names.sysname, ""
end

--- Says the running test is skipped for `why`, cut to its first line,
--- where the platform could have given the sandbox this host refused;
--- elsewhere, nothing.
function sandbox_skip.refused(why: string)
  -- A platform that cannot be named is taken for one that could
  -- sandbox: a skip, never a silent pass.
  local name, _ = platform()
  if name ~= nil and name ~= "Linux" then return end
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
