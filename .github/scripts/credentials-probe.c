#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <linux/capability.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <linux/securebits.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fsuid.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

/* A required CI proof, not a runtime binding. Setup deliberately leaves
 * capabilities across setuid so capset, rather than that side effect,
 * must remove them. Every unavailable prerequisite fails the lane. */
static void require (int ok, const char *what) {
  if (!ok) { perror(what); exit(1); }
}

static void refuse (const char *mode) {
  int number = -1, operation = -1;
  if (!strcmp(mode, "groups")) number = SYS_setgroups;
  else if (!strcmp(mode, "gid")) number = SYS_setresgid;
  else if (!strcmp(mode, "uid")) number = SYS_setresuid;
  else if (!strcmp(mode, "caps")) number = SYS_capset;
  else if (!strcmp(mode, "nnp")) { number = SYS_prctl; operation = PR_SET_NO_NEW_PRIVS; }
  else if (!strcmp(mode, "capture")) { number = SYS_prctl; operation = PR_GET_DUMPABLE; }
  else if (!strcmp(mode, "restore")) { number = SYS_prctl; operation = PR_SET_DUMPABLE; }
  else return;
  struct sock_filter rules[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned int)number, 0, 4),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned int)operation, 1, 0),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned int)-1, 0, 1),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  /* Non-prctl refusals match the syscall without inspecting arguments. */
  if (operation == -1) rules[1].jt = 3;
  struct sock_fprog program = { sizeof rules / sizeof rules[0], rules };
  require(prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0, "fixture no_new_privs");
  require(prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) == 0, "fixture seccomp");
}

static void probe (const char *secret, const char *marker) {
  uid_t r, e, s;
  gid_t gr, ge, gs;
  require(getresuid(&r, &e, &s) == 0 && r == 65532 && e == r && s == r, "all user IDs");
  require(getresgid(&gr, &ge, &gs) == 0 && gr == 65532 && ge == gr && gs == gr, "all group IDs");
  require(setfsuid((uid_t)-1) == 65532 && setfsgid((gid_t)-1) == 65532, "filesystem IDs");
  require(getgroups(0, NULL) == 0, "supplementary groups cleared");
  struct __user_cap_header_struct header = { _LINUX_CAPABILITY_VERSION_3, 0 };
  struct __user_cap_data_struct caps[2];
  require(syscall(SYS_capget, &header, caps) == 0, "capget");
  for (int i = 0; i < 2; i++)
    require(caps[i].effective == 0 && caps[i].permitted == 0 && caps[i].inheritable == 0,
            "capability sets cleared");
  for (int i = 0; i <= CAP_LAST_CAP; i++)
    require(prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_IS_SET, i, 0, 0) == 0, "ambient cleared");
  require(prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) == 1, "no_new_privs set");
  require(syscall(SYS_setresuid, 0, 0, 0) == -1 && errno == EPERM, "root IDs refused");
  caps[0].effective = caps[0].permitted = 1U << CAP_SETUID;
  require(syscall(SYS_capset, &header, caps) == -1 && errno == EPERM, "capability recovery refused");
  require(open(secret, O_RDONLY) == -1 && errno == EACCES, "root-only file refused");
  char granted[7] = { 0 };
  require(read(9, granted, 6) == 6 && !strcmp(granted, "grant\n"), "inherited descriptor grant");
  int fd = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600);
  require(fd >= 0, "probe marker");
  require(close(fd) == 0, "marker close");
}

int main (int argc, char **argv) {
  if (argc == 7 && !strcmp(argv[1], "setup")) {
    require(getuid() == 0 && geteuid() == 0, "fixture requires root");
    gid_t groups[] = { 17, 23 };
    require(setgroups(2, groups) == 0, "fixture supplementary groups");
    require(prctl(PR_SET_SECUREBITS, SECBIT_KEEP_CAPS | SECBIT_NO_SETUID_FIXUP) == 0,
            "fixture securebits");
    struct __user_cap_header_struct header = { _LINUX_CAPABILITY_VERSION_3, 0 };
    struct __user_cap_data_struct caps[2];
    require(syscall(SYS_capget, &header, caps) == 0, "fixture capget");
    caps[0].inheritable |= 1U << CAP_CHOWN;
    require(syscall(SYS_capset, &header, caps) == 0, "fixture inheritable capability");
    require(prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, CAP_CHOWN, 0, 0) == 0,
            "fixture ambient capability");
    refuse(argv[2]);
    execl(argv[3], argv[3], "--standalone", argv[4], argv[5], argv[6], argv[2], (char *)NULL);
    perror("fixture exec");
    return 1;
  }
  if (argc == 4 && !strcmp(argv[1], "probe")) {
    probe(argv[2], argv[3]);
    return 0;
  }
  if (argc == 3 && !strcmp(argv[1], "marker")) {
    int fd = open(argv[2], O_WRONLY | O_CREAT, 0600);
    require(fd >= 0, "unexpected exec marker");
    close(fd);
    for (;;) pause();
  }
  fprintf(stderr, "credentials-probe: invalid invocation\n");
  return 2;
}
