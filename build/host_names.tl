--- The names a test may require of its host, how a name is read and
--- refused, what a policy implies of them, and the rules a declaration
--- breaks (`check`): the pure half of [`build.host_requires`], which probes
--- them. It reaches nothing of the host, so the build's analyzer reads a
--- policy's `requires` through it without the probes' libraries.
---
--- A name is one of:
---
--- - `sandbox`: this host can run a worker under a policy;
--- - `landlock` or `landlock:N`: Landlock, of ABI version N or later;
--- - `userns`: the kernel's settings allow a user namespace;
--- - `nest`: a sandboxed process may build a sandbox of its own: `userns`
---   and, for a root, the capabilities to map the user its child runs as;
--- - `own_proc`: a sandbox gets a procfs of its own;
--- - `proc`: /proc is mounted;
--- - `portable`: this run is a portable artifact, not a native start;
--- - `root`: the run's user is root;
--- - `path:<absolute path>`: a file or directory of the host;
--- - `program:<name>`: a program the PATH finds.
---
--- `unprivileged` is no name: it is `root`'s negation, which a test can
--- state by skipping where `root` is present.
---
--- Its class says what an absence means. A `platform` requirement is one
--- only some platforms have (Landlock, /proc and a user namespace are
--- Linux's; a portable artifact is no native start's): where the platform
--- never has it the outcome is `na`, a test that has nothing to check
--- there; where the platform could and this host refuses it, `skipped`. A
--- `host` requirement (a path, a program, root) is any platform's to have
--- or lack, so its absence is always `skipped`.

local record host_names
  --- The table's names, sorted: `landlock` is also written `landlock:N`,
  --- and `path` and `program` only with an argument.
  names: {string}

  --- Whether a requirement is one only some platforms have.
  enum Class
    "platform"
    "host"
  end

  --- What of a declaration `check` reads: the analyzer's `Declared`
  --- as far as it says what the worker is given.
  record Inputs
    --- Whether the profile "system" is joined.
    system: boolean
    --- The absolute paths granted as host files.
    host: {string}
    --- The variables passed through, by name.
    env: {string}
  end

  --- A name taken apart.
  record Spec
    --- Its table entry's name, without an argument: "landlock", "path".
    base: string
    --- What follows the colon, "" where none.
    argument: string
    --- Its table entry's class.
    class: Class
  end
end

--- A name's shape: its class, and whether it takes an argument, which may
--- be left out for `landlock`.
local record Shape
  class: host_names.Class
  argument: boolean
  optional: boolean
end

local shapes: {string:Shape} = {
  sandbox = { class = "platform", argument = false, optional = false },
  landlock = { class = "platform", argument = true, optional = true },
  userns = { class = "platform", argument = false, optional = false },
  nest = { class = "platform", argument = false, optional = false },
  own_proc = { class = "platform", argument = false, optional = false },
  proc = { class = "platform", argument = false, optional = false },
  portable = { class = "platform", argument = false, optional = false },
  root = { class = "host", argument = false, optional = false },
  path = { class = "host", argument = true, optional = false },
  program = { class = "host", argument = true, optional = false },
}

