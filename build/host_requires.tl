--- What a test may require of the host it runs on, as a closed table of
--- names, each with a probe, a class and the text a verdict key holds
--- while the requirement is met. Nothing declares a requirement yet: this
--- is the table [`Test.policy`]'s `requires` will read.
---
--- A name is one of:
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
---   user its child runs as ([`confine.may_map_ids`]);
--- - `own_proc`: a sandbox gets a procfs of its own ([`confine.own_proc_given`]);
--- - `proc`: /proc is mounted;
--- - `portable`: this program was started from a portable artifact, so it
---   has one to start again ([`Proc.relaunch`]);
--- - `root`: the run's user is root;
--- - `path:<absolute path>`: a file or directory of the host;
--- - `program:<name>`: a program the PATH finds ([`Proc.find`]).
---
--- Its class says what an absence means. A `platform` requirement is one
--- only some platforms have (Landlock, /proc and a user namespace are
--- Linux's; a portable artifact is no native start's): where the platform
--- never has it the outcome is `na`, a test that has nothing to check
--- there; where the platform could and this host refuses it, `skipped`. A
--- `host` requirement (a path, a program, root) is any platform's to have
--- or lack, so its absence is always `skipped`. Whether a platform has a
--- requirement at all is the platform's own answer
--- ([`confine.sandbox_platform`], which is Linux's), never a probe's.
---
--- Each probe runs once per [`host_requires.Host`], in the process that
--- asks (the runner's, never a test's), and a probe that cannot tell raises
--- rather than answer present or absent, since a wrong "present" would run
--- a test that fails for the host and a wrong "absent" would pass one that
--- checked nothing.
---
--- A harness module (build/harness_epoch.tl): it reaches the host through
--- the raw bindings and the libraries `library` names, and takes what it
--- calls of them as locals when it loads.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local digest = require("build.digest")
local type test_sandbox_probe = require("build.test_sandbox_probe")

local find_program, read_file, exists, is_dir = Proc.find, Fs.read, Fs.exists, Fs.is_dir
local relaunch, getuid = Proc.relaunch, sys.getuid
local sandbox_platform, may_map_ids = confine.sandbox_platform, confine.may_map_ids
local own_proc_given, landlock_abi = confine.own_proc_given, confine.landlock_abi
local hex_sha256 = digest.hex_sha256

local record host_requires
  --- The table's names, sorted: `landlock` is also written `landlock:N`,
  --- and `path` and `program` only with an argument.
  names: {string}

  --- What a probe found of one requirement.
  enum Kind
    "present"
    "na"
    "skipped"
    "refused"
  end

  --- Whether a requirement is one only some platforms have.
  enum Class
    "platform"
    "host"
  end

  --- One requirement's outcome.
  record Answer
    --- The requirement as written.
    name: string
    kind: Kind
    --- Where `present`, what a verdict key holds of it (the Landlock ABI
    --- the kernel gives, a program's digest, ...); "" otherwise.
    key: string
    --- Where not `present`, why: what the probe found, or the rule a
    --- refused name breaks; "" where `present`.
    why: string
  end

  --- What the caller hands in that the table cannot probe itself.
  record Context
    --- Whether a worker can run sandboxed here: the runner's own
    --- [`test_sandbox_probe.available`] answer. Without it `sandbox` is
    --- refused, since no cheaper probe answers the same.
    sandbox: function(): test_sandbox_probe.Answer
    --- The search list `program:` looks in; PATH by default
    --- ([`Proc.find`]).
    path: string
  end

  --- The probes of one run: each requirement is asked of the host once.
  record Host
    context: Context
    found: {string:host_requires.Answer}
  end

  --- A name taken apart.
  record Spec
    --- Its table entry's name, without an argument: "landlock", "path".
    base: string
    --- What follows the colon, "" where none.
    argument: string
  end
end

--- Whether this platform is Linux, which has every platform requirement
--- but a portable artifact.
local function linux(): boolean
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
  class: host_requires.Class
  --- How many arguments it takes, and whether one is optional.
  argument: boolean
  optional: boolean
  --- Of a `platform` entry, whether this platform ever has it, where the
  --- answer is no probe's but the platform's own; the outcome is `na`
  --- where it does not.
  platform_has: function(): boolean
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

--- Whether this program has an artifact to start again.
local function has_artifact(): boolean
  local found, _ = relaunch()
  return found ~= nil
end

local function present(text: string): Found
  return { present = true, text = text }
end

local function absent(why: string): Found
  return { present = false, text = why }
end

--- The digest of the file at `path`, as a verdict key holds it; raises
--- where it cannot be read, since a key that could not hold the file
--- would stand on whatever it held.
local function contents_digest(path: string): string
  local data, trouble = read_file(path)
  if data == nil then error("host_requires: " .. path .. " cannot be read: " .. trouble, 0) end
  return "sha256:" .. hex_sha256(data)
end

--- The sysctl at `path` as a number, or nil where the host has none.
local function sysctl(path: string): integer | nil
  local text, _ = read_file(path)
  if text == nil then return nil end
  return math.tointeger(tonumber((text:gsub("%s+$", ""))))
end

-- TODO: probe `userns` by making one, once a spawn of a trivial child in a
-- user namespace of its own is cheap enough to run once a run beside
-- `own_proc` (core/process.h has no binding for it alone): the settings
-- say what the kernel is told, not what a seccomp filter or a security
-- module then refuses.
--- Whether the kernel's settings allow this process a user namespace: a
--- limit above 0, and neither of the switches a distribution or a
--- container adds turned against it. A root is held to the limit alone,
--- which the switches do not bind.
local function userns_allowed(): Found
  local limit = sysctl("/proc/sys/user/max_user_namespaces")
  if limit == nil then
    -- A kernel with no such file has none built in, or a /proc that hides it.
    if not there("/proc/self") then
      return absent("/proc is not mounted, so no setting can be read")
    end
    return absent("the kernel has no user.max_user_namespaces: user namespaces are not built in")
  end
  if limit <= 0 then return absent("user.max_user_namespaces is " .. limit) end
  if getuid() ~= 0 then
    if sysctl("/proc/sys/kernel/unprivileged_userns_clone") == 0 then
      return absent("kernel.unprivileged_userns_clone is 0")
    end
    if sysctl("/proc/sys/kernel/apparmor_restrict_unprivileged_userns") == 1 then
      return absent("kernel.apparmor_restrict_unprivileged_userns is 1")
    end
  end
  return present("max=" .. limit)
end

local table_of: {string:Entry} = {
  sandbox = { class = "platform", platform_has = linux, argument = false, optional = false,
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
  landlock = { class = "platform", platform_has = linux, argument = true, optional = true,
    probe = function(argument: string, _: host_requires.Host): Found
      local wanted = argument == "" and 1 or assert(math.tointeger(tonumber(argument)))
      local abi, why = landlock_abi()
      if abi == nil then return absent("no Landlock: " .. why) end
      if abi < wanted then return absent("Landlock ABI " .. abi .. " is below " .. wanted) end
      return present("abi=" .. abi)
    end },
  userns = { class = "platform", platform_has = linux, argument = false, optional = false,
    probe = function(_: string, _: host_requires.Host): Found return userns_allowed() end },
  nest = { class = "platform", platform_has = linux, argument = false, optional = false,
    probe = function(_: string, _: host_requires.Host): Found
      local userns = userns_allowed()
      if not userns.present then return userns end
      if getuid() == 0 and not may_map_ids() then
        return absent("root without CAP_SETUID, CAP_SETGID and CAP_SETFCAP cannot map the user a sandbox runs as")
      end
      return present(getuid() == 0 and "root" or "user")
    end },
  own_proc = { class = "platform", platform_has = linux, argument = false, optional = false,
    probe = function(_: string, _: host_requires.Host): Found
      if own_proc_given() then return present("own") end
      return absent("the kernel refuses a sandbox a procfs of its own (a container masking /proc, or no user namespace)")
    end },
  proc = { class = "platform", platform_has = linux, argument = false, optional = false,
    probe = function(_: string, _: host_requires.Host): Found
      if there("/proc/self") and directory("/proc/self") then return present("mounted") end
      return absent("/proc/self is not there")
    end },
  portable = { class = "platform", platform_has = has_artifact, argument = false, optional = false,
    probe = function(_: string, _: host_requires.Host): Found
      if has_artifact() then return present("artifact") end
      return absent("this program was started natively, with no artifact to start again")
    end },
  root = { class = "host", argument = false, optional = false,
    probe = function(_: string, _: host_requires.Host): Found
      if getuid() == 0 then return present("root") end
      return absent("the run's user is " .. getuid() .. ", not root")
    end },
  path = { class = "host", argument = true, optional = false,
    probe = function(argument: string, _: host_requires.Host): Found
      if not there(argument) then return absent(argument .. " does not exist") end
      if directory(argument) then return present("dir") end
      -- A file of /proc has no contents a key could hold: they change as it is read.
      if argument == "/proc" or argument:sub(1, 6) == "/proc/" then return present("present") end
      return present(contents_digest(argument))
    end },
  program = { class = "host", argument = true, optional = false,
    probe = function(argument: string, host: host_requires.Host): Found
      local resolved, why = find_program(argument, host.context.path)
      if resolved == nil then return absent(why) end
      -- The digest of the file it finds, as `host` keys a file: a test's
      -- output may turn on the program's version.
      return present(contents_digest(resolved))
    end },
}

host_requires.names = {}
for name in pairs(table_of) do host_requires.names[#host_requires.names + 1] = name end
table.sort(host_requires.names)

--- Takes `name` apart, or nil and the rule it breaks: a name the table does
--- not have, an argument where it takes none (or none where it needs one),
--- a `landlock:N` whose N is not a positive integer of at most four digits,
--- a `path:` that is not absolute, a `program:` that names a path.
--- @param name a requirement as written
--- @return its table name and argument, or nil and why it is refused
function host_requires.parse(name: string): host_requires.Spec | nil, string
  local base, argument = name:match("^([^:]*):(.*)$")
  if base == nil then base, argument = name, nil end
  local entry = table_of[base]
  if entry == nil then
    return nil, string.format("unknown requirement %q: it is one of %s, with `landlock:N`, `path:<absolute path>` and `program:<name>`",
      name, table.concat(host_requires.names, ", "))
  end
  if argument == nil then
    if entry.argument and not entry.optional then
      return nil, string.format("%q needs an argument: `%s:<%s>`", name, base,
        base == "path" and "absolute path" or "name")
    end
    return { base = base, argument = "" }
  end
  if not entry.argument then
    return nil, string.format("%q: `%s` takes no argument", name, base)
  end
  if base == "landlock" then
    if not argument:match("^[1-9]%d?%d?%d?$") then
      return nil, string.format("%q: `landlock:N` takes the least ABI version as a positive integer of at most four digits, from 1", name)
    end
  elseif base == "path" then
    if argument:sub(1, 1) ~= "/" then
      return nil, string.format("%q: `path:` takes an absolute path, one that begins with \"/\"", name)
    end
    if argument:find("\0", 1, true) then
      return nil, string.format("%q: `path:` takes a path with no NUL byte", name)
    end
  elseif base == "program" then
    if argument == "" or argument:find("/", 1, true) or argument:find("\0", 1, true) then
      return nil, string.format("%q: `program:` takes the name of a program the PATH finds, with no \"/\" (a file of a known place is `path:`)", name)
    end
  end
  return { base = base, argument = argument }
end

--- The class of a requirement, or nil where `name` is refused.
--- @param name a requirement as written
--- @return its class, or nil and why it is refused
function host_requires.class(name: string): host_requires.Class | nil, string
  local spec, why = host_requires.parse(name)
  if spec == nil then return nil, why end
  return table_of[spec.base].class
end

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
      local spec, why = host_requires.parse(name)
      if spec == nil then
        cached = { name = name, kind = "refused", key = "", why = why }
      else
        local entry = table_of[spec.base]
        if entry.class == "platform" and not entry.platform_has() then
          cached = { name = name, kind = "na", key = "", why = spec.base .. ": this platform has none" }
        else
          local found = entry.probe(spec.argument, host)
          if found.present then
            cached = { name = name, kind = "present", key = found.text, why = "" }
          else
            cached = { name = name, kind = "skipped", key = "", why = found.text }
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
