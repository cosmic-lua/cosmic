--- The promises filter (core/promises.c) as the kernel would run it:
--- `promise_filter` builds the seccomp program for either architecture
--- from any host, and a small interpreter of classic BPF here runs it
--- against calls this test makes up -- a number, its arguments and an
--- architecture -- as seccomp would, so every promise is held to what it
--- allows and refuses on x86_64 and on aarch64 whatever this host is.
--- The calls a promise lets a live child make, and what a kernel does
--- with the program, are core/promises_child_test.tl's, and a dynamic
--- program's core/promises_system_test.tl's.

local type raw_process = require("cosmic.internal.process")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

local type Searcher = function(string): any, any

--- The raw table the store's searcher hands `wrapper`'s loader, as
--- `require` would hand it.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error(wrapper .. " is handed no raw table")
end

local process = raw_behind("cosmic.child") as raw_process -- cast: the table core/process.h declares

local AUDIT: {string: integer} = { x86_64 = 0xc000003e, aarch64 = 0xc00000b7 }
local ARCHES: {string} = { "x86_64", "aarch64" }

local ALLOW <const> = 0x7fff0000
local KILL_PROCESS <const> = 0x80000000
local ERRNO <const> = 0x00050000

--- Every call this test names, by its number on x86_64 and aarch64 --
--- from the kernel's asm/unistd_64.h of each, apart from the table in
--- core/promises_calls.h this checks: nil where an architecture has no
--- such call.
local numbers: {string: {integer}} = {
  ["madvise"] = { 28, 233 },
  ["sched_setattr"] = { 314, 274 },
  ["read"] = { 0, 63 },
  ["write"] = { 1, 64 },
  ["open"] = { 2 },
  ["close"] = { 3, 57 },
  ["stat"] = { 4 },
  ["poll"] = { 7 },
  ["mmap"] = { 9, 222 },
  ["mprotect"] = { 10, 226 },
  ["munmap"] = { 11, 215 },
  ["brk"] = { 12, 214 },
  ["rt_sigaction"] = { 13, 134 },
  ["rt_sigprocmask"] = { 14, 135 },
  ["ioctl"] = { 16, 29 },
  ["access"] = { 21 },
  ["pipe"] = { 22 },
  ["select"] = { 23 },
  ["sched_yield"] = { 24, 124 },
  ["shmget"] = { 29, 194 },
  ["dup2"] = { 33 },
  ["getpid"] = { 39, 172 },
  ["socket"] = { 41, 198 },
  ["sendmsg"] = { 46, 211 },
  ["recvmsg"] = { 47, 212 },
  ["shutdown"] = { 48, 210 },
  ["socketpair"] = { 53, 199 },
  ["clone"] = { 56, 220 },
  ["fork"] = { 57 },
  ["vfork"] = { 58 },
  ["execve"] = { 59, 221 },
  ["wait4"] = { 61, 260 },
  ["kill"] = { 62, 129 },
  ["msgget"] = { 68, 186 },
  ["fcntl"] = { 72, 25 },
  ["getdents"] = { 78 },
  ["mkdir"] = { 83 },
  ["creat"] = { 85 },
  ["readlink"] = { 89 },
  ["chmod"] = { 90 },
  ["fchmod"] = { 91, 52 },
  ["chown"] = { 92 },
  ["fchown"] = { 93, 55 },
  ["lchown"] = { 94 },
  ["getrlimit"] = { 97, 163 },
  ["ptrace"] = { 101, 117 },
  ["setuid"] = { 105, 146 },
  ["setgid"] = { 106, 144 },
  ["setpgid"] = { 109, 154 },
  ["setresuid"] = { 117, 147 },
  ["getpgid"] = { 121, 155 },
  ["getsid"] = { 124, 156 },
  ["capget"] = { 125, 90 },
  ["rt_sigqueueinfo"] = { 129, 138 },
  ["sigaltstack"] = { 131, 132 },
  ["mknod"] = { 133 },
  ["getpriority"] = { 140, 141 },
  ["setpriority"] = { 141, 140 },
  ["sched_setscheduler"] = { 144, 119 },
  ["pivot_root"] = { 155, 41 },
  ["prctl"] = { 157, 167 },
  ["arch_prctl"] = { 158 },
  ["setrlimit"] = { 160, 164 },
  ["chroot"] = { 161, 51 },
  ["mount"] = { 165, 40 },
  ["umount2"] = { 166, 39 },
  ["reboot"] = { 169, 142 },
  ["init_module"] = { 175, 105 },
  ["delete_module"] = { 176, 106 },
  ["setxattr"] = { 188, 5 },
  ["fsetxattr"] = { 190, 7 },
  ["removexattr"] = { 197, 14 },
  ["tkill"] = { 200, 130 },
  ["futex"] = { 202, 98 },
  ["sched_setaffinity"] = { 203, 122 },
  ["sched_getaffinity"] = { 204, 123 },
  ["getdents64"] = { 217, 61 },
  ["set_tid_address"] = { 218, 96 },
  ["clock_gettime"] = { 228, 113 },
  ["exit_group"] = { 231, 94 },
  ["tgkill"] = { 234, 131 },
  ["utimes"] = { 235 },
  ["kexec_load"] = { 246, 104 },
  ["add_key"] = { 248, 217 },
  ["request_key"] = { 249, 218 },
  ["keyctl"] = { 250, 219 },
  ["openat"] = { 257, 56 },
  ["mkdirat"] = { 258, 34 },
  ["mknodat"] = { 259, 33 },
  ["fchownat"] = { 260, 54 },
  ["newfstatat"] = { 262, 79 },
  ["unlinkat"] = { 263, 35 },
  ["fchmodat"] = { 268, 53 },
  ["unshare"] = { 272, 97 },
  ["set_robust_list"] = { 273, 99 },
  ["get_robust_list"] = { 274, 100 },
  ["vmsplice"] = { 278, 75 },
  ["utimensat"] = { 280, 88 },
  ["epoll_pwait"] = { 281, 22 },
  ["pipe2"] = { 293, 59 },
  ["rt_tgsigqueueinfo"] = { 297, 240 },
  ["perf_event_open"] = { 298, 241 },
  ["prlimit64"] = { 302, 261 },
  ["name_to_handle_at"] = { 303, 264 },
  ["open_by_handle_at"] = { 304, 265 },
  ["setns"] = { 308, 268 },
  ["process_vm_readv"] = { 310, 270 },
  ["process_vm_writev"] = { 311, 271 },
  ["finit_module"] = { 313, 273 },
  ["renameat2"] = { 316, 276 },
  ["seccomp"] = { 317, 277 },
  ["getrandom"] = { 318, 278 },
  ["memfd_create"] = { 319, 279 },
  ["kexec_file_load"] = { 320, 294 },
  ["bpf"] = { 321, 280 },
  ["execveat"] = { 322, 281 },
  ["userfaultfd"] = { 323, 282 },
  ["pkey_mprotect"] = { 329, 288 },
  ["pkey_alloc"] = { 330, 289 },
  ["pkey_free"] = { 331, 290 },
  ["rseq"] = { 334, 293 },
  ["pidfd_send_signal"] = { 424, 424 },
  ["io_uring_setup"] = { 425, 425 },
  ["io_uring_enter"] = { 426, 426 },
  ["io_uring_register"] = { 427, 427 },
  ["sethostname"] = { 170, 161 },
  ["mount_setattr"] = { 442, 442 },
  ["open_tree"] = { 428, 428 },
  ["move_mount"] = { 429, 429 },
  ["fsopen"] = { 430, 430 },
  ["fsconfig"] = { 431, 431 },
  ["fsmount"] = { 432, 432 },
  ["fspick"] = { 433, 433 },
  ["pidfd_open"] = { 434, 434 },
  ["clone3"] = { 435, 435 },
  ["openat2"] = { 437, 437 },
  ["pidfd_getfd"] = { 438, 438 },
  ["process_madvise"] = { 440, 440 },
  ["landlock_create_ruleset"] = { 444, 444 },
  ["landlock_add_rule"] = { 445, 445 },
  ["landlock_restrict_self"] = { 446, 446 },
  ["fchmodat2"] = { 452, 452 },
}

