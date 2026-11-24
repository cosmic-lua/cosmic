/* The child's side of a sandboxed start on Linux: the namespaces it
 * makes, the root it builds and moves into, its procfs, idmapped binds,
 * loopback and relay listeners, and the ids and capabilities it keeps. */

#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#define _XOPEN_SOURCE 700

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <termios.h>
#if defined(__linux__)
#include <linux/capability.h>
#include <linux/landlock.h>
#include <linux/sched.h>
#include <linux/if.h>
#include <linux/sockios.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <stddef.h>
#include <sys/auxv.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/vfs.h>
/* _XOPEN_SOURCE intentionally hides these libc escape hatches: syscall,
 * for the calls musl has no wrapper for, and clone, which starts a child
 * on this process's memory (core/spawn.c's `start_child`). */
extern long syscall (long, ...);
extern int clone (int (*)(void *), void *, int, void *, ...);
#endif
#if defined(__APPLE__)
#include <spawn.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/event.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#endif
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/utsname.h>

#include "check.h"
#include "coverage.h"
#include "fail.h"
#include "fault.h"
#include "guard.h"
#include "lauxlib.h"
#include "executable.h"
#include "memory.h"
#include "crypto.h"
#include "environment.h"
#include "syscalls.h"
#include "portable.h"
#include "process.h"
#include "rand.h"
#include "startup.h"
#include "store.h"

#include "sandbox.h"

#if defined(__linux__)
/* Writes `text` whole to the file at `path`, relative to the directory
 * `dir` holds (AT_FDCWD for this process's own): 0, or an errno. */
static int write_whole_at (int dir, const char *path, const char *text) {
  int fd = openat(dir, path, O_WRONLY | O_CLOEXEC);
  if (fd < 0) return errno;
  size_t left = strlen(text);
  int number = 0;
  while (left > 0) {
    ssize_t put = write(fd, text, left);
    if (put < 0 && errno == EINTR) continue;
    if (put <= 0) { number = put < 0 ? errno : EIO; break; }
    text += put;
    left -= (size_t)put;
  }
  close(fd);
  return number;
}

/* Writes `text` to the file at `path` whole: 0, or an errno. */
static int write_whole (const char *path, const char *text) {
  return write_whole_at(AT_FDCWD, path, text);
}

/* The mode a directory made at `path` in the root being built takes:
 * that of the one it stands for, `skip` bytes in, the host's own path
 * -- a program may check its directories' modes, as a cache refusing
 * one others can write to does -- or 0755 where the host has none. */
static mode_t mirrored_mode (const char *path, size_t skip) {
  struct stat st;
  if (stat(path + skip, &st) == 0 && S_ISDIR(st.st_mode)) return st.st_mode & 07777;
  return 0755;
}

/* Makes the directory `name` in the one `dir` holds (AT_FDCWD for this
 * process's own) with `mode`, whatever the umask, which is cleared while
 * it does and put back, so no chmod is asked of a child whose filter
 * grants none (a `nest` program, whose start of its own builds a root as
 * this does): a mode with a setuid or setgid bit is made without them
 * where the filter refuses one, as it does a mode made with them,
 * and the bits the kernel does not make a directory with are set after,
 * where that is allowed. 0, or an errno. */
static int make_directory (int dir, const char *name, mode_t mode) {
  mode_t before = umask(0);
  int number = 0;
  if (mkdirat(dir, name, mode) != 0 && errno != EEXIST) {
    number = errno;
    if (number == EPERM && (mode & 06000) != 0) {
      number = 0;
      mode &= 01777;
      if (mkdirat(dir, name, mode) != 0 && errno != EEXIST) number = errno;
    }
  }
  umask(before);
  if (number == 0 && (mode & 06000) != 0 && fchmodat(dir, name, mode, 0) != 0 && errno != EPERM)
    number = errno;
  return number;
}

/* Makes the directory `path` in the root being built with the mode of
 * the one it stands for, and one its owner -- the child, once it has
 * given up its capabilities -- can pass through even where the host's let
 * only its group: 0, or an errno. */
static int make_mirrored (const char *path, size_t skip) {
  return make_directory(AT_FDCWD, path, mirrored_mode(path, skip) | 0700);
}

/* The directory `name` in the one `dir` holds, opened without following
 * a link: a link there is refused with ELOOP, whatever it leads to. The
 * descriptor, or -1 with errno. */
static int open_unlinked_directory (int dir, const char *name) {
  struct stat st;
  if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode)) {
    errno = ELOOP;
    return -1;
  }
  return openat(dir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

/* Makes the place a path is bound at: `target`, a path in the root being
 * built, of which the first `skip` bytes name the root. Each directory
 * on the way is made where it is missing, with the mode of the one it
 * stands for ([`mirrored_mode`]), and its last name a directory, with
 * `directory`, or else an empty file, where it is not there -- going
 * through no link. A link on the way or at its end
 * is refused with ELOOP: a name placed beneath a path bound from the
 * host (`at`) could otherwise lead out through a link there, and make
 * a file where the host has the link's target. `target` is written
 * into and put back. 0, or an errno.
 * TODO: bind through the descriptor of the place made (a mount of
 * /proc/self/fd/<n>) rather than its name again, so a link a host
 * process puts on the way between this walk and the mount is not
 * followed either. */
static int make_target (char *target, size_t skip, int directory) {
  char held = target[skip];
  target[skip] = '\0';
  int dir = open(target, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  target[skip] = held;
  if (dir < 0) return errno;
  int number = 0;
  char *name = target + skip + 1;
  while (number == 0) {
    char *end = strchr(name, '/');
    if (end == NULL) break;
    *end = '\0';
    int next = -1;
    if (*name != '\0') {
      next = open_unlinked_directory(dir, name);
      if (next < 0 && errno == ENOENT) {
        number = make_directory(dir, name, mirrored_mode(target, skip) | 0700);
        if (number == 0) next = open_unlinked_directory(dir, name);
      }
      if (number == 0 && next < 0) number = errno;
    }
    *end = '/';
    if (next >= 0) {
      close(dir);
      dir = next;
    }
    name = end + 1;
  }
  if (number == 0 && *name != '\0') {
    struct stat st;
    if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0) {
      if (S_ISLNK(st.st_mode)) number = ELOOP;
    } else if (errno != ENOENT) {
      number = errno;
    } else if (directory) {
      if (mkdirat(dir, name, 0755) != 0 && errno != EEXIST) number = errno;
    } else {
      int fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
      if (fd < 0) number = errno;
      else close(fd);
    }
  }
  close(dir);
  return number;
}

/* Makes a link at `path`, under the root being built, to `to`, making its
 * parents as [`make_target`] does, going through no link and making
 * nothing where something already is: 0, or an errno. */
static int make_link (char *path, size_t skip, const char *to) {
  struct stat st;
  for (char *at = path + skip + 1; *at != '\0'; at++) {
    if (*at != '/') continue;
    *at = '\0';
    int number = 0;
    if (lstat(path, &st) != 0) {
      number = errno != ENOENT ? errno : make_mirrored(path, skip);
    } else if (!S_ISDIR(st.st_mode)) {
      number = EEXIST;
    }
    *at = '/';
    if (number == EEXIST) return 0;
    if (number != 0) return number;
  }
  if (symlink(to, path) != 0 && errno != EEXIST) return errno;
  return 0;
}

/* mount_setattr(2), which a libc may not name: making a mount and every
 * mount beneath it read-only at once, as a remount cannot. */
#ifndef SYS_mount_setattr
#define SYS_mount_setattr 442
#endif
#ifndef AT_RECURSIVE
#define AT_RECURSIVE 0x8000
#endif
#define COSMIC_MOUNT_ATTR_RDONLY 0x1
#define COSMIC_MOUNT_ATTR_NOSUID 0x2
#define COSMIC_MOUNT_ATTR_NOEXEC 0x8
struct cosmic_mount_attr {
  uint64_t attr_set, attr_clr, propagation, userns_fd;
};

/* An idmapped mount ([`idmapped_tree`], [`build_root`]): open_tree(2)
 * and move_mount(2), which a libc may not name either. */
#ifndef SYS_open_tree
#define SYS_open_tree 428
#endif
#ifndef SYS_move_mount
#define SYS_move_mount 429
#endif
#define COSMIC_MOUNT_ATTR_IDMAP 0x00100000
#define COSMIC_OPEN_TREE_CLONE 1
#define COSMIC_MOVE_MOUNT_F_EMPTY_PATH 4

/* `number`, an errno, as the failure of `stage` where `strict` asks for
 * stages. A failure already staged stays as it is. */
static int staged (int strict, int stage, int number) {
  if (!strict || number == 0 || number >> STAGE_SHIFT != 0) return number;
  return (stage << STAGE_SHIFT) | number;
}

/* What to tell the caller of a start that failed at `stage` with `number`
 * (an errno): the remedy, which the errno alone does not name. Isolation
 * needs unprivileged user namespaces, and a procfs of its own needs a
 * container that does not mask /proc. */
void staged_message (int stage, int number, const char *path, char *message,
                     size_t room) {
  const char *what = cosmic_errno_describe(number, NULL);
  if (stage == STAGE_IDMAP) {
    snprintf(message, room,
             "an idmapped mount of %s was refused (%s): the sandbox's user must write or read "
             "what its owner alone may, which needs a Linux kernel from 5.12, a file system that "
             "supports idmapped mounts (ext4, xfs, btrfs and tmpfs do; an overlay or network file "
             "system may not) and CAP_SYS_ADMIN here: make the path's mode readable and "
             "writable by every user instead", path != NULL ? path : "a grant", what);
  } else if (stage == STAGE_KIND) {
    snprintf(message, room,
             "a path this sandbox binds changed kind between the start's check and the bind (it "
             "became a directory, or a socket no `u` grant names), which would let the program "
             "reach what a host process put there: it is refused, not an error of the file "
             "system (%s)", what);
  } else if (stage == STAGE_RELAY) {
    snprintf(message, room,
             "the relay's listeners could not be made in this sandbox's network namespace (%s): "
             "a socket, a bind of 127.0.0.1 at one of the ports given (the two must differ), a "
             "listen, or the send of both descriptors over the channel failed", what);
  } else if (stage == STAGE_TRUNCATION) {
    snprintf(message, room,
             "seccomp filter: %s: a child a Landlock ruleset holds without promises, where the "
             "ruleset does not handle truncation (below Landlock ABI 3), is held to a filter "
             "that refuses it, which this kernel did not install", what);
  } else if (stage == STAGE_PROC) {
    snprintf(message, room,
             "this sandbox's own /proc was refused (%s): a container's runtime masks parts of "
             "/proc, and a user namespace may mount a procfs only where all of it is visible: "
             "run the container with --security-opt systempaths=unconfined (Docker, Podman), "
             "or on a host with no masked /proc; a sandbox never falls back to the host's /proc",
             what);
  } else if (stage == STAGE_NAMESPACE) {
    snprintf(message, room,
             "this sandbox's user, mount, pid or network namespace was refused (%s): isolation "
             "needs unprivileged user namespaces, which %s", what,
             number == ENOSPC
                 ? "this host allows none of: user.max_user_namespaces is 0, raise it"
                 : "this host may refuse: set kernel.unprivileged_userns_clone=1 (Debian), "
                   "kernel.apparmor_restrict_unprivileged_userns=0 or allow `userns` in this "
                   "program's AppArmor profile (Ubuntu 24.04), let a container's seccomp "
                   "profile allow unshare and clone with CLONE_NEWUSER, and start it from a "
                   "process no Landlock ruleset holds");
  } else if (number != EPERM && number != EACCES) {
    snprintf(message, room,
             "this sandbox's root could not be built (%s): a path it binds, or a step of making "
             "its mount points, failed (a link beneath a bound path, a name too long, a path "
             "that went away since the start began)", what);
  } else {
    snprintf(message, room,
             "this sandbox's root could not be built (%s): it needs mounts in a user namespace "
             "of its own, which a container's seccomp or AppArmor profile may refuse, as may "
             "a Landlock ruleset the starting process is held by, and a mapped user, which a "
             "root inside another sandbox lacks", what);
  }
}

/* Brings up the loopback of the network namespace the child has just made
 * its own, which the kernel makes down: a connection to 127.0.0.1 is then
 * refused, or reaches a listener the child's own processes opened, as
 * on a host, rather than finding no network at all. 0, or an errno. */
static int loopback_up (void) {
  /* A unix socket, which any socket's interface ioctls fall through to,
   * so a parent with no "inet" socket promise still starts an offline child. Made
   * as a pair, which the promises filter allows where it refuses socket():
   * a program that builds sandboxes (`nest`) starts this one's own. */
  int pair[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) != 0) return errno;
  int fd = pair[0];
  struct ifreq request;
  memset(&request, 0, sizeof request);
  memcpy(request.ifr_name, "lo", sizeof "lo");
  int number = 0;
  if (ioctl(fd, SIOCGIFFLAGS, &request) != 0) {
    number = errno;
  } else {
    request.ifr_flags |= IFF_UP;
    if (ioctl(fd, SIOCSIFFLAGS, &request) != 0) number = errno;
  }
  close(pair[0]);
  close(pair[1]);
  return number;
}

