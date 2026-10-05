/*-*- mode:c;indent-tabs-mode:nil;c-basic-offset:2;tab-width:8;coding:utf-8 -*-│
│ vi: set et ft=c ts=2 sts=2 sw=2 fenc=utf-8                               :vi │
╞══════════════════════════════════════════════════════════════════════════════╡
│ Copyright 2022 Justine Alexandra Roberts Tunney                              │
│                                                                              │
│ Permission to use, copy, modify, and/or distribute this software for         │
│ any purpose with or without fee is hereby granted, provided that the         │
│ above copyright notice and this permission notice appear in all copies.      │
│                                                                              │
│ THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL                │
│ WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED                │
│ WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE             │
│ AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL         │
│ DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR        │
│ PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER               │
│ TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR             │
│ PERFORMANCE OF THIS SOFTWARE.                                                │
╚─────────────────────────────────────────────────────────────────────────────*/

/*
 * The promises filter (core/promises.h), whose tables and argument rules
 * are ported by hand from Cosmopolitan libc's libc/calls/pledge-linux.c,
 * whose notice heads this file and whose commit is recorded in
 * build/bom/cosmopolitan.pin. Where that file
 * names promises after OpenBSD's pledge(2) and filters by the calls a
 * promise needs, this one is an allow list over four promises (`fork`,
 * `jit`, `fattr`, `nest`) and the basics every program has, for a sandbox
 * whose paths Landlock holds (or, under `nest`, whose root does): a call that opens, creates or changes a file is a
 * basic, since which files it reaches is Landlock's to say. Landlock does
 * not cover the calls that only look (stat, access, readlink, getxattr,
 * statfs, inotify_add_watch); only a root of the program's own that
 * leaves the files out (`isolate file`) hides what they would report.
 *
 * `jit` is not a boundary against a program that can write a file it can
 * also map: the same file mapped shared and writable at one address and
 * executable at another is writable executable memory the filter does
 * not see. Nor does it hold against a write through /proc/self/mem. A
 * Landlock ruleset that grants no such file or /proc is what holds them.
 *
 * Every table is a list of call names, so a call's number is the
 * architecture's (core/promises_calls.h), and a call an architecture has
 * no number for (open on aarch64) is left out of its program. A program
 * is a binary decision tree over the allowed numbers, so a call costs
 * about ten instructions however many the tables hold; a call with an
 * argument rule jumps from its leaf to the rule's block after the tree.
 * Every path ends in a return, and a rule that ends without one denies.
 */

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__linux__)
#include <asm/unistd.h>
#include <linux/capability.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
extern long syscall (long, ...);
#endif

#include "check.h"
#include "fail.h"
#include "lauxlib.h"
#include "process.h"
#include "promises.h"
#include "promises_calls.h"

/* The architectures a filter is written for. */
enum cosmic_arch { COSMIC_ARCH_X86_64, COSMIC_ARCH_AARCH64 };

/* One instruction of a classic BPF program, as the kernel's `struct
 * sock_filter` lays it out, so a program is handed to seccomp as it is,
 * and an interpreter on any host reads the bytes. */
struct cosmic_insn {
  uint16_t code;
  uint8_t jt;
  uint8_t jf;
  uint32_t k;
};

/* The most instructions a program holds, which the kernel's own limit
 * (BPF_MAXINSNS) is. The full tables fit in about a fifth of it. */
#define COSMIC_PROMISE_INSNS 4096


/* Every call, by the name core/promises_calls.h gives it. */
enum call {
#define NAME(name, number) CALL_##name,
  X86_64_CALLS(NAME)
#undef NAME
  CALL_COUNT
};

/* A call's number plus one for each architecture, by call, so that 0 is
 * a call the architecture has no number for. */
#define NUMBER(name, number) [CALL_##name] = (number) + 1,
static const short x86_64_numbers[CALL_COUNT] = { X86_64_CALLS(NUMBER) };
static const short aarch64_numbers[CALL_COUNT] = { AARCH64_CALLS(NUMBER) };
#undef NUMBER

/* Each architecture's numbers by name, for the check below. */
#define NUMBER_OF(name, number) NUMBER_##name = (number),
#if defined(__linux__) && defined(__x86_64__)
enum { X86_64_CALLS(NUMBER_OF) };
#elif defined(__linux__) && defined(__aarch64__)
enum { AARCH64_CALLS(NUMBER_OF) };
#endif
#undef NUMBER_OF

/* A sample of calls every set of headers has -- the calls a loader and a
 * libc make before main -- which the host's headers must number as the
 * tables do: a table of another architecture's, or one shifted, is a
 * build that fails. Not every call: a header older than the tables (the
 * kernel's calls past 451 are only in the newest) lacks some names, so
 * the rest are as the kernel's own list numbers them.
 * TODO: check both lists in full against the pinned zig's
 * asm/unistd_64.h, once a test can find the pinned zig install (as the
 * TODO in build/bom_test.tl waits on): only bin/zig's own Teal knows
 * where it unpacked it. */
