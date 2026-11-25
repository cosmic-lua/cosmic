/* What the files of a start and a sandbox share: core/syscalls.c,
 * core/spawn.c, core/sandbox_root.c and core/sandbox_rules.c. */
#ifndef COSMIC_SANDBOX_H
#define COSMIC_SANDBOX_H

#if defined(__linux__)
/* Fixed by the kernel's ABI; a libc or a header older than them may not
 * name them. */
#ifndef O_PATH
#define O_PATH 010000000
#endif
#ifndef LANDLOCK_ACCESS_FS_IOCTL_DEV
#define LANDLOCK_ACCESS_FS_IOCTL_DEV (1ULL << 15)
#endif

/* What a rule beneath a file, not a directory, may allow. */
#define LANDLOCK_FILE_ACCESS                                                \
  (LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_WRITE_FILE |             \
   LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_TRUNCATE |             \
   LANDLOCK_ACCESS_FS_IOCTL_DEV)
#endif

/* One resource limit a child is held to: `resource` is an RLIMIT_ constant
 * and `value` both its soft and its hard limit. */
struct spawn_rlimit {
  int resource;
  rlim_t value;
};

/* Everything a spawned child reads between starting and exec, made ready
 * by the parent: the child shares the parent's memory on Linux
 * (core/sandbox_root.c's [`spawn_child`]), so it allocates nothing and writes nothing of the
 * parent's but the one thing it means to -- the coverage flags of the
 * functions it enters, and on the checked core UBSan's own state -- and
 * reads only this, which the parent holds, unchanged, until the child
 * has exec'd or ended. On Darwin the parent hands it to posix_spawn
 * (core/spawn.c's `spawn_program`). */
struct spawn_plan {
  const char *path;
  char **argv;
  char **envp;
  const char *cwd;
  /* source[t] is the parent descriptor the child sees as t, or -1: for
   * 0..2 that means inherit, above that it means closed. */
  const int *source;
  int top;
  int status_read;
  int status_write;
  long descriptor_limit;
  int process_group;
  int terminal;
  int credentials;
  uid_t user;
  gid_t group;
  /* The Landlock ruleset `grants` made to restrict the child to, or -1. */
  int confine;
  /* Whether the child is held to the promises filter (core/promises.c),
   * and to which promises: COSMIC_PROMISE_ bits. */
  int promising;
  unsigned promises;
  /* What else holds the child, as COSMIC_HELD_ bits (core/promises.h): the
   * signal scope of `confine` (core/sandbox_rules.c's [`grants_ruleset`]), and what the child's
   * namespaces make of the calls the filter cannot read. */
  unsigned held;
  /* The socket families it may make (COSMIC_SOCKETS_ bits). */
  unsigned sockets;
  /* The limits to set, last but the filter: `rlimit_count` of them. */
  int rlimit_count;
  const struct spawn_rlimit *rlimits;
#if defined(__APPLE__)
  /* The Seatbelt profile the child is held to, or NULL for none, and its
   * parameters as `parameter_count` names and values, alternating. */
  const char *seatbelt_profile;
  const char *const *seatbelt_parameters;
  int seatbelt_parameter_count;
  /* Whether the program is a cosmic core that applies the profile itself
   * at boot (core/main.c), handed it in its environment: the trampoline
   * then applies none, as macOS applies no second one. */
  bool seatbelt_boot;
  /* The path of the terminal slave the child is given as its controlling
   * terminal, which its trampoline opens (core/sandbox_rules.c's `cosmic_trampoline`), or NULL. */
  const char *terminal_path;
#endif
  int unveiling;
  int offline;
  int noexec_scratch;
  /* With `offline`, the relay's channel (a parent descriptor, or -1 for
   * no relay) and the two ports its listeners are bound at
   * (core/sandbox_root.c's `relay_listeners`). */
  int relay_channel;
  int relay_ports[2];
  /* A policy's sandbox (`staged` (core/sandbox_root.c), `build_root` (core/sandbox_root.c)): the child gives its
   * failures' stages, and its own procfs and tmpfs are Landlock-granted
   * (core/sandbox_root.c's `own_rules`). */
  int strict;
  /* An unveiled child that builds no root: a pid namespace and a procfs
   * of its own over the host's filesystem (core/sandbox_root.c's `mount_proc_only`). */
  int proc_only;
  /* The size of the /tmp of a strict root's own, or 0 for none. */
  unsigned long tmp_bytes;
  int tmp_exec;
  /* Whether a unix socket is allowed below Landlock ABI 9 on the strength
   * of the root alone (core/sandbox_rules.c's [`grants_ruleset`], a `u` grant): `build_root` (core/sandbox_root.c) then
   * fails the start for a path it binds that is a directory, or a socket
   * `unveiled_unix` (a flag each path has) does not name. */
  int unix_guard;
  const int *unveiled_unix;
  const char *root_dir;
  char *const *resolved_paths;
  char *const *given_names;
  const char *const *bound_at;
  const int *unveiled_writable;
  const int *unveiled_noexec;
  /* With `dropping`: whether each path is mounted idmapped, so the user
   * the child runs as owns what the path's owner does (core/sandbox_root.c's `idmapped_tree`);
   * and, where the child makes each mount, its descriptor, which it
   * places before its namespaces and `build_root` (core/sandbox_root.c) moves into the
   * root, or -1. `idmap_failed` is the index of the path whose mount
   * the child could not make, written by the child, which shares this
   * memory. */
  const int *unveiled_idmap;
  int *idmap_fds;
  int *idmap_failed;
  int unveil_count;
  const char *uid_map;
  const char *gid_map;
  /* Whether the child is root in a user namespace not the host's, which
   * may not map root into one of its own. */
  int unmap_root;
  /* With `user`: whether an unveiled child gives root up for `drop_uid`
   * and `drop_gid` (core/sandbox_root.c's `start_program`), and the maps a process of this
   * one's writes of its namespace from outside (core/sandbox_root.c's `map_from_outside`),
   * root's and theirs; `uid_map` and `gid_map` then map theirs alone,
   * for the namespace it makes as that user. */
  int dropping;
  uid_t drop_uid;
  gid_t drop_gid;
  const char *outer_uid_map;
  const char *outer_gid_map;
#if defined(__linux__)
  /* For an unveiled child: the tops of the stacks its init and its
   * program start on (core/sandbox_root.c's `start_unveiled`), and where it writes their
   * pids, the one thing of the parent's it writes besides its coverage
   * flags. */
  char *init_stack;
  char *program_stack;
  /* And, for one that gives root up, the top of the stack the process
   * that maps it from outside runs on (core/sandbox_root.c's `map_from_outside`). */
  char *helper_stack;
  pid_t *init;
  pid_t *program;
#endif
  /* The parent's signal mask from before it blocked every signal to
   * start the child, which the program is to start with. */
  sigset_t mask;
};