/* In the child, in the network namespace it has just made its own
 * ([`loopback_up`]) and before any ruleset or filter holds it: listens on
 * 127.0.0.1 at each of `ports`, and sends both descriptors in one message
 * over `channel`, the parent's end of a stream socketpair, pinned above
 * the descriptors the program is handed, which this closes whatever the
 * outcome. The listeners are the sandbox's own, so a program there
 * reaches them at those ports, and whoever holds the other end of the
 * channel accepts what it connects. It allocates nothing, as a child that
 * shares the parent's memory must not. 0, or an errno staged as
 * STAGE_RELAY, which the parent names whether or not the start is strict. */
static int relay_listeners (int channel, const int *ports) {
  int fds[2] = { -1, -1 };
  int number = 0;
  for (int i = 0; !number && i < 2; i++) {
    fds[i] = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fds[i] < 0) {
      number = errno;
      break;
    }
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons((uint16_t)ports[i]);
    if (bind(fds[i], (const struct sockaddr *)&address, sizeof address) != 0 ||
        listen(fds[i], SOMAXCONN) != 0)
      number = errno;
  }
  if (!number) {
    union {
      struct cmsghdr alignment;
      unsigned char bytes[CMSG_SPACE(2 * sizeof(int))];
    } control;
    memset(&control, 0, sizeof control);
    char marker = '\0';
    struct iovec payload = { &marker, 1 };
    struct msghdr message;
    memset(&message, 0, sizeof message);
    message.msg_iov = &payload;
    message.msg_iovlen = 1;
    message.msg_control = control.bytes;
    message.msg_controllen = (socklen_t)CMSG_SPACE(2 * sizeof(int));
    struct cmsghdr *rights = CMSG_FIRSTHDR(&message);
    rights->cmsg_level = SOL_SOCKET;
    rights->cmsg_type = SCM_RIGHTS;
    rights->cmsg_len = (socklen_t)CMSG_LEN(2 * sizeof(int));
    memcpy(CMSG_DATA(rights), fds, sizeof fds);
    ssize_t sent;
    do {
      sent = sendmsg(channel, &message, MSG_NOSIGNAL);
    } while (sent < 0 && errno == EINTR);
    if (sent < 0) number = errno;
    else if (sent != 1) number = EPROTO;
  }
  for (int i = 0; i < 2; i++) {
    if (fds[i] >= 0) close(fds[i]);
  }
  close(channel);
  return staged(1, STAGE_RELAY, number);
}

/* Whether this process is in a user namespace other than the host's:
 * its uid_map maps less than every id to itself. False where it cannot
 * tell, as without /proc. */
bool inner_user_namespace (void) {
  int fd = open("/proc/self/uid_map", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return false;
  char text[128];
  ssize_t got = read(fd, text, sizeof text - 1);
  close(fd);
  if (got <= 0) return false;
  text[got] = '\0';
  unsigned long inside = 0, outside = 0, count = 0;
  if (sscanf(text, "%lu %lu %lu", &inside, &outside, &count) != 3) return false;
  return inside != 0 || outside != 0 || count != 4294967295UL;
}

/* In a child whose user namespace is its own and fresh: maps its user
 * and group to themselves, and refuses it setgroups. `mapped` says
 * whether its user was mapped (see below). 0, or an errno. */
int map_ids (int unmap_root, const char *uid_map, const char *gid_map, int *mapped) {
  int number = write_whole("/proc/self/setgroups", "deny");
  if (number != 0 && number != ENOENT) return number;
  /* Root inside a user namespace not the host's -- a sandbox's child --
   * may map root only holding CAP_SETFCAP, which it gave up (`unmap_root`
   * says it is such a root): its user stays unmapped, the kernel's
   * overflow id inside, owning what root owns but with no capability to
   * override a file's permissions, as it had none mapped either. Any
   * other refusal is the sandbox's failure. Left unmapped, it confines
   * none of its own in turn: the kernel refuses a user namespace to a
   * user its own does not map. So `spawn`'s `user` runs a root caller's
   * child as a user of its own instead, mapped from outside
   * ([`map_from_outside`]), which confines at any depth, as any mapped
   * child does; `cosmic test` runs root's sandboxed workers so. */
  *mapped = 1;
  if ((number = write_whole("/proc/self/uid_map", uid_map)) != 0) {
    if (number != EPERM || !unmap_root) return number;
    *mapped = 0;
  }
  return write_whole("/proc/self/gid_map", gid_map);
}

/* Gives up every capability a namespace of the child's own gave it, for
 * good: none is left to pass to a program it executes, so a caller's
 * root cannot undo a read-only mount or make one of its own. 0, or an
 * errno. */
static int drop_capabilities (void) {
  for (int cap = 0; cap < 64; cap++) {
    if (prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) != 0 && errno != EINVAL) return errno;
  }
  if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0 && errno != EINVAL)
    return errno;
  return 0;
}