local type Insn = record
  code: integer
  jt: integer
  jf: integer
  k: integer
end

--- A program's instructions, from the eight bytes each is: a 16-bit
--- code, two 8-bit jumps and a 32-bit operand, little-endian.
local function decode(program: string): {Insn}
  assert(#program > 0 and #program % 8 == 0, "a program is whole instructions")
  assert(#program // 8 <= 4096, "the kernel takes 4096 instructions at most")
  local insns: {Insn} = {}
  for at = 1, #program, 8 do
    local jt, jf = string.byte(program, at + 2, at + 3)
    insns[#insns + 1] = {
      code = string.unpack("<I2", program, at), jt = jt, jf = jf,
      k = string.unpack("<I4", program, at + 4),
    }
  end
  return insns
end

--- What seccomp's interpreter does with `insns` for one call: the
--- program's return value. Only the instructions the filter is made of
--- (a load of seccomp_data, an AND, a jump, an equality, an unsigned
--- greater-than and at-least, a test of bits, a return); jumps go forward
--- only, as the kernel requires, and every path must end in a return.
local function run(insns: {Insn}, arch: integer, number: integer, args: {integer}): integer
  local function word(offset: integer): integer
    if offset == 0 then return number & 0xffffffff end
    if offset == 4 then return arch end
    assert(offset >= 16 and offset % 4 == 0 and offset < 64, "a load outside seccomp_data")
    local value = args[(offset - 16) // 8 + 1] or 0
    if offset % 8 == 0 then return value & 0xffffffff end
    return (value >> 32) & 0xffffffff
  end
  local a = 0
  local pc = 1
  while true do
    local insn = insns[pc]
    assert(insn ~= nil, "the program ran off its end at " .. pc)
    local code, k = insn.code, insn.k
    pc = pc + 1
    if code == 0x20 then
      a = word(k)
    elseif code == 0x54 then
      a = a & k
    elseif code == 0x05 then
      pc = pc + k
    elseif code == 0x15 then
      pc = pc + (a == k and insn.jt or insn.jf)
    elseif code == 0x25 then
      pc = pc + (a > k and insn.jt or insn.jf)
    elseif code == 0x35 then
      pc = pc + (a >= k and insn.jt or insn.jf)
    elseif code == 0x45 then
      pc = pc + ((a & k) ~= 0 and insn.jt or insn.jf)
    elseif code == 0x06 then
      return k
    else
      error(string.format("instruction %d has code 0x%x, which the filter never uses", pc - 1, code))
    end
  end
end

--- What a program's return value says, in words.
local function verdict(value: integer): string
  if value == ALLOW then return "allow" end
  if value == KILL_PROCESS then return "kill" end
  if value & 0xffff0000 == ERRNO then
    local errno = value & 0xffff
    if errno == 1 then return "EPERM" end
    if errno == 25 then return "ENOTTY" end
    if errno == 38 then return "ENOSYS" end
    return "errno " .. errno
  end
  return string.format("0x%x", value)
end

local type Case = record
  name: string
  want: string
  args: {integer}
end

--- A call that must get `want`, with these arguments (the rest are 0).
local function call(name: string, want: string, ...: integer): Case
  return { name = name, want = want, args = { ... } }
end

--- Runs `cases` against the program for `promises` on `arch`, saying
--- which call got what.
local function holds(promises: {string}, arch: string, cases: {Case},
                     options?: raw_process.PromiseOptions)
  local insns = decode(process.promise_filter(promises, arch, options))
  for _, case in ipairs(cases) do
    local both = numbers[case.name]
    assert(both ~= nil, case.name .. " is in no table of this test")
    local number = arch == "x86_64" and both[1] or both[2]
    if number ~= nil then
      local got = verdict(run(insns, AUDIT[arch], number, case.args))
      local shown: {string} = {}
      for _, value in ipairs(case.args) do shown[#shown + 1] = tostring(value) end
      assert(got == case.want, string.format("%s: %s(%s) on %s with {%s} is %s, not %s",
        table.concat(promises, "+"), case.name, tostring(number), arch,
        table.concat(shown, ","), got, case.want))
    end
  end
end

--- Every architecture's program for `promises` holds `cases`.
local function holds_on_both(promises: {string}, cases: {Case},
                             options?: raw_process.PromiseOptions)
  for _, arch in ipairs(ARCHES) do holds(promises, arch, cases, options) end
end

local PROT_READ <const> = 1
local PROT_WRITE <const> = 2
local PROT_EXEC <const> = 4
local MAP_PRIVATE <const> = 2
local MAP_ANONYMOUS <const> = 0x20
local O_CREAT <const> = 0x40
local MFD_NOEXEC_SEAL <const> = 8
local SIGCHLD <const> = 17

--- clone's flags: what a thread is made with, as musl's pthread_create
--- gives them, and the ones that make a namespace.
local THREAD <const> = 0x100 | 0x200 | 0x400 | 0x800 | 0x10000 | 0x40000 | 0x80000 | 0x100000 | 0x200000 | 0x400000
local VFORK_CLONE <const> = 0x4000 | 0x100 | SIGCHLD
local NAMESPACES: {integer} = {
  0x00020000, 0x02000000, 0x04000000, 0x08000000, 0x10000000, 0x20000000, 0x40000000,
}

--- Every call a sandbox never has, whatever it promised: each reaches
--- another process's memory or descriptors, the kernel, or calls this
--- filter cannot see.
local NEVER: {string} = {
  "ptrace", "process_vm_readv", "process_vm_writev", "fsopen", "fsmount", "fsconfig",
  "fspick", "bpf", "perf_event_open", "kexec_load", "kexec_file_load", "init_module",
  "finit_module", "delete_module", "add_key", "request_key", "keyctl", "io_uring_setup",
  "io_uring_enter", "io_uring_register", "userfaultfd", "setns", "name_to_handle_at",
  "open_by_handle_at", "pidfd_getfd", "process_madvise", "vmsplice", "setuid", "setgid",
  "setresuid", "chroot", "sethostname", "reboot", "pidfd_send_signal", "sched_setattr",
}

--- The calls that reach the program's own namespaces and mounts, which
--- only `nest` grants.
local NESTED: {string} = {
  "mount", "umount2", "pivot_root", "move_mount", "open_tree", "mount_setattr", "unshare",
}

local function never(): {Case}
  local cases: {Case} = {}
  for _, name in ipairs(NEVER) do cases[#cases + 1] = call(name, "EPERM") end
  for _, name in ipairs(NESTED) do cases[#cases + 1] = call(name, "EPERM") end
  return cases
end

local function test_the_basics_allow_what_every_program_has()
  holds_on_both({}, {
    call("read", "allow"), call("write", "allow"), call("close", "allow"),
    call("openat", "allow", -100, 0, 0, 0), call("newfstatat", "allow"),
    call("getdents64", "allow"), call("execve", "allow"), call("execveat", "allow"),
    call("exit_group", "allow"), call("futex", "allow"), call("getrandom", "allow"),
    call("clock_gettime", "allow"), call("brk", "allow"), call("rt_sigaction", "allow"),
    call("rt_sigprocmask", "allow"), call("set_tid_address", "allow"),
    call("set_robust_list", "allow"), call("rseq", "allow"), call("pipe2", "allow"),
    call("poll", "allow"), call("epoll_pwait", "allow"), call("wait4", "allow"),
    call("landlock_create_ruleset", "allow"), call("landlock_add_rule", "allow"),
    call("landlock_restrict_self", "allow"), call("seccomp", "allow"),
    call("sched_yield", "allow"), call("munmap", "allow"), call("getpid", "allow"),
    call("sigaltstack", "allow"), call("renameat2", "allow"), call("unlinkat", "allow"),
    -- What a loader and a libc ask before main, on the architectures that have them.
    call("arch_prctl", "allow"), call("readlink", "allow"), call("access", "allow"),
    call("open", "allow", 0, 0, 0), call("stat", "allow"), call("getdents", "allow"),
    call("select", "allow"), call("dup2", "allow"), call("pipe", "allow"),
  })
end

local function test_the_basics_refuse_what_reaches_past_the_process()
  holds_on_both({}, never())
  holds_on_both({}, {
    call("fork", "EPERM"), call("vfork", "EPERM"), call("pidfd_open", "EPERM"),
    call("chmod", "EPERM", 0, 0x1a4), call("fchmodat", "EPERM", -100, 0, 0x1a4),
    call("chown", "EPERM"), call("utimensat", "EPERM"), call("setxattr", "EPERM"),
    call("socket", "EPERM", 2, 1, 0), call("socket", "EPERM", 1, 1, 0),
    call("socket", "EPERM", 16, 3, 0), call("socket", "EPERM", 17, 3, 0),
    call("setrlimit", "EPERM"), call("shmget", "EPERM"), call("msgget", "EPERM"),
  })
end

local function test_a_call_above_the_reviewed_table_answers_ENOSYS()
  for _, arch in ipairs(ARCHES) do
    local insns = decode(process.promise_filter({ "fork", "jit", "fattr" }, arch))
    local reviewed = process.PROMISE_CALLS_REVIEWED
    for _, number in ipairs({ reviewed, reviewed + 1, 1000, 0x7fffffff, 0xffffffff }) do
      local got = verdict(run(insns, AUDIT[arch], number, {}))
      assert(got == "ENOSYS", arch .. " call " .. number .. " is " .. got)
    end
    -- The highest call reviewed is within the table, so a call there is
    -- judged, not answered as unknown.
    local last = verdict(run(insns, AUDIT[arch], reviewed - 1, {}))
    assert(last == "EPERM", arch .. " call " .. (reviewed - 1) .. " is " .. last)
  end
  -- x32's calls share x86_64's architecture and set a high bit.
  local insns = decode(process.promise_filter({ "fork", "jit", "fattr" }, "x86_64"))
  assert(verdict(run(insns, AUDIT.x86_64, 0x40000000 + numbers.read[1], {})) == "ENOSYS")
end

local function test_clone3_and_openat2_answer_ENOSYS_whatever_was_promised()
  for _, promises in ipairs({ {}, { "fork" }, { "fork", "jit", "fattr" } }) do
    holds_on_both(promises, { call("clone3", "ENOSYS"), call("openat2", "ENOSYS") })
  end
  holds_on_both({}, { call("clone3", "ENOSYS"), call("openat2", "ENOSYS") }, { unix = true })
end

local function test_a_call_of_another_architecture_ends_the_process()
  for _, arch in ipairs(ARCHES) do
    local insns = decode(process.promise_filter({}, arch))
    local other = arch == "x86_64" and AUDIT.aarch64 or AUDIT.x86_64
    assert(verdict(run(insns, other, 0, {})) == "kill")
    assert(verdict(run(insns, 0x40000003, 0, {})) == "kill", "i386 on x86_64 is another architecture")
  end
end

local function test_the_same_number_is_another_call_on_the_other_architecture()
  -- x86_64's open is 2, which aarch64 has as io_submit: not a call it allows.
  assert(verdict(run(decode(process.promise_filter({}, "x86_64")), AUDIT.x86_64, 2, { 0, 0, 0 })) == "allow")
  assert(verdict(run(decode(process.promise_filter({}, "aarch64")), AUDIT.aarch64, 2, { 0, 0, 0 })) == "EPERM")
  -- And aarch64's read, 63, is x86_64's uname, which it allows too; its openat, 56, is x86_64's clone.
  assert(verdict(run(decode(process.promise_filter({}, "x86_64")), AUDIT.x86_64, 56, { 0, 0, 0 })) == "EPERM")
  assert(verdict(run(decode(process.promise_filter({}, "aarch64")), AUDIT.aarch64, 56, { 0, 0, 0 })) == "allow")
end

local function test_a_refused_ioctl_answers_ENOTTY()
  local TCGETS, TIOCGWINSZ, FIONREAD, TCSETS, TIOCSTI, FS_IOC_SETFLAGS =
    0x5401, 0x5413, 0x541b, 0x5402, 0x5412, 0x40086602
  holds_on_both({}, {
    call("ioctl", "allow", 0, TCGETS), call("ioctl", "allow", 0, TIOCGWINSZ),
    call("ioctl", "allow", 0, FIONREAD),
    call("ioctl", "ENOTTY", 0, TCSETS), call("ioctl", "ENOTTY", 0, TIOCSTI),
    call("ioctl", "ENOTTY", 0, FS_IOC_SETFLAGS),
    -- A command is its low 32 bits, as the kernel takes it.
    call("ioctl", "allow", 0, (1 << 32) | TCGETS),
    call("ioctl", "ENOTTY", 0, (1 << 32) | TIOCSTI),
  })
end

local function test_fcntl_refuses_a_lease_and_a_notification()
  holds_on_both({}, {
    call("fcntl", "allow", 3, 0), call("fcntl", "allow", 3, 1), call("fcntl", "allow", 3, 3),
    call("fcntl", "allow", 3, 4), call("fcntl", "allow", 3, 1030), call("fcntl", "allow", 3, 5),
    call("fcntl", "allow", 3, 37), call("fcntl", "allow", 3, 1033),
    call("fcntl", "EPERM", 3, 1024), call("fcntl", "EPERM", 3, 1026),
    call("fcntl", "EPERM", 3, 8), call("fcntl", "EPERM", 3, 1025),
  })
end

local function test_prctl_allows_what_the_core_asks_before_exec_and_no_more()
  holds_on_both({}, {
    call("prctl", "allow", 1), call("prctl", "allow", 4), call("prctl", "allow", 15),
    call("prctl", "allow", 22), call("prctl", "allow", 36), call("prctl", "allow", 38),
    call("prctl", "allow", 65),
    -- The ptracer, the keep-capabilities bit, a memory map and an ambient capability.
    call("prctl", "EPERM", 0x59616d61), call("prctl", "EPERM", 8),
    call("prctl", "EPERM", 35), call("prctl", "EPERM", 47),
  })
end

local function test_memory_is_never_anonymous_and_executable_without_jit()
  local rw = PROT_READ | PROT_WRITE
  local rx = PROT_READ | PROT_EXEC
  local rwx = rw | PROT_EXEC
  local file = MAP_PRIVATE
  local anonymous = MAP_PRIVATE | MAP_ANONYMOUS
  holds_on_both({}, {
    call("mmap", "allow", 0, 4096, rw, anonymous), call("mmap", "allow", 0, 4096, rx, file),
    call("mmap", "allow", 0, 4096, PROT_READ, file),
    call("mmap", "EPERM", 0, 4096, rx, anonymous), call("mmap", "EPERM", 0, 4096, rwx, file),
    call("mmap", "EPERM", 0, 4096, rwx, anonymous),
    call("mprotect", "allow", 0, 4096, rw), call("mprotect", "allow", 0, 4096, PROT_READ),
    call("mprotect", "EPERM", 0, 4096, rx), call("mprotect", "EPERM", 0, 4096, rwx),
    call("pkey_mprotect", "EPERM", 0, 4096, rx),
    -- A protection is its low 32 bits, as the kernel reads it.
    call("mmap", "EPERM", 0, 4096, (1 << 40) | rx, anonymous),
    -- memfd_create needs MFD_NOEXEC_SEAL, which a kernel before 6.3 refuses to know.
    call("memfd_create", "allow", 0, MFD_NOEXEC_SEAL), call("memfd_create", "allow", 0, MFD_NOEXEC_SEAL | 1),
    call("memfd_create", "EPERM", 0, 0), call("memfd_create", "EPERM", 0, 1),
  })
end

local function test_jit_grants_executable_memory()
  holds_on_both({ "jit" }, {
    call("mmap", "allow", 0, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS),
    call("mprotect", "allow", 0, 4096, PROT_READ | PROT_EXEC),
    call("pkey_mprotect", "allow", 0, 4096, PROT_READ | PROT_EXEC),
    call("pkey_alloc", "allow"), call("pkey_free", "allow"),
    call("memfd_create", "allow", 0, 0),
    call("fork", "EPERM"), call("chmod", "EPERM", 0, 0x1a4),
  })
  holds_on_both({ "jit" }, never())
end

local function test_fork_grants_processes_but_no_namespace()
  local refused: {Case} = {}
  for _, flag in ipairs(NAMESPACES) do
    refused[#refused + 1] = call("clone", "EPERM", flag | SIGCHLD)
    refused[#refused + 1] = call("clone", "EPERM", flag | THREAD)
  end
  holds_on_both({ "fork" }, refused)
  holds_on_both({ "fork" }, {
    call("fork", "allow"), call("vfork", "allow"), call("pidfd_open", "allow"),
    call("clone", "allow", SIGCHLD), call("clone", "allow", VFORK_CLONE),
    call("clone", "allow", THREAD),
    -- clone's low byte is the signal the child ends with: SIGCHLD is no namespace.
    call("clone", "allow", 0x11), call("clone", "allow", 0),
    -- Into a tracer, or as a sibling of the parent, a process never.
    call("clone", "EPERM", 0x2000 | SIGCHLD), call("clone", "EPERM", 0x8000 | SIGCHLD),
    call("unshare", "EPERM", 0x10000000), call("setns", "EPERM"),
    call("clone3", "ENOSYS"), call("chmod", "EPERM", 0, 0x1a4),
  })
  holds_on_both({ "fork" }, never())
end

local function test_without_fork_a_clone_must_be_a_thread()
  local missing: {Case} = {}
  for _, drop in ipairs({ 0x100, 0x400, 0x800, 0x10000 }) do
    missing[#missing + 1] = call("clone", "EPERM", THREAD & ~drop)
  end
  holds_on_both({}, missing)
  holds_on_both({}, {
    call("clone", "allow", THREAD), call("clone", "EPERM", SIGCHLD),
    call("clone", "EPERM", VFORK_CLONE), call("clone", "EPERM", THREAD | 0x10000000),
    call("clone", "EPERM", THREAD | 0x2000), call("clone", "EPERM", THREAD | 0x8000),
  })
end

local function test_fattr_grants_modes_but_never_a_special_bit()
  holds_on_both({ "fattr" }, {
    call("chmod", "allow", 0, 0x1ed), call("fchmod", "allow", 3, 0x1a4),
    call("fchmodat", "allow", -100, 0, 0x1ed), call("fchmodat2", "allow", -100, 0, 0x1ed),
    call("chmod", "EPERM", 0, 0x9ed), call("fchmod", "EPERM", 3, 0x4ed),
    call("fchmod", "EPERM", 3, 0x2ed), call("chmod", "EPERM", 0, 0x200),
    call("fchmodat", "EPERM", -100, 0, 0x9ed), call("fchmodat2", "EPERM", -100, 0, 0x4ed),
    call("chown", "allow"), call("fchown", "allow"), call("lchown", "allow"),
    call("fchownat", "allow"), call("utimensat", "allow"), call("utimes", "allow"),
    call("setxattr", "allow"), call("fsetxattr", "allow"), call("removexattr", "allow"),
    call("fork", "EPERM"), call("mmap", "EPERM", 0, 4096, PROT_EXEC, MAP_ANONYMOUS),
  })
  holds_on_both({ "fattr" }, never())
end

local function test_a_file_is_never_made_with_a_special_bit()
  holds_on_both({}, {
    call("openat", "allow", -100, 0, O_CREAT | 1, 0x1a4),
    call("openat", "allow", -100, 0, 0, 0xffff),
    call("openat", "EPERM", -100, 0, O_CREAT | 1, 0x9ed),
    call("openat", "EPERM", -100, 0, O_CREAT, 0x4ed),
    call("openat", "EPERM", -100, 0, 0x410000 | 2, 0x2ed),
    call("open", "allow", 0, O_CREAT, 0x1a4), call("open", "EPERM", 0, O_CREAT, 0x4ed),
    call("creat", "allow", 0, 0x1a4), call("creat", "EPERM", 0, 0x4ed),
    call("mkdir", "allow", 0, 0x1ed), call("mkdir", "EPERM", 0, 0x9ed),
    call("mkdirat", "allow", -100, 0, 0x1ed), call("mkdirat", "EPERM", -100, 0, 0x9ed),
    -- A fifo, a socket or a file, never a device.
    call("mknod", "allow", 0, 0x1000 | 0x1a4), call("mknod", "allow", 0, 0xc000 | 0x1a4),
    call("mknod", "allow", 0, 0x8000 | 0x1a4), call("mknod", "allow", 0, 0x1a4),
    call("mknod", "EPERM", 0, 0x2000 | 0x1a4), call("mknod", "EPERM", 0, 0x6000 | 0x1a4),
    call("mknod", "EPERM", 0, 0x1000 | 0x4ed),
    call("mknodat", "allow", -100, 0, 0x1000 | 0x1a4), call("mknodat", "EPERM", -100, 0, 0x2000 | 0x1a4),
  })
end

--- The namespaces `nest` lets a program make: user, mount, pid, IPC and network.
local NEST_NAMESPACES: {integer} = { 0x00020000, 0x08000000, 0x10000000, 0x20000000, 0x40000000 }
--- And those it never does: cgroup, UTS, and unshare's time namespace.
local NEST_REFUSED: {integer} = { 0x02000000, 0x04000000, 0x80 }

local function test_nest_grants_the_calls_a_sandbox_is_built_with()
  local pid = 4242
  local cases: {Case} = {}
  local everything = 0
  for _, flag in ipairs(NEST_NAMESPACES) do
    cases[#cases + 1] = call("unshare", "allow", flag)
    everything = everything | flag
  end
  for _, name in ipairs({ "mount", "umount2", "pivot_root", "move_mount", "open_tree",
      "mount_setattr", "setrlimit" }) do
    cases[#cases + 1] = call(name, "allow")
  end
  cases[#cases + 1] = call("unshare", "allow", everything)
  cases[#cases + 1] = call("unshare", "allow", 0)
  for _, flag in ipairs(NEST_REFUSED) do
    cases[#cases + 1] = call("unshare", "EPERM", flag)
    cases[#cases + 1] = call("unshare", "EPERM", 0x10000000 | flag)
  end
  -- Not a thread's or a file table's own: only the namespaces.
  cases[#cases + 1] = call("unshare", "EPERM", 0x400)
  -- A sandbox gives its capabilities up, and sets limits it can only lower.
  cases[#cases + 1] = call("prctl", "allow", 24)
  cases[#cases + 1] = call("prctl", "allow", 47)
  cases[#cases + 1] = call("prctl", "allow", 38)
  cases[#cases + 1] = call("prctl", "EPERM", 8)
  cases[#cases + 1] = call("prctl", "EPERM", 28)
  cases[#cases + 1] = call("prlimit64", "allow", 0, 7, 1 << 40, 0x7000)
  cases[#cases + 1] = call("prlimit64", "allow", pid, 7, 1 << 40, 0x7000)
  cases[#cases + 1] = call("prlimit64", "EPERM", pid + 1, 7, 1 << 40, 0x7000)
  -- A sandbox of its own ends what it starts by pid and group: its pid
  -- namespace is what holds the signal.
  cases[#cases + 1] = call("kill", "allow", pid + 1, 9)
  cases[#cases + 1] = call("kill", "allow", -pid, 0)
  cases[#cases + 1] = call("tgkill", "allow", pid + 1, pid + 1, 9)
  cases[#cases + 1] = call("tkill", "allow", pid + 1, 9)
  cases[#cases + 1] = call("rt_sigqueueinfo", "allow", pid + 1, 9)
  cases[#cases + 1] = call("rt_tgsigqueueinfo", "allow", pid + 1, pid + 1, 9)
  cases[#cases + 1] = call("pidfd_send_signal", "EPERM")
  -- Whatever it promised, it holds no process's descriptor or a namespace of the host's.
  cases[#cases + 1] = call("setns", "EPERM")
  cases[#cases + 1] = call("fsopen", "EPERM")
  cases[#cases + 1] = call("chroot", "EPERM")
  cases[#cases + 1] = call("sethostname", "EPERM")
  cases[#cases + 1] = call("fork", "EPERM")
  cases[#cases + 1] = call("chmod", "EPERM", 0, 0x1a4)
  -- Making a process is `fork`'s, namespace or not.
  cases[#cases + 1] = call("clone", "EPERM", SIGCHLD)
  cases[#cases + 1] = call("clone", "EPERM", 0x10000000 | SIGCHLD)
  cases[#cases + 1] = call("clone", "allow", THREAD)
  holds_on_both({ "nest" }, cases, { pid = pid })
  local still: {Case} = {}
  for _, name in ipairs(NEVER) do still[#still + 1] = call(name, "EPERM") end
  holds_on_both({ "nest" }, still)
  holds_on_both({ "nest", "fork" }, still)
end

local function test_nest_beside_fork_lets_a_process_start_in_the_namespaces()
  local cases: {Case} = {
    call("fork", "allow"), call("clone", "allow", SIGCHLD), call("clone", "allow", THREAD),
    -- A sandbox's init is cloned as the sibling of the process that starts it.
    call("clone", "allow", 0x4000 | 0x100 | 0x8000 | SIGCHLD),
    call("clone", "allow", 0x8000 | SIGCHLD),
    call("clone", "EPERM", 0x2000 | SIGCHLD), call("clone", "EPERM", 0x2000 | 0x8000),
    call("unshare", "allow", 0x10000000), call("unshare", "EPERM", 0x02000000),
  }
  for _, flag in ipairs(NEST_NAMESPACES) do
    cases[#cases + 1] = call("clone", "allow", flag | SIGCHLD)
  end
  for _, flag in ipairs({ 0x02000000, 0x04000000 }) do
    cases[#cases + 1] = call("clone", "EPERM", flag | SIGCHLD)
    cases[#cases + 1] = call("clone", "EPERM", 0x10000000 | flag | SIGCHLD)
  end
  holds_on_both({ "nest", "fork" }, cases)
end

--- With `nest` an ioctl may read and set an interface's flags, which a start
--- brings the loopback of its network namespace up with, and no other
--- interface ioctl; without it neither.
local function test_nest_adds_the_interface_flag_ioctls_and_no_other()
  for _, promises in ipairs({ { "nest" }, { "nest", "fork" } }) do
    holds_on_both(promises, {
      call("ioctl", "allow", 3, 0x8913), call("ioctl", "allow", 3, 0x8914),
      call("ioctl", "allow", 3, 0x541b), call("ioctl", "allow", 3, 0x5401),
      call("ioctl", "ENOTTY", 3, 0x8912), call("ioctl", "ENOTTY", 3, 0x8915),
      call("ioctl", "ENOTTY", 3, 0x8916), call("ioctl", "ENOTTY", 3, 0x8918),
      call("ioctl", "ENOTTY", 3, 0x894c),
    })
  end
  for _, promises in ipairs({ {}, { "fork", "jit", "fattr" } }) do
    holds_on_both(promises, {
      call("ioctl", "ENOTTY", 3, 0x8913), call("ioctl", "ENOTTY", 3, 0x8914),
      call("ioctl", "allow", 3, 0x541b),
    })
  end
end

local function test_the_namespace_calls_are_refused_without_nest()
  local cases: {Case} = {}
  for _, name in ipairs(NESTED) do cases[#cases + 1] = call(name, "EPERM") end
  cases[#cases + 1] = call("unshare", "EPERM", 0x10000000)
  cases[#cases + 1] = call("setrlimit", "EPERM")
  cases[#cases + 1] = call("kill", "EPERM", 4243, 9)
  cases[#cases + 1] = call("prctl", "EPERM", 24)
  cases[#cases + 1] = call("prctl", "EPERM", 47)
  for _, promises in ipairs({ {}, { "fork" }, { "jit" }, { "fattr" }, { "fork", "jit", "fattr" } }) do
    holds_on_both(promises, cases)
  end
end

local function test_a_unix_socket_is_made_only_where_it_is_allowed()
  holds_on_both({}, {
    call("socketpair", "allow", 1, 1, 0), call("socketpair", "EPERM", 2, 1, 0),
    call("socketpair", "EPERM", 16, 3, 0), call("socket", "EPERM", 1, 1, 0),
    call("sendmsg", "allow"), call("recvmsg", "allow"), call("shutdown", "allow"),
  })
  holds_on_both({}, {
    call("socket", "allow", 1, 1, 0), call("socket", "EPERM", 2, 1, 0),
    call("socket", "EPERM", 10, 1, 0), call("socket", "EPERM", 16, 3, 0),
    call("socket", "EPERM", 17, 3, 0), call("socketpair", "allow", 1, 1, 0),
    call("socketpair", "EPERM", 2, 1, 0),
  }, { unix = true })
end

local function test_an_inet_socket_is_made_only_where_it_is_allowed()
  -- AF_INET and AF_INET6, for a program in a network namespace of its own;
  -- never netlink or packet sockets, and a unix one only where allowed.
  holds_on_both({}, {
    call("socket", "allow", 2, 1, 0), call("socket", "allow", 10, 2, 0),
    call("socket", "EPERM", 1, 1, 0), call("socket", "EPERM", 16, 3, 0),
    call("socket", "EPERM", 17, 3, 0), call("socket", "EPERM", 9, 1, 0),
    call("socketpair", "allow", 1, 1, 0), call("socketpair", "EPERM", 2, 1, 0),
  }, { inet = true })
  holds_on_both({}, {
    call("socket", "allow", 1, 1, 0), call("socket", "allow", 2, 1, 0),
    call("socket", "allow", 10, 1, 0), call("socket", "EPERM", 16, 3, 0),
    call("socket", "EPERM", 17, 3, 0),
  }, { unix = true, inet = true })
end

local function test_a_signal_goes_to_the_process_itself()
  local pid = 4242
  holds_on_both({}, {
    call("kill", "allow", pid, 15), call("kill", "EPERM", pid + 1, 15),
    call("kill", "EPERM", 0, 15), call("kill", "EPERM", -1, 9), call("kill", "EPERM", 1, 9),
    call("tgkill", "allow", pid, 4243, 6), call("tgkill", "EPERM", pid + 1, 4243, 6),
    call("rt_sigqueueinfo", "allow", pid, 10), call("rt_sigqueueinfo", "EPERM", 1, 10),
    call("rt_tgsigqueueinfo", "allow", pid, 4243, 10),
    call("rt_tgsigqueueinfo", "EPERM", 1, 4243, 10),
    call("tkill", "allow", pid, 6), call("tkill", "EPERM", pid + 1, 6),
    -- A pid is an int: its low 32 bits are what the kernel reads.
    call("kill", "allow", (1 << 33) | pid, 15),
  }, { pid = pid })
end

--- Where Landlock's signal scope holds the process, the kernel refuses a
--- signal to a process outside its domain, so the filter takes any pid:
--- another's, a group's (negative, or 0) and every process's (-1), and a
--- pidfd's signal too.
local function test_a_scoped_filter_lets_a_signal_take_any_pid()
  local pid = 4242
  for _, promises in ipairs({ {}, { "fork" }, { "fork", "jit", "fattr" }, { "nest" } }) do
    holds_on_both(promises, {
      call("kill", "allow", pid + 1, 15), call("kill", "allow", 0, 15),
      call("kill", "allow", -1, 9), call("kill", "allow", -(pid + 1), 15),
      call("kill", "allow", 1, 0),
      call("tgkill", "allow", pid + 1, pid + 2, 6), call("tkill", "allow", pid + 1, 6),
      call("rt_sigqueueinfo", "allow", pid + 1, 10),
      call("rt_tgsigqueueinfo", "allow", pid + 1, pid + 2, 10),
      call("pidfd_send_signal", "allow", 3, 15),
    }, { pid = pid, scoped = true })
  end
  -- Only the signal calls: who a call asks after, and what it sets, stay held.
  holds_on_both({}, {
    call("sched_getaffinity", "EPERM", pid + 1), call("sched_setaffinity", "EPERM", pid + 1),
    call("getpgid", "EPERM", pid + 1), call("setpgid", "EPERM", pid + 1),
    call("get_robust_list", "EPERM", pid + 1), call("prlimit64", "EPERM", pid + 1),
    call("pidfd_open", "EPERM", pid + 1), call("pidfd_getfd", "EPERM"),
    call("process_madvise", "EPERM"), call("ptrace", "EPERM"),
    call("fork", "EPERM"), call("setrlimit", "EPERM"),
  }, { pid = pid, scoped = true })
  holds_on_both({ "fork" }, { call("pidfd_open", "allow") }, { pid = pid, scoped = true })
end

--- Without the scope, `scoped` unset or false, the signal calls keep to
--- the pid, and pidfd_send_signal is refused.
local function test_an_unscoped_filter_keeps_a_signal_to_the_starting_pid()
  local pid = 4242
  for _, options in ipairs({ { pid = pid }, { pid = pid, scoped = false } }) do
    holds_on_both({ "fork" }, {
      call("kill", "allow", pid, 15), call("kill", "EPERM", pid + 1, 15),
      call("kill", "EPERM", 0, 15), call("kill", "EPERM", -1, 9),
      call("kill", "EPERM", -pid, 9),
      call("tgkill", "EPERM", pid + 1, pid + 1, 6), call("tkill", "EPERM", pid + 1, 6),
      call("pidfd_send_signal", "EPERM", 3, 15),
    }, options)
  end
end

local function test_a_call_that_asks_after_a_process_is_held_to_the_process_itself()
  local pid = 4242
  holds_on_both({}, {
    call("sched_getaffinity", "allow", 0), call("sched_getaffinity", "allow", pid),
    call("sched_getaffinity", "EPERM", 1), call("sched_setaffinity", "EPERM", 77),
    call("getpgid", "allow", 0), call("getpgid", "EPERM", 1), call("getsid", "EPERM", 1),
    call("setpgid", "allow", 0, 0), call("setpgid", "EPERM", 1, 0),
    call("getpriority", "allow", 0, 0), call("getpriority", "EPERM", 0, 1),
    call("setpriority", "EPERM", 0, 1, 5), call("setpriority", "allow", 0, 0, 5),
    -- Not every process of the user.
    call("setpriority", "EPERM", 2, 0, 5), call("getpriority", "EPERM", 2, 0),
    call("sched_setscheduler", "allow", 0, 0), call("sched_setscheduler", "allow", pid, 3),
    call("sched_setscheduler", "allow", 0, 5 | 0x40000000),
    call("sched_setscheduler", "EPERM", 0, 1), call("sched_setscheduler", "EPERM", 0, 2),
    call("sched_setscheduler", "EPERM", 0, 6), call("sched_setscheduler", "EPERM", 1, 0),
    call("sched_setattr", "EPERM", 0),
    call("madvise", "allow", 0, 4096, 4), call("madvise", "allow", 0, 4096, 8),
    call("madvise", "EPERM", 0, 4096, 9), call("madvise", "EPERM", 0, 4096, 100),
    call("madvise", "EPERM", 0, 4096, 101), call("madvise", "EPERM", 0, 4096, 12),
    call("sched_setscheduler", "EPERM", 1), call("get_robust_list", "EPERM", 1),
    -- prlimit64 reads: a pid of its own, and no new limit.
    call("prlimit64", "allow", 0, 7, 0, 0x7000), call("prlimit64", "allow", pid, 7, 0, 0x7000),
    call("prlimit64", "EPERM", 1, 7, 0, 0x7000), call("prlimit64", "EPERM", 0, 7, 0x7000, 0),
    call("prlimit64", "EPERM", 0, 7, 1 << 40, 0x7000),
    call("getrlimit", "allow"),
  }, { pid = pid })
end

--- A unix socket is made where the process is in a root, a network
--- namespace and a Landlock domain that hold what it reaches
--- (`unix_held`), and only a unix one: an inet socket still needs `inet`.
local function test_a_held_process_may_make_a_unix_socket_and_no_other()
  for _, promises in ipairs({ {}, { "fork" }, { "fork", "jit", "fattr" }, { "nest" } }) do
    holds_on_both(promises, {
      call("socket", "allow", 1, 1, 0), call("socket", "allow", 1, 2, 0),
      call("socket", "EPERM", 2, 1, 0), call("socket", "EPERM", 10, 1, 0),
      call("socket", "EPERM", 16, 3, 0), call("socket", "EPERM", 17, 3, 0),
      call("socketpair", "allow", 1, 1, 0), call("socketpair", "EPERM", 2, 1, 0),
    }, { unix_held = true })
  end
  holds_on_both({}, {
    call("socket", "allow", 1, 1, 0), call("socket", "allow", 2, 1, 0),
    call("socket", "allow", 10, 1, 0), call("socket", "EPERM", 16, 3, 0),
  }, { unix_held = true, inet = true })
  -- Without it the filter keeps to its sockets, as `unix` names them.
  holds_on_both({}, { call("socket", "EPERM", 1, 1, 0) }, { unix_held = false })
  holds_on_both({}, { call("socket", "EPERM", 1, 1, 0) }, { scoped = true, limits_held = true,
    pids_held = true })
end

--- A process that cannot raise a hard limit may set its own limits, with
--- setrlimit or prlimit64 of itself; another process's limits stay out of
--- reach, and nothing else is let through.
local function test_a_process_that_cannot_raise_a_hard_limit_sets_its_own_limits()
  local pid = 4242
  for _, promises in ipairs({ {}, { "fork", "jit", "fattr" }, { "nest" } }) do
    holds_on_both(promises, {
      call("setrlimit", "allow", 7, 0x7000),
      call("prlimit64", "allow", 0, 7, 0x7000, 0), call("prlimit64", "allow", pid, 7, 0x7000, 0x7100),
      call("prlimit64", "allow", 0, 7, 0, 0x7000), call("prlimit64", "allow", pid, 7, 0, 0),
      call("prlimit64", "EPERM", 1, 7, 0x7000, 0), call("prlimit64", "EPERM", pid + 1, 7, 0x7000, 0),
      call("prlimit64", "EPERM", 1, 7, 0, 0x7000),
      call("getrlimit", "allow"),
    }, { pid = pid, limits_held = true })
  end
  holds_on_both({}, {
    call("setrlimit", "EPERM", 7, 0x7000), call("prlimit64", "EPERM", 0, 7, 0x7000, 0),
    call("prlimit64", "EPERM", pid, 7, 0x7000, 0),
    call("prlimit64", "allow", 0, 7, 0, 0x7000),
  }, { pid = pid, limits_held = false })
  -- Only the limits: nothing else a namespace or a scope holds comes with them.
  holds_on_both({}, {
    call("kill", "EPERM", pid + 1, 9), call("getpgid", "EPERM", pid + 1),
    call("setpgid", "EPERM", pid + 1, 0), call("socket", "EPERM", 1, 1, 0),
    call("sched_setaffinity", "EPERM", pid + 1), call("unshare", "EPERM", 0x10000000),
  }, { pid = pid, limits_held = true })
end

--- In a pid namespace of its own, a pid names a process of the sandbox or
--- none: getpgid, getsid and setpgid take any. Without one they are held
--- to the process itself, and what else asks after a process is, whatever
--- is held.
local function test_a_process_in_its_own_pid_namespace_asks_after_any_pid()
  local pid = 4242
  for _, promises in ipairs({ {}, { "fork" }, { "fork", "jit", "fattr" } }) do
    holds_on_both(promises, {
      call("getpgid", "allow", pid + 1), call("getpgid", "allow", 1), call("getpgid", "allow", 0),
      call("getsid", "allow", pid + 1), call("getsid", "allow", 1),
      call("setpgid", "allow", pid + 1, 0), call("setpgid", "allow", pid + 1, pid + 1),
      call("capget", "allow", 0x7000, 0x7100),
      call("sched_getaffinity", "EPERM", pid + 1), call("sched_setaffinity", "EPERM", pid + 1),
      call("get_robust_list", "EPERM", pid + 1),
      call("prlimit64", "EPERM", pid + 1, 7, 0, 0x7000), call("setpriority", "EPERM", 0, pid + 1, 5),
      call("kill", "EPERM", pid + 1, 9), call("setrlimit", "EPERM", 7, 0x7000),
    }, { pid = pid, pids_held = true })
  end
  holds_on_both({}, {
    call("getpgid", "EPERM", pid + 1), call("getsid", "EPERM", pid + 1),
    call("setpgid", "EPERM", pid + 1, 0), call("getpgid", "allow", pid),
    call("setpgid", "allow", 0, 0), call("capget", "EPERM", 0x7000, 0x7100),
  }, { pid = pid, pids_held = false, scoped = true })
end

local function test_a_promise_is_one_of_the_four()
  for _, bad in ipairs({ "inet", "stdio", "" }) do
    local ok = pcall(process.promise_filter, { bad }, "x86_64")
    assert(not ok, bad .. " is no promise")
  end
  local numeric: any = { 1 }
  assert(not pcall(process.promise_filter, numeric as {string}, "x86_64"))
  assert(not pcall(process.promise_filter, {}, "riscv64"))
  assert(not pcall(process.promise_filter, {}, "x86_64", { pid = 0 }))
  local text_pid: any = { pid = "1" }
  assert(not pcall(process.promise_filter, {}, "x86_64", text_pid as raw_process.PromiseOptions))
end

--- Every number from 0 through the reviewed table's end, with every
--- combination of promises, ends in a return the kernel accepts: allowed,
--- or refused as one of the four errnos, never off the end of the program.
local function test_every_call_gets_an_answer()
  for _, arch in ipairs(ARCHES) do
    for mask = 0, 15 do
      local promises: {string} = {}
      if mask & 1 ~= 0 then promises[#promises + 1] = "fork" end
      if mask & 2 ~= 0 then promises[#promises + 1] = "jit" end
      if mask & 4 ~= 0 then promises[#promises + 1] = "fattr" end
      if mask & 8 ~= 0 then promises[#promises + 1] = "nest" end
      for _, unix in ipairs({ false, true }) do
        for _, inet in ipairs({ false, true }) do
          local insns = decode(process.promise_filter(promises, arch,
            { pid = 9, unix = unix, inet = inet }))
          for number = 0, process.PROMISE_CALLS_REVIEWED + 2 do
            local got = verdict(run(insns, AUDIT[arch], number, {}))
            assert(got == "allow" or got == "EPERM" or got == "ENOSYS" or got == "ENOTTY",
              arch .. " " .. number .. " is " .. got)
          end
        end
      end
    end
  end
end

--- The tables are one program per promise set: a promise adds calls and
--- takes none away, and a program is a small fraction of the kernel's limit.
local function test_a_promise_only_adds()
  for _, arch in ipairs(ARCHES) do
    local base = decode(process.promise_filter({}, arch))
    local full = decode(process.promise_filter({ "fork", "jit", "fattr", "nest" }, arch))
    assert(#full > #base and #full < 1500, #base .. " and " .. #full .. " instructions")
    for number = 0, process.PROMISE_CALLS_REVIEWED - 1 do
      local before = verdict(run(base, AUDIT[arch], number, { 0, 0, 0, 0 }))
      local after = verdict(run(full, AUDIT[arch], number, { 0, 0, 0, 0 }))
      assert(before ~= "allow" or after == "allow", arch .. " " .. number .. " lost to a promise")
    end
  end
end

--- Linux's generic table, which aarch64's headers carry a count of, is
--- reviewed up to the number the tables hold: a header that names more calls
--- names ones no one has judged, which the filter answers ENOSYS
--- until they are added to core/promises_calls.h and judged.
-- TODO: check x86_64's headers too, once the kernel's x86 uapi
-- asm/unistd_64.h carries a count of its calls as the generic table's
-- asm-generic/unistd.h does (__NR_syscalls): until then a call added there
-- alone goes unseen, though every new call is added to both tables.
local function test_the_headers_name_no_call_beyond_the_reviewed_table()
  local headers = process.PROMISE_CALLS_HEADERS
  assert(headers <= process.PROMISE_CALLS_REVIEWED,
    "the headers name system calls up to " .. (headers - 1) .. ", past the " ..
      (process.PROMISE_CALLS_REVIEWED - 1) .. " core/promises_calls.h is reviewed to: judge them, " ..
      "add them to its tables and core/promises.c's, and raise PROMISE_CALLS_REVIEWED")
end

--- glibc's loader on aarch64 makes the text of a library marked for
--- branch-target protection executable with PROT_BTI, so an mprotect that
--- adds PROT_EXEC is allowed there with it and without PROT_WRITE; x86_64
--- has no such protection, and refuses every one.
local function test_aarch64_allows_the_loader_s_protection_with_bti()
  local rx = PROT_READ | PROT_EXEC
  local BTI = 0x10
  holds({}, "aarch64", {
    call("mprotect", "allow", 0, 4096, rx | BTI),
    call("mprotect", "EPERM", 0, 4096, rx),
    call("mprotect", "EPERM", 0, 4096, rx | BTI | PROT_WRITE),
    call("mprotect", "allow", 0, 4096, PROT_READ | BTI),
    call("pkey_mprotect", "EPERM", 0, 4096, rx | BTI),
  })
  holds({}, "x86_64", { call("mprotect", "EPERM", 0, 4096, rx | BTI) })
end