#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
#define HOST_NUMBER(name) \
  _Static_assert(__NR_##name == NUMBER_##name, "core/promises_calls.h and the headers disagree on " #name);
HOST_NUMBER(read)
HOST_NUMBER(write)
HOST_NUMBER(close)
HOST_NUMBER(mmap)
HOST_NUMBER(mprotect)
HOST_NUMBER(munmap)
HOST_NUMBER(brk)
HOST_NUMBER(ioctl)
HOST_NUMBER(clone)
HOST_NUMBER(execve)
HOST_NUMBER(exit_group)
HOST_NUMBER(openat)
HOST_NUMBER(futex)
HOST_NUMBER(getrandom)
HOST_NUMBER(prctl)
HOST_NUMBER(seccomp)
HOST_NUMBER(socket)
HOST_NUMBER(kill)
HOST_NUMBER(pipe2)
HOST_NUMBER(rt_sigaction)
#undef HOST_NUMBER
#endif

/* How a call is granted, ordered by how much it allows, so that a call
 * two promises grant differently is granted as the more allowing one
 * says: a thread-only clone is a fork's, and either is anything's. */
enum rule {
  RULE_NONE,
  /* The call answers ENOSYS. */
  RULE_ENOSYS,
  /* mmap, mprotect and memfd_create, which `jit` grants whole. */
  RULE_MMAP,
  RULE_MPROTECT,
  RULE_MEMFD,
  /* clone: a thread only; any but one into a namespace; and, for a
   * program that builds a sandbox, one into the namespaces `nest` names. */
  RULE_CLONE_THREAD,
  RULE_CLONE_FORK,
  RULE_CLONE_NEST,
  /* A signal call: held to the process's own pid, or, where the filter
   * is told Landlock's signal scope holds the process, let through. */
  RULE_SIGNAL,
  /* Held to one argument, which a promise loosens only where a rule of
   * its own says so (the `_NEST` ones). */
  RULE_PID_SELF_OR_ZERO,
  RULE_PRLIMIT,
  RULE_PRLIMIT_NEST,
  RULE_PRIORITY,
  RULE_SCHED_POLICY,
  RULE_MADVISE,
  RULE_FCNTL,
  RULE_IOCTL,
  RULE_IOCTL_NEST,
  RULE_PRCTL,
  RULE_PRCTL_NEST,
  RULE_UNSHARE_NEST,
  RULE_SOCKET_UNIX,
  RULE_SOCKET_INET,
  RULE_SOCKET_UNIX_INET,
  RULE_OPEN,
  RULE_OPENAT,
  RULE_MODE1,
  RULE_MODE2,
  RULE_MKNOD1,
  RULE_MKNOD2,
  /* The call is allowed whole. */
  RULE_ALLOW,
  RULE_COUNT
};

struct grant {
  uint16_t call;
  uint8_t rule;
};

#define A(name) { CALL_##name, RULE_ALLOW }
#define R(name, rule) { CALL_##name, RULE_##rule }

/* What every program has: memory, time, signals to itself, threads,
 * descriptors, files, a unix socketpair, execve, and what a loader and a
 * libc ask before main. The calls that open, create or change a file are
 * here rather than under a promise, since Landlock holds the paths.
 *
 * Every call left out answers EPERM:
 * - setrlimit, and a prlimit64 that sets, unless the process cannot raise
 *   a hard limit (COSMIC_HELD_LIMITS): it may then lower its limits, and
 *   raise a soft one to its hard one. A start that sets soft and hard
 *   together (`rlimits`) leaves it no more than it began with.
 * - SysV IPC, chroot, mount and the namespace calls, which `nest` grants.
 * - pidfd_send_signal, which signals through a descriptor no pid rule sees,
 *   unless the signal scope holds (see RULE_SIGNAL).
 * - socket, except where the process is held to a root, network namespace
 *   and either Landlock ABI 9 or a root showing no directory or socket of the
 *   host's, that make a unix socket harmless (COSMIC_HELD_UNIX)
 *   or the caller names the families (`sockets`).
 * - vmsplice.
 * - The never-allowed set (ptrace, bpf, io_uring, ...), which no table names.
 *
 * `clone3` and `openat2` answer ENOSYS: the filter cannot read the
 * structure they take, and a libc falls back to clone and openat.
 *
 * The signal calls, tkill among them, take the process's own pid, or any
 * where Landlock's signal scope holds the process; see RULE_SIGNAL. getpgid,
 * getsid and setpgid take the process's own pid, or any where it is in a
 * pid namespace of its own (COSMIC_HELD_PIDS): kill's scope says nothing of
 * them, since a pgid read of a host process reveals it. */
static const struct grant basics[] = {
  /* Memory. mmap and mprotect refuse executable memory that is anonymous
   * or writable, which `jit` grants. */
  R(mmap, MMAP), R(mprotect, MPROTECT), A(munmap), A(mremap), A(brk), R(madvise, MADVISE),
  A(mlock), A(mlock2), A(munlock), A(mlockall), A(munlockall), A(mincore),
  A(msync), A(membarrier), A(mseal), A(map_shadow_stack), A(cachestat),
  R(memfd_create, MEMFD),
  /* Time. */
  A(clock_gettime), A(clock_getres), A(clock_nanosleep), A(gettimeofday),
  A(nanosleep), A(time), A(times), A(getitimer), A(setitimer), A(alarm),
  A(timer_create), A(timer_settime), A(timer_gettime), A(timer_getoverrun),
  A(timer_delete), A(timerfd_create), A(timerfd_settime), A(timerfd_gettime),
  /* Signals, to itself or, where the scope holds, anywhere in the domain. */
  A(rt_sigaction), A(rt_sigprocmask), A(rt_sigreturn), A(rt_sigpending),
  A(rt_sigsuspend), A(rt_sigtimedwait), A(sigaltstack), A(signalfd),
  A(signalfd4), A(pause), A(restart_syscall), R(kill, SIGNAL),
  R(tgkill, SIGNAL), R(tkill, SIGNAL), R(rt_sigqueueinfo, SIGNAL),
  R(rt_tgsigqueueinfo, SIGNAL),
  /* Threads, and who it is. */
  R(clone, CLONE_THREAD), R(clone3, ENOSYS), A(set_tid_address),
  A(set_robust_list), R(get_robust_list, PID_SELF_OR_ZERO), A(futex),
  A(futex_waitv), A(futex_wake), A(futex_wait), A(futex_requeue), A(gettid),
  A(getpid), A(getppid), R(getpgid, PID_SELF_OR_ZERO), A(getpgrp),
  R(getsid, PID_SELF_OR_ZERO), A(setsid), R(setpgid, PID_SELF_OR_ZERO),
  A(exit), A(exit_group), A(sched_yield),
  R(sched_getaffinity, PID_SELF_OR_ZERO), R(sched_setaffinity, PID_SELF_OR_ZERO),
  R(sched_getparam, PID_SELF_OR_ZERO), R(sched_setparam, PID_SELF_OR_ZERO),
  R(sched_getscheduler, PID_SELF_OR_ZERO), R(sched_setscheduler, SCHED_POLICY),
  R(sched_rr_get_interval, PID_SELF_OR_ZERO), R(sched_getattr, PID_SELF_OR_ZERO),
  A(sched_get_priority_max),
  A(sched_get_priority_min), A(getcpu), R(getpriority, PRIORITY),
  R(setpriority, PRIORITY), A(getuid), A(geteuid), A(getgid), A(getegid),
  A(getgroups), A(getresuid), A(getresgid), A(umask), A(uname), A(sysinfo),
  A(getrusage), A(getrlimit), R(prlimit64, PRLIMIT), R(prctl, PRCTL),
  A(arch_prctl), A(rseq), A(getrandom), A(wait4), A(waitid),
  /* Filters and rulesets, which only narrow what the process may do. */
  A(seccomp), A(landlock_create_ruleset), A(landlock_add_rule),
  A(landlock_restrict_self),
  A(execve), A(execveat),
  /* Descriptors it has: handed in, or made by the calls below. */
  A(read), A(write), A(readv), A(writev), A(pread64), A(pwrite64), A(preadv),
  A(pwritev), A(preadv2), A(pwritev2), A(close), A(close_range), A(dup),
  A(dup2), A(dup3), R(fcntl, FCNTL), R(ioctl, IOCTL), A(lseek), A(pipe),
  A(pipe2), A(poll), A(ppoll), A(select), A(pselect6), A(epoll_create),
  A(epoll_create1), A(epoll_ctl), A(epoll_wait), A(epoll_pwait),
  A(epoll_pwait2), A(eventfd), A(eventfd2), A(sendfile), A(splice), A(tee),
  A(copy_file_range), A(readahead), A(fadvise64), A(fallocate), A(fsync),
  A(fdatasync), A(sync_file_range), A(sync), A(syncfs), A(flock),
  A(ftruncate), A(truncate), A(inotify_init), A(inotify_init1),
  A(inotify_add_watch), A(inotify_rm_watch),
  /* Sockets: a socketpair of unix sockets, and the calls on a socket it
   * already has. `socket` itself is granted only where a unix socket may
   * be made (`collect`). A descriptor handed in is the grant that lets
   * it reach where its owner meant. */
  R(socketpair, SOCKET_UNIX), A(bind), A(connect), A(listen), A(accept),
  A(accept4), A(getsockname), A(getpeername), A(sendto), A(recvfrom),
  A(sendmsg), A(recvmsg), A(sendmmsg), A(recvmmsg), A(shutdown),
  A(setsockopt), A(getsockopt),
  /* Files: Landlock holds the paths, and the filter holds a mode to none
   * with a setuid, setgid or sticky bit. */
  R(open, OPEN), R(openat, OPENAT), R(creat, MODE1), R(openat2, ENOSYS),
  A(stat), A(fstat), A(lstat), A(newfstatat), A(statx), A(statfs), A(fstatfs),
  A(access), A(faccessat), A(faccessat2), A(readlink), A(readlinkat),
  A(getcwd), A(chdir), A(fchdir), A(rename), A(renameat), A(renameat2),
  R(mkdir, MODE1), R(mkdirat, MODE2), A(rmdir), A(link), A(linkat), A(unlink),
  A(unlinkat), A(symlink), A(symlinkat), R(mknod, MKNOD1), R(mknodat, MKNOD2),
  A(getdents), A(getdents64), A(getxattr), A(lgetxattr), A(fgetxattr),
  A(listxattr), A(llistxattr), A(flistxattr), A(getxattrat), A(listxattrat),
  A(file_getattr),
};

/* `nest`: what a program needs to build a sandbox of its own, as
 * [`Child.start`] with a policy does: namespaces, a root in them, and
 * the limits and capabilities it then sets. It is granted only to a
 * program in a root of its own (`isolate file`), which holds its files
 * instead of Landlock, since the kernel refuses a mount to a process a
 * Landlock ruleset holds.
 *
 * What each reaches is the program's own: a user namespace made here is
 * its own user namespace's child, in which its user is mapped and holds
 * what that namespace gives, over the namespaces it makes in it alone;
 * a mount is in a mount namespace it made, whose mounts it was given
 * locked (a read-only, noexec or nosuid mount of the root it copies
 * cannot be made writable, executable or setuid, nor unmounted to show
 * what is beneath); and setns, which could join a namespace of the
 * host through a descriptor it holds, is never granted.
 * - unshare, only of the user, mount, pid, IPC and network namespaces
 *   (RULE_UNSHARE_NEST): not cgroup, whose filesystem would then be
 *   mountable, UTS, which a program that builds a sandbox needs none of,
 *   or time.
 * - mount, umount2, pivot_root, and open_tree, move_mount and
 *   mount_setattr, which a mount of an idmapped tree and a flag
 *   change are made with.
 * - clone into those namespaces, and with CLONE_PARENT, as a start from
 *   a sandbox of its own makes its init: only beside `fork`, which is
 *   what makes a process.
 * - prctl's PR_CAPBSET_DROP and PR_CAP_AMBIENT, which give capabilities
 *   up, and setrlimit and prlimit64 that set, which a process may only
 *   lower without a capability the host's user namespace gives.
 * - the ioctls SIOCGIFFLAGS and SIOCSIFFLAGS (RULE_IOCTL_NEST), with which
 *   a start brings up the loopback of a network namespace it made.
 *   SIOCGIFFLAGS reveals the flags of an interface of the namespace the
 *   socket is in, by name. SIOCSIFFLAGS needs CAP_NET_ADMIN over that
 *   namespace's own user namespace, so it reaches only a namespace the
 *   sandbox made, never the host's.
 * - signals to any process, not only its own: a sandbox that starts one
 *   of its own ends and reaps it by pid and group. They reach only the
 *   processes of the pid namespace the program is in, which `isolate
 *   file` gives and the start of `nest` requires (core/syscalls.c's
 *   `spawn`), and it has no Landlock signal scope to make it so.
 * The calls that only the filesystem a mount shows or the host's own
 * namespaces could make dangerous (setns, fsopen and its kind, chroot,
 * sethostname) stay refused.
 *
 * Limits left, which no rule of this filter can close, since it cannot
 * tell one file system or one process from another by an argument that
 * is a string or a pid's parent:
 * - A procfs the program mounts in a pid namespace of its own shows what
 *   the host's /proc shows a user (the processor and memory files, the
 *   version, the sysctls it may read; writes are refused): the sandbox's
 *   own /proc is subset=pid, a mount of its own is not. A sysfs it tries
 *   is refused, the root having none for the kernel to find visible.
 * - A tmpfs it mounts is as large as its memory lets it, not `tmp`'s size.
 * - clone's CLONE_PARENT from the sandbox's first process gives the host
 *   process that started it a child, one inside the sandbox that the
 *   host process then has to reap. */
static const struct grant nest_calls[] = {
  R(unshare, UNSHARE_NEST), A(mount), A(umount2), A(pivot_root),
  A(mount_setattr), A(open_tree), A(move_mount), A(setrlimit),
  R(prlimit64, PRLIMIT_NEST), R(prctl, PRCTL_NEST), A(kill), A(tgkill), A(tkill),
  A(rt_sigqueueinfo), A(rt_tgsigqueueinfo), R(ioctl, IOCTL_NEST),
};

/* `fork`: a process of its own, and the descriptor to wait for it on. */
static const struct grant fork_calls[] = {
  A(fork), A(vfork), R(clone, CLONE_FORK), A(pidfd_open),
};

/* `jit`: memory that is executable and not a file's, and what makes it. */
static const struct grant jit_calls[] = {
  A(mmap), A(mprotect), A(pkey_mprotect), A(pkey_alloc), A(pkey_free),
  A(memfd_create),
};

/* `fattr`: a file's mode (never with a setuid, setgid or sticky bit),
 * times, owner and extended attributes. */
static const struct grant fattr_calls[] = {
  R(chmod, MODE1), R(fchmod, MODE1), R(fchmodat, MODE2), R(fchmodat2, MODE2),
  A(chown), A(fchown), A(lchown), A(fchownat), A(utime), A(utimes),
  A(futimesat), A(utimensat), A(setxattr), A(lsetxattr), A(fsetxattr),
  A(removexattr), A(lremovexattr), A(fremovexattr), A(setxattrat),
  A(removexattrat),
};

#undef A
#undef R

/* The classic BPF an instruction is made of, and what seccomp hands a
 * program: the call's number, the architecture, and its arguments, each
 * 64 bits, from a little-endian offset (both architectures are). */
#define OP_LOAD 0x20u
#define OP_AND 0x54u
#define OP_JUMP 0x05u
#define OP_EQ 0x15u
#define OP_GREATER 0x25u
#define OP_AT_LEAST 0x35u
#define OP_ANY_SET 0x45u
#define OP_RETURN 0x06u

#define DATA_NUMBER 0u
#define DATA_ARCH 4u
#define DATA_ARGUMENT(n) (16u + 8u * (n))
#define DATA_LOW 0u
#define DATA_HIGH 4u

/* What a program returns: seccomp's own values, with Linux's errno
 * numbers, which are no host's. */
#define RETURN_ALLOW 0x7fff0000u
#define RETURN_KILL_PROCESS 0x80000000u
#define RETURN_ERRNO(number) (0x00050000u | (number))
#define LINUX_EPERM 1u
#define LINUX_ENOTTY 25u
#define LINUX_ENOSYS 38u

#define AUDIT_X86_64 0xc000003eu
#define AUDIT_AARCH64 0xc00000b7u

/* The flags and options the rules read, as Linux has them on both
 * architectures. */
#define PROT_WRITE_BIT 0x2u
#define PROT_EXEC_BIT 0x4u
#define PROT_BTI_BIT 0x10u
#define MAP_ANONYMOUS_BIT 0x20u
#define MFD_NOEXEC_SEAL_BIT 0x8u
#define O_CREAT_BIT 0x40u
#define O_TMPFILE_BIT 0x400000u
#define SPECIAL_MODE_BITS 0xe00u
#define FILE_TYPE_BITS 0xf000u
#define TYPE_REGULAR 0x8000u
#define TYPE_FIFO 0x1000u
#define TYPE_SOCKET 0xc000u
#define AF_UNIX_FAMILY 1u
#define AF_INET_FAMILY 2u
#define AF_INET6_FAMILY 10u
#define SCHED_RESET_ON_FORK_BIT 0x40000000u

/* clone's flags: the namespaces (CLONE_NEWNS, CLONE_NEWCGROUP, UTS, IPC,
 * USER, PID and NET), CLONE_PTRACE and CLONE_PARENT, which a process
 * never has; and what a thread has: CLONE_VM, FILES, SIGHAND and THREAD.
 * The low byte is the signal the child ends with, not a flag. */
#define CLONE_NAMESPACES 0x7e020000u
#define CLONE_FORBIDDEN (CLONE_NAMESPACES | 0x2000u | 0x8000u)

/* What `nest` lets a process make: the user, mount, pid, IPC and network
 * namespaces, and clone's CLONE_PARENT. */
#define NEST_NAMESPACES 0x78020000u
#define CLONE_FORBIDDEN_NEST ((CLONE_NAMESPACES & ~NEST_NAMESPACES) | 0x2000u)
#define CLONE_THREAD_REQUIRED (0x100u | 0x400u | 0x800u | 0x10000u)

/* What a rule's block is built with: instructions appended to `code`,
 * which `full` says ran out of room for, or a jump too far. */
struct builder {
  struct cosmic_insn *code;
  size_t length;
  bool full;
};

/* Appends one instruction, answers where it went (0 when it did not). */
static size_t emit (struct builder *b, uint16_t code, uint8_t jt, uint8_t jf, uint32_t k) {
  if (b->length >= COSMIC_PROMISE_INSNS) {
    b->full = true;
    return 0;
  }
  b->code[b->length] = (struct cosmic_insn){ code, jt, jf, k };
  return b->length++;
}

/* Where a jump in a block goes: the next instruction, the one after it,
 * or the block's end, where a call is allowed or denied. */
enum target { JUMP_NEXT, JUMP_SKIP, JUMP_ALLOW, JUMP_DENY };

struct patch {
  size_t at;
  bool when_false;
  enum target target;
};

/* A rule's block, whose jumps to its end are patched once it has one. */
struct block {
  struct builder *b;
  struct patch patches[32];
  size_t patch_count;
};

static uint8_t jump_to (struct block *k, size_t at, bool when_false, enum target target) {
  if (target == JUMP_NEXT) return 0;
  if (target == JUMP_SKIP) return 1;
  if (k->patch_count < sizeof k->patches / sizeof k->patches[0])
    k->patches[k->patch_count++] = (struct patch){ at, when_false, target };
  else
    k->b->full = true;
  return 0;
}

/* A comparison of the accumulator with `value`, going `yes` where it
 * holds and `no` where it does not. */
static void test (struct block *k, uint16_t op, uint32_t value, enum target yes, enum target no) {
  size_t at = k->b->length;
  uint8_t jt = jump_to(k, at, false, yes);
  uint8_t jf = jump_to(k, at, true, no);
  emit(k->b, op, jt, jf, value);
}

/* The accumulator is argument `n`'s low 32 bits -- where an `int` or an
 * `unsigned` the kernel truncates to is, so a high bit set by the
 * caller reads as the kernel will -- or its high ones. */
static void load (struct block *k, uint32_t offset) {
  emit(k->b, OP_LOAD, 0, 0, offset);
}

static void mask (struct block *k, uint32_t value) {
  emit(k->b, OP_AND, 0, 0, value);
}

/* Closes the block with a denial -- what falls off its end -- then an
 * allowance, and points its jumps at them. */
static void finish (struct block *k, uint32_t denial) {
  struct builder *b = k->b;
  size_t deny = emit(b, OP_RETURN, 0, 0, denial);
  size_t allow = emit(b, OP_RETURN, 0, 0, RETURN_ALLOW);
  for (size_t i = 0; i < k->patch_count; i++) {
    const struct patch *p = &k->patches[i];
    size_t to = p->target == JUMP_ALLOW ? allow : deny;
    size_t distance = to - (p->at + 1);
    if (distance > 255) {
      b->full = true;
      continue;
    }
    if (p->when_false) b->code[p->at].jf = (uint8_t)distance;
    else b->code[p->at].jt = (uint8_t)distance;
  }
}

/* Allowed when the accumulator is one of `values`. */
static void allow_one_of (struct block *k, const uint32_t *values, size_t count) {
  for (size_t i = 0; i < count; i++) test(k, OP_EQ, values[i], JUMP_ALLOW, JUMP_NEXT);
}

/* The commands fcntl may be given: duplicating, flags, locks (record and
 * open file description), the owner read, pipe sizes and seals. Not
 * F_SETOWN, which points signals at another process, F_SETSIG, F_NOTIFY
 * or any lease. */
static const uint32_t fcntl_commands[] = {
  0, 1, 2, 3, 4, 5, 6, 7, 9, 36, 37, 38, 1030, 1031, 1032, 1033, 1034,
};

/* The ioctls that read a descriptor or a terminal: FIONREAD, FIONBIO,
 * FIOCLEX and FIONCLEX; TCGETS, TCGETA and TCGETS2, TIOCGWINSZ, TIOCGPGRP,
 * TIOCGSID and TIOCOUTQ. The same numbers on both architectures. */
static const uint32_t ioctl_commands[] = {
  0x541b, 0x5421, 0x5451, 0x5450, 0x5401, 0x5405, 0x802c542a, 0x5413, 0x540f,
  0x5429, 0x5411,
};

/* The ioctls `nest` adds: SIOCGIFFLAGS and SIOCSIFFLAGS, with which a
 * sandbox's start brings up the loopback of the network namespace it made
 * for the program. SIOCGIFFLAGS reveals the flags of a named interface of
 * the namespace the socket is in, which the filter cannot narrow to the
 * program's own. SIOCSIFFLAGS needs CAP_NET_ADMIN over that namespace's own
 * user namespace, so it reaches only a namespace the sandbox made. */
static const uint32_t nest_ioctl_commands[] = { 0x8913, 0x8914 };

/* The prctl options a program may use: its parent-death signal, whether it
 * dumps core, its name, the filter and no_new_privs it holds, the
 * bounding set read, being a subreaper, its timer slack, naming an
 * anonymous mapping (PR_SET_VMA), the transparent huge page switch, and
 * the memory-deny-write-execute setting. Not the keep-capabilities,
 * securebits, ptracer, memory map or ambient capability ones. */
static const uint32_t prctl_options[] = {
  1, 2, 3, 4, 15, 16, 21, 22, 23, 29, 30, 36, 37, 38, 39, 40, 41, 42, 65, 66,
  0x53564d41,
};

/* The prctl options `nest` adds: PR_CAPBSET_DROP and PR_CAP_AMBIENT, with
 * which a sandbox's start gives up the capabilities its namespace gave. */
static const uint32_t nest_prctl_options[] = { 24, 47 };

/* The scheduling policies a program may set itself to: SCHED_OTHER,
 * SCHED_BATCH and SCHED_IDLE, none of which is real-time. */
static const uint32_t sched_policies[] = { 0, 3, 5 };

/* The madvise advice a program may give: normal, random, sequential,
 * will-need, dont-need, free, and the fork, dump, huge-page, wipe, cold,
 * page-out and populate hints. Not MADV_REMOVE, which punches a hole in
 * a file, MADV_MERGEABLE (KSM), nor MADV_HWPOISON, MADV_SOFT_OFFLINE or
 * the other advice that needs privilege. */
static const uint32_t madvise_advice[] = {
  0, 1, 2, 3, 4, 8, 10, 11, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
};

/* The block of `rule`, entered with a call's arguments in the data.
 * `pid` is the process's own, which a rule about who a call is aimed at
 * compares with. */
static void rule_block (struct builder *b, enum rule rule, uint32_t pid, enum cosmic_arch arch) {
  struct block k = { .b = b, .patch_count = 0 };
  uint32_t denial = RETURN_ERRNO(LINUX_EPERM);
  switch (rule) {
    case RULE_MMAP:
    /* Executable only where it is a file's and not writable: never
     * W and X at once, never anonymous. */
    load(&k, DATA_ARGUMENT(2) + DATA_LOW);
    test(&k, OP_ANY_SET, PROT_EXEC_BIT, JUMP_NEXT, JUMP_ALLOW);
    test(&k, OP_ANY_SET, PROT_WRITE_BIT, JUMP_DENY, JUMP_NEXT);
    load(&k, DATA_ARGUMENT(3) + DATA_LOW);
    test(&k, OP_ANY_SET, MAP_ANONYMOUS_BIT, JUMP_DENY, JUMP_ALLOW);
    break;
    case RULE_MPROTECT:
    load(&k, DATA_ARGUMENT(2) + DATA_LOW);
    if (arch == COSMIC_ARCH_AARCH64) {
      /* glibc's loader marks every branch-target-protected library's
       * text with PROT_EXEC | PROT_BTI, and fails to load it if that
       * is refused: so an executable protection is allowed with
       * PROT_BTI and without PROT_WRITE, the loader's shape.
       * TODO: refuse it again, as x86_64's is, once spawn starts a
       * child with no `jit` on an address space of its own, where
       * PR_SET_MDWE (which lets this through, since a mapping that
       * was executable stays so) can hold the rest. Until then
       * memory that was mapped writable and written can be made
       * executable with this protection. */
      test(&k, OP_ANY_SET, PROT_EXEC_BIT, JUMP_NEXT, JUMP_ALLOW);
      test(&k, OP_ANY_SET, PROT_WRITE_BIT, JUMP_DENY, JUMP_NEXT);
      test(&k, OP_ANY_SET, PROT_BTI_BIT, JUMP_ALLOW, JUMP_DENY);
    } else {
      test(&k, OP_ANY_SET, PROT_EXEC_BIT, JUMP_DENY, JUMP_ALLOW);
    }
    break;
    case RULE_MEMFD:
    /* A memfd that can never be executed: MFD_NOEXEC_SEAL. */
    load(&k, DATA_ARGUMENT(1) + DATA_LOW);
    mask(&k, MFD_NOEXEC_SEAL_BIT);
    test(&k, OP_EQ, MFD_NOEXEC_SEAL_BIT, JUMP_ALLOW, JUMP_DENY);
    break;
    case RULE_CLONE_THREAD:
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    test(&k, OP_ANY_SET, CLONE_FORBIDDEN, JUMP_DENY, JUMP_NEXT);
    mask(&k, CLONE_THREAD_REQUIRED);
    test(&k, OP_EQ, CLONE_THREAD_REQUIRED, JUMP_ALLOW, JUMP_DENY);
    break;
    case RULE_CLONE_FORK:
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    test(&k, OP_ANY_SET, CLONE_FORBIDDEN, JUMP_DENY, JUMP_ALLOW);
    break;
    case RULE_CLONE_NEST:
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    test(&k, OP_ANY_SET, CLONE_FORBIDDEN_NEST, JUMP_DENY, JUMP_ALLOW);
    break;
    case RULE_UNSHARE_NEST:
    /* Only the namespaces `nest` names; the kernel refuses a flag it
     * does not know, past the low 32 bits too. */
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    mask(&k, ~NEST_NAMESPACES);
    test(&k, OP_EQ, 0, JUMP_ALLOW, JUMP_DENY);
    break;
    case RULE_SIGNAL:
    /* Unscoped, the pid is held. A tid equal to it is the thread group
     * leader's own, so tkill takes this rule too. */
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    test(&k, OP_EQ, pid, JUMP_ALLOW, JUMP_DENY);
    break;
    case RULE_PID_SELF_OR_ZERO:
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    test(&k, OP_EQ, 0, JUMP_ALLOW, JUMP_NEXT);
    test(&k, OP_EQ, pid, JUMP_ALLOW, JUMP_DENY);
    break;
    case RULE_PRLIMIT:
    /* Its own limits, read and not set: a null new limit. */
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    test(&k, OP_EQ, 0, JUMP_SKIP, JUMP_NEXT);
    test(&k, OP_EQ, pid, JUMP_NEXT, JUMP_DENY);
    load(&k, DATA_ARGUMENT(2) + DATA_LOW);
    test(&k, OP_EQ, 0, JUMP_NEXT, JUMP_DENY);
    load(&k, DATA_ARGUMENT(2) + DATA_HIGH);
    test(&k, OP_EQ, 0, JUMP_ALLOW, JUMP_DENY);
    break;
    case RULE_PRLIMIT_NEST:
    /* Its own limits, read or set: it may lower them. */
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    test(&k, OP_EQ, 0, JUMP_ALLOW, JUMP_NEXT);
    test(&k, OP_EQ, pid, JUMP_ALLOW, JUMP_DENY);
    break;
    case RULE_PRIORITY:
    /* PRIO_PROCESS (0) of the calling process, which `who` 0 names:
     * not PRIO_USER, which would renice every process of the user. */
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    test(&k, OP_EQ, 0, JUMP_NEXT, JUMP_DENY);
    load(&k, DATA_ARGUMENT(1) + DATA_LOW);
    test(&k, OP_EQ, 0, JUMP_ALLOW, JUMP_DENY);
    break;
    case RULE_SCHED_POLICY:
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    test(&k, OP_EQ, 0, JUMP_SKIP, JUMP_NEXT);
    test(&k, OP_EQ, pid, JUMP_NEXT, JUMP_DENY);
    load(&k, DATA_ARGUMENT(1) + DATA_LOW);
    mask(&k, ~SCHED_RESET_ON_FORK_BIT);
    allow_one_of(&k, sched_policies, sizeof sched_policies / sizeof sched_policies[0]);
    break;
    case RULE_MADVISE:
    load(&k, DATA_ARGUMENT(2) + DATA_LOW);
    allow_one_of(&k, madvise_advice, sizeof madvise_advice / sizeof madvise_advice[0]);
    break;
    case RULE_FCNTL:
    load(&k, DATA_ARGUMENT(1) + DATA_LOW);
    allow_one_of(&k, fcntl_commands, sizeof fcntl_commands / sizeof fcntl_commands[0]);
    break;
    case RULE_IOCTL:
    denial = RETURN_ERRNO(LINUX_ENOTTY);
    load(&k, DATA_ARGUMENT(1) + DATA_LOW);
    allow_one_of(&k, ioctl_commands, sizeof ioctl_commands / sizeof ioctl_commands[0]);
    break;
    case RULE_IOCTL_NEST:
    denial = RETURN_ERRNO(LINUX_ENOTTY);
    load(&k, DATA_ARGUMENT(1) + DATA_LOW);
    allow_one_of(&k, ioctl_commands, sizeof ioctl_commands / sizeof ioctl_commands[0]);
    allow_one_of(&k, nest_ioctl_commands, sizeof nest_ioctl_commands / sizeof nest_ioctl_commands[0]);
    break;
    case RULE_PRCTL:
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    allow_one_of(&k, prctl_options, sizeof prctl_options / sizeof prctl_options[0]);
    break;
    case RULE_PRCTL_NEST:
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    allow_one_of(&k, prctl_options, sizeof prctl_options / sizeof prctl_options[0]);
    allow_one_of(&k, nest_prctl_options, sizeof nest_prctl_options / sizeof nest_prctl_options[0]);
    break;
    case RULE_SOCKET_UNIX:
    /* The family is the first argument of socket and socketpair. */
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    test(&k, OP_EQ, AF_UNIX_FAMILY, JUMP_ALLOW, JUMP_DENY);
    break;
    case RULE_SOCKET_INET:
    case RULE_SOCKET_UNIX_INET:
    /* Only the families: netlink and packet sockets (16, 17) stay
     * refused, and a raw one needs a capability no program has. */
    load(&k, DATA_ARGUMENT(0) + DATA_LOW);
    if (rule == RULE_SOCKET_UNIX_INET) test(&k, OP_EQ, AF_UNIX_FAMILY, JUMP_ALLOW, JUMP_NEXT);
    test(&k, OP_EQ, AF_INET_FAMILY, JUMP_ALLOW, JUMP_NEXT);
    test(&k, OP_EQ, AF_INET6_FAMILY, JUMP_ALLOW, JUMP_DENY);
    break;
    case RULE_OPEN:
    case RULE_OPENAT: {
      /* A mode is read only where the call creates a file. */
      uint32_t flags = rule == RULE_OPEN ? 1 : 2;
      load(&k, DATA_ARGUMENT(flags) + DATA_LOW);
      test(&k, OP_ANY_SET, O_CREAT_BIT | O_TMPFILE_BIT, JUMP_NEXT, JUMP_ALLOW);
      load(&k, DATA_ARGUMENT(flags + 1) + DATA_LOW);
      test(&k, OP_ANY_SET, SPECIAL_MODE_BITS, JUMP_DENY, JUMP_ALLOW);
      break;
    }
    case RULE_MODE1:
    case RULE_MODE2:
    load(&k, DATA_ARGUMENT(rule == RULE_MODE1 ? 1 : 2) + DATA_LOW);
    test(&k, OP_ANY_SET, SPECIAL_MODE_BITS, JUMP_DENY, JUMP_ALLOW);
    break;
    case RULE_MKNOD1:
    case RULE_MKNOD2:
    /* A file, a fifo or a socket, and never a device. */
    load(&k, DATA_ARGUMENT(rule == RULE_MKNOD1 ? 1 : 2) + DATA_LOW);
    test(&k, OP_ANY_SET, SPECIAL_MODE_BITS, JUMP_DENY, JUMP_NEXT);
    mask(&k, FILE_TYPE_BITS);
    test(&k, OP_EQ, 0, JUMP_ALLOW, JUMP_NEXT);
    test(&k, OP_EQ, TYPE_REGULAR, JUMP_ALLOW, JUMP_NEXT);
    test(&k, OP_EQ, TYPE_FIFO, JUMP_ALLOW, JUMP_NEXT);
    test(&k, OP_EQ, TYPE_SOCKET, JUMP_ALLOW, JUMP_DENY);
    break;
    default:
    break;
  }
  finish(&k, denial);
}

/* One call that is allowed, by its number on the architecture, and how. */
struct entry {
  uint16_t number;
  uint8_t rule;
};

/* A call a rule's block is jumped to from: its jump, to be pointed at the
 * block once every block has a place. */
struct pending {
  size_t at;
  uint8_t rule;
};

/* How many instructions a run of entries is left to compare one by one
 * instead of halving. */
#define LEAF_RUN 4

/* The decision tree over `entries`, sorted by number: past a handful it
 * halves, a jump over the lower half to the upper where the number is the
 * middle one or more, and each leaf compares one number and returns, or
 * jumps to its rule. A run that matches nothing ends in the denial. A
 * leaf's jump to a rule is left for `pending`. */
static void tree (struct builder *b, const struct entry *entries, size_t count,
                  struct pending *pending, size_t *pending_count) {
  if (count <= LEAF_RUN) {
    for (size_t i = 0; i < count; i++) {
      emit(b, OP_EQ, 0, 1, entries[i].number);
      if (entries[i].rule == RULE_ALLOW) {
        emit(b, OP_RETURN, 0, 0, RETURN_ALLOW);
      } else if (entries[i].rule == RULE_ENOSYS) {
        emit(b, OP_RETURN, 0, 0, RETURN_ERRNO(LINUX_ENOSYS));
      } else {
        size_t at = emit(b, OP_JUMP, 0, 0, 0);
        pending[(*pending_count)++] = (struct pending){ at, entries[i].rule };
      }
    }
    emit(b, OP_RETURN, 0, 0, RETURN_ERRNO(LINUX_EPERM));
    return;
  }
  size_t middle = count / 2;
  emit(b, OP_AT_LEAST, 0, 1, entries[middle].number);
  size_t over = emit(b, OP_JUMP, 0, 0, 0);
  tree(b, entries, middle, pending, pending_count);
  b->code[over].k = (uint32_t)(b->length - over - 1);
  tree(b, entries + middle, count - middle, pending, pending_count);
}

/* Adds each call of `table` to `rules`, the more allowing of two grants
 * of one call winning. */
static void add (uint8_t *rules, const struct grant *table, size_t count) {
  for (size_t i = 0; i < count; i++) {
    if (table[i].rule > rules[table[i].call]) rules[table[i].call] = table[i].rule;
  }
}

#define ADD(table) add(rules, table, sizeof table / sizeof table[0])

/* Writes to `out`, room for COSMIC_PROMISE_INSNS, the program that holds
 * a process of `arch` and pid `pid` to `promises`, and answers how many
 * instructions it is, or 0 where it did not fit. `held` says what else
 * holds the process (core/promises.h's COSMIC_HELD_ bits).
 *
 * COSMIC_HELD_SIGNALS says it is in a Landlock domain that handles
 * LANDLOCK_SCOPE_SIGNAL (ABI 6): its signal calls then take any pid, and
 * pidfd_send_signal is allowed. The kernel's check holds them, per
 * target: a signal to a process outside the domain -- a parent domain or
 * a process with none (linux/landlock.h) -- is refused with EPERM, and
 * every way of naming a target goes through it: a pid, a thread, a group
 * (negative, or 0), every process (-1, which the kernel answers 0 when it
 * signalled none), a pidfd, and the queueing calls. Without
 * COSMIC_HELD_SIGNALS they keep to the process's own pid.
 *
 * `sockets` (COSMIC_SOCKETS_ bits) lets it make a socket of those
 * families -- socket(AF_UNIX), AF_INET and AF_INET6 -- a socketpair of
 * unix ones it always may; COSMIC_HELD_UNIX adds AF_UNIX.
 *
 * COSMIC_HELD_LIMITS lets it set its own limits. A pointer is all
 * setrlimit and prlimit64 take, which no rule can read, so no call that
 * only lowers can be told from one that raises: the hold is that the
 * kernel refuses a raised hard limit to a process without CAP_SYS_RESOURCE
 * of the initial user namespace (`capable`, not `ns_capable`), so the
 * process may not have it, now or after an exec (no_new_privs bounds
 * what an exec gives by what it holds). Limits a start set soft and hard
 * together then stay what it set, at most. A process that holds the
 * capability keeps the refusal: its limits are its own to raise.
 * COSMIC_HELD_PIDS lets getpgid, getsid, setpgid and capget (whose header
 * names a pid, which no rule can read) take any pid: in a pid
 * namespace of its own a pid names a process of the sandbox or none (the
 * kernel answers ESRCH), and setpgid reaches only the caller and its
 * children whichever pid it is given. Nothing in it depends on the host. */
static size_t program_for (struct cosmic_insn *out, enum cosmic_arch arch,
                                      unsigned promises, unsigned sockets, uint32_t pid,
                                      unsigned held) {
  const short *numbers = arch == COSMIC_ARCH_X86_64 ? x86_64_numbers : aarch64_numbers;
  uint32_t audit = arch == COSMIC_ARCH_X86_64 ? AUDIT_X86_64 : AUDIT_AARCH64;
  uint8_t rules[CALL_COUNT];
  memset(rules, 0, sizeof rules);
  ADD(basics);
  if (held & COSMIC_HELD_UNIX) sockets |= COSMIC_SOCKETS_UNIX;
  if (sockets == COSMIC_SOCKETS_UNIX) rules[CALL_socket] = RULE_SOCKET_UNIX;
  else if (sockets == COSMIC_SOCKETS_INET) rules[CALL_socket] = RULE_SOCKET_INET;
  else if (sockets == (COSMIC_SOCKETS_UNIX | COSMIC_SOCKETS_INET))
    rules[CALL_socket] = RULE_SOCKET_UNIX_INET;
  if (promises & COSMIC_PROMISE_FORK) ADD(fork_calls);
  if (promises & COSMIC_PROMISE_JIT) ADD(jit_calls);
  if (promises & COSMIC_PROMISE_FATTR) ADD(fattr_calls);
  if (promises & COSMIC_PROMISE_NEST) {
    ADD(nest_calls);
    /* A sandbox's start makes processes, which is `fork`'s. */
    if (promises & COSMIC_PROMISE_FORK) rules[CALL_clone] = RULE_CLONE_NEST;
  }

  if (held & COSMIC_HELD_SIGNALS) {
    for (int call = 0; call < CALL_COUNT; call++)
      if (rules[call] == RULE_SIGNAL) rules[call] = RULE_ALLOW;
    rules[CALL_pidfd_send_signal] = RULE_ALLOW;
  }
  if (held & COSMIC_HELD_LIMITS) {
    rules[CALL_setrlimit] = RULE_ALLOW;
    /* Its own limits only: the rule holds the pid, which another process
     * of the user could be set a limit of. */
    if (rules[CALL_prlimit64] < RULE_PRLIMIT_NEST) rules[CALL_prlimit64] = RULE_PRLIMIT_NEST;
  }
  if (held & COSMIC_HELD_PIDS) {
    rules[CALL_getpgid] = RULE_ALLOW;
    rules[CALL_getsid] = RULE_ALLOW;
    rules[CALL_setpgid] = RULE_ALLOW;
    /* The capabilities of a process, which `restrict` reads to know it
     * cannot raise a hard limit, and which name a pid in the header. */
    rules[CALL_capget] = RULE_ALLOW;
  }

  /* The calls this architecture has a number for, in number order. */
  struct entry entries[CALL_COUNT];
  size_t count = 0;
  for (int call = 0; call < CALL_COUNT; call++) {
    if (rules[call] == RULE_NONE || numbers[call] == 0) continue;
    struct entry entry = { (uint16_t)(numbers[call] - 1), rules[call] };
    size_t at = count++;
    while (at > 0 && entries[at - 1].number > entry.number) {
      entries[at] = entries[at - 1];
      at--;
    }
    entries[at] = entry;
  }

  struct builder b = { out, 0, false };
  emit(&b, OP_LOAD, 0, 0, DATA_ARCH);
  emit(&b, OP_EQ, 1, 0, audit);
  emit(&b, OP_RETURN, 0, 0, RETURN_KILL_PROCESS);
  /* Above the reviewed table is ENOSYS: x32's numbers, which set a high
   * bit, are among them. */
  emit(&b, OP_LOAD, 0, 0, DATA_NUMBER);
  emit(&b, OP_GREATER, 0, 1, PROMISE_CALLS_REVIEWED - 1);
  emit(&b, OP_RETURN, 0, 0, RETURN_ERRNO(LINUX_ENOSYS));

  struct pending pending[CALL_COUNT];
  size_t pending_count = 0;
  tree(&b, entries, count, pending, &pending_count);

  size_t blocks[RULE_COUNT] = { 0 };
  bool needed[RULE_COUNT];
  memset(needed, 0, sizeof needed);
  for (size_t i = 0; i < pending_count; i++) needed[pending[i].rule] = true;
  for (int rule = 0; rule < RULE_COUNT; rule++) {
    if (!needed[rule]) continue;
    blocks[rule] = b.length;
    rule_block(&b, (enum rule)rule, pid, arch);
  }
  for (size_t i = 0; i < pending_count; i++)
    b.code[pending[i].at].k = (uint32_t)(blocks[pending[i].rule] - pending[i].at - 1);
  return b.full ? 0 : b.length;
}

#undef ADD

unsigned cosmic_promise_named (const char *name) {
  if (strcmp(name, "fork") == 0) return COSMIC_PROMISE_FORK;
  if (strcmp(name, "jit") == 0) return COSMIC_PROMISE_JIT;
  if (strcmp(name, "fattr") == 0) return COSMIC_PROMISE_FATTR;
  if (strcmp(name, "nest") == 0) return COSMIC_PROMISE_NEST;
  return 0;
}

#if defined(__linux__) && defined(__NR_syscalls)
const int cosmic_promise_headers_end = __NR_syscalls;
#else
const int cosmic_promise_headers_end = 0;
#endif

#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
/* Whether the process lacks CAP_SYS_RESOURCE in its permitted set, and so
 * can never raise a hard limit: the kernel asks it of the initial user
 * namespace, which no capability of a process's own gives, and no_new_privs
 * (set by the caller) keeps an exec from giving a permitted set more than
 * this one. A capability of a user namespace the process made reads as
 * held, which refuses where it need not: the caller that made one says so
 * with COSMIC_HELD_LIMITS. Where an earlier filter refuses capget (EPERM,
 * which capget itself never answers), a setrlimit of a limit to the value
 * it has stands in: it succeeds only if that filter allows setrlimit, which
 * it does only after proving the capability absent (or, under `nest`, in a
 * user namespace of its own), and the process only ever loses capabilities.
 * False where neither can be told. */
static bool lacks_resource_capability (void) {
  struct __user_cap_header_struct header = { _LINUX_CAPABILITY_VERSION_3, 0 };
  struct __user_cap_data_struct data[_LINUX_CAPABILITY_U32S_3];
  if (syscall(SYS_capget, &header, data) != 0) {
    struct rlimit current;
    if (errno != EPERM || getrlimit(RLIMIT_NOFILE, &current) != 0) return false;
    return setrlimit(RLIMIT_NOFILE, &current) == 0;
  }
  return (data[CAP_TO_INDEX(CAP_SYS_RESOURCE)].permitted & CAP_TO_MASK(CAP_SYS_RESOURCE)) == 0;
}
#endif

int cosmic_promises_apply (unsigned promises, unsigned sockets, unsigned held) {
#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
#if defined(__x86_64__)
  enum cosmic_arch arch = COSMIC_ARCH_X86_64;
#else
  enum cosmic_arch arch = COSMIC_ARCH_AARCH64;
#endif
  /* no_new_privs first: the capabilities read below are then all the
   * process can have. */
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return errno;
  if (lacks_resource_capability()) held |= COSMIC_HELD_LIMITS;
  struct cosmic_insn code[COSMIC_PROMISE_INSNS];
  size_t length = program_for(code, arch, promises, sockets, (uint32_t)getpid(), held);
  if (length == 0) return ENOSPC;
  _Static_assert(sizeof(struct sock_filter) == sizeof(struct cosmic_insn), "one instruction");
  struct sock_fprog program = { (unsigned short)length, (struct sock_filter *)code };
  if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) != 0) return errno;
  return 0;