/* Puts at `target` in the root being built the /proc given: a procfs
 * of the child's pid namespace, which it must already be in, holding
 * that namespace's processes alone (subset=pid: no /proc/sys, no
 * /proc/sysrq-trigger, nothing of the host's but those processes') --
 * writable, so a process in it can map its ids in a user namespace of
 * its own, and confine one of its own in turn. What it may write there
 * is its own processes', and its session's autogroup, which is the
 * sandbox's own ([`run_program`] starts one, as [`cosmic_sandbox_init`]
 * does). Where the kernel refuses one -- a container's runtime masks
 * parts of its /proc, and a user namespace may mount a procfs only
 * where one is wholly visible (mount_too_revealing, which subset=pid
 * does not escape as of Linux 6.18), EPERM; a kernel before 5.8 knows
 * no subset, EINVAL -- the host's /proc is bound there instead,
 * read-only even where given to write, since what it holds to write is
 * the host's (/proc/sys, other processes' entries) -- unless `strict`,
 * a policy's sandbox, which has no fallback: a refusal is STAGE_PROC's.
 * `own` says whether the procfs is the child's own. 0, or an errno.
 * TODO: keep a child from setting its own audit login id
 * (/proc/self/loginuid), which it may while that is unset (the kernel
 * asks no capability to set an unset one, unless audit's
 * loginuid_immutable is on), so the host's audit log names the uid it
 * chose for what its processes do: a per-process file cannot be bound
 * over in a procfs, so this waits on a way to refuse the write -- a
 * Landlock rule on /proc files, or a seccomp filter able to tell the
 * path -- or on setting it from here to the parent's own, which the
 * kernel only lets a process holding CAP_AUDIT_CONTROL do.
 * TODO: refuse the sandbox where the kernel refuses a procfs of its
 * own (EPERM, which build.confine's `unconfinable` falls back on and
 * `must_confine` fails), rather than bind the host's, as a policy's
 * (`strict`) already does, once
 * no container the tree is tested in masks /proc: CI's Linux legs run
 * with systempaths=unconfined (.github/scripts/leg-container.sh), but a
 * developer's docker may not. Meanwhile a child with the host's /proc
 * cannot confine one of its own (EROFS writing its uid_map there), and
 * sees the host's processes and state, whose pids are not the ones it
 * is in (it is pid 2 of its own namespace). */
static int place_proc (const char *target, int *own, int strict) {
  *own = mount("proc", target, "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, "subset=pid") == 0;
  if (*own) return 0;
  if (strict) return staged(1, STAGE_PROC, errno);
  if (errno != EPERM && errno != EINVAL) return errno;
  if (mount("/proc", target, NULL, MS_BIND | MS_REC, NULL) != 0) return errno;
  struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_RDONLY, 0, 0, 0 };
  if (syscall(SYS_mount_setattr, AT_FDCWD, target, AT_RECURSIVE, &attr, sizeof attr) != 0)
    return errno;
  return 0;
}

/* In an unveiled child's program's process ([`start_program`]), in its
 * namespaces -- user, pid, mount, System V IPC, and the network with
 * `offline` -- before anything else of it:
 * a root of the child's own, with a /tmp of its own unless /tmp or /
 * is among the paths, holding the `count` paths at their own names --
 * read-only, and every mount beneath them too, but where `writable`
 * says; /proc a procfs of its own pid namespace ([`place_proc`]) -- and
 * nothing else, so a path outside them is not there at all, to stat as
 * to open. The paths are resolved, with no link or `..` left in them;
 * `at` holds, for each bound at a name of the caller's choosing rather
 * than its own, that name, and NULL elsewhere -- where each is placed,
 * its name or its path, a shorter coming before a longer. `names` holds
 * the names they were given by where one differs from its path and it
 * has no `at`, and NULL elsewhere, and each such name is a link in the
 * root to its path, where no path placed holds it already. `root` is an
 * empty directory the parent made to build on; `mapped` says whether
 * the child's user is mapped ([`map_ids`]); `own` says, once it is built,
 * whether its /proc is a procfs of its own ([`place_proc`]). The root is
 * this process's own and its working directory's, and every process's
 * in the namespace whose root was the old one. 0, or an errno.
 * With `strict`, a policy's root: no /tmp but the sized, noexec tmpfs
 * `tmp_bytes` asks for (none for 0, noexec unless `tmp_exec`), a tmpfs of its own to build on
 * ([`staged`]'s STAGE_ROOT where the user is not mapped), a procfs of
 * its own or the failure of the start, and each path `noexec` flags
 * mounted noexec. With `unix_guard`, where a unix socket is allowed below
 * Landlock ABI 9 on the strength of the root alone (COSMIC_HELD_UNIX set
 * for `root_shows_no_socket` (core/sandbox_rules.c), or a `u` grant), each path bound is checked
 * once placed, on what the mount shows: a directory fails the start, and so
 * does a socket that `unix_ok` (one flag a path) does not name, a `u`
 * grant's. It fails as STAGE_KIND, the path having changed kind since the
 * caller looked, so a path swapped for one in between is not the sandbox's.
 * TODO: remove the directory an unmapped child's root is built on once
 * the child ends: its root and its /tmp are that directory, in its
 * parent's TMPDIR, which `spawn`, returning at the child's exec, leaves
 * behind with what the child wrote to its /tmp. Removing it sooner
 * would take the child's mounts from under it, so this waits on the
 * process table's `waitpid` removing a directory its `spawn` handed the
 * reaped child's pid.
 * A UTS namespace would change nothing a child sees: its host's name
 * and kernel stay what `uname` answers, which no key holds. */
