--- The checks and the parts of the hold of a start that [`cosmic.child`]'s `held_to` makes of a policy (its
--- `Sandbox` option): what a start may run and reach, the user it runs as, the cores it shares, the relay it holds,
--- and the scratch directory it is given. Use [`cosmic.child`]. Apart from it only to keep that module smaller.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local RelayConfig = require("cosmic.internal.relay_config")
local Rules = require("cosmic.sandbox")
local Seatbelt = require("cosmic.sandbox.seatbelt")
local sys = require("cosmic.sys")
local type raw_process = require("cosmic.internal.process")
local raw = require("cosmic.internal.process")

--- The unprivileged user and group a root caller's program runs as.
local record MappedUser
  uid: integer
  gid: integer
end

--- What a policy makes of a start.
local record Held
  --- The file to run.
  path: string
  --- The child's whole environment.
  env: mut {string:string}
  --- What spawn is handed to hold the child to it.
  sandbox: raw_process.Sandbox
  --- The temporary directory made for the child, "" for none: made by
  --- [`make_tmp`], the last step before the spawn.
  mut tmp: string
  --- Whether the policy asks for one: not under `isolate` file, whose
  --- /tmp is a tmpfs of the sandbox's own.
  wants_tmp: boolean
  --- The grants the core of a cosmic child holds itself to at boot, the
  --- policy's without the start's `rx` on that core ([`layer_text`]); nil
  --- for a host program, and under `isolate` file or `nest`.
  layer?: mut {raw_process.Grant}
  --- Whether it promises `nest`, which no descriptor to a directory or to a
  --- file open for less than both may be handed to ([`nest_descriptors`]).
  nests: boolean
  --- The directory to start in, as a path the root of `isolate` file
  --- holds; nil to start in the caller's.
  cwd?: string
  --- The user and group the child runs as where this process is root,
  --- which a program of a policy never is ([`mapped_user`]); nil for this
  --- process's own. The directory `tmp` makes is given to them.
  user?: MappedUser
  --- `user`, where the child gives root up for it directly, in no
  --- namespace (spawn's `credentials`); nil where it is mapped into one.
  drop?: MappedUser
  --- The arguments to run with, where they are not the caller's: this
  --- program's relaunch ([`relaunch_of`]).
  argv?: {string}
  --- The descriptors the relaunch hands the child, by its number; nil for none.
  fds?: {integer:integer}
  --- Whether `sandbox` holds the child by Seatbelt, as on macOS, and not
  --- by Landlock and seccomp.
  seatbelt?: boolean
  --- Under Seatbelt, the profile's parameter that names `tmp`'s directory,
  --- which [`make_tmp`] sets; nil without `tmp`.
  tmp_parameter?: string
  --- Under Seatbelt, whether the child is a cosmic core that applies its
  --- profile itself at boot ([`seatbelt_boot_env`]), with no `rx` on
  --- itself, in place of the trampoline: macOS applies one profile to a
  --- process, so the start's and the policy's cannot stack as Landlock's do.
  seatbelt_boot?: boolean
  --- The policy's `connect` targets, which the network relay serves; nil
  --- for a policy with none, which starts no relay.
  relay?: {string}
  --- Under Seatbelt with a relay, the policy and the host facts its profile
  --- is compiled from once the relay's port is known ([`relay_held`]).
  seatbelt_policy?: Rules.Policy
  seatbelt_options?: Seatbelt.Options
end

local record Hold
  type MappedUser = MappedUser
  type Held = Held
  holds_by_seatbelt: function(): boolean
  RELAY_MAIN: string
end

--- The most grants spawn takes (`GRANT_MAX` in core/sandbox.h, which is
--- `UNVEIL_MAX`: under `isolate` file each is a path the root unveils), the
--- temporary directory's included.
local MAX_GRANTS <const> = raw.UNVEIL_MAX

--- Whether `file` is `grant` or beneath it.
function Hold.beneath(file: string, grant: string): boolean
  if grant == "/" or file == grant then return true end
  return file:sub(1, #grant + 1) == grant .. "/"
end
local beneath = Hold.beneath

--- Why a start under `grants` cannot run the `files` a program needs to
--- start ([`Rules.loaders`], the program itself first), or "": a file
--- must be beneath a grant giving `r` and one giving `x`, which may be
--- one. A grant whose path does not exist is skipped, as spawn names
--- it.
function Hold.ungranted(files: {string}, grants: {Rules.Path}, cwd?: string): string
  local reals: mut {{string}} = {}
  for _, grant in ipairs(grants) do
    local at = grant.path
    if cwd ~= nil and at:sub(1, 1) ~= "/" then at = cwd .. "/" .. at end
    local real, _ = sys.realpath(at)
    if real ~= nil then reals[#reals + 1] = { real, grant.letters } end
  end
  for i, file in ipairs(files) do
    local missing: mut {string} = {}
    for _, letter in ipairs({ "r", "x" }) do
      local given = false
      for _, held in ipairs(reals) do
        if beneath(file, held[1]) and held[2]:find(letter, 1, true) ~= nil then given = true end -- checked: index_may_be_nil, nil_not_allowed
      end
      if not given then missing[#missing + 1] = letter end
    end
    if #missing > 0 then
      local what = if i == 1 then "the program" else "the interpreter the program starts through" end
      return string.format("%s %s is not granted %s: grant it, { path = %q, letters = \"rx\" }, " ..
          "or add the \"programs\" profile for the host's own programs", what, file,
        table.concat(missing, " and "), file)
    end
  end
  return ""
end

--- The most a start under `isolate` file may grant: one of spawn's
--- unveiled paths is the sandbox's own /proc.
local MAX_ISOLATED_GRANTS <const> = MAX_GRANTS - 1

--- Whether `merged`'s `isolate` holds `kind`.
function Hold.isolates(merged: Rules.Policy, kind: Rules.Isolate): boolean
  for _, held in ipairs(merged.isolate or {}) do
    if held == kind then return true end
  end
  return false
end
local isolates = Hold.isolates

--- Whether `merged` promises `nest`.
function Hold.nests(merged: Rules.Policy): boolean
  for _, promise in ipairs(Rules.calls(merged)) do
    if promise == "nest" then return true end
  end
  return false
end
local nests = Hold.nests

--- A policy's fields not yet met, by what each would need.
function Hold.unmet(merged: Rules.Policy): string
  local file = isolates(merged, "file")
  local held = #(Rules.paths(merged)) + (if merged.tmp == true and not file then 1 else 0 end)
  local most = if file then MAX_ISOLATED_GRANTS else MAX_GRANTS end
  if held > most then
    return "grants: the policy holds " .. tostring(held) ..
      (if file then ", and the sandbox's /proc is one more" else ", tmp's included" end) ..
      ", past the most a start takes, " .. tostring(most) .. "; grant a directory above them instead"
  end
  if nests(merged) and not file then
    return "calls \"nest\" needs isolate \"file\": the root of the program's own is what " ..
      "holds its files once Landlock's hold is given up, since the kernel refuses a mount to " ..
      "a process Landlock holds"
  end
  for _, grant in ipairs(Rules.paths(merged)) do
    if grant.from ~= nil and not file then
      return "grant \"" .. grant.path .. "\" has from, which needs isolate \"file\": the host's " ..
        "path is bound at that name in a root of the program's own"
    end
  end
  if (merged.limits or {}).processes ~= nil and not isolates(merged, "proc") and not file then
    return "limits.processes counts the processes of a user namespace of the sandbox's own, " ..
      "which isolate \"proc\" or \"file\" makes: add one"
  end
  for name, _ in pairs(merged.set_env_digests or {}) do
    return "set_env_digests \"" .. name .. "\" holds a digest, not the value to set; the " ..
      "policy cannot start a program"
  end
  return ""
end

--- The size of the /tmp of a sandbox's own under `isolate` file, in bytes.
-- TODO: let a policy say how large its /tmp is (a field beside `limits`),
-- once the design names one: every `isolate` file sandbox has this size.
local TMP_BYTES <const> = 256 * 1024 * 1024

--- `path` as a root holding it names it: unchanged where absolute, else
--- beneath `base`, which is absolute.
function Hold.named(path: string, base: string): string
  if path:sub(1, 1) == "/" then return path end
  if path == "." then return base end
  return base .. (if base:sub(-1) == "/" then "" else "/" end) .. path
end
local named = Hold.named

--- Whether `letters` holds `letter`.
function Hold.lettered(letters: string, letter: string): boolean
  return letters:find(letter, 1, true) ~= nil
end
local lettered = Hold.lettered

--- What `isolate` file builds from a policy's grants, resolved against the
--- directory `base`: each grant's host path (its `from`, else itself) bound
--- at its name when that differs, writable where it may be written or
--- created in, and noexec where it is and may not be run; and the sandbox's
--- own /proc; `idmap` says which are mounted idmapped ([`reached_by`]).
--- With `nest`, which has no Landlock to refuse running a file, every grant
--- without `x` is noexec. Nil and why where a grant cannot be placed.
function Hold.root_of(merged: Rules.Policy, base: string, idmap: {integer: boolean}, nest: boolean,
                      tmp_exec: boolean): raw_process.Unveil?, string
  local binds: mut {raw_process.Bind} = {}
  local reads: mut {string} = {}
  local proc = true
  for index, grant in ipairs(Rules.paths(merged)) do
    local name = named(grant.path, base)
    if name == "/proc" and grant.from ~= nil then
      return nil, "grant \"/proc\" has from, but /proc is the sandbox's own: grant its " ..
        "contents at another name"
    end
    if merged.tmp == true and (name == "/tmp" or name == "/") then
      return nil, "grant \"" .. grant.path .. "\" is the name of the sandbox's own /tmp, " ..
        "which tmp makes: grant what is beneath it, or leave tmp out, or grant \"/tmp\" " ..
        "itself with no `from`, for its letters"
    end
    if name == "/proc" or name == "/" then proc = false end
    local writable = lettered(grant.letters, "w") or lettered(grant.letters, "c")
    binds[#binds + 1] = { path = named(grant.from or grant.path, base),
      at = if grant.from ~= nil then name else nil end, writable = writable,
      noexec = (writable or nest) and not lettered(grant.letters, "x"), idmap = idmap[index] == true }
  end
  if proc then reads[1] = "/proc" end
  local tmp: integer?
  if merged.tmp == true then tmp = TMP_BYTES end
  return { reads = reads, writes = {}, binds = binds, tmp = tmp, tmp_exec = tmp_exec or nil }, "" -- checked: or_mix
end

--- Why a `u` grant cannot be held under `isolate` file, or "". Below
--- Landlock ABI 9 nothing tells one unix socket of the root from another
--- (the filter allows AF_UNIX to the program whole, and a read-only bind
--- does not stop a connect), so the root alone holds: it may show no
--- directory of the host, which may hold sockets a host service put
--- there, and no socket but one granted `u`. The sandbox's own /tmp is
--- no grant and holds only what the program makes. A `u` grant beside a
--- directory grant waits on ABI 9, at which Landlock holds it, unless
--- `nest` gives Landlock up, which leaves the root alone to.
-- TODO: hold a `u` grant beside a directory grant below ABI 9, once the
-- kernels the suite runs on give Landlock ABI 9 (core/sandbox_rules.c's
-- TODO on the same): the directory may hold a socket the grant does not
-- name, which the filter cannot tell from the granted one.
function Hold.unix_unheld(merged: Rules.Policy, base: string, nest: boolean): string
  local abi, _ = raw.landlock_abi()
  if not nest and (abi == nil or abi >= 9) then return "" end
  for _, grant in ipairs(Rules.paths(merged)) do
    local st, _ = sys.stat(named(grant.from or grant.path, base))
    local kind = if st ~= nil then st.kind else "" end
    if kind == "dir" or (kind == "socket" and not lettered(grant.letters, "u")) then
      local what = if kind == "dir" then "a directory" else "a socket without `u`" end
      if nest then
        return "a `u` grant under isolate file beside " .. what .. " (" ..
          string.format("%q", grant.path) .. ") needs Landlock, which calls \"nest\" gives " ..
          "up: the granted socket cannot be told from another socket in the root, and the " ..
          "root holds every socket a granted directory holds. Grant the socket alone (and " ..
          "files), or leave nest out"
      end
      return "a `u` grant under isolate file needs Landlock ABI 9 beside " .. what .. " (" ..
        string.format("%q", grant.path) .. "): this kernel gives ABI " .. tostring(abi) ..
        ", where the granted socket cannot be told from another socket in the root, and " ..
        "the root holds every socket a granted directory holds. Grant the socket alone " ..
        "(and files, and `tmp`), or run a kernel with ABI 9"
    end
  end
  return ""
end

--- Why a grant cannot be held by the root alone, which is all that holds
--- a program's files once `nest` gives up Landlock, or "". The root has a
--- bind that is writable or not and, where it is not given `x`, noexec:
--- it cannot tell writing a file from making or removing one in a
--- directory, nor running a file from reading it, as Landlock's `w` and
--- `c`, `x` and `r` do. So a directory granted one of `w` and `c` without
--- the other, a file granted `c` without `w`, and a grant of `x` without
--- `r` are refused, naming the letters to add.
function Hold.nest_unheld(merged: Rules.Policy, base: string): string
  for _, grant in ipairs(Rules.paths(merged)) do
    local letters = grant.letters
    local what = "grant " .. string.format("%q", grant.path) .. " (" .. letters .. ")"
    local st, _ = sys.stat(named(grant.from or grant.path, base))
    local directory = st ~= nil and st.kind == "dir"
    if lettered(letters, "x") and not lettered(letters, "r") then
      return what .. " runs files it cannot read, which a root cannot hold once \"nest\" gives " ..
        "up Landlock: add `r`"
    elseif lettered(letters, "c") and not lettered(letters, "w") then
      return what .. " creates what it cannot write, which a root cannot hold once \"nest\" gives " ..
        "up Landlock: add `w`"
    elseif directory and lettered(letters, "w") and not lettered(letters, "c") then
      return what .. " writes files but makes and removes none, which a root cannot hold once " ..
        "\"nest\" gives up Landlock: a writable directory is one a program may create in " ..
        "too; add `c`"
    end
  end
  return ""
end

--- Whether a grant of `merged` has `u`.
function Hold.isolated_unix(merged: Rules.Policy): boolean
  for _, grant in ipairs(Rules.paths(merged)) do
    if lettered(grant.letters, "u") then return true end
  end
  return false
end

--- What a process's pid is multiplied by to make a sandbox's serial
--- ([`Sandbox.user_id`]): an odd number, so processes whose pids are
--- near differ in it.
local PID_SPREAD <const> = 2481

--- The sandboxes this process has given a user: the part of the serial
--- that makes two of its own differ.
local sandbox_serial: integer = 0

--- The user this process runs as, which a program of a policy is not to
--- be where it is root. Where /proc/self/status is not there (macOS) it is
--- the real user.
--- TODO: return the effective user on macOS, once cosmic.sys carries
--- geteuid: a setuid program's real and effective users differ there.
local function effective_user(): integer
  local status, _ = Fs.read("/proc/self/status")
  local effective = if status ~= nil then status:match("\nUid:%s+%d+%s+(%d+)") else nil end
  local number = if effective ~= nil then math.tointeger(tonumber(effective)) else nil end
  return number or sys.getuid()
end

--- The group this process runs as, which a caller that is not root may
--- name as its program's, and which a root caller's namespace maps beside
--- its program's. Where /proc/self/status is not there (macOS) it is the
--- real group, until cosmic.sys carries getegid (the TODO of [`effective_user`]).
function Hold.effective_group(): integer
  local status, _ = Fs.read("/proc/self/status")
  local effective = if status ~= nil then status:match("\nGid:%s+%d+%s+(%d+)") else nil end
  local number = if effective ~= nil then math.tointeger(tonumber(effective)) else nil end
  return number or sys.getgid()
end
local effective_group = Hold.effective_group

--- The user and group a program runs as where this process is root,
--- which a program of a policy never is: nil with no reason where this
--- process is not root (the program then runs as it does, mapped as itself
--- in a user namespace of its own), and nil and why where `merged` names
--- another `user` or `group` than its own then; where it is root and may,
--- `merged`'s `user` and `group`, or else a user of its own from
--- [`Sandbox.user_id`]'s pool; nil and why where it is root but may not
--- map one -- it needs CAP_SETUID, CAP_SETGID and CAP_SETFCAP, and a user
--- namespace that maps the user.
function Hold.mapped_user(merged: Rules.Policy): MappedUser?, string
  local platform, _, _ = raw.sandbox_platform()
  local own = effective_user()
  if not platform and own == 0 then
    local merged_user = merged.user
    if merged_user ~= nil then
      return nil, "user " .. tostring(merged_user) .. ": a program runs as a user of the policy's only " ..
        "where it is sandboxed, on Linux"
    end
    return nil, ""
  end
  if own ~= 0 then
    local group = effective_group()
    local merged_group = merged.group
    local merged_user = merged.user
    if merged_user ~= nil and (merged_user ~= own or (merged_group ~= nil and merged_group ~= group)) then
      local merged_group2 = merged.group
      return nil, "user " .. tostring(merged_user) .. (if merged_group2 ~= nil then ", group " .. tostring(merged_group2) else "" end) ..
        ": only a root caller chooses the user its program runs as, and this process is user " ..
        tostring(own) .. ", group " .. tostring(group) .. ", which its program runs as: name that or none"
    end
    return nil, ""
  end
  local mayed, _, _ = raw.may_map_ids()
  -- TODO: ask only CAP_SETUID and CAP_SETGID of a policy that makes no
  -- namespace, whose child gives root up directly and maps nothing, once
  -- this is told the policy: a container that leaves out CAP_SETFCAP
  -- refuses that start today for a capability it does not use.
  if not mayed then
    return nil, "this process is root, and a program of a policy never runs as root: it runs " ..
      "as a user of its own, mapped into its user namespace from outside, which needs " ..
      "CAP_SETUID, CAP_SETGID and CAP_SETFCAP in effect here (a container may leave out " ..
      "CAP_SETFCAP: add it, or start from another user)"
  end
  local uid_map, _ = Fs.read("/proc/self/uid_map")
  local gid_map, _ = Fs.read("/proc/self/gid_map")
  if uid_map == nil or gid_map == nil then
    return nil, "this process's user and group maps cannot be read, so the user a program " ..
      "of a policy runs as (never root) cannot be chosen: /proc/self/uid_map"
  end
  local user = merged.user
  if user ~= nil then
    local group = merged.group or user
    if not Rules.maps_id(uid_map, user) or not Rules.maps_id(gid_map, group) then
      return nil, "user " .. tostring(user) .. " and group " .. tostring(group) .. ": this " ..
        "process's user namespace does not map both, so its program cannot run as them"
    end
    if Rules.in_pool(uid_map, gid_map, user) or Rules.in_pool(uid_map, gid_map, group) then
      return nil, "user " .. tostring(user) .. " and group " .. tostring(group) .. ": one is of the pool a " ..
        "root caller's sandboxes are each given a user from, which a concurrent one may be " ..
        "given: name one outside it"
    end
    return { uid = user, gid = group }, ""
  end
  sandbox_serial = sandbox_serial + 1
  local id, why = Rules.user_id(uid_map, gid_map, sys.getpid() * PID_SPREAD + sandbox_serial)
  if id == nil then return nil, why end
  return { uid = id, gid = id }, ""
end

--- Whether every directory above `path`, an absolute real path, may be
--- searched by `user`, the user of a root caller's sandbox, as it must to
--- reach it in the host's own tree: "" or the directory that may not.
local function unsearchable_above(path: string, user: MappedUser): string
  local at = Fs.dirname(path)
  while true do
    local st, _ = sys.stat(at)
    local by = if st ~= nil then Rules.reach("x", st, user.uid, user.gid).by else "other" end
    if by ~= "other" and by ~= "user" then return at end
    if at == "/" or at == "." then return "" end
    at = Fs.dirname(at)
  end
end

--- Which of `merged`'s grants `user`, the user of a root caller's sandbox,
--- can use only as their owner can ([`Sandbox.reach`]): those are mounted idmapped, so that user is the
--- owner, where `file` gives the sandbox a root of its own to mount them
--- in. Nil, and why, where one cannot be used either way, or, without
--- `file`, only as its owner can, which only that mount gives; naming it
--- and what to do. Without `file` every directory above a grant must also
--- be searchable by that user, and so must `base`, the directory the
--- program starts in, and, for `tmp`, TMPDIR's; under it the root is built without walking to a
--- grant. A grant that does not exist is left for the start's own report.
function Hold.reached_by(merged: Rules.Policy, base: string, file: boolean,
                         user: MappedUser): {integer: boolean}?, string
  if merged.tmp == true and not file then
    local tmpdir = Fs.temp_dir()
    local real, _ = sys.realpath(tmpdir)
    local above = if real ~= nil then unsearchable_above(real .. "/.", user) else "" end
    if above ~= "" then
      return nil, "tmp makes its directory in TMPDIR, " .. string.format("%q", tmpdir) ..
        ", which the user a root caller's program runs as cannot reach: " .. above ..
        " is not searchable by everyone; point TMPDIR at a directory everyone may search, " ..
        "or isolate \"file\", whose /tmp is a tmpfs of the sandbox's own"
    end
  end
  local idmap: mut {integer: boolean} = {}
  for index, grant in ipairs(Rules.paths(merged)) do
    local named_at = named(grant.from or grant.path, base)
    local real, _ = sys.realpath(named_at)
    local st: sys.Stat?
    if real ~= nil then
      local got, _ = sys.stat(real)
      st = got
    end
    if real ~= nil and st ~= nil then
      local reach = Rules.reach(grant.letters, st, user.uid, user.gid)
      local what = "grant " .. string.format("%q", grant.path) .. " (" .. real .. ")"
      if reach.by == "" then
        return nil, what .. " cannot be used by the user a root caller's program runs as, " ..
          "user " .. tostring(user.uid) .. ": " .. reach.lacks .. "; change its mode so it may"
      elseif reach.by == "owner" then
        if not file then
          return nil, what .. " is owned by user " .. tostring(st.uid) .. " and not open to the user a " ..
            "root caller's program runs as, user " .. tostring(user.uid) .. ", which is not its owner, so " ..
            "it cannot use it: change its mode, or isolate \"file\", which mounts it so that " ..
            "user owns it"
        end
        -- The mount shows the grant's owner as the program's user, and so
        -- cannot show that user's own files as its own too: a user
        -- namespace's map takes each outside id once. They show as the
        -- owner's instead (core/sandbox_root.c's swapped_map), which a
        -- policy's `user` reaches by their mode for everyone (and for the
        -- group, where it is the owner's).
        idmap[index] = true
      elseif not file then
        local above = unsearchable_above(real, user)
        if above ~= "" then
          return nil, what .. " is beneath the directory " .. above .. ", which the user a " ..
            "root caller's program runs as cannot search: change its mode, or isolate " ..
            "\"file\", which gives the program a root holding only what is granted"
        end
      end
    end
  end
  if not file then
    local above = unsearchable_above(base .. "/.", user)
    if above ~= "" then
      return nil, "the directory the program starts in, " .. string.format("%q", base) ..
        ", or one above it, " .. above .. ", cannot be searched by the user a root caller's " ..
        "program runs as: pass `cwd` of a directory everyone may search (this process's own is " ..
        "the default), or isolate \"file\""
    end
  end
  return idmap, ""
end

--- Where a root caller's programs run this program's core from: a
--- directory of root's, 0755, whose copies of the core are 0555 -- every
--- user may run one, and no one but root may write or swap one. It is in
--- /run, which every user may search and only root may write, as root's
--- own cache (in its home) is not searched and /tmp is written by all.
local SHARED_CORES <const> = "/run/cosmic-sandbox-cores"

--- Whether `st` is a directory of root's that no one else may write.
local function roots_alone(st: sys.Stat?): boolean
  return st ~= nil and st.kind == "dir" and st.uid == 0 and st.mode & 0x12 == 0
end

--- `core`, this program's core, where the user of a root caller's program
--- may run it: a copy in [`SHARED_CORES`], made once per core under a lock
--- there, so concurrent starts take one copy and none replaces another's.
--- Startup hashes it against the artifact's digest every start, as no
--- stamp is left beside it. The copy's path, or nil and why.
-- TODO: remove a copy no start has used for a while, as nothing prunes
-- the launcher's own cores directory either, once that has a rule to
-- share: each core a host's root runs this program under leaves one.
local function shared_core(core: string): string?, string
  local name = core:match("([^/]+)$")
  if name == nil or not name:find("^core%-") then
    return nil, core .. " is not a cached core of this program"
  end
  local parent = Fs.dirname(SHARED_CORES)
  local up, _ = sys.lstat(parent)
  if not roots_alone(up) then
    return nil, parent .. " is not a directory of root's that only root may write, where " ..
      "the copy of this program's core a root caller's program runs is kept"
  end
  local made, made_trouble, made_errno = sys.mkdir(SHARED_CORES, 0x1ed)
  if made then
    local shut, shut_trouble = sys.chmod(SHARED_CORES, 0x1ed)
    if not shut then return nil, SHARED_CORES .. ": " .. shut_trouble end
  elseif made_errno ~= sys.EEXIST then
    return nil, SHARED_CORES .. ": " .. made_trouble
  end
  local st, _ = sys.lstat(SHARED_CORES)
  if st == nil or not roots_alone(st) or st.mode & 0xfff ~= 0x1ed then
    return nil, SHARED_CORES .. " is not a directory of root's, mode 0755: remove it, and the " ..
      "next start makes it again"
  end
  local lock, lock_trouble = sys.open(SHARED_CORES .. "/.lock", sys.O_RDWR | sys.O_CREAT, 0x180)
  if lock == nil then return nil, SHARED_CORES .. "/.lock: " .. lock_trouble end
  local locked, locked_trouble = sys.flock(lock, "exclusive", -1)
  if not locked then
    local _, _ = sys.close(lock)
    return nil, SHARED_CORES .. "/.lock: " .. locked_trouble
  end
  local copy = SHARED_CORES .. "/" .. name
  local failure = ""
  local there, _ = sys.lstat(copy)
  if there == nil or there.kind ~= "file" or there.uid ~= 0 or there.mode & 0xfff ~= 0x16d then
    local data, read_trouble = Fs.read(core)
    if data == nil then
      failure = core .. ": " .. tostring(read_trouble)
    else
      local staged = SHARED_CORES .. "/.staged-" .. tostring(sys.getpid())
      local wrote, write_trouble = Fs.write(staged, data, 0x16d)
      local ok, trouble = wrote, if wrote then "" else tostring(write_trouble) end
      if ok then ok, trouble = sys.chmod(staged, 0x16d) end
      if ok then ok, trouble = sys.rename(staged, copy) end
      if not ok then
        local _, _ = sys.unlink(staged)
        failure = copy .. ": " .. trouble
      end
    end
  end
  local _, _ = sys.close(lock)
  if failure ~= "" then return nil, failure end
  return copy, ""
end

--- The descriptor open on each shared copy of the core, by its path: one
--- serves every start, as [`Proc.relaunch`]'s does; a spawn hands a child
--- only the descriptors it names.
local shared_fds: mut {string:integer} = {}

--- How a policy's program that is this program starts: by a relaunch of
--- its core ([`Proc.relaunch`]), past the launcher, which would fork and
--- unpack a core into a cache the policy does not give it. `user` is the
--- user a root caller's program runs as, which runs a copy of the core it
--- may run ([`shared_core`]); nil for this process's own. With a
--- `database`, the result is the split shape, the core on that file
--- (`core --database <real path>`), whatever this process runs on, with
--- no descriptor to hand on; a core already run against a database
--- relaunches so too, on its own. Nil and "" where this program has no
--- core to start past its own start (a host program), or nil and why.
function Hold.relaunch_of(user: MappedUser?, database?: string): Proc.Relaunch?, string
  local launched, _ = Proc.relaunch()
  if launched == nil then return nil, "" end
  local portable = launched.env["COSMIC_PORTABLE_CORE_FD"] ~= nil
  if not portable and launched.argv[2] ~= "--database" then return nil, "" end
  if database ~= nil then
    local real, real_trouble = sys.realpath(database)
    if real == nil then return nil, "database " .. database .. ": " .. real_trouble end
    launched = { argv = { launched.argv[1], "--database", real }, env = {}, fds = {}, -- checked: index_may_be_nil
      cwd = launched.cwd }
    portable = false
  end
  if user == nil then return launched, "" end
  local copy, trouble = shared_core(launched.argv[1]) -- checked: index_may_be_nil
  if copy == nil then return nil, trouble end
  if not portable then
    local argv: mut {string} = { copy }
    table.move(launched.argv, 2, #launched.argv, #argv + 1, argv)
    return { argv = argv, env = launched.env, fds = launched.fds, cwd = launched.cwd }, ""
  end
  -- The copy may have been removed and made again since it was opened
  -- (a /run cleared, a hand): the descriptor handed on must be the file
  -- the child runs, which its startup holds it to.
  local fd = shared_fds[copy]
  if fd ~= nil then
    local held, _ = sys.fstat(fd)
    local named_now, _ = sys.lstat(copy)
    if held == nil or named_now == nil or held.ino ~= named_now.ino or held.dev ~= named_now.dev then
      local _, _ = sys.close(fd)
      shared_fds[copy] = nil
      fd = nil
    end
  end
  if fd == nil then
    local handle, open_trouble = sys.open(copy, sys.O_RDONLY)
    if handle == nil then return nil, copy .. ": " .. open_trouble end
    fd = handle
    shared_fds[copy] = fd
  end
  local core_fd = math.tointeger(tonumber(launched.env["COSMIC_PORTABLE_CORE_FD"]))
  local fds: mut {integer:integer} = {}
  for number, given in pairs(launched.fds) do fds[number] = number == core_fd and fd or given end -- checked: and_ternary
  local argv: mut {string} = { copy }
  table.move(launched.argv, 2, #launched.argv, #argv + 1, argv)
  return { argv = argv, env = launched.env, fds = fds, cwd = launched.cwd }, ""
end

--- Whether the file at `path`, the database a policy's program runs on,
--- is the one `database` names: true where it hashes to the policy's
--- `sha256`, or where the policy holds none; otherwise false and why.
function Hold.database_holds(database: Rules.Database, path: string): boolean, string
  local digest = database.sha256
  if digest == nil then return true, "" end
  local bytes, why = Fs.read(path)
  if bytes == nil then return false, "database " .. tostring(why) end
  if Hash.hex_sha256(bytes) ~= digest then
    return false, "database " .. path .. " is not the one its policy names: " ..
      "its SHA-256 has changed since"
  end
  return true, ""
end

--- This program's own file's real path ([`Proc.executable`]) where `name`,
--- a policy's program as the caller names it, from `cwd` (this process's
--- own where nil), is it; nil for any other program.
function Hold.this_program(name: string, cwd: string?): string?
  local executable, _ = Proc.executable()
  if executable == nil then return nil end
  local own, _ = sys.realpath(executable)
  if own == nil then return nil end
  local found: string = name
  if not name:find("/", 1, true) then
    local on_path, _ = Proc.find(name)
    if on_path == nil then return nil end
    found = on_path
  elseif cwd ~= nil and name:sub(1, 1) ~= "/" then
    found = cwd .. "/" .. name
  end
  local real, _ = sys.realpath(found)
  if real ~= own then return nil end
  return own
end

--- The path of the first of `grants` that reaches `file`, a real path
--- (the grant is at it or above it, where it is a directory), as the
--- grant names it; "" for none. A relative grant is from `base`, this
--- process's own directory where nil; one with `from` reaches what `from`
--- names. A guard against a policy that grants the file by accident: a
--- hard link, a copy or a bind-mounted view of it elsewhere in a granted
--- directory still reads the program, so it does not hold against a
--- policy author who means to reach it.
function Hold.reaching(file: string, grants: {Rules.Path}, base: string?): string
  for _, grant in ipairs(grants) do
    local at = grant.from or grant.path
    if base ~= nil and at:sub(1, 1) ~= "/" then at = base .. "/" .. at end
    local real, _ = sys.realpath(at)
    if beneath(file, real or at) then return grant.path end
  end
  return ""
end

--- The kernel's release, as uname(2) reports it, or "" where it fails.
local function kernel_release(): string
  local names, _ = sys.uname()
  return if names ~= nil then names.release else "" end
end

--- What a program started under `isolate` with no `processes` of its
--- own is held to: the count of its whole user namespace.
local DEFAULT_PROCESSES <const> = 4096

--- The `processes` limit a start sets, as RLIMIT_NPROC, or nil for none,
--- and why not: the policy's own, or [`DEFAULT_PROCESSES`] under `isolate`,
--- both held by the kernel's count of the processes and threads of the
--- sandbox's user namespace, which only a kernel from Linux 5.17 keeps
--- apart from its creator's (an older one's counts every process of the
--- user the namespace was made by, so a limit would hold the caller's
--- other processes too). The default is dropped where the kernel is
--- older, and a limit the policy names fails there; either is lowered
--- to this process's hard limit if that is lower, but only the default
--- may be: a limit the policy names above it fails.
function Hold.process_limit(merged: Rules.Policy, isolated: boolean): integer?, string
  local named_limit = (merged.limits or {}).processes
  if not isolated then return nil, "" end
  local release = kernel_release()
  if release ~= "" and not Rules.counts_per_namespace(release) then
    if named_limit == nil then return nil, "" end
    return nil, "limits.processes needs a kernel that counts the processes of a user " ..
      "namespace apart from its creator's user, Linux 5.17 or a stable kernel with the fix: " ..
      "this one is " .. release
  end
  local wanted = named_limit or DEFAULT_PROCESSES
  local held, _ = sys.getrlimit(sys.RLIMIT_NPROC)
  if held ~= nil and held.hard < wanted then
    if named_limit ~= nil then
      return nil, "limits.processes " .. tostring(named_limit) .. " is above this process's own hard " ..
        "limit on processes, " .. tostring(held.hard) .. ", which a child cannot raise"
    end
    return held.hard, ""
  end
  return wanted, ""
end

--- Why a policy with `connect` may not have the environment it names, or
--- "": the proxy variables the relay sets are not the policy's to set.
function Hold.reserved_by_relay(merged: Rules.Policy): string
  if #Rules.connects(merged) == 0 then return "" end
  local variables: mut {string} = {}
  for _, name in ipairs(merged.env or {}) do variables[#variables + 1] = name end
  for name, _ in pairs(merged.set_env or {}) do variables[#variables + 1] = name end
  table.sort(variables)
  local reserved = RelayConfig.reserved(variables)
  if reserved == "" then return "" end
  return "sandbox: " .. reserved .. " is set by the relay that serves connect \"" ..
    Rules.connects(merged)[1] .. "\" (the proxy variables point the program at it), so the policy " .. -- checked: nil_not_allowed
    "may not name it in env or set_env"
end

local holds_by_seatbelt <const> = Rules.on_macos
Hold.holds_by_seatbelt = holds_by_seatbelt

--- Whether a program of `merged` may be started on macOS as the policy
--- says: "" or why not ([`Seatbelt.credentials_unmet`], told this process's
--- ids). Seatbelt holds a program but changes no user or group, and the core
--- carries credentials on Linux alone, so the program runs as this process
--- does.
--- TODO: run the program as the policy's `user` and `group`, and drop root,
--- once core/sandbox_root.c carries credentials outside Linux (#2852).
function Hold.seatbelt_credentials(merged: Rules.Policy): string
  return Seatbelt.credentials_unmet(merged, effective_user(), effective_group())
end

--- `p` with `extra` grants beside its own, every other field as it is:
--- the policy a profile is compiled from once the start grants its
--- program's start files, unmerged, as [`Seatbelt.compile`] takes it.
function Hold.with_grants(p: Rules.Policy, extra: {Rules.Path}): Rules.Policy
  local grants: mut {Rules.Grant} = {}
  for _, grant in ipairs(p.grants or {}) do grants[#grants + 1] = grant end
  for _, grant in ipairs(extra) do grants[#grants + 1] = grant end
  local result: Rules.Policy = {
    grants = grants, isolate = p.isolate,
    loopback = p.loopback, env = p.env, set_env = p.set_env,
    set_env_digests = p.set_env_digests, tmp = p.tmp, limits = p.limits,
    user = p.user, group = p.group, database = p.database, profiles = p.profiles,
  }
  return result
end

--- Points the program of `held`, held by Seatbelt, at its relay, which
--- serves at `port` of the host's loopback behind `token`: its profile is
--- compiled again to reach that port, and its environment names it. "" or
--- why not.
function Hold.relay_held(held: Held, port: integer, token: string): string
  local options = assert(held.seatbelt_options)
  options.relay_port = port
  local profile, trouble = Seatbelt.compile(assert(held.seatbelt_policy), options)
  if profile == nil then return trouble end
  assert(held.sandbox.seatbelt).profile = profile.text -- checked: field_fixed
  for name, value in pairs(RelayConfig.proxy_env({}, port, token, held.relay)) do
    held.env[name] = value
  end
  return ""
end

--- Hands `held`'s Seatbelt profile and its parameters to the cosmic core
--- it starts, which applies them at boot (core/main.c), and leaves the
--- trampoline none to apply (its `boot`). The parameters are each name and value
--- "<length>:<bytes>", after [`make_tmp`] and [`relay_held`] have
--- set the last of them.
function Hold.seatbelt_boot_env(held: Held)
  local seatbelt = assert(held.sandbox.seatbelt)
  local words: mut {string} = {}
  for name, value in pairs(seatbelt.parameters) do
    words[#words + 1] = tostring(#name) .. ":" .. name .. tostring(#value) .. ":" .. value
  end
  table.sort(words)
  held.env["COSMIC_SEATBELT_PROFILE"] = seatbelt.profile
  held.env["COSMIC_SEATBELT_PARAMETERS"] = table.concat(words)
end

--- `grants` as the core reads them at boot (core/sandbox_rules.c's
--- `cosmic_boot_layer_apply`): each "<letters> <length>:<path>" and a
--- newline, so a path may hold any byte but NUL.
function Hold.layer_text(grants: {raw_process.Grant}): string
  local parts: mut {string} = {}
  for _, grant in ipairs(grants) do
    parts[#parts + 1] = grant.access .. " " .. tostring(#grant.path) .. ":" .. grant.path .. "\n"
  end
  return table.concat(parts)
end

--- Makes the temporary directory a policy's `tmp` asks for, as an absolute
--- path whatever TMPDIR is (the child may start in another directory),
--- grants it `rwc` and names it in TMPDIR; it is the child's user's,
--- where that is not this process's. "" or why not.
function Hold.make_tmp(held: Held): string
  local dir, trouble = Fs.mkdtemp("cosmic-sandbox-")
  if dir == nil then return "tmp: " .. tostring(trouble) end
  local real, real_trouble = sys.realpath(dir)
  if real == nil then
    local _, _ = Fs.remove_tree(dir)
    return "tmp: " .. dir .. ": " .. real_trouble
  end
  local user = held.user
  if user ~= nil then
    local given, given_trouble = sys.chown(real, user.uid, user.gid)
    if not given then
      local _, _ = Fs.remove_tree(dir)
      return "tmp: " .. real .. ": " .. given_trouble
    end
  end
  held.tmp = real
  if held.seatbelt == true then
    -- The profile grants the directory through a parameter, left for this.
    assert(held.sandbox.seatbelt).parameters[assert(held.tmp_parameter)] = real -- checked: view_written
  else
    local grants = assert(held.sandbox.grants)
    grants[#grants + 1] = { path = real, access = "rwc" } -- checked: view_written
    local layer = held.layer
    if layer ~= nil then layer[#layer + 1] = { path = real, access = "rwc" } end
  end
  held.env.TMPDIR = real -- checked: map_field
  return ""
end

--- Why a descriptor the child would get cannot be handed to a `nest`
--- child, or "". Landlock, given up there, is what stopped a descriptor
--- reaching past itself: a directory is a way to every file beneath and
--- above it (/proc/self/fd/N/..), and a regular file opened read-only or
--- write-only is reopened through /proc/self/fd/N for what it was not
--- opened for, where its owner (this process's user) may. The root holds no
--- descriptor. So a directory, or a regular file not open for both, is
--- refused, naming it; pipes, sockets and devices have no path to reach.
--- `slots` is `wire` in [`cosmic.child`]'s: the descriptor each child number copies, and
--- 0 to 2 not in it are this process's own.
function Hold.nest_descriptors(slots: {integer:integer}): string
  local numbers: mut {integer} = {}
  for number, _ in pairs(slots) do numbers[#numbers + 1] = number end
  for number = 0, 2 do
    if slots[number] == nil then numbers[#numbers + 1] = number end
  end
  table.sort(numbers)
  for _, number in ipairs(numbers) do
    local fd = slots[number] or number
    local what = "descriptor " .. tostring(number) .. (if fd ~= number then " (this process's " .. tostring(fd) .. ")" else "" end)
    -- The descriptors the runtime retains of its own (its artifact and core,
    -- which a relaunch hands on) are refused to every binding that takes a
    -- descriptor, a stat included, by raising; any other raise is rethrown.
    local looked, st = pcall(sys.fstat, fd)
    if not looked and not tostring(st):find("retained", 1, true) then error(st, 0) end
    if not looked then
      return what .. " is one this runtime retains of its own (its artifact or core), which " ..
        "calls \"nest\" cannot hand a program: it is a file open for reading alone"
    end
    if st ~= nil and st.kind == "dir" then
      return what .. " is a directory, which calls \"nest\" cannot hand a program: " ..
        "with Landlock given up, /proc/self/fd/" .. string.format("%d", number) .. " opens every file beneath " ..
        "it and, by .., above it, and the root of its own holds no descriptor"
    elseif st ~= nil and st.kind == "file" then
      local info, _ = Fs.read("/proc/self/fdinfo/" .. tostring(fd))
      local flags = if info ~= nil then info:match("flags:%s*(%d+)") else nil end
      local mode = if flags ~= nil then (math.tointeger(tonumber(flags, 8)) or 0) & 3 else nil end
      if mode ~= 2 then
        return what .. " is a file not open for reading and writing, which promises " ..
          "\"nest\" cannot hand a program: with Landlock given up, /proc/self/fd/" ..
          string.format("%d", number) .. " reopens it for what it was not opened for wherever its owner may; " ..
          "open it O_RDWR, or pass a pipe"
      end
    end
  end
  return ""
end

--- The module the network relay's process runs: the main of a database
--- sealed for it ([`cosmic.internal.relay_main`]), which this module cannot require
--- (it and what it requires start children through this one).
local RELAY_MAIN <const> = "cosmic.internal.relay_main"
Hold.RELAY_MAIN = RELAY_MAIN

return Hold