/* The highest descriptor number a child may be handed besides stdio. */
#define CHILD_FD_MAX 255

/* The most grants one `spawn` takes: as many as a sandbox has paths
 * (`UNVEIL_MAX`), since a policy's start under `isolate` file binds each
 * grant into its root as an unveiled path (cosmic.child's `MAX_GRANTS`).
 * With their letters they are 12 bytes each of a frame that already holds
 * several times what these arrays come to, so they are not worth an
 * allocation a failure path would have to free. */
#define GRANT_MAX UNVEIL_MAX

/* The most limits one `spawn` takes: one for each resource its
 * `rlimits` names, in core/sandbox_rules.c's `RLIMIT_NAMES`. */
#define SPAWN_RLIMIT_MAX 5

#if defined(__linux__)
/* Where in building a policy's sandbox (`spawn`'s `strict`) a child
 * failed, which its errno alone does not say: the status pipe carries
 * the stage above the errno's bits, and `spawn` reads both back to
 * name the remedy. A child that is not strict reports its errno only,
 * but for STAGE_RELAY and STAGE_TRUNCATION, which any start may meet. */
enum {
  STAGE_NAMESPACE = 1, /* a user, pid, mount or network namespace, or mapping its ids */
  STAGE_PROC,          /* a procfs of its own */
  STAGE_ROOT,          /* the root's mounts */
  STAGE_IDMAP,         /* an idmapped mount of a path, which the plan's `idmap_failed` names */
  STAGE_KIND,          /* a path bound that is a directory or socket the start did not see */
  STAGE_RELAY,         /* the relay's listeners: made, bound, or handed over the channel */
  STAGE_TRUNCATION,    /* the filter that holds truncation where no promises filter does */
  STAGE_SHIFT = 16,
};

/* A grant's letters, in the order the plan lists them: "rwxcu". */
enum { GRANT_READ = 1, GRANT_WRITE = 2, GRANT_EXECUTE = 4, GRANT_CREATE = 8, GRANT_UNIX = 16 };
#endif

rlim_t check_limit (lua_State *L, int index);

const char *plain_string (lua_State *L, int index, const char *what);

size_t checked_argv (lua_State *L, int index);

void checked_variable (lua_State *L, int index);

bool restored_descriptor_limit (rlim_t least, struct rlimit *limits);

bool restore_descriptor_limit (rlim_t least);

unsigned read_promises (lua_State *L, int list, int arg);

int read_rlimits (lua_State *L, int table, int arg, struct spawn_rlimit *into);

int read_grants (lua_State *L, int list, int arg, const char **paths, unsigned *letters);

extern bool descriptor_limit_raised;

extern int sigpipe_ignored_here;

extern bool artifact_kept;

#if defined(__linux__)
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif

#ifndef LANDLOCK_ACCESS_FS_RESOLVE_UNIX
#define LANDLOCK_ACCESS_FS_RESOLVE_UNIX (1ULL << 16)
#endif
#define LANDLOCK_ABI_RESOLVE_UNIX 9
/* The headers this core builds with may predate these (ABI 4 and 6). */
#ifndef LANDLOCK_ACCESS_NET_BIND_TCP
#define LANDLOCK_ACCESS_NET_BIND_TCP (1ULL << 0)
#define LANDLOCK_ACCESS_NET_CONNECT_TCP (1ULL << 1)
#endif
#ifndef LANDLOCK_SCOPE_SIGNAL
#define LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0)
#define LANDLOCK_SCOPE_SIGNAL (1ULL << 1)
#endif

/* `struct landlock_ruleset_attr` as the newest kernel has it, so a
 * header older than a field does not leave it out; a kernel older than
 * a field is handed the struct only up to the one it knows. */
struct grants_attr {
  uint64_t handled_access_fs;
  uint64_t handled_access_net;
  uint64_t scoped;
};

int report_child_error (int fd, int number);

void close_child_descriptors (int from, long limit);

int read_whole (const char *path, char **text, size_t *used);

void staged_message (int stage, int number, const char *path, char *message,
                     size_t room);

bool inner_user_namespace (void);

int map_ids (int unmap_root, const char *uid_map, const char *gid_map, int *mapped);

int enforce_ruleset (int ruleset);

_Noreturn int spawn_child (void *argument);

bool root_shows_no_socket (char *const *resolved, const char *const *at, int count,
                           const int *source, int top);

int grants_ruleset (const char *const *paths, const unsigned *letters, int count,
                    int inet, int unix_bound, int offline, int unix_tmp, char *message,
                    size_t room, int *error, unsigned *held);

uint64_t grant_rights (unsigned letters, long abi);

/* The process that opened the /proc handles a restriction reads
 * (core/sandbox_rules.c's `inspected`), or 0 for none. A copy a fork gave
 * another process names its parent's /proc, so the next restriction there
 * closes it and opens its own. A fork's child sets this to 0, so its copy
 * is closed even where a later process has the pid the parent had. */
extern pid_t inspected_by;
#endif

#if defined(__APPLE__)
/* Why Darwin's start has a trampoline. Seatbelt holds the process that
 * applies a profile (sandbox_init_with_parameters), from that call on, and
 * everything it execs; a limit and a session are made by the
 * process they are for as well. posix_spawn runs none of our code between
 * its fork and the exec, and fork would: but once a process has had threads
 * only async-signal-safe calls are allowed in its child, and compiling a
 * profile allocates, reads the system's files and talks to its daemons.
 * So the parent posix_spawns this very program under the name
 * COSMIC_TRAMPOLINE (core/spawn.c's `spawn_program`), which `main` recognizes before it
 * does anything else (core/sandbox_rules.c's `cosmic_trampoline_asked`); it is a process of its
 * own, free to do all that, and it executes the child's program last,
 * having applied the profile to itself: the program, and what it starts,
 * is held by it, and the profile is never applied to the parent. The
 * start's status pipe is handed to it, and a failure of any step -- the
 * profile refused above all -- is written there, so the start fails and
 * the program is never run unconfined.
 *
 * Its arguments, which carry everything, so no descriptor is spent on them
 * that the program is to have, and the environment is the program's own.
 * They show in the process table for the moment before the exec, the
 * profile's parameters being the real paths a policy grants.
 * TODO: hand the profile and its parameters over a pipe of their own
 * instead of argv, once a descriptor may be spent on them past the
 * program's own (the trampoline closes it before the exec) -- today a
 * `ps` of the same user reads them while the trampoline runs.
 *   0  COSMIC_TRAMPOLINE
 *   1  the status pipe's descriptor, which is the one above the program's
 *   2  "1" to lead a session of its own (setsid), which the program then
 *      has no controlling terminal in unless 7 names one, else "0"
 *   3  the soft RLIMIT_NOFILE to give the program back, or "-" for none
 *   4  how many limits follow
 *   5  how many words of parameters follow, their names and values alternating
 *   6  the profile's text, or "" for none
 *   7  the path of the terminal slave to acquire as the controlling
 *      terminal after the session is made, or "" for none
 *   then each limit as its resource and its value, each parameter as its
 *   name and its value, the program's path and its own arguments. */
#define TRAMPOLINE_LIMITS 8
#define TRAMPOLINE_LEAST 10

/* The most of a refusal's text the status pipe carries. */
#define TRAMPOLINE_MESSAGE_MAX 480

/* libsystem_sandbox's private sandbox_init_with_parameters. */
typedef int (*seatbelt_init_function) (const char *profile, uint64_t flags,
                                       const char *const parameters[], char **error);

seatbelt_init_function seatbelt_init (void);

int seatbelt_holding (int *error);
#endif

#endif