static int build_root (const char *root, char *const *paths, char *const *names,
                       const char *const *at, const int *writable, const int *noexec,
                       const int *idmapped, int count, int mapped, int noexec_scratch, int strict,
                       unsigned long tmp_bytes, int tmp_exec, int unix_guard, const int *unix_ok,
                       int *own) {
  int number = 0;
  *own = 0;
  /* A private writable tmpfs needs a mapped owner. Refuse before an
   * unmapped child's root leaves directories on its host backing. */
  if ((noexec_scratch || strict) && !mapped) return strict ? staged(1, STAGE_ROOT, EPERM) : EPERM;
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) return errno;
  /* A tmpfs of this namespace takes no file from a user it does not
   * map: an unmapped one builds on `root` itself, which its parent's
   * namespace maps it on. */
  if (mapped ? mount("tmpfs", root, "tmpfs", MS_NOSUID | MS_NODEV, "mode=0755") != 0
             : mount(root, root, NULL, MS_BIND, NULL) != 0)
    return errno;
  char target[PATH_MAX];
  /* A /tmp of its own, writable and empty but for the paths given
   * beneath the host's, which a program takes for granted -- unless
   * /tmp or / is given, under its own name or another; mounted first,
   * so a path given beneath the host's /tmp is bound into it. */
  int tmp = strict ? tmp_bytes > 0 : 1;
  for (int i = 0; tmp && i < count; i++) {
    const char *placed = at[i] != NULL ? at[i] : paths[i];
    if (strcmp(placed, "/tmp") == 0 || strcmp(placed, "/") == 0 ||
        (names[i] != NULL && strcmp(names[i], "/tmp") == 0)) {
      tmp = 0;
    }
  }
  if (tmp) {
    int made = snprintf(target, sizeof target, "%s/tmp", root);
    if (made < 0 || (size_t)made >= sizeof target) return ENAMETOOLONG;
    /* The mode made here never shows: a tmpfs covers it, or the chmod below sets it. */
    if (mkdir(target, 0777) != 0) return errno;
    if (strict) {
      /* Writable and so not executable, as a grant `rwc` is, unless the
       * caller asked for one run from (`tmp_exec`, a grant `rwxc`). */
      char options[64];
      snprintf(options, sizeof options, "mode=1777,size=%lu", tmp_bytes);
      if (mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV | (tmp_exec ? 0 : MS_NOEXEC),
                options) != 0)
        return errno;
    } else if (mapped ? mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777") != 0
                      : chmod(target, 01777) != 0 ||
                        mount(target, target, NULL, MS_BIND, NULL) != 0) {
      return errno;
    }
  }
  if (noexec_scratch) {
    int made = snprintf(target, sizeof target, "%s/noexec", root);
    if (made < 0 || (size_t)made >= sizeof target) return ENAMETOOLONG;
    if (mkdir(target, 0777) != 0) return errno;
    /* No host backing path remains reachable through an executable
     * alias, unlike a bind of ordinary scratch. */
    if (mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, "mode=1777") != 0)
      return errno;
  }
  int own_proc = 0;
  for (int i = 0; i < count; i++) {
    const char *placed = at[i] != NULL ? at[i] : paths[i];
    /* A procfs of its own holds nothing of the host's to bind: a path
     * placed beneath /proc besides it is not there. */
    if (own_proc && strncmp(placed, "/proc/", 6) == 0) continue;
    struct stat st;
    if (stat(paths[i], &st) != 0) return errno;
    int length = snprintf(target, sizeof target, "%s%s", root, placed);
    if (length < 0 || (size_t)length >= sizeof target) return ENAMETOOLONG;
    if ((number = make_target(target, strlen(root), S_ISDIR(st.st_mode))) != 0) return number;
    if (at[i] == NULL && strcmp(paths[i], "/proc") == 0) {
      number = place_proc(target, &own_proc, strict);
      if (number != 0) return number;
      continue;
    }
    if (idmapped != NULL && idmapped[i] >= 0) {
      if (syscall(SYS_move_mount, idmapped[i], "", AT_FDCWD, target,
                  COSMIC_MOVE_MOUNT_F_EMPTY_PATH) != 0)
        return errno;
    } else if (mount(paths[i], target, NULL, MS_BIND | MS_REC, NULL) != 0) {
      return errno;
    }
    /* A path in the host's /proc is its state, read-only whoever asks:
     * /proc itself too, bound at another name (`at`). */
    if (!writable[i] || strncmp(paths[i], "/proc/", 6) == 0 || strcmp(paths[i], "/proc") == 0) {
      struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_RDONLY, 0, 0, 0 };
      if (syscall(SYS_mount_setattr, AT_FDCWD, target, AT_RECURSIVE, &attr, sizeof attr) != 0)
        return errno;
    }
    if (noexec != NULL && noexec[i]) {
      struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_NOEXEC, 0, 0, 0 };
      if (syscall(SYS_mount_setattr, AT_FDCWD, target, AT_RECURSIVE, &attr, sizeof attr) != 0)
        return errno;
    }
    if (unix_guard) {
      /* What the mount shows, not what the path named a moment ago. */
      struct stat shown;
      if (stat(target, &shown) != 0) return errno;
      if (S_ISDIR(shown.st_mode) || (S_ISSOCK(shown.st_mode) && !unix_ok[i]))
        return staged(1, STAGE_KIND, ESTALE);
    }
  }
  for (int i = 0; i < count; i++) {
    if (names[i] == NULL) continue;
    int held = 0;
    for (int j = 0; j < count && !held; j++) {
      const char *placed = at[j] != NULL ? at[j] : paths[j];
      size_t n = strlen(placed);
      held = strncmp(names[i], placed, n) == 0 &&
             (names[i][n] == '/' || names[i][n] == '\0' || n == 1);
    }
    if (held) continue;
    int length = snprintf(target, sizeof target, "%s%s", root, names[i]);
    if (length < 0 || (size_t)length >= sizeof target) return ENAMETOOLONG;
    if ((number = make_link(target, strlen(root), paths[i])) != 0) return number;
  }
  /* With /proc, the links into it a program expects in /dev, as a
   * container's root has them. */
  /* A /dev given whole has its own, or has none to make. */
  int proc = 0, dev = 0;
  for (int i = 0; i < count; i++) {
    const char *placed = at[i] != NULL ? at[i] : paths[i];
    proc = proc || (at[i] == NULL && strcmp(paths[i], "/proc") == 0);
    dev = dev || strcmp(placed, "/dev") == 0 || strcmp(placed, "/") == 0;
  }
  static const char *const dev_links[][2] = {
    { "/dev/fd", "/proc/self/fd" }, { "/dev/stdin", "/proc/self/fd/0" },
    { "/dev/stdout", "/proc/self/fd/1" }, { "/dev/stderr", "/proc/self/fd/2" },
  };
  for (size_t i = 0; proc && !dev && i < sizeof dev_links / sizeof dev_links[0]; i++) {
    int made = snprintf(target, sizeof target, "%s%s", root, dev_links[i][0]);
    if (made < 0 || (size_t)made >= sizeof target) return ENAMETOOLONG;
    if ((number = make_link(target, strlen(root), dev_links[i][1])) != 0) return number;
  }
  int length = snprintf(target, sizeof target, "%s/.old", root);
  if (length < 0 || (size_t)length >= sizeof target) return ENAMETOOLONG;
  if (mkdir(target, 0700) != 0) return errno;
  if (syscall(SYS_pivot_root, root, target) != 0) return errno;
  if (chdir("/") != 0) return errno;
  if (umount2("/.old", MNT_DETACH) != 0) return errno;
  if (rmdir("/.old") != 0) return errno;
  /* Nothing is made at the root itself once it is built. */
  if (mount(NULL, "/", NULL, MS_REMOUNT | MS_BIND | MS_RDONLY | MS_NOSUID | MS_NODEV, NULL) != 0)
    return errno;
  *own = own_proc;
  return 0;
}

/* In an unveiled child's program's process that builds no root
 * ([`start_program`]), in its namespaces: its mounts made private, and
 * a procfs of its own pid namespace over the host's /proc there, so
 * what it reads of /proc is its own sandbox's processes and nothing
 * else, while it keeps the host's filesystem. There is no fallback to
 * the host's /proc: a refusal is STAGE_PROC's. `own` says it is there.
 * 0, or an errno. */
static int mount_proc_only (int *own) {
  *own = 0;
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) return errno;
  int number = place_proc("/proc", own, 1);
  return number;
}

/* In a child that is `offline` and unveils nothing, before anything
 * else of the sandbox: a user namespace of its own, mapping its user
 * and group to themselves, and a network namespace of its own, which
 * has nothing but a loopback, brought up, where it makes the relay's
 * listeners if it has a channel for them ([`relay_listeners`]); then it
 * gives up every capability they gave it. It keeps the host's pid namespace, as it
 * keeps the host's filesystem and /proc with it. 0, or an errno. */
static int go_offline (int unmap_root, const char *uid_map, const char *gid_map, int strict,
                       int relayed, const int *relay_ports) {
  if (syscall(SYS_unshare, CLONE_NEWUSER | CLONE_NEWNET) != 0)
    return staged(strict, STAGE_NAMESPACE, errno);
  int mapped = 1;
  int number = map_ids(unmap_root, uid_map, gid_map, &mapped);
  if (number == 0) number = loopback_up();
  /* A failure of the namespace is its stage's; the relay's is already staged. */
  if (number != 0) return staged(strict, STAGE_NAMESPACE, number);
  if (relayed >= 0) number = relay_listeners(relayed, relay_ports);
  if (number == 0) number = drop_capabilities();
  return staged(strict, STAGE_NAMESPACE, number);
}
#endif

#if defined(__linux__)
/* One past the highest signal number: Linux's real-time signals end at
 * 64. */
#define SIGNAL_LIMIT 65

/* In the child, with every signal blocked: every signal this process
 * catches is set back to its default, so none can run a handler of the
 * parent's -- in the parent's memory -- before exec. One ignored stays
 * ignored across exec, as it would through fork, but SIGPIPE when cosmic
 * itself ignored it. A signal the kernel will not change (SIGKILL,
 * SIGSTOP) or a libc keeps for itself is refused and left alone. */
static void default_signals (void) {
  struct sigaction initial;
  memset(&initial, 0, sizeof initial);
  initial.sa_handler = SIG_DFL;
  sigemptyset(&initial.sa_mask);
  for (int number = 1; number < SIGNAL_LIMIT; number++) {
    struct sigaction current;
    if (sigaction(number, NULL, &current) != 0) continue;
    int reset = current.sa_handler != SIG_DFL && current.sa_handler != SIG_IGN;
    if (number == SIGPIPE && sigpipe_ignored_here) reset = 1;
    if (reset) sigaction(number, &initial, NULL);
  }
}

/* Raw calls only: this child shares the parent's memory, but must not
 * ask libc to coordinate its credential change with parent threads.
 * Clearing all three capability sets also clears ambient capabilities;
 * the bounding set stays unchanged. */
static int set_credentials (const struct spawn_plan *plan) {
  struct __user_cap_header_struct header = { _LINUX_CAPABILITY_VERSION_3, 0 };
  struct __user_cap_data_struct caps[2] = { { 0, 0, 0 }, { 0, 0, 0 } };
  if (syscall(SYS_prctl, PR_SET_NO_NEW_PRIVS, 1L, 0L, 0L, 0L) != 0 ||
      syscall(SYS_setgroups, 0, NULL) != 0 ||
      syscall(SYS_setresgid, plan->group, plan->group, plan->group) != 0 ||
      syscall(SYS_setresuid, plan->user, plan->user, plan->user) != 0 ||
      syscall(SYS_capset, &header, caps) != 0) return errno;
  return 0;
}


