--- What `spawn`'s sandbox (core/process.h's `Sandbox`) can hold a
--- child to on this host, part by part: a trivial child is started
--- under each part alone and under all of them, and each says whether
--- it held, or the errno it was refused with. CI's Linux legs run it
--- (cosmic_ci/orchestration.tl's `sandbox` phase) to say whether their
--- containers can confine a test at all.
---
---     cosmic build/sandbox_probe.tl
---
--- It prints a Markdown report, and exits 0 whatever it found: what
--- the kernel refuses is the report, not a failure.
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")

local type Searcher = function(string): any, any

--- The raw process table, as the store's searcher hands it to
--- `cosmic.child`'s loader (core/syscalls_test.tl finds it the same
--- way): no module requires it by name but under boot.
local function raw_process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then return extra as raw_process end
  end
  error("cosmic.child is handed no raw table")
end

local process = raw_process_table()

local record SandboxProbe
  main: function({integer:string}): integer
  --- One part of the sandbox, as tried.
  record Part
    name: string
    --- whether a test's confinement (`observations.confine`) needs it
    needed: boolean
    held: boolean
    --- "held", or why not: an errno's name and message, or what the
    --- child said
    said: string
  end
  record Report
    parts: {Part}
    --- what of the host bears on it, each a name and what it says
    host: {{string}}
  end
end

--- The errnos a sandbox's setup is refused with, by name: what a
--- seccomp filter, a kernel without the feature, or a switch that turns
--- it off answers.
local errno_names: {integer:string} = {
  [sys.EPERM] = "EPERM", [sys.ENOSYS] = "ENOSYS", [sys.EACCES] = "EACCES",
  [sys.EINVAL] = "EINVAL", [sys.ENOSPC] = "ENOSPC", [sys.EOPNOTSUPP] = "EOPNOTSUPP",
  [sys.ENOENT] = "ENOENT", [sys.EAGAIN] = "EAGAIN",
}

--- The name of errno `number`, or its number where it is none of
--- `errno_names`.
function SandboxProbe.errno_name(number: integer): string
  return errno_names[number] or "errno " .. tostring(number)
end

--- The first line of `path`, trimmed, or "absent" where it cannot be
--- read.
local function first_line(path: string): string
  local text, _ = Fs.read(path)
  if text == nil then return "absent" end
  return ((text:match("^[^\n]*") or ""):gsub("[%s%z]+$", ""))
end

--- The value of the field `name` in /proc/self/status, or "absent".
local function status_field(status: string | nil, name: string): string
  if status == nil then return "absent" end
  local value = status:match("\n" .. name .. ":%s*([^\n]*)")
  if value == nil then return "absent" end
  return value
end

--- What of this host bears on whether it can confine a process: the
--- kernel, who this is, the filter and profile it already runs under,
--- and the switches that turn unprivileged user namespaces off.
local function host(): {{string}}
  local status, _ = Fs.read("/proc/self/status")
  if status ~= nil then status = "\n" .. status end
  return {
    { "kernel", first_line("/proc/sys/kernel/osrelease") },
    { "uid", tostring(sys.getuid()) },
    { "seccomp mode (0 none, 2 filter)", status_field(status, "Seccomp") },
    { "seccomp filters", status_field(status, "Seccomp_filters") },
    { "no_new_privs", status_field(status, "NoNewPrivs") },
    { "effective capabilities", status_field(status, "CapEff") },
    { "AppArmor label", first_line("/proc/self/attr/current") },
    { "user.max_user_namespaces", first_line("/proc/sys/user/max_user_namespaces") },
    { "kernel.unprivileged_userns_clone",
      first_line("/proc/sys/kernel/unprivileged_userns_clone") },
    { "kernel.apparmor_restrict_unprivileged_userns",
      first_line("/proc/sys/kernel/apparmor_restrict_unprivileged_userns") },
  }
end

