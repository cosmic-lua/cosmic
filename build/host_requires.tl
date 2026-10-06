--- What a test may require of the host it runs on, as a closed table of
--- names, each with a probe, a class and the text a verdict key holds
--- while the requirement is met: the table [`Test.policy`]'s `requires`
--- names, which the build checks a declaration against (`check`) and the
--- runner asks of the host once a run, before any worker starts.
---
--- The names, how they are read and refused, and the rules a declaration
--- breaks are [`build.host_names`]'s, which reads nothing of the host; this
--- module probes each name:
---
--- - `sandbox`: this host can run a worker under a policy (the runner's
---   probe, [`build.test_sandbox_probe`]'s `available`, handed in as
---   [`host_requires.Context`]'s `sandbox`);
--- - `landlock` or `landlock:N`: Landlock, of ABI version N or later
---   ([`confine.landlock_abi`]);
--- - `userns`: the kernel's settings allow a user namespace (a sysctl a
---   container or a distribution turns off). What a seccomp filter or a
---   security module refuses beyond them shows in `sandbox` and `own_proc`;
--- - `nest`: a sandboxed process may build a sandbox of its own: `userns`,
---   and, for a root, CAP_SETUID, CAP_SETGID and CAP_SETFCAP to map the
---   user its child runs as ([`confine.may_map_ids`]). It needs no Landlock:
---   the `nest` promise is for a program no ruleset holds, and a ruleset
---   would refuse the mounts a root of its own is made of;
--- - `own_proc`: a sandbox gets a procfs of its own ([`confine.own_proc_given`]);
--- - `proc`: /proc is mounted;
--- - `portable`: this run is a portable artifact (`runtime_context`
---   "portable-v1", which the runner hands in as `portable`), not a native
---   start or a core with a database;
--- - `checked`: this core is the checked build (`checked`, which the runner
---   reads from [`cosmic.internal.testing`]'s `configuration`): another
---   core has none of the instruments such a test uses, so it is n/a there;
--- - `root`: the run's user is root;
--- - `path:<absolute path>`: a file or directory of the host;
--- - `program:<name>`: a program the PATH finds ([`Proc.find`]).
---
--- Every probe runs in the process that asks (the runner's), not in a
--- worker: `path:` and `program:` use its filesystem and its PATH, which a
--- sandboxed worker may not see the same, and `nest` and `userns` say what
--- that process may do, where a worker held by a Landlock ruleset and no
--- `nest` promise is refused the mounts a root of its own is made of.

--- A name's class ([`build.host_names`]) says what an absence means: where
--- a `platform` requirement is one the platform never has, the outcome is
--- `na`; otherwise `skipped`. Whether a platform has a requirement at all
--- is the platform's own answer ([`confine.sandbox_platform`], which is
--- Linux's), never a probe's.
---
--- A held run (`COSMIC_TEST_SANDBOX=1`, `COSMIC_SANDBOX=must`,
--- `COSMIC_CI_REQUIRE_SANDBOX=1`) fails a module for an absence only of a
--- requirement its leg promises (COSMIC_TEST_PROMISES, which ci/cosmic_ci/capabilities.tl
--- lists per leg and [`build.host_names`]'s `promised` reads): a test that
--- finds `jq` missing returned without a skip before, so failing each
--- `program:` or `path:` absence would fail hosts that never promised the
--- tool. What a held run holds beyond the promises is the sandbox, as it
--- always did.
-- TODO: add a `relaunch` name (a program that can start itself again, as
-- `Proc.relaunch() == nil` tests ask) once Proc.relaunch tells a native
-- start from a failure to reopen: both answer nil today, so a probe cannot
-- make the one n/a and raise on the other.
--- Each probe runs once per [`host_requires.Host`], in the process that
--- asks (the runner's, never a test's), and a probe that cannot tell raises
--- rather than answer present or absent, since a wrong "present" would run
--- a test that fails for the host and a wrong "absent" would pass one that
--- checked nothing.
---
--- It is a harness module (build/harness_epoch.tl): the runner reads it
--- before any worker starts and its answers are part of a verdict's key, so
--- it reaches the host through the raw bindings and the libraries `library`
--- names, and takes what it calls of them as locals when it loads.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local digest = require("build.digest")
local host_names = require("build.host_names")

local find_program, exists, is_dir = Proc.find, Fs.exists, Fs.is_dir
local relaunch, getuid, realpath = Proc.relaunch, sys.getuid, Fs.absolute
local sandbox_platform, may_map_ids = confine.sandbox_platform, confine.may_map_ids
local own_proc_given, landlock_abi = confine.own_proc_given, confine.landlock_abi
local hex_sha256 = digest.hex_sha256
local system_paths = confine.system_paths

local record host_requires
  --- What a probe found of one requirement.
  enum Kind
    "present"
    "na"
    "skipped"
    "refused"
  end

  --- One requirement's outcome.
  record Answer
    --- The requirement as written.
    name: string
    --- Its class; "host" for a refused name, which no platform decides.
    class: host_names.Class
    kind: Kind
    --- Where `present`, what a verdict key holds of it (the Landlock ABI
    --- the kernel gives, a program's digest, ...); "" otherwise.
    key: string
    --- Where not `present`, why: what the probe found, or the rule a
    --- refused name breaks; "" where `present`.
    why: string
  end

  --- What reading a file came to.
  record Read
    --- Its bytes, where `why` is "".
    data: string
    --- Why it could not be read, "" where it was.
    why: string
    --- Whether it failed for there being no such file, which is the
    --- setting's absence, not a defect.
    missing: boolean
  end

  --- What the runner's probe of the sandbox found, in the shape of
  --- [`build.test_sandbox_probe`]'s [`Answer`], which this module cannot name
  --- (the analyzer reads this module, and that one reads the analyzer).
  record Sandbox
    ok: boolean
    --- Why not, "" where it can.
    why: string
    --- Whether the failure is a defect, no limit of the host.
    broken: boolean
  end

  --- What the caller hands in that the table cannot probe itself.
  record Context
    --- Whether a worker can run sandboxed here: the runner's own
    --- [`build.test_sandbox_probe`]'s `available` answer. Without it `sandbox` is
    --- refused, since no cheaper probe answers the same.
    sandbox: function(): host_requires.Sandbox
    --- Whether this run is a portable artifact, which the runner reads from
    --- the program's `runtime_context` ("portable-v1", as its launcher key
    --- does): this module cannot read the store, which the harness would
    --- carry with it. Nil is a native start.
    portable: boolean
    --- Whether this core is the checked build, which the runner reads from
    --- `configuration` ("sanitized"); nil is no.
    checked: boolean
    --- Whether the platform is Linux, which is the platform's own answer
    --- ([`confine.sandbox_platform`]) where nil. A test of the runner
    --- sets it false to make every Linux requirement not applicable on a
    --- host that has them.
    linux: boolean
    --- The paths a worker with the profile "system" is given, which a
    --- `program:` must be under; [`confine.system_paths`] by default.
    system: {string}
    --- The search list `program:` looks in; PATH by default
    --- ([`Proc.find`]).
    path: string
    --- Reads a file for the settings `userns` and `nest` read, which a
    --- test stands in for.
    read: function(path: string): host_requires.Read
  end

  --- The probes of one run: each requirement is asked of the host once.
  record Host
    context: Context
    found: {string:host_requires.Answer}
  end

end

--- Whether this platform is Linux, which has every platform requirement
--- but a portable artifact.
local function linux(host: host_requires.Host): boolean
  local stood_in = host.context.linux
  if stood_in ~= nil then return stood_in end
  return sandbox_platform()
end

--- The outcome a probe answers: whether present, and what a key holds or
--- why not.
local record Found
  present: boolean
  text: string
end

--- A requirement's table entry.
local record Entry
  --- Of a `platform` entry, whether this platform ever has it, where the
  --- answer is no probe's but the platform's own; the outcome is `na`
  --- where it does not.
  platform_has: function(host: host_requires.Host): boolean
  --- The probe, handed its argument ("" for none) and the host.
  probe: function(argument: string, host: host_requires.Host): Found
end

--- Whether `path` is there; raises where the host cannot say, as for a
--- directory it may not search.
local function there(path: string): boolean
  local found, trouble = exists(path)
  if found == nil then
    error("host_requires: " .. path .. " cannot be inspected: " .. trouble, 0)
  end
  return found
end

--- Whether `path` is a directory, which it must be there to be.
local function directory(path: string): boolean
  local found, trouble = is_dir(path)
  if found == nil then
    error("host_requires: " .. path .. " cannot be inspected: " .. trouble, 0)
  end
  return found
end

local function present(text: string): Found
  return { present = true, text = text }
end

local function absent(why: string): Found
  return { present = false, text = why }
end

--- The most bytes of a file a probe reads, which a key's digest or a
--- setting never needs more than.
local MOST_BYTES <const> = 64 << 20

--- What opening a path once found.
local record Opened
  --- What it is, as fstat of the open descriptor says ("file", "dir",
  --- "fifo", ...); "" where it could not be opened.
  kind: string
  --- Its bytes where it is a regular file within `MOST_BYTES`.
  data: string
  --- Why there is none, "" where there is; and the errno of a failed open.
  why: string
  errno: integer
end

--- Opens `path` once, without waiting (a FIFO with no writer would
--- block an open without O_NONBLOCK), asks the descriptor what it is, and,
--- for a regular file, reads it from that descriptor: a path swapped
--- for a FIFO between a check and a read cannot hang it. A file larger
--- than `MOST_BYTES` is no regular file a key can hold.
local function slurp(path: string): Opened
  local fd, trouble, errno = sys.open(path, sys.O_RDONLY | sys.O_NONBLOCK)
  if fd == nil then
    return { kind = "", data = "", why = path .. ": " .. trouble, errno = errno }
  end
  local st, why, st_errno = sys.fstat(fd)
  if st == nil then
    local _, _ = sys.close(fd)
    return { kind = "", data = "", why = path .. ": " .. why, errno = st_errno }
  end
  local opened: Opened = { kind = st.kind, data = "", why = "", errno = 0 }
  if st.kind == "file" then
    local parts: {string} = {}
    local total = 0
    while true do
      local chunk, failure, read_errno = sys.read(fd, 1 << 20)
      if chunk == nil then
        opened.kind, opened.why, opened.errno = "", path .. ": " .. failure, read_errno
        break
      end
      if #chunk == 0 then
        opened.data = table.concat(parts)
        break
      end
      total = total + #chunk
      if total > MOST_BYTES then
        opened.why = string.format("%s is larger than %d MiB, which no key holds", path, MOST_BYTES >> 20)
        break
      end
      parts[#parts + 1] = chunk
    end
  else
    opened.why = string.format("%s is a %s, which no key can hold: name a regular file or a directory",
      path, st.kind)
  end
  local _, _ = sys.close(fd)
  return opened
end

--- `path`'s bytes, or nil and the rule a file that is no regular one or too
--- large breaks; raises where it cannot be opened or read, since a key that
--- could not hold the file would stand on whatever it held.
local function bytes_of(path: string): string | nil, string
  local opened = slurp(path)
  if opened.kind == "" then error("host_requires: " .. opened.why, 0) end
  if opened.why ~= "" then return nil, opened.why end
  return opened.data, ""
end

--- The reading a probe of a setting does: the context's, else a regular
--- file's.
local function reader(host: host_requires.Host): function(string): host_requires.Read
  return host.context.read or function(path: string): host_requires.Read
    local opened = slurp(path)
    return { data = opened.data, why = opened.why,
      missing = opened.errno == sys.ENOENT or opened.errno == sys.ENOTDIR }
  end
end

--- The sysctl at `path` as a number, or nil where the host has none: the read
--- answers that there is no such file. Any other failure, or text that is
--- no number, raises: neither is the setting's absence.
local function sysctl(host: host_requires.Host, path: string): integer | nil
  local read = reader(host)(path)
  if read.why ~= "" then
    if read.missing then return nil end
    error("host_requires: " .. path .. " cannot be read: " .. read.why, 0)
  end
  local number = math.tointeger(tonumber((read.data:gsub("%s+$", ""))))
  if number == nil then error("host_requires: " .. path .. " holds no number: " .. read.data, 0) end
  return number
end

--- CAP_SYS_ADMIN, the capability bit a user namespace needs of no
--- security module's restriction (`CapEff` in /proc/self/status).
local CAP_SYS_ADMIN <const> = 21

--- Whether this process holds CAP_SYS_ADMIN in effect; raises where
--- /proc/self/status says no `CapEff`, since nothing else answers.
local function admin(host: host_requires.Host): boolean
  local read = reader(host)("/proc/self/status")
  if read.why ~= "" then
    error("host_requires: /proc/self/status cannot be read: " .. read.why, 0)
  end
  local effective = read.data:match("\nCapEff:%s*(%x+)")
  if effective == nil then error("host_requires: /proc/self/status has no CapEff", 0) end
  local bits = math.tointeger(tonumber(effective:sub(-8), 16)) or 0 -- the low 32 bits hold bit 21
  return bits & (1 << CAP_SYS_ADMIN) ~= 0
end

-- TODO: probe `userns` by making one, once a spawn of a trivial child in a
-- user namespace of its own is cheap enough to run once a run beside
-- `own_proc` (core/process.h has no binding for it alone): the settings
-- say what the kernel is told, not what a seccomp filter or a security
-- module then refuses. Nor is CapEff the whole answer: it is the process's
-- capabilities in its own user namespace, so a process holding all of them
-- in a nested one may still be refused by the initial namespace's checks.
--- Whether the kernel's settings allow this process a user namespace: a
--- limit above 0 and, unless it holds CAP_SYS_ADMIN, neither of the
--- switches a distribution or a container adds turned against it. Which
--- switches bind is the capability's, not the user's: a root that has
--- given the capability up (a container's) is bound by them as any user is.
--- What a key holds is "allowed", not the limit, which differs by host
--- and would split a verdict across hosts that all allow one.
local function userns_allowed(host: host_requires.Host): Found
  local limit = sysctl(host, "/proc/sys/user/max_user_namespaces")
  if limit == nil then
    -- A kernel with no such file has none built in, or a /proc that hides it.
    if not there("/proc/self") then
      return absent("/proc is not mounted, so no setting can be read")
    end
    return absent("the kernel has no user.max_user_namespaces: user namespaces are not built in")
  end
  if limit <= 0 then return absent("user.max_user_namespaces is " .. limit) end
  if not admin(host) then
    if sysctl(host, "/proc/sys/kernel/unprivileged_userns_clone") == 0 then
      return absent("kernel.unprivileged_userns_clone is 0")
    end
    if sysctl(host, "/proc/sys/kernel/apparmor_restrict_unprivileged_userns") == 1 then
      return absent("kernel.apparmor_restrict_unprivileged_userns is 1")
    end
  end
  return present("allowed")
end

--- What a program keys by: the digest of its own bytes, read once, and
--- for a script that of its interpreter beside it (the first word of its
--- `#!` line) and, where that is `env`, of the program `env` runs (its
--- options and NAME=value words skipped). The shared libraries and data files a
--- binary loads are not keyed, so a library changed under an unchanged
--- program moves no key. Nil and the rule where the file is no regular
--- one or too large.
local function program_key(path: string, search: string | nil): string | nil, string
  local data, why = bytes_of(path)
  if data == nil then return nil, why end
  local key = "sha256:" .. hex_sha256(data)
  local line = data:match("^#![ \t]*([^\n]*)")
  if line == nil then return key, "" end
  local words: {string} = {}
  for word in line:gmatch("%S+") do words[#words + 1] = word end
  --- The digest of the file at `named`, as an interpreter's, or a marker where it cannot be keyed.
  local function interpreter_digest(named: string | nil): string
    if named == nil then return "absent" end
    local opened = slurp(named)
    if opened.kind == "" or opened.why ~= "" then return "unkeyed" end
    return "sha256:" .. hex_sha256(opened.data)
  end
  key = key .. ";interpreter=" .. interpreter_digest(words[1])
  if words[1] ~= nil and words[1]:match("/env$") then
    local index = 2
    while words[index] ~= nil do
      local word = words[index]
      if word == "-u" or word == "-C" or word == "--unset" or word == "--chdir" then
        index = index + 2
      elseif word:sub(1, 1) == "-" or word:match("^[%w_]+=") then
        index = index + 1
      else
        break
      end
    end
    if words[index] ~= nil then
      local found, _ = find_program(words[index], search)
      key = key .. ";runs=" .. interpreter_digest(found)
    end
  end
  return key, ""
end

--- What `path` is keyed by, following links: a regular file by its digest, a
--- directory as "dir", /proc and /sys (by the path with its links
--- resolved) as "present", whose files change as they are read. Nil and the
--- rule where it is a device, a FIFO, a socket or a file too large. The
--- prefix classifies only those two: a procfs or other virtual filesystem
--- mounted elsewhere is caught by the regular-file check and the size cap,
--- which a file that never ends or changes as it is read breaks, not by
--- where it is.
local function file_key(path: string): string | nil, string
  local real, trouble = realpath(path)
  if real == nil then error("host_requires: " .. trouble, 0) end
  for _, virtual in ipairs({ "/proc", "/sys" }) do
    if real == virtual or real:sub(1, #virtual + 1) == virtual .. "/" then return "present" end
  end
  local opened = slurp(real)
  if opened.kind == "" then error("host_requires: " .. opened.why, 0) end
  if opened.kind == "dir" then return "dir" end
  if opened.why ~= "" then return nil, opened.why end
  return "sha256:" .. hex_sha256(opened.data)
end

--- Whether `path` is under a path of the "system" profile a worker is given.
local function given(path: string, host: host_requires.Host): boolean
  for _, root in ipairs(host.context.system or system_paths) do
    if path == root or path:sub(1, #root + 1) == root .. "/" then return true end
  end
  return false
end

local table_of: {string:Entry} = {
  sandbox = { platform_has = linux,
    probe = function(_: string, host: host_requires.Host): Found
      local ask = host.context.sandbox
      if ask == nil then
        error("host_requires: `sandbox` needs the runner's sandbox probe in the context", 0)
      end
      local answer = ask()
      if answer.broken then
        -- A defect, no limit of the host: the run fails, as the runner's own probe's does.
        error("host_requires: the sandbox probe failed: " .. answer.why, 0)
      end
      if answer.ok then return present("worker") end
      return absent(answer.why)
    end },
  landlock = { platform_has = linux,
    probe = function(argument: string, _: host_requires.Host): Found
      local wanted = argument == "" and 1 or assert(math.tointeger(tonumber(argument)))
      local abi, why = landlock_abi()
      if abi == nil then return absent("no Landlock: " .. why) end
      if abi < wanted then return absent("Landlock ABI " .. abi .. " is below " .. wanted) end
      return present("abi=" .. abi)
    end },
  userns = { platform_has = linux,
    probe = function(_: string, host: host_requires.Host): Found return userns_allowed(host) end },
  nest = { platform_has = linux,
    probe = function(_: string, host: host_requires.Host): Found
      local userns = userns_allowed(host)
      if not userns.present then return userns end
      if getuid() == 0 and not may_map_ids() then
        return absent("root without CAP_SETUID, CAP_SETGID and CAP_SETFCAP cannot map the user a sandbox runs as")
      end
      return present(getuid() == 0 and "root" or "user")
    end },
  own_proc = { platform_has = linux,
    probe = function(_: string, _: host_requires.Host): Found
      if own_proc_given() then return present("own") end
      return absent("the kernel refuses a sandbox a procfs of its own (a container masking /proc, or no user namespace)")
    end },
  proc = { platform_has = linux,
    probe = function(_: string, _: host_requires.Host): Found
      if there("/proc/self") and directory("/proc/self") then return present("mounted") end
      return absent("/proc/self is not there")
    end },
  portable = { platform_has = function(host: host_requires.Host): boolean
    return host.context.portable == true
  end,
    probe = function(_: string, _: host_requires.Host): Found
      -- Only a portable artifact gets here ([`platform_has`]), so what it cannot
      -- reopen to start again is a defect, never an absence.
      local found, trouble = relaunch()
      if found == nil then
        error("host_requires: a portable artifact cannot start again: " .. trouble, 0)
      end
      return present("artifact")
    end },
  checked = { platform_has = function(host: host_requires.Host): boolean
    return host.context.checked == true
  end,
    probe = function(_: string, _: host_requires.Host): Found
      return present("checked")
    end },
  root = {
    probe = function(_: string, _: host_requires.Host): Found
      if getuid() == 0 then return present("root") end
      return absent("the run's user is " .. getuid() .. ", not root")
    end },
  path = {
    probe = function(argument: string, _: host_requires.Host): Found
      -- The worker sees the path only where its module grants it: `check`
      -- refuses a `path:` with no `host` grant of it.
      if not there(argument) then return absent(argument .. " does not exist") end
      local key, rule = file_key(argument)
      if key == nil then return absent(rule) end
      return present(key)
    end },
  program = {
    probe = function(argument: string, host: host_requires.Host): Found
      -- The worker runs it only with the profile "system" and the variable
      -- PATH: `check` refuses a `program:` without both.
      local resolved, why = find_program(argument, host.context.path)
      if resolved == nil then return absent(why) end
      -- A worker with the profile "system" sees only the system's paths
      -- ([`confine.system_paths`]): a program found elsewhere on PATH is one
      -- it cannot run, so it is absent for the test, whatever the runner finds.
      local real, trouble = realpath(resolved)
      if real == nil then error("host_requires: " .. trouble, 0) end
      if not (given(resolved, host) and given(real, host)) then
        return absent(resolved .. " is outside the system's paths a worker is given")
      end
      -- Keyed by the file it finds, as `host` keys a file: a test's output
      -- may turn on the program's version.
      local key, rule = program_key(resolved, host.context.path)
      if key == nil then return absent(rule) end
      return present(key)
    end },
}

--- A fresh set of probes for one run: `context` hands in what the table
--- cannot probe itself.
function host_requires.new(context?: host_requires.Context): host_requires.Host
  return { context = context or {}, found = {} }
end

--- The outcome of each of `names`, in order. A refused name answers
--- `refused` with the rule it breaks, whatever the host; a requirement of
--- the `platform` class a platform never has answers `na` without a probe;
--- any other asks its probe, once per `host`, and answers `present` with
--- its key text, or `skipped`. Raises where a probe cannot tell.
--- @param names requirements as written
--- @return an answer for each
function host_requires.answer(host: host_requires.Host, names: {string}): {host_requires.Answer}
  local out: {host_requires.Answer} = {}
  for i, name in ipairs(names) do
    local cached = host.found[name]
    if cached == nil then
      local spec, why = host_names.parse(name)
      if spec == nil then
        cached = { name = name, class = "host", kind = "refused", key = "", why = why }
      else
        local entry = table_of[spec.base]
        if spec.class == "platform" and not entry.platform_has(host) then
          cached = { name = name, class = spec.class, kind = "na", key = "", why = spec.base .. ": this platform has none" }
        else
          local found = entry.probe(spec.argument, host)
          if found.present then
            cached = { name = name, class = spec.class, kind = "present", key = found.text, why = "" }
          else
            cached = { name = name, class = spec.class, kind = "skipped", key = "", why = found.text }
          end
        end
      end
      host.found[name] = cached
    end
    out[i] = cached
  end
  return out
end

return host_requires