/* What a policy's sandbox ([`build_root`]'s `strict`) makes of its own, which no path
 * the ruleset was built from names -- built after it, in the child --
 * the ruleset is given, so it is not left refusing it: the procfs of its
 * own, to read (a program expects /proc/self), and the sized tmpfs at
 * /tmp, to read, write and create, as a grant `rwc` is (and to execute,
 * as `rwxc` is, with `tmp_exec`). The ruleset is
 * this child's alone, made for its start, so what is added widens no
 * other's. Raw calls only ([`run_program`]). 0, or an errno. */
static int own_rules (const struct spawn_plan *plan, int ruleset, int own_proc) {
  long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 1) return abi < 0 ? errno : ENOSYS;
  for (int tmp = 0; tmp < 2; tmp++) {
    if (tmp ? plan->tmp_bytes == 0 : !own_proc) continue;
    uint64_t rights = tmp ? grant_rights(GRANT_READ | GRANT_WRITE | GRANT_CREATE |
                                         (plan->tmp_exec ? GRANT_EXECUTE : 0), abi)
                          : grant_rights(GRANT_READ, abi);
    int fd = open(tmp ? "/tmp" : "/proc", O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return errno;
    struct landlock_path_beneath_attr beneath = { .allowed_access = rights, .parent_fd = fd };
    int number = syscall(SYS_landlock_add_rule, ruleset, LANDLOCK_RULE_PATH_BENEATH, &beneath, 0) != 0
                     ? errno : 0;
    close(fd);
    if (number != 0) return number;
  }
  return 0;
}

/* Holds this process, for good, to the Landlock ruleset `ruleset`: no_new_privs,
 * which the kernel asks of a process without CAP_SYS_ADMIN, and the
 * restriction. 0, or an errno. Raw calls only, for a child that shares its
 * parent's memory ([`run_program`]) and for the process itself
 * (`restrict_self`) alike. */
int enforce_ruleset (int ruleset) {
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return errno;
  if (syscall(SYS_landlock_restrict_self, ruleset, 0) != 0) return errno;
  return 0;
}

/* The rest of a child's start once its sandbox's namespaces are made
 * ([`spawn_child`]): its process group -- for an unveiled child, a
 * session of its own, and so a group of its own whatever
 * `process_group` says, so the autogroup its writable /proc lets it set
 * (/proc/self/autogroup) is the sandbox's, not its parent's session's --
 * its directory, its descriptors moved from where `pinned` holds them,
 * Landlock's `confined` ruleset, the parent's mask, its limits, the
 * promises filter, and exec. A failure goes to the parent over `status_fd` as an errno. */
static _Noreturn void run_program (const struct spawn_plan *plan, const int *pinned,
                                   int confined, int status_fd, int own_proc) {
  int top = plan->top;
  int failure = 0;
  if (plan->unveiling || plan->terminal) {
    if (setsid() < 0) failure = errno;
  } else if (plan->process_group && setpgid(0, 0) != 0) {
    failure = errno;
  }
  if (!failure && plan->credentials) failure = set_credentials(plan);
  if (!failure && plan->cwd != NULL && chdir(plan->cwd) != 0) failure = errno;
  for (int t = 0; !failure && t <= top; t++) {
    if (pinned[t] >= 0) {
      if (dup2(pinned[t], t) < 0) failure = errno;
    } else if (t < 3) {
      /* An inherited stdio descriptor must be as safe for exec as a
       * mapped one. */
      int flags = fcntl(t, F_GETFD);
      if (flags >= 0) {
        if (fcntl(t, F_SETFD, flags & ~FD_CLOEXEC) != 0) failure = errno;
      } else if (errno != EBADF) {
        failure = errno;
      }
    } else {
      close(t);
    }
  }
  if (!failure && plan->terminal && ioctl(0, TIOCSCTTY, 0) != 0) failure = errno;
  /* Confined last, just before exec: what the child and every process
   * it starts may reach is the ruleset's, and nothing lets it off. The
   * ruleset is made from `grants` for this child alone, so a strict
   * unveiled one is given its own /proc and /tmp here ([`own_rules`]). */
  if (!failure && confined >= 0 && plan->strict && plan->unveiling)
    failure = own_rules(plan, confined, own_proc);
  if (!failure && confined >= 0) failure = enforce_ruleset(confined);
  close_child_descriptors(top + 2, plan->descriptor_limit);
  /* The program starts with the parent's own mask; a signal pending
   * since the start is delivered now, at its default. */
  if (!failure && sigprocmask(SIG_SETMASK, &plan->mask, NULL) != 0) failure = errno;
  /* Lowered last, once every descriptor is moved above `top`, which a
   * lower limit can refuse; what is open above it stays open. */
  if (!failure) restore_descriptor_limit(0);
  /* Set after the restore, which would raise a lowered NOFILE again, and
   * before the filter, which follows every other step. Soft and hard
   * together, so the program cannot raise one again. */
  for (int i = 0; !failure && i < plan->rlimit_count; i++) {
    struct rlimit limits = { .rlim_cur = plan->rlimits[i].value, .rlim_max = plan->rlimits[i].value };
    if (setrlimit(plan->rlimits[i].resource, &limits) != 0) failure = errno;
  }
  /* The promises filter goes last, so no step above is refused by it,
   * and just before exec, which it allows. It is built here because it
   * holds the scheduling calls, and the signals where Landlock does not
   * scope them, to the process's own pid, which only the child has; it
   * follows Landlock so the ruleset is made with calls the filter has
   * not yet limited, and so `held` is what the kernel now holds.
   * PR_SET_MDWE is not set for a child with no `jit`: it is a property
   * of the address space, which this child shares with its parent until
   * exec, so it would hold the parent too.
   * TODO: set PR_SET_MDWE here for a child with no `jit`, once spawn
   * starts it on an address space of its own instead of
   * clone(CLONE_VM). The filter then drops the PROT_EXEC | PROT_BTI
   * mprotect it allows on aarch64 for glibc's loader. */
  if (!failure && plan->promising) failure = cosmic_promises_apply(plan->promises, plan->sockets, plan->held);
  /* Without a promises filter, one that holds truncation alone, where the
   * ruleset does not (core/promises.h's `cosmic_truncation_apply`). */
  else if (!failure && confined >= 0 && (plan->held & COSMIC_HELD_TRUNCATE) == 0)
    failure = staged(1, STAGE_TRUNCATION, cosmic_truncation_apply());
  if (!failure) execve(plan->path, plan->argv, plan->envp);
  if (!failure) failure = errno;
  report_child_error(status_fd, failure);
  _exit(127);
}

#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif

/* What an unveiled child ([`start_unveiled`]) shares with the init and
 * the program it starts, each on its memory and each while it waits:
 * the plan, and the descriptors [`spawn_child`] placed; whether its user
 * is mapped; this program, the pipe ends the init takes, and the
 * errno the init failed with before its exec, which the init writes. */
struct sandbox_start {
  const struct spawn_plan *plan;
  const int *pinned;
  int confined;
  int status_fd;
  int mapped;
  int exe;
  int started;
  int ready;
  int init_error;
};

/* `fd`, or -1 with errno, moved above every descriptor a child is
 * handed (`top` + 2 on) and close-on-exec, at `placed`: so none can
 * land on a descriptor the program is to have, nor reach it. 0, or an
 * errno. */
static int raise_descriptor (int fd, int top, int *placed) {
  *placed = -1;
  if (fd < 0) return errno;
  *placed = fcntl(fd, F_DUPFD_CLOEXEC, top + 2);
  int number = *placed < 0 ? errno : 0;
  close(fd);
  return number;
}

/* The sandbox's init, on the unveiled child's memory from its start to
 * its exec: the first process in the child's pid namespace, it gives up
 * its capabilities and executes this very program as
 * [`cosmic_sandbox_init`], holding the started pipe's read end as 0, the
 * ready pipe's write end as 1 and the parent's status pipe's write end
 * as 2, and nothing else -- from / as the host has it still, where a
 * core linked dynamically (the checked one) finds its loader and
 * libraries, whatever the child is given. Its root and directory move
 * to the child's own when the program pivots ([`start_program`]). A
 * failure before that exec is its errno in the shared `init_error`. */
static _Noreturn int start_init (void *argument) {
  struct sandbox_start *start = argument;
  const struct spawn_plan *plan = start->plan;
  int failure = drop_capabilities();
  if (!failure && chdir("/") != 0) failure = errno;
  /* Each source but the status pipe's is above the child's descriptors
   * ([`raise_descriptor`]), and that one, just above them, is moved
   * before 3 is written: so none is overwritten by the moves. */
  const int from[4] = { start->started, start->ready, start->status_fd, start->exe };
  for (int t = 0; !failure && t < 4; t++) {
    if (dup2(from[t], t) < 0) failure = errno;
  }
  if (!failure && fcntl(3, F_SETFD, FD_CLOEXEC) != 0) failure = errno;
  if (!failure) {
    close_child_descriptors(4, plan->descriptor_limit);
    char *argv[] = { (char *)COSMIC_SANDBOX_INIT, NULL };
    char *envp[] = { NULL };
    syscall(SYS_execveat, 3, "", argv, envp, AT_EMPTY_PATH);
    failure = errno;
  }
  start->init_error = failure;
  _exit(127);
}