--- The system's own paths a shell needs, each where this host has it.
local function system(): {string}
  local found: {string} = {}
  for _, path in ipairs({ "/bin", "/sbin", "/usr", "/lib", "/lib64", "/etc", "/proc",
                          "/dev/null" }) do
    local there, _ = sys.stat(path)
    if there ~= nil then found[#found + 1] = path end
  end
  return found
end

--- Starts `script` in /bin/sh under `sandbox`, in `tmp`, and says
--- whether it started and exited 0, and if not, why not.
local function tried(tmp: string, script: string, sandbox: raw_process.Sandbox): boolean, string
  local output, open_trouble = sys.open(tmp .. "/said", sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC,
    0x180)
  if output == nil then return false, open_trouble end
  local pid, trouble, errno = process.spawn("/bin/sh", { "sh", "-c", script }, nil, tmp, nil,
    output, output, false, nil, sandbox)
  local _, _ = sys.close(output)
  if pid == nil then return false, SandboxProbe.errno_name(errno) .. " (" .. trouble .. ")" end
  local status, wait_trouble = process.waitpid(pid, false)
  if status == nil then return false, "waitpid: " .. wait_trouble end
  if status.code == 0 then return true, "" end
  local said, _ = Fs.read(tmp .. "/said")
  local words = ((said or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
  local how = status.code >= 0 and "exited " .. tostring(status.code) or
    "killed by signal " .. tostring(status.signal)
  return false, how .. (words ~= "" and ": " .. words:sub(1, 200) or "")
end

--- Tries each part of the sandbox, and all of them together, in `tmp`,
--- a fresh directory of the caller's: a child held to a Landlock
--- ruleset, a pledge, no network, an unveiled filesystem, the last two
--- as `observations.confine` holds a test's processes, and all four.
function SandboxProbe.run(tmp: string): SandboxProbe.Report
  local root = assert(sys.realpath(tmp))
  local inside, outside = root .. "/in", root .. "/out"
  assert(sys.mkdir(inside, 0x1c0))
  assert(sys.mkdir(outside, 0x1c0))
  assert(Fs.write(inside .. "/f", "in\n"))
  assert(Fs.write(outside .. "/f", "out\n"))
  local reads = system()
  reads[#reads + 1] = inside
  -- What each child checks: it reads what it was given, and, where
  -- held, not what it was not; offline, it has no interface but lo.
  local reads_in = "cat " .. inside .. "/f >/dev/null"
  local no_out = "! cat " .. outside .. "/f 2>/dev/null"
  local unseen = "test ! -e " .. outside .. "/f"
  local lone_loopback = "test \"$(grep -c : /proc/self/net/dev)\" = 1"
  local parts: {SandboxProbe.Part} = {}
  local function add(name: string, needed: boolean, held: boolean, why: string)
    parts[#parts + 1] = { name = name, needed = needed, held = held,
      said = held and "held" or why }
  end

  -- /dev/null is written to, as a shell's redirections do.
  local ruleset, trouble, errno = process.landlock_ruleset(reads, { "/dev/null" })
  if ruleset == nil then
    add("landlock", false, false, SandboxProbe.errno_name(errno) .. " (" .. trouble .. ")")
  else
    local held, said = tried(root, reads_in .. " && " .. no_out, { ruleset = ruleset })
    add("landlock", false, held, said)
  end
  local held, said = tried(root, reads_in, { pledge = {} })
  add("pledge", false, held, said)
  held, said = tried(root, lone_loopback, { offline = true })
  add("offline", true, held, said)
  held, said = tried(root, reads_in .. " && " .. unseen,
    { unveil = { reads = reads, writes = {} } })
  add("unveil", true, held, said)
  held, said = tried(root, reads_in .. " && " .. unseen .. " && " .. lone_loopback,
    { unveil = { reads = reads, writes = {} }, offline = true })
  add("unveil + offline (a confined test)", true, held, said)
  if ruleset == nil then
    add("all four", false, false, "no landlock ruleset to hold it to")
  else
    held, said = tried(root, reads_in .. " && " .. unseen .. " && " .. lone_loopback,
      { ruleset = ruleset, unveil = { reads = reads, writes = {} }, offline = true,
        pledge = {} })
    add("all four", false, held, said)
    local _, _ = sys.close(ruleset)
  end
  return { parts = parts, host = host() }
end

--- Whether every part a confined test needs held, and, where one did
--- not, which.
function SandboxProbe.enforceable(report: SandboxProbe.Report): boolean, string
  local missing: {string} = {}
  for _, part in ipairs(report.parts) do
    if part.needed and not part.held then missing[#missing + 1] = part.name end
  end
  if #missing == 0 then return true, "" end
  return false, table.concat(missing, ", ")
end

--- A table cell of `text`: no pipe or line break in it.
local function cell(text: string): string
  return (text:gsub("|", "\\|"):gsub("[\r\n]", " "))
end

--- The report as Markdown: each part, what of the host bears on it, and
--- one line saying whether a test can be confined here.
function SandboxProbe.markdown(report: SandboxProbe.Report): string
  local lines: {string} = { "| Part | Needed to confine a test | Result |\n",
    "|---|---|---|\n" }
  for _, part in ipairs(report.parts) do
    lines[#lines + 1] = "| " .. cell(part.name) .. " | " .. (part.needed and "yes" or "no") ..
      " | " .. (part.held and "held" or "**failed**: " .. cell(part.said)) .. " |\n"
  end
  lines[#lines + 1] = "\n| Host | |\n|---|---|\n"
  for _, pair in ipairs(report.host) do
    lines[#lines + 1] = "| " .. cell(pair[1]) .. " | " .. cell(pair[2]) .. " |\n"
  end
  local ok, missing = SandboxProbe.enforceable(report)
  lines[#lines + 1] = ok and "\nConfinement: available.\n" or
    "\nConfinement: **unavailable** (" .. missing .. ").\n"
  return table.concat(lines)
end

--- Probes this host and prints the report; 0 whatever it found.
function SandboxProbe.main(_argv: {integer:string}): integer
  local names, _ = sys.uname()
  if names == nil or names.sysname ~= "Linux" then
    assert(Fs.put(Fs.stdout, "Confinement: not probed; the sandbox is Linux's alone.\n"))
    return 0
  end
  local tmp = assert(Fs.mkdtemp("sandbox-probe-"))
  local report: SandboxProbe.Report | nil = nil
  local called, trouble = pcall(function(): boolean
    report = SandboxProbe.run(tmp)
    return true
  end)
  local _, _ = Fs.remove_tree(tmp)
  if not called or report == nil then error(trouble, 0) end
  assert(Fs.put(Fs.stdout, SandboxProbe.markdown(report)))
  return 0
end

return SandboxProbe