#else
  (void)promises;
  (void)sockets;
  (void)held;
  return ENOSYS;
#endif
}

COSMIC_SYSCALL(promise_filter, 3) {
  luaL_checktype(L, 1, LUA_TTABLE);
  unsigned promises = 0;
  lua_Integer listed = (lua_Integer)lua_rawlen(L, 1);
  for (lua_Integer i = 1; i <= listed; i++) {
    lua_rawgeti(L, 1, i);
    unsigned bit = lua_type(L, -1) == LUA_TSTRING ? cosmic_promise_named(lua_tostring(L, -1)) : 0;
    if (bit == 0) return luaL_argerror(L, 1, "a promise is \"fork\", \"jit\", \"fattr\" or \"nest\"");
    promises |= bit;
    lua_pop(L, 1);
  }
  const char *name = luaL_checkstring(L, 2);
  enum cosmic_arch arch;
  if (strcmp(name, "x86_64") == 0) arch = COSMIC_ARCH_X86_64;
  else if (strcmp(name, "aarch64") == 0) arch = COSMIC_ARCH_AARCH64;
  else return luaL_argerror(L, 2, "an architecture is \"x86_64\" or \"aarch64\"");
  lua_Integer pid = 1;
  unsigned sockets = 0;
  unsigned held = 0;
  if (!lua_isnoneornil(L, 3)) {
    luaL_checktype(L, 3, LUA_TTABLE);
    lua_getfield(L, 3, "pid");
    if (!lua_isnil(L, -1)) {
      pid = lua_isinteger(L, -1) ? lua_tointeger(L, -1) : -1;
      if (pid < 1 || pid > INT32_MAX) return luaL_argerror(L, 3, "pid must be a positive integer");
    }
    lua_getfield(L, 3, "unix");
    if (lua_toboolean(L, -1)) sockets |= COSMIC_SOCKETS_UNIX;
    lua_getfield(L, 3, "inet");
    if (lua_toboolean(L, -1)) sockets |= COSMIC_SOCKETS_INET;
    static const struct { const char *name; unsigned bit; } holds[] = {
      { "scoped", COSMIC_HELD_SIGNALS }, { "unix_held", COSMIC_HELD_UNIX },
      { "limits_held", COSMIC_HELD_LIMITS }, { "pids_held", COSMIC_HELD_PIDS },
    };
    for (size_t i = 0; i < sizeof holds / sizeof holds[0]; i++) {
      lua_getfield(L, 3, holds[i].name);
      if (lua_toboolean(L, -1)) held |= holds[i].bit;
      lua_pop(L, 1);
    }
    lua_pop(L, 3);
  }
  struct cosmic_insn code[COSMIC_PROMISE_INSNS];
  size_t length = program_for(code, arch, promises, sockets, (uint32_t)pid, held);
  if (length == 0) return luaL_error(L, "the filter does not fit");
  lua_pushlstring(L, (const char *)code, length * sizeof code[0]);
  return 1;
}