/* The program's process, on the unveiled child's memory from its start
 * to its exec: the second in the pid namespace, and, started with
 * CLONE_PARENT, the parent's own child, as a child unconfined is. It
 * builds the root, in the pid namespace as a procfs's mounter must be
 * to hold it ([`build_root`]), gives up its capabilities, and runs the
 * program ([`run_program`]). */
static _Noreturn int start_program (void *argument) {
  const struct sandbox_start *start = argument;
  const struct spawn_plan *plan = start->plan;
  int failure = 0;
  /* One that gives root up (`spawn`'s `user`) builds its root as root,
   * which reaches what only root may -- root's own files, mapped in its
   * namespace ([`map_from_outside`]) -- but makes it as that user, as an
   * unprivileged caller's child's is made: its filesystem ids are that
   * user's and group's, and the capabilities over files that change
   * takes out of effect are put back. The kernel makes its memory
   * undumpable as its ids or capabilities change, which is made
   * dumpable again each time, so the child's own /proc files are its
   * own to write its maps in; that memory is the parent's too, which
   * puts back what it had once the child has exec'd. */
  if (plan->dropping) {
    syscall(SYS_setfsgid, plan->drop_gid);
    syscall(SYS_setfsuid, plan->drop_uid);
    if ((uid_t)syscall(SYS_setfsuid, (uid_t)-1) != plan->drop_uid ||
        (gid_t)syscall(SYS_setfsgid, (gid_t)-1) != plan->drop_gid)
      failure = EPERM;
    struct __user_cap_header_struct header = { _LINUX_CAPABILITY_VERSION_3, 0 };
    struct __user_cap_data_struct data[2];
    if (!failure && syscall(SYS_capget, &header, data) != 0) failure = errno;
    for (int i = 0; !failure && i < 2; i++) data[i].effective = data[i].permitted;
    if (!failure && syscall(SYS_capset, &header, data) != 0) failure = errno;
    if (prctl(PR_SET_DUMPABLE, 1, 0, 0, 0) != 0 && !failure) failure = errno;
  }
  int own_proc = 0;
  if (!failure && plan->proc_only) {
    failure = staged(plan->strict, STAGE_ROOT, mount_proc_only(&own_proc));
  } else if (!failure) {
    failure = staged(plan->strict, STAGE_ROOT,
                     build_root(plan->root_dir, plan->resolved_paths, plan->given_names,
                                plan->bound_at, plan->unveiled_writable, plan->unveiled_noexec,
                                plan->idmap_fds,
                                plan->unveil_count, start->mapped, plan->noexec_scratch,
                                plan->strict, plan->tmp_bytes, plan->tmp_exec, plan->unix_guard, plan->unveiled_unix, &own_proc));
  }
  if (!failure) failure = drop_capabilities();
  /* Then it gives root up for good, its groups first, while it may.
   * Where its /proc is its own, it makes a user namespace as that user,
   * mapping it alone, as an unprivileged caller's child is: root's files
   * are the overflow id's there, and no setuid program of root's runs
   * as root. Where it has the host's, read-only, it could write no map,
   * and stays where root is mapped beside it: so every mount of its
   * root is made nosuid first, which no setuid program runs past. */
  if (!failure && plan->dropping) {
    struct cosmic_mount_attr nosuid = { COSMIC_MOUNT_ATTR_NOSUID, 0, 0, 0 };
    if (syscall(SYS_mount_setattr, AT_FDCWD, "/", AT_RECURSIVE, &nosuid, sizeof nosuid) != 0)
      failure = errno;
  }
  if (!failure && plan->dropping) {
    if (syscall(SYS_setgroups, 0, NULL) != 0 ||
        syscall(SYS_setresgid, plan->drop_gid, plan->drop_gid, plan->drop_gid) != 0 ||
        syscall(SYS_setresuid, plan->drop_uid, plan->drop_uid, plan->drop_uid) != 0)
      failure = errno;
    if (prctl(PR_SET_DUMPABLE, 1, 0, 0, 0) != 0 && !failure) failure = errno;
    int mapped = 1;
    if (!failure && own_proc && syscall(SYS_unshare, CLONE_NEWUSER) != 0) failure = errno;
    if (!failure && own_proc) failure = map_ids(0, plan->uid_map, plan->gid_map, &mapped);
    if (!failure && own_proc) failure = drop_capabilities();
  }
  if (failure) {
    report_child_error(start->status_fd, failure);
    _exit(127);
  }
  run_program(plan, start->pinned, start->confined, start->status_fd, own_proc);
}

/* What an unveiled child that gives root up (`spawn`'s `user`) shares
 * with the process that maps its user namespace from outside
 * ([`map_from_outside`]): the plan, the child's pid, its /proc directory,
 * which the child opened itself -- so a map is written to it alone,
 * whatever pid another process may come to have -- the pipe the child
 * says over that it has made the namespace, and the errno the mapping
 * failed with, ECHILD until it is done. */
struct outside_map {
  const struct spawn_plan *plan;
  pid_t child;
  int proc;
  int told;
  int tell;
  int error;
};

/* On the unveiled child's memory, started before the child makes its
 * user namespace ([`start_unveiled`]), and so in this one's, as this
 * process's root: once the child says it has made it -- a byte of 1 --
 * writes its uid_map and gid_map, which map root and the user and group
 * it gives root up for (`outer_uid_map`, `outer_gid_map`). The child
 * could map its own ids alone; a map of more is written by a process
 * holding CAP_SETUID and CAP_SETGID where they are mapped -- and, to
 * map root, CAP_SETFCAP -- which the kernel asks of the opener and the
 * writer both. setgroups stays allowed there, for the child to give up
 * root's groups. The child calls nothing that sets errno, which they
 * share, until this has ended. */
static _Noreturn int map_from_outside (void *argument) {
  struct outside_map *map = argument;
  /* Its own copy of the end the child writes, closed, so a child gone
   * before it said anything ends the read. */
  close(map->tell);
  char byte = 0;
  ssize_t got;
  while ((got = read(map->told, &byte, 1)) < 0 && errno == EINTR) {}
  int failure = got == 1 && byte == 1 ? 0 : ECHILD;
  /* The child is its parent, and waits for it. */
  if (!failure && (pid_t)syscall(SYS_getppid) != map->child) failure = ECHILD;
  const char *const files[2] = { "uid_map", "gid_map" };
  const char *const maps[2] = { map->plan->outer_uid_map, map->plan->outer_gid_map };
  for (int i = 0; !failure && i < 2; i++) failure = write_whole_at(map->proc, files[i], maps[i]);
  map->error = failure;
  _exit(failure ? 127 : 0);
}

/* What [`idmapped_tree`] shares with the process that makes the user
 * namespace the mount is mapped through: the pipe it says over that it
 * has made it, and the one it then waits on until it is ended. */
struct idmap_holder {
  int told;
  int hold;
};

/* On the unveiled child's memory, in a process of its own that
 * [`idmapped_tree`] starts: makes a user namespace, says so with a byte
 * of 1 -- or 0 -- and waits, holding it, until it is killed. */
static _Noreturn int idmap_holder (void *argument) {
  const struct idmap_holder *holder = argument;
  char byte = syscall(SYS_unshare, CLONE_NEWUSER) == 0 ? 1 : 0;
  if (write(holder->told, &byte, 1) != 1) _exit(127);
  while (byte == 1 && read(holder->hold, &byte, 1) < 0 && errno == EINTR) {}
  _exit(0);
}

/* An idmapped mount's map ([`idmapped_tree`]) of `owner` to `drop`, and,
 * where they differ, of `drop` to `owner`: a map takes each id once on
 * either side, so `drop`'s own files cannot show as `drop`'s too, and
 * left out of the map they would refuse every write, whatever their mode;
 * swapped, they show as `owner`'s and are written as their mode lets
 * everyone. */
static void swapped_map (char *text, size_t room, unsigned long owner, unsigned long drop) {
  if (owner == drop) snprintf(text, room, "%lu %lu 1\n", owner, drop);
  else snprintf(text, room, "%lu %lu 1\n%lu %lu 1\n", owner, drop, drop, owner);
}