host_names.names = {}
for name in pairs(shapes) do host_names.names[#host_names.names + 1] = name end
table.sort(host_names.names)

--- Takes `name` apart, or nil and the rule it breaks: a name the table does
--- not have, an argument where it takes none (or none where it needs one),
--- a `landlock:N` whose N is not a positive integer of at most four digits,
--- a `path:` that is not absolute, a `program:` that names a path.
--- @param name a requirement as written
--- @return its table name and argument, or nil and why it is refused
function host_names.parse(name: string): host_names.Spec | nil, string
  local base, argument = name:match("^([^:]*):(.*)$")
  if base == nil then base, argument = name, nil end
  local entry = shapes[base]
  if entry == nil then
    return nil, string.format("unknown requirement %q: it is one of %s, with `landlock:N`, `path:<absolute path>` and `program:<name>`",
      name, table.concat(host_names.names, ", "))
  end
  if argument == nil then
    if entry.argument and not entry.optional then
      return nil, string.format("%q needs an argument: `%s:<%s>`", name, base,
        base == "path" and "absolute path" or "name")
    end
    return { base = base, argument = "", class = entry.class }
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
  return { base = base, argument = argument, class = entry.class }
end

--- The class of a requirement, or nil where `name` is refused.
--- @param name a requirement as written
--- @return its class, or nil and why it is refused
function host_names.class(name: string): host_names.Class | nil, string
  local spec, why = host_names.parse(name)
  if spec == nil then return nil, why end
  return spec.class
end

-- TODO: infer requirements from the rest of a policy -- the promise "nest"
-- is `nest`, a `host` grant of /proc or beneath it is `proc`, `isolate` is
-- `sandbox` and `userns` -- once ci/capabilities.tl lists each leg's
-- promises, so a held run can fail a platform requirement its leg promised
-- (step 4 of the host requirements design), and each module that would
-- gain a requirement has been audited: inferred now, about 25 modules
-- (build/must_confine_test.tl among them) would stop running on a host
-- that lacks Linux's features, and no run would fail for it.
-- TODO: let a policy name the Linux-class requirements `LINUX_NAMES`
-- holds, which `check` refuses until that same step: declared now, a module
-- would be skipped or n/a silently on a CI leg that should have given it.

--- The Linux-class names, refused in a declaration until a leg's promises
--- are written down.
local LINUX_NAMES <const>: {string:boolean} = {
  sandbox = true, landlock = true, userns = true, nest = true, own_proc = true, proc = true,
}

--- Whether `path` is /proc or beneath it, which a grant may name as a
--- directory.
local function in_proc(path: string): boolean
  return path == "/proc" or path:sub(1, 6) == "/proc/"
end

--- Whether a host grant `granted` lets the worker see `path`: the same
--- path, or one beneath a /proc grant (the one directory a grant names).
local function grants(granted: string, path: string): boolean
  return granted == path or (in_proc(granted) and path:sub(1, #granted + 1) == granted .. "/")
end

--- Whether the requirements a policy asks of its host break a rule, and
--- the rule it breaks: a name is one the table does not have (`parse`),
--- is a Linux-class name (refused for now, see the TODO above), is written
--- twice, a `path:` has no `host` grant of the same path (the worker sees
--- what its module grants, not what the runner found), or a `program:` has
--- not the profile "system" and the variable PATH in `env` (the worker runs
--- what its own search list finds).
--- @param declared the names a policy's `requires` holds
--- @param inputs the rest of the policy
--- @return true, or false and why
function host_names.check(declared: {string}, inputs: host_names.Inputs): boolean, string
  local seen: {string:boolean} = {}
  for _, name in ipairs(declared) do
    local spec, why = host_names.parse(name)
    if spec == nil then return false, "requires: " .. why end
    if LINUX_NAMES[spec.base] then
      return false, string.format("requires: %q is a Linux-class requirement, which a policy may not " ..
          "name yet: no leg's promises are written down, so a module that names one would be " ..
          "skipped or n/a silently where CI should have given it (the TODO in build/host_names.tl)", name)
    end
    if seen[name] then return false, string.format("requires: %q is written twice", name) end
    seen[name] = true
    if spec.base == "path" then
      local granted = false
      for _, path in ipairs(inputs.host or {}) do
        if grants(path, spec.argument) then granted = true end
      end
      if not granted then
        return false, string.format("requires: %q needs a host grant of the path, which is what the " ..
            "worker sees of it: grants = { { path = %q, letters = \"r\" } }", name, spec.argument)
      end
    elseif spec.base == "program" then
      local path_named = false
      for _, variable in ipairs(inputs.env or {}) do
        if variable == "PATH" then path_named = true end
      end
      if not (inputs.system and path_named) then
        return false, string.format("requires: %q needs the profile \"system\" and env = { \"PATH\" }, " ..
            "so the worker can find and run what the runner found", name)
      end
    end
  end
  return true, ""
end

return host_names