/* In the unveiled child, before its own namespaces, as the root of
 * this process's own: at `fd` (placed above `top`), a detached copy of
 * the mount tree at `path`, idmapped so that the user and group that
 * own `path` -- the owner of the file the mount shows -- are the user
 * and group `plan` drops to, and every other owner none: what the
 * path's owner may do, the child's user may, and what it creates is
 * the owner's on the host; the drop user's own files show as the
 * owner's ([`swapped_map`]). The mapping is a user namespace of its own,
 * made by [`idmap_holder`] and mapped here, `owner` to the drop user
 * and group, which a mount may be idmapped through only where this
 * process may mount (CAP_SYS_ADMIN where the file system is
 * mounted), so the mount is made here, not by the child, which has no
 * capability there. 0, or an errno. */
static int idmapped_tree (const struct spawn_plan *plan, const char *path, int top, int *fd) {
  *fd = -1;
  struct stat st;
  if (stat(path, &st) != 0) return errno;
  int made[2], held[2];
  if (pipe(made) != 0) return errno;
  if (pipe(held) != 0) {
    int number = errno;
    close(made[0]);
    close(made[1]);
    return number;
  }
  struct idmap_holder holder = { made[1], held[0] };
  int failure = 0;
  pid_t pid = clone(idmap_holder, plan->helper_stack, CLONE_VM | SIGCHLD, &holder);
  close(made[1]);
  close(held[0]);
  if (pid < 0) {
    failure = errno;
  } else {
    char byte = 0;
    ssize_t got;
    while ((got = read(made[0], &byte, 1)) < 0 && errno == EINTR) {}
    if (got != 1 || byte != 1) failure = EPERM;
    char at[64], text[96];
    if (!failure) {
      snprintf(at, sizeof at, "/proc/%d/setgroups", (int)pid);
      failure = write_whole(at, "deny");
    }
    if (!failure) {
      snprintf(at, sizeof at, "/proc/%d/uid_map", (int)pid);
      swapped_map(text, sizeof text, (unsigned long)st.st_uid, (unsigned long)plan->drop_uid);
      failure = write_whole(at, text);
    }
    if (!failure) {
      snprintf(at, sizeof at, "/proc/%d/gid_map", (int)pid);
      swapped_map(text, sizeof text, (unsigned long)st.st_gid, (unsigned long)plan->drop_gid);
      failure = write_whole(at, text);
    }
    int namespace = -1;
    if (!failure) {
      snprintf(at, sizeof at, "/proc/%d/ns/user", (int)pid);
      namespace = open(at, O_RDONLY | O_CLOEXEC);
      if (namespace < 0) failure = errno;
    }
    if (!failure) {
      int tree = (int)syscall(SYS_open_tree, AT_FDCWD, path,
                              COSMIC_OPEN_TREE_CLONE | O_CLOEXEC | AT_RECURSIVE);
      if (tree < 0) {
        failure = errno;
      } else {
        struct cosmic_mount_attr attr = { COSMIC_MOUNT_ATTR_IDMAP, 0, 0, (uint64_t)namespace };
        if (syscall(SYS_mount_setattr, tree, "", AT_EMPTY_PATH | AT_RECURSIVE, &attr,
                    sizeof attr) != 0) {
          failure = errno;
          close(tree);
        } else {
          failure = raise_descriptor(tree, top, fd);
        }
      }
    }
    if (namespace >= 0) close(namespace);
    kill(pid, SIGKILL);
    int ignored;
    while (waitpid(pid, &ignored, 0) < 0 && errno == EINTR) {}
  }
  close(made[0]);
  close(held[1]);
  return failure;
}

/* An unveiled child, from where [`spawn_child`] placed its descriptors:
 * it makes a user namespace of its own, which it maps ([`map_ids`]), a pid
 * namespace for what it starts, a mount namespace, System V IPC, and
 * with `offline` a network namespace with its loopback up
 * ([`loopback_up`]). The init it starts first is pid 1 of that namespace
 * ([`start_init`]); the program it starts next is pid 2, the parent's
 * child ([`start_program`]): signalled, stopped and reaped as any child
 * is, with the exit status its own, rather than a pid 1's, from which a
 * signal the program does not catch -- a SIGTERM, its own abort() --
 * would be dropped. Its pid is the one `spawn` answers. So the
 * program's own processes see, and signal, none but each other and
 * that init, which ignores them. The init is the parent's child too
 * (CLONE_PARENT), so no subreaper adopts it when this process ends, as
 * one would a stray (`waitpid` ends and reaps it with its program:
 * `end_sandbox_init` (core/spawn.c)), and it ends if the parent does. This
 * process waits for the init to be past its exec -- until then it
 * shares this memory -- and to have made itself undumpable, so no
 * program of the same user in the sandbox can ptrace it; then it starts
 * the program, and ends when the program has exec'd: the pipe the init
 * reads then ends, once the program's copy of it is closed at exec. A
 * failure goes to the parent over `status_fd` as an errno. */
static _Noreturn void start_unveiled (const struct spawn_plan *plan, const int *pinned,
                                      int confined, int relayed, int status_fd) {
  struct sandbox_start start = { plan, pinned, confined, status_fd, 1, -1, -1, -1, 0 };
  int top = plan->top;
  /* Each descriptor raised above `top` here is counted in
   * SPAWN_PLACED_ABOVE (core/process.h). */
  /* Through unshare, not clone's flags, which a container's seccomp
   * profile refuses where it lets unshare through (Docker's default,
   * narrowed as CI's is). Each namespace but the user's is the new
   * user namespace's own. */
  int flags = CLONE_NEWUSER | CLONE_NEWPID | CLONE_NEWNS | CLONE_NEWIPC |
              (plan->offline ? CLONE_NEWNET : 0);
  int failure = 0;
  /* One that gives root up is mapped from outside ([`map_from_outside`]),
   * by a process started before its namespace is made, and waited for. */
  struct outside_map outside = { plan, (pid_t)syscall(SYS_getpid), -1, -1, -1, ECHILD };
  pid_t helper = -1;
  /* An idmapped mount is made while this is root where the file system
   * is, with the one stack the user-mapping helper has not yet taken. */
  for (int i = 0; !failure && plan->unveiled_idmap != NULL && i < plan->unveil_count; i++) {
    plan->idmap_fds[i] = -1;
    if (!plan->unveiled_idmap[i]) continue;
    failure = idmapped_tree(plan, plan->resolved_paths[i], top, &plan->idmap_fds[i]);
    if (failure) {
      *plan->idmap_failed = i;
      failure = staged(plan->strict, STAGE_IDMAP, failure);
    }
  }
  if (!failure && plan->dropping) {
    int made[2];
    failure = raise_descriptor(open("/proc/self", O_RDONLY | O_DIRECTORY | O_CLOEXEC), top,
                               &outside.proc);
    if (!failure && pipe(made) != 0) failure = errno;
    if (!failure) {
      failure = raise_descriptor(made[0], top, &outside.told);
      int other = raise_descriptor(made[1], top, &outside.tell);
      if (!failure) failure = other;
    }
    if (!failure) {
      helper = clone(map_from_outside, plan->helper_stack, CLONE_VM | SIGCHLD, &outside);
      if (helper < 0) failure = errno;
    }
  }
  if (!failure && syscall(SYS_unshare, flags) != 0)
    failure = staged(plan->strict, STAGE_NAMESPACE, errno);
  if (helper > 0) {
    char byte = failure ? 0 : 1;
    ssize_t put = write(outside.tell, &byte, 1);
    if (put != 1 && !failure) failure = put < 0 ? errno : EIO;
    close(outside.tell);
    outside.tell = -1;
    int ignored;
    pid_t reaped;
    while ((reaped = waitpid(helper, &ignored, 0)) < 0 && errno == EINTR) {}
    if (reaped < 0 && !failure) failure = errno;
    if (!failure) failure = outside.error;
  }
  if (outside.proc >= 0) close(outside.proc);
  if (outside.told >= 0) close(outside.told);
  if (outside.tell >= 0) close(outside.tell);
  if (!failure && !plan->dropping)
    failure = staged(plan->strict, STAGE_NAMESPACE,
                     map_ids(plan->unmap_root, plan->uid_map, plan->gid_map, &start.mapped));
  if (!failure && plan->offline) failure = staged(plan->strict, STAGE_NAMESPACE, loopback_up());
  if (!failure && relayed >= 0) failure = relay_listeners(relayed, plan->relay_ports);
  if (!failure)
    failure = raise_descriptor(open("/proc/self/exe", O_RDONLY | O_CLOEXEC), top, &start.exe);
  int started[2] = { -1, -1 }, ready[2] = { -1, -1 };
  for (int p = 0; !failure && p < 2; p++) {
    int *ends = p == 0 ? started : ready;
    int made[2];
    if (pipe(made) != 0) {
      failure = errno;
      break;
    }
    failure = raise_descriptor(made[0], top, &ends[0]);
    int other = raise_descriptor(made[1], top, &ends[1]);
    if (!failure) failure = other;
  }
  if (!failure) {
    start.started = started[0];
    start.ready = ready[1];
    pid_t init = clone(start_init, plan->init_stack,
                       CLONE_VM | CLONE_VFORK | CLONE_PARENT | SIGCHLD, &start);
    if (init < 0) {
      failure = errno;
    } else {
      *plan->init = init;
      failure = start.init_error;
    }
  }
  /* Its own copies of what the init took: the ready pipe then ends
   * when the init has answered, or has died. */
  if (started[0] >= 0) close(started[0]);
  if (ready[1] >= 0) close(ready[1]);
  if (start.exe >= 0) close(start.exe);
  if (!failure) {
    int answer = 0;
    size_t received = 0;
    while (received < sizeof answer) {
      ssize_t got = read(ready[0], (char *)&answer + received, sizeof answer - received);
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) break;
      received += (size_t)got;
    }
    failure = received == sizeof answer ? answer : ECHILD;
  }
  if (ready[0] >= 0) close(ready[0]);
  if (!failure) {
    pid_t program = clone(start_program, plan->program_stack,
                          CLONE_VM | CLONE_VFORK | CLONE_PARENT | SIGCHLD, &start);
    if (program < 0) failure = errno;
    else *plan->program = program;
  }
  if (failure) report_child_error(status_fd, failure);
  _exit(failure ? 127 : 0);
}

/* The child `spawn` starts on Linux, from its start to exec: on the
 * parent's memory, through clone(CLONE_VM | CLONE_VFORK) on a stack of
 * its own, the parent stopped until this execs or ends. So it neither
 * allocates nor touches the Lua state, writes only its own stack and
 * descriptors, the kernel's side of the process, and errno (which is
 * the parent's too; the parent reads none after a start that succeeded)
 * -- and, deliberately, the parent's memory in one place: the coverage
 * flag of each function it enters (core/coverage.h), so a test is
 * credited with what its child ran, and on the checked core the
 * sanitizer runtime's state (UBSan's report dedup), which a report from
 * here would write; an unveiled one writes its program's pid too
 * ([`start_unveiled`]). It leaves by exec or _exit, never by returning,
 * so no atexit handler or stdio flush runs. A failure goes to the
 * parent over the status pipe as an errno. */
_Noreturn int spawn_child (void *argument) {
  const struct spawn_plan *plan = argument;
  int top = plan->top;
  default_signals();
  close(plan->status_read);
  int failure = 0;
  /* dup2 onto a target can overwrite another mapping's source, so every
   * source is first pinned above everything the child is handed. A
   * source that is its own target is pinned too: the copy is what makes
   * the final dup2 clear CLOEXEC on it. Inherited stdio is left alone,
   * so a closed one stays closed. What is placed above `top` besides the
   * copies is counted in SPAWN_PLACED_ABOVE (core/process.h). */
  int pinned[CHILD_FD_MAX + 1];
  for (int t = 0; t <= top; t++) {
    pinned[t] = -1;
    if (!failure && plan->source[t] >= 0) {
      pinned[t] = fcntl(plan->source[t], F_DUPFD_CLOEXEC, top + 2);
      if (pinned[t] < 0) failure = errno;
    }
  }
  /* The ruleset is pinned with them, before the exec-status descriptor
   * takes top + 1 -- which the ruleset may be -- and before any mapping
   * can land on it. */
  int confined = -1;
  if (!failure && plan->confine >= 0) {
    confined = fcntl(plan->confine, F_DUPFD_CLOEXEC, top + 2);
    if (confined < 0) failure = errno;
  }
  /* The relay's channel too, which [`relay_listeners`] closes. */
  int relayed = -1;
  if (!failure && plan->relay_channel >= 0) {
    relayed = fcntl(plan->relay_channel, F_DUPFD_CLOEXEC, top + 2);
    if (relayed < 0) failure = errno;
  }
  /* The exec-status descriptor sits just above the child's own. */
  int status_fd = plan->status_write;
  if (!failure && status_fd != top + 1) {
    if (dup2(status_fd, top + 1) < 0) {
      failure = errno;
    } else {
      close(status_fd);
      status_fd = top + 1;
    }
  }
  if (!failure && fcntl(status_fd, F_SETFD, FD_CLOEXEC) != 0) failure = errno;
  if (failure) {
    report_child_error(status_fd, failure);
    _exit(127);
  }
  /* The sandbox's own namespaces first: the root the rest resolves in,
   * and mounting, which Landlock and the promises filter would refuse. */
  if (plan->unveiling) start_unveiled(plan, pinned, confined, relayed, status_fd);
  if (plan->offline && (failure = go_offline(plan->unmap_root, plan->uid_map, plan->gid_map,
                                              plan->strict, relayed, plan->relay_ports)) != 0) {
    report_child_error(status_fd, failure);
    _exit(127);
  }
  run_program(plan, pinned, confined, status_fd, 0);
}

/* The kind of descriptor `fd` is (S_IFIFO and the like), or 0 where it
 * is none. */
static mode_t descriptor_kind (int fd) {
  struct stat st;
  if (fstat(fd, &st) != 0) return 0;
  return st.st_mode & S_IFMT;
}

bool cosmic_sandbox_init_asked (int argc, char **argv) {
  return argc == 1 && strcmp(argv[0], COSMIC_SANDBOX_INIT) == 0 && getpid() == 1 &&
         (COSMIC_ENVIRON == NULL || COSMIC_ENVIRON[0] == NULL) &&
         descriptor_kind(0) == S_IFIFO && descriptor_kind(1) == S_IFIFO &&
         descriptor_kind(2) == S_IFIFO;
}

/* The sandbox's init, as [`start_init`] executes this program: pid 1 of
 * an unveiled child's pid namespace, which ends, and every process left
 * in it with it, when it does. It starts a session of its own, so the
 * autogroup a process in the sandbox could set through /proc/1 is not
 * its parent's session's; makes itself undumpable, so no process in the
 * sandbox, which has its user, can ptrace it; and ends when its parent
 * does (PR_SET_PDEATHSIG), so the parent's end -- a runner ended by
 * Ctrl-C, or killed -- ends the sandbox too: it holds the parent's
 * status pipe on 2, which the parent reads from until the program has
 * started, so a parent already gone by the time the signal is set is
 * seen there, as a pipe with no reader. It says so -- 0, or an errno --
 * on 1; then it waits for 0 to end, which it does once the program has
 * exec'd or failed to, and for the program, pid 2, to end, reaping
 * meanwhile every process the namespace orphans. Every signal stays
 * blocked, as it started: pid 1 takes none it does not catch from its
 * own namespace, and from outside it only SIGKILL and SIGSTOP. */
_Noreturn void cosmic_sandbox_init (void) {
  sigset_t every;
  sigfillset(&every);
  int failure = 0;
  if (sigprocmask(SIG_SETMASK, &every, NULL) != 0) failure = errno;
  if (!failure && setsid() < 0) failure = errno;
  if (!failure && prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) failure = errno;
  if (!failure && prctl(PR_SET_NAME, COSMIC_SANDBOX_INIT_COMM, 0, 0, 0) != 0) failure = errno;
  if (!failure && prctl(PR_SET_PDEATHSIG, SIGKILL, 0, 0, 0) != 0) failure = errno;
  if (!failure) {
    struct pollfd parent = { 2, POLLOUT, 0 };
    if (poll(&parent, 1, 0) < 0) failure = errno;
    else if (parent.revents & (POLLERR | POLLHUP)) _exit(127);
  }
  close(2);
  /* The kernel's own signal set, one bit per signal: SIGCHLD alone. */
  uint64_t chld = (uint64_t)1 << (SIGCHLD - 1);
  int children = -1;
  if (!failure) {
    children = (int)syscall(SYS_signalfd4, -1, &chld, sizeof chld, O_CLOEXEC);
    if (children < 0) failure = errno;
  }
  report_child_error(1, failure);
  close(1);
  if (failure) _exit(127);
  char byte;
  for (;;) {
    ssize_t got = read(0, &byte, 1);
    if (got == 0 || (got < 0 && errno != EINTR)) break;
  }
  close(0);
  int program = (int)syscall(SYS_pidfd_open, 2, 0);
  if (program < 0 && errno == ESRCH) _exit(0);
  /* Where a filter refuses pidfd_open, the program is looked for every
   * tenth of a second instead: it is there, a zombie too, until the
   * parent reaps it. */
  struct pollfd waiting[2] = { { program, POLLIN, 0 }, { children, POLLIN, 0 } };
  for (;;) {
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
    if (program < 0 && kill(2, 0) != 0 && errno == ESRCH) _exit(0);
    if (poll(waiting, 2, program < 0 ? 100 : -1) < 0 && errno != EINTR) _exit(127);
    if (waiting[0].revents != 0) _exit(0);
    if (waiting[1].revents != 0) {
      char info[128];
      if (read(children, info, sizeof info) < 0 && errno != EINTR) _exit(127);
    }
  }
}
#endif
