/* The sampling profiler: see core/profile.h. */

#define _POSIX_C_SOURCE 200809L
/* O_NOFOLLOW is outside strict POSIX on Darwin. */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

#include "profile.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "check.h"
#include "hook.h"
#include "lauxlib.h"
#include "ldebug.h"
#include "lstate.h"
#include "memory.h"
#include "syscalls.h"

/* The thread a resume runs, NULL while only the main thread runs:
 * patch/lua/36-running-thread-declared.txt defines it, and this declares
 * it itself, since the core's C is read against the unpatched tree. */
extern lua_State *volatile luaD_running;

/* The most frames of a stack a sample records, from the innermost, and
 * room for the C function and the line after them. */
#define PROFILE_DEPTH 128
/* The most open spans a sample and a total name; one opened deeper is
 * counted, and its time goes to the span it stands in. */
#define SPAN_DEPTH 32
#define PROFILE_SLOTS (SPAN_DEPTH + PROFILE_DEPTH + 2)
#define SPAN_SLOTS (1u << 12)
/* The slots of the tables of texts, of stacks and of C function names,
 * powers of two. A sample that finds either of the first two half full
 * is counted in `dropped`. */
#define TEXT_SLOTS (1u << 17)
#define STACK_SLOTS (1u << 21)
#define NAME_SLOTS (1u << 14)
/* The samples a second when COSMIC_PROFILE_HZ is unset: a prime, so the
 * samples do not fall in step with a loop that runs on a round period. */
#define DEFAULT_HZ 997

/* One text a sample names: a frame `name@source:line`, a C function
 * `name@[C]`, or the line it stood on, `source:line`. */
struct text {
  char *text;
  uint64_t hash;
};

/* One stack and line, its texts' indexes in `texts`: the frames from the
 * outermost, then the line. */
struct stack {
  uint32_t *ids;
  uint64_t hash;
  unsigned long us;
  uint32_t depth;
};

/* A C function, by its pointer (a light C function's own, a C closure's
 * object), and the name the modules give it. */
struct name {
  const void *key;
  char *name;
};

/* A span open now: its name's index in `texts`, and the clocks when it
 * opened. */
struct open_span {
  uint32_t id;
  /* What `profile_span_open` answered for it: a number no other span
   * of this process gets, so a stale token closes nothing. */
  lua_Integer token;
  int64_t wall_ns;
  int64_t cpu_ns;
};

/* The total of the spans of one path: the names of the spans it stood in
 * and its own, from the outermost. */
struct span_total {
  uint32_t ids[SPAN_DEPTH];
  uint32_t depth;
  unsigned long count;
  int64_t wall_ns;
  int64_t cpu_ns;
  /* The most the Lua heap held, in KB, as a span of this path closed;
   * 0 where none closed with the state at hand. */
  long heap_kb;
};

static struct open_span open_spans[SPAN_DEPTH];
/* How many spans are open, those past SPAN_DEPTH included. */
static int open_depth;
/* The last token a span was given. */
static lua_Integer last_token;
/* How many of the open spans a fork's child found open: its samples
 * stand under them, but their totals are the parent's to write. */
static int inherited_depth;
static struct span_total *span_totals;

static struct text *texts;
static size_t texts_used;
static struct stack *stacks;
static size_t stacks_used;
static struct name *names;
static size_t names_used;
/* Microseconds the tables had no room for. */
static unsigned long dropped;
static unsigned long sampled;
/* The samples taken when the C function names were last read. */
static unsigned long named_at;
static int named_ever;

/* What [`cosmic_profile_prepare`] set up: the file the profile goes to,
 * the clock, the rate, and the command line, joined. */
static int out_fd = -1;
static int timer_which;
static int timer_signal;
static int hz = DEFAULT_HZ;
static const char *clock_name = "cpu";
static char *command;
/* The directory, absolute, for a fork's own file. */
static char *profile_dir;
/* The profile's variables for a child, `NAME=value` each. */
static char *child_entries[3];
static size_t child_entry_count;
/* The process the profile is of: a child that forked from it and exits
 * through the same handler writes nothing, rather than a copy of it. */
static pid_t profiled;
static pthread_t owner;
static lua_State *main_state;
static int64_t started_wall_ns;
static int64_t started_cpu_ns;

/* The microseconds the timer's ticks measured since the last sample: in
 * Lua, in a C function (`ticked_c`, the last such function), and on a
 * thread with no Lua. A tick measures the time since the one before on
 * the profile's clock, since a timer of CPU time fires on the kernel's
 * own tick (every 4 ms on many Linux kernels), whatever rate it is set
 * to. */
static volatile long ticks_lua;
static volatile long ticks_c;
static volatile long ticks_other;
static const void *volatile ticked_c;
static unsigned long other_total;
static clockid_t tick_clock = CLOCK_PROCESS_CPUTIME_ID;
static int64_t last_tick_ns;

static int64_t now_ns (clockid_t clock) {
  struct timespec ts;
  if (clock_gettime(clock, &ts) != 0) return 0;
  return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static uint64_t fnv (uint64_t h, const void *p, size_t n) {
  const unsigned char *s = p;
  for (size_t i = 0; i < n; i++) h = (h ^ s[i]) * 1099511628211u;
  return h;
}

/* The index of `text` in `texts`, added when new; UINT32_MAX when the
 * table is half full or memory runs out. */
static uint32_t text_id (const char *text) {
  size_t n = strlen(text);
  uint64_t h = fnv(1469598103934665603u, text, n);
  size_t at = (size_t)h & (TEXT_SLOTS - 1);
  while (texts[at].text != NULL) {
    if (texts[at].hash == h && strcmp(texts[at].text, text) == 0) {
      return (uint32_t)at;
    }
    at = (at + 1) & (TEXT_SLOTS - 1);
  }
  if (texts_used >= TEXT_SLOTS / 2) return UINT32_MAX;
  char *copy = cosmic_malloc(n + 1);
  if (copy == NULL) return UINT32_MAX;
  memcpy(copy, text, n + 1);
  texts[at].text = copy;
  texts[at].hash = h;
  texts_used++;
  return (uint32_t)at;
}

static void count_stack (const uint32_t *ids, uint32_t depth, unsigned long us) {
  uint64_t h = fnv(1469598103934665603u, ids, depth * sizeof *ids);
  size_t at = (size_t)h & (STACK_SLOTS - 1);
  while (stacks[at].ids != NULL) {
    if (stacks[at].hash == h && stacks[at].depth == depth &&
        memcmp(stacks[at].ids, ids, depth * sizeof *ids) == 0) {
      stacks[at].us += us;
      return;
    }
    at = (at + 1) & (STACK_SLOTS - 1);
  }
  if (stacks_used >= STACK_SLOTS / 2) {
    dropped += us;
    return;
  }
  uint32_t *copy = cosmic_malloc(depth * sizeof *ids);
  if (copy == NULL) {
    dropped += us;
    return;
  }
  memcpy(copy, ids, depth * sizeof *ids);
  stacks[at].ids = copy;
  stacks[at].hash = h;
  stacks[at].us = us;
  stacks[at].depth = depth;
  stacks_used++;
}

/* A `;` or a space in a text would split it in the file's lines. */
static void plain (char *text) {
  for (char *c = text; *c != '\0'; c++) {
    if (*c == ';' || *c == ' ' || *c == '\n') *c = '_';
  }
}

static struct name *name_slot (const void *key) {
  size_t at = ((uintptr_t)key >> 4) & (NAME_SLOTS - 1);
  while (names[at].key != NULL && names[at].key != key) at = (at + 1) & (NAME_SLOTS - 1);
  return &names[at];
}

static void name_one (const void *key, const char *owner_name, const char *sep, const char *field) {
  if (key == NULL || names_used >= NAME_SLOTS / 2) return;
  struct name *slot = name_slot(key);
  if (slot->key != NULL) return;
  size_t n = strlen(owner_name) + strlen(sep) + strlen(field) + 1;
  char *name = cosmic_malloc(n);
  if (name == NULL) return;
  snprintf(name, n, "%s%s%s", owner_name, sep, field);
  slot->key = key;
  slot->name = name;
  names_used++;
}

/* The key a C function value at `index` is named by: a light C
 * function's pointer, a C closure's object; NULL for anything else. */
static const void *c_key (lua_State *L, int index) {
  if (lua_iscfunction(L, index) == 0) return NULL;
  const TValue *o = index > 0 ? s2v(L->ci->func.p + index) : s2v(L->top.p + index);
  if (ttislcf(o)) return (const void *)fvalue(o);
  if (ttisCclosure(o)) return (const void *)clCvalue(o);
  return NULL;
}

/* Names the C functions of the table at the top of the stack `owner`
 * `sep` field, and those of its metatable's __index table `owner:field`. */
static void name_table (lua_State *L, const char *owner_name, const char *sep) {
  int t = lua_gettop(L);
  lua_pushnil(L);
  while (lua_next(L, t) != 0) {
    if (lua_type(L, -2) == LUA_TSTRING) {
      const void *key = c_key(L, -1);
      if (key != NULL) name_one(key, owner_name, sep, lua_tostring(L, -2));
    }
    lua_pop(L, 1);
  }
}

/* Reads the names of the C functions the loaded modules hold (a field of
 * a module: `module.field`) and the metatables the registry names (a
 * method: `type:method`). Run in the hook, never in the signal handler. */
static void read_names (lua_State *L) {
  if (!lua_checkstack(L, 8)) return;
  int top = lua_gettop(L);
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
  if (lua_istable(L, -1)) {
    int loaded = lua_gettop(L);
    lua_pushnil(L);
    while (lua_next(L, loaded) != 0) {
      if (lua_type(L, -2) == LUA_TSTRING && lua_istable(L, -1)) {
        const char *module = lua_tostring(L, -2);
        if (strcmp(module, LUA_GNAME) == 0) module = "_G";
        name_table(L, module, ".");
      }
      lua_pop(L, 1);
    }
  }
  lua_settop(L, top);
  lua_pushnil(L);
  while (lua_next(L, LUA_REGISTRYINDEX) != 0) {
    if (lua_type(L, -2) == LUA_TSTRING && lua_istable(L, -1)) {
      const char *type = lua_tostring(L, -2);
      name_table(L, type, ".");
      lua_pushliteral(L, "__index");
      if (lua_rawget(L, -2) == LUA_TTABLE) name_table(L, type, ":");
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
  }
  lua_settop(L, top);
  named_at = sampled;
  named_ever = 1;
}

/* The name of the C function `key`, reading the names again where it has
 * none and samples have been taken since the last read. */
static const char *c_name (lua_State *L, const void *key) {
  struct name *slot = name_slot(key);
  if (slot->key == NULL && (!named_ever || sampled - named_at >= 1000)) {
    read_names(L);
    slot = name_slot(key);
  }
  return slot->key != NULL ? slot->name : NULL;
}

static long take (volatile long *ticks) {
  return __atomic_exchange_n(ticks, 0, __ATOMIC_SEQ_CST);
}

/* The first ordinal of a chunk numbered by instruction (build/lua_tail.tl's
 * `ordinal_base`; core/coverage.c's ORDINAL_BASE is the same): a function
 * of such a chunk is defined on line ORDINAL_BASE + k, k the instructions
 * before its first, and holds no line information. */
#define ORDINAL_BASE (1u << 24)

/* The line `d`'s running instruction counts on where its function has no
 * line information and is numbered by instruction, as core/coverage.c
 * counts it: the ordinal of the instruction in its chunk, past
 * ORDINAL_BASE, which `cosmic profile` places at a source line. -1 for any
 * other function, whose `currentline` Lua gives. */
static int ordinal_line (const lua_Debug *d) {
  CallInfo *ci = d->i_ci;
  if (ci == NULL || !isLua(ci)) return -1;
  const Proto *p = ci_func(ci)->p;
  if (p->lineinfo != NULL) return -1;
  if (p->linedefined != 0 && (unsigned)p->linedefined <= ORDINAL_BASE) return -1;
  unsigned first = p->linedefined > 0 ? (unsigned)p->linedefined : ORDINAL_BASE;
  return (int)(first + (unsigned)pcRel(ci->u.l.savedpc, p) + 1);
}

/* Records `us` microseconds against the stack `L` stands in, with the C function
 * `c` innermost where it is set. */
static void record (lua_State *L, unsigned long us, const void *c) {
  uint32_t ids[PROFILE_SLOTS] = {0};
  uint32_t depth = 0;
  lua_Debug d;
  char text[512] = "";
  char line[512] = "";
  while (depth < PROFILE_DEPTH && lua_getstack(L, (int)depth, &d)) {
    if (!lua_getinfo(L, "Snl", &d)) break;
    const char *name = d.name != NULL ? d.name : "?";
    if (d.what[0] == 'C') {
      snprintf(text, sizeof text, "%s@[C]", name);
    } else {
      snprintf(text, sizeof text, "%s@%s:%d", name, d.short_src, d.linedefined);
      if (line[0] == '\0') {
        int at = d.currentline >= 0 ? d.currentline : ordinal_line(&d);
        snprintf(line, sizeof line, "%s:%d", d.short_src, at);
        plain(line);
      }
    }
    plain(text);
    uint32_t id = text_id(text);
    if (id == UINT32_MAX) {
      dropped += us;
      return;
    }
    ids[depth++] = id;
  }
  /* Outermost first, under the open spans. */
  for (uint32_t i = 0; i < depth / 2; i++) {
    uint32_t t = ids[i];
    ids[i] = ids[depth - 1 - i];
    ids[depth - 1 - i] = t;
  }
  uint32_t spans = open_depth < SPAN_DEPTH ? (uint32_t)open_depth : SPAN_DEPTH;
  if (spans > 0) {
    memmove(ids + spans, ids, depth * sizeof *ids);
    for (uint32_t i = 0; i < spans; i++) ids[i] = open_spans[i].id;
    depth += spans;
  }
  if (c != NULL) {
    const char *name = c_name(L, c);
    /* An address would differ from run to run, so a function no module
     * names is `?`, as Lua names one it cannot. */
    snprintf(text, sizeof text, "%s@[C]", name != NULL ? name : "?");
    plain(text);
    uint32_t id = text_id(text);
    if (id == UINT32_MAX) {
      dropped += us;
      return;
    }
    ids[depth++] = id;
  }
  if (line[0] == '\0') snprintf(line, sizeof line, "-");
  uint32_t id = text_id(line);
  if (id == UINT32_MAX) {
    dropped += us;
    return;
  }
  ids[depth++] = id;
  count_stack(ids, depth, us);
}

void cosmic_profile_sample (lua_State *L) {
  if (stacks == NULL) return;
  long c = take(&ticks_c);
  const void *in_c = ticked_c;
  ticked_c = NULL;
  long lua = take(&ticks_lua);
  other_total += (unsigned long)take(&ticks_other);
  sampled++;
  if (c > 0) record(L, (unsigned long)c, in_c);
  if (lua > 0) record(L, (unsigned long)lua, NULL);
}

/* Adds the span at the top of `open_spans` to its path's total. */
static void total_span (const struct open_span *span, uint32_t depth, long heap_kb) {
  int64_t wall = now_ns(CLOCK_MONOTONIC) - span->wall_ns;
  int64_t cpu = now_ns(CLOCK_THREAD_CPUTIME_ID) - span->cpu_ns;
  uint32_t ids[SPAN_DEPTH] = {0};
  if (depth > SPAN_DEPTH) depth = SPAN_DEPTH;
  for (uint32_t i = 0; i < depth; i++) ids[i] = open_spans[i].id;
  uint64_t h = fnv(1469598103934665603u, ids, depth * sizeof *ids);
  size_t at = (size_t)h & (SPAN_SLOTS - 1);
  for (size_t tries = 0; tries < SPAN_SLOTS; tries++) {
    struct span_total *t = &span_totals[at];
    if (t->depth == 0) {
      memcpy(t->ids, ids, depth * sizeof *ids);
      t->depth = depth;
    }
    if (t->depth == depth && memcmp(t->ids, ids, depth * sizeof *ids) == 0) {
      t->count++;
      t->wall_ns += wall;
      t->cpu_ns += cpu;
      if (heap_kb > t->heap_kb) t->heap_kb = heap_kb;
      return;
    }
    at = (at + 1) & (SPAN_SLOTS - 1);
  }
}

/* Closes the open spans down to `depth` of them, the Lua heap holding
 * `heap_kb` (0: not read, as the process exits). */
static void close_spans (int depth, long heap_kb) {
  while (open_depth > depth && open_depth > 0) {
    open_depth--;
    if (open_depth >= inherited_depth) total_span(&open_spans[open_depth], (uint32_t)open_depth + 1, heap_kb);
  }
  if (inherited_depth > open_depth) inherited_depth = open_depth;
}

bool cosmic_profile_taking (void) {
  return span_totals != NULL;
}

int64_t cosmic_profile_span_open (const char *prefix, const char *name) {
  if (span_totals == NULL) return 0;
  /* A span deeper than the stack holds is not taken: its time goes to
   * the span it stands in. */
  if (open_depth >= SPAN_DEPTH) return 0;
  char text[512];
  snprintf(text, sizeof text, "[%s%s]", prefix, name);
  plain(text);
  uint32_t id = text_id(text);
  if (id == UINT32_MAX) return 0;
  struct open_span *span = &open_spans[open_depth++];
  span->id = id;
  span->token = ++last_token;
  span->wall_ns = now_ns(CLOCK_MONOTONIC);
  span->cpu_ns = now_ns(CLOCK_THREAD_CPUTIME_ID);
  return span->token;
}

bool cosmic_profile_span_close (int64_t token) {
  /* The span `token` names, if it is open still: from the top, since the
   * innermost closes most. */
  int at = open_depth - 1;
  while (at >= 0 && open_spans[at].token != token) at--;
  bool closed = span_totals != NULL && token > 0 && at >= 0;
  /* The heap as the span closes, read on the state that runs it: what
   * the phase left alive, and garbage not yet collected. */
  if (closed) close_spans(at, main_state != NULL ? (long)lua_gc(main_state, LUA_GCCOUNT, 0) : 0);
  return closed;
}

COSMIC_SYSCALL(profile_span_open, 1) {
  lua_pushinteger(L, (lua_Integer)cosmic_profile_span_open("", luaL_checkstring(L, 1)));
  return 1;
}

COSMIC_SYSCALL(profile_span_close, 1) {
  lua_pushboolean(L, cosmic_profile_span_close((int64_t)luaL_checkinteger(L, 1)));
  return 1;
}

size_t cosmic_profile_entries (char *const **entries) {
  *entries = child_entries;
  return out_fd >= 0 || profiled == getpid() ? child_entry_count : 0;
}

int cosmic_profile_signal (void) {
  return timer_signal;
}

/* The C function `L` stands in, read without following any pointer: a
 * light C function's pointer, or a C closure's object. NULL in Lua, or
 * where the frame is not one this can read (the stack is moving). */
static const void *running_c (lua_State *L) {
  CallInfo *ci = L->ci;
  if (ci == NULL || ci == &L->base_ci || isLua(ci)) return NULL;
  StkId func = ci->func.p;
  if (func < L->stack.p || func >= L->stack_last.p) return NULL;
  const TValue *o = s2v(func);
  if (ttislcf(o)) return (const void *)fvalue(o);
  if (ttisCclosure(o)) return (const void *)clCvalue(o);
  return NULL;
}

/* The microseconds on the profile's clock since the last tick. */
static long elapsed_us (void) {
  int64_t now = now_ns(tick_clock);
  int64_t d = now - last_tick_ns;
  last_tick_ns = now;
  return d > 0 ? (long)(d / 1000) : 0;
}

static void on_tick (int signal_number) {
  (void)signal_number;
  int saved = errno;
  if (!pthread_equal(pthread_self(), owner)) {
    __atomic_add_fetch(&ticks_other, elapsed_us(), __ATOMIC_SEQ_CST);
    errno = saved;
    return;
  }
  lua_State *L = luaD_running != NULL ? luaD_running : main_state;
  const void *c = running_c(L);
  long us = elapsed_us();
  if (c != NULL) {
    ticked_c = c;
    __atomic_add_fetch(&ticks_c, us, __ATOMIC_SEQ_CST);
  } else {
    __atomic_add_fetch(&ticks_lua, us, __ATOMIC_SEQ_CST);
  }
  cosmic_hook_arm(L);
  errno = saved;
}

/* Stops the timer, and the signal it sends with it. */
static void stop_timer (void) {
  if (timer_signal == 0) return;
  struct itimerval off = {{0, 0}, {0, 0}};
  setitimer(timer_which, &off, NULL);
  /* Ignored first, which drops a tick still pending, then the default
   * again, so a program an exec starts gets the signal as it would have
   * without a profile. */
  signal(timer_signal, SIG_IGN);
  signal(timer_signal, SIG_DFL);
  timer_signal = 0;
}

/* A new file for this process's profile in `dir`, or -1. */
static int open_profile (const char *dir) {
  char path[4096];
  long pid = (long)getpid();
  /* Where the pid's name is taken -- after an exec, or by the many
   * processes each pid 2 of a sandbox's pid namespace -- a name of the
   * pid and a number drawn from the clock, tried again on a clash. */
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  uint64_t draw = (uint64_t)now.tv_sec * 1000000000u + (uint64_t)now.tv_nsec;
  for (int n = 0; n < 100; n++) {
    draw = draw * 6364136223846793005ULL + 1442695040888963407ULL;
    int made = n == 0 ? snprintf(path, sizeof path, "%s/%ld.prof", dir, pid)
                      : snprintf(path, sizeof path, "%s/%ld-%08x.prof", dir, pid, (unsigned)(draw >> 32));
    if (made < 0 || made >= (int)sizeof path) return -1;
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd >= 0 || errno != EEXIST) return fd;
  }
  return -1;
}

void cosmic_profile_prepare (int argc, char **argv) {
  const char *dir = getenv("COSMIC_PROFILE");
  if (dir == NULL || dir[0] == '\0' || out_fd >= 0) return;
  const char *clock = getenv("COSMIC_PROFILE_CLOCK");
  if (clock != NULL && strcmp(clock, "wall") == 0) clock_name = "wall";
  const char *given = getenv("COSMIC_PROFILE_HZ");
  if (given != NULL) {
    long n = strtol(given, NULL, 10);
    if (n > 0 && n <= 100000) hz = (int)n;
  }
  /* The directory is made where it is missing; one that is there is
   * used as it is. */
  if (mkdir(dir, 0700) != 0 && errno != EEXIST) return;
  /* A new file of this user's alone: never one that is there already,
   * nor a symbolic link at the path's last name, so the variable cannot
   * aim the write at a file that exists. The image an exec starts keeps
   * the pid, so its profile takes the next free name. Opened here, before
   * a sandbox layer holds the process, so a sandboxed process writes its
   * profile too. */
  out_fd = open_profile(dir);
  if (out_fd < 0) return;
  /* Absolute, since a child may start in another directory. */
  char absolute[4096];
  char here[4096];
  const char *named = dir;
  if (dir[0] != '/' && getcwd(here, sizeof here) != NULL) {
    int made = snprintf(absolute, sizeof absolute, "%s/%s", here, dir);
    if (made > 0 && made < (int)sizeof absolute) named = absolute;
  }
  size_t dir_size = strlen(named) + 1;
  profile_dir = cosmic_malloc(dir_size);
  if (profile_dir != NULL) memcpy(profile_dir, named, dir_size);
  const char *values[3][2] = {{"COSMIC_PROFILE", named}, {"COSMIC_PROFILE_CLOCK", clock_name},
    {"COSMIC_PROFILE_HZ", NULL}};
  char rate[32];
  snprintf(rate, sizeof rate, "%d", hz);
  values[2][1] = rate;
  for (size_t i = 0; i < 3; i++) {
    size_t size = strlen(values[i][0]) + 1 + strlen(values[i][1]) + 1;
    char *entry = cosmic_malloc(size);
    if (entry == NULL) break;
    snprintf(entry, size, "%s=%s", values[i][0], values[i][1]);
    child_entries[child_entry_count++] = entry;
  }
  size_t n = 1;
  for (int i = 0; i < argc; i++) n += strlen(argv[i]) + 1;
  command = cosmic_malloc(n);
  if (command != NULL) {
    command[0] = '\0';
    for (int i = 0; i < argc; i++) {
      if (i > 0) strcat(command, " ");
      strcat(command, argv[i]);
    }
    for (char *c = command; *c != '\0'; c++) {
      if (*c == '\n') *c = ' ';
    }
  }
  profiled = getpid();
  /* Here, not at install: a process that never opens a Lua state (a
   * refused start) still writes its totals. */
  atexit(cosmic_profile_report);
  started_wall_ns = now_ns(CLOCK_MONOTONIC);
  started_cpu_ns = now_ns(CLOCK_PROCESS_CPUTIME_ID);
}

void cosmic_profile_report (void) {
  if (out_fd < 0 || getpid() != profiled) return;
  stop_timer();
  int fd = out_fd;
  /* Written once: the atexit call after an earlier one finds nothing. */
  out_fd = -1;
  FILE *f = fdopen(fd, "w");
  if (f == NULL) {
    close(fd);
    return;
  }
  int64_t wall = now_ns(CLOCK_MONOTONIC) - started_wall_ns;
  int64_t cpu = now_ns(CLOCK_PROCESS_CPUTIME_ID) - started_cpu_ns;
  unsigned long sampled_us = 0;
  for (size_t i = 0; stacks != NULL && i < STACK_SLOTS; i++) sampled_us += stacks[i].us;
  fprintf(f, "cosmic-profile 1\n");
  fprintf(f, "process %ld parent %ld clock %s hz %d\n", (long)getpid(), (long)getppid(), clock_name, hz);
  fprintf(f, "command %s\n", command != NULL ? command : "");
  /* The resident set's peak: kilobytes on Linux, bytes on macOS. */
  struct rusage usage;
  long peak_rss_kb = 0;
  if (getrusage(RUSAGE_SELF, &usage) == 0) {
#ifdef __APPLE__
    peak_rss_kb = (long)(usage.ru_maxrss / 1024);
#else
    peak_rss_kb = (long)usage.ru_maxrss;
#endif
  }
  fprintf(f, "total wall_ns %lld cpu_ns %lld sampled_us %lu dropped_us %lu other_us %lu peak_rss_kb %ld\n",
          (long long)wall, (long long)cpu, sampled_us, dropped, other_total + (unsigned long)ticks_other, peak_rss_kb);
  /* A span open still, a phase the process ended in, closes as it exits. */
  if (span_totals != NULL) close_spans(0, 0);
  for (size_t i = 0; span_totals != NULL && i < SPAN_SLOTS; i++) {
    const struct span_total *t = &span_totals[i];
    if (t->depth == 0) continue;
    fprintf(f, "span ");
    for (uint32_t k = 0; k < t->depth; k++) fprintf(f, "%s%s", k == 0 ? "" : ";", texts[t->ids[k]].text);
    fprintf(f, " %lu %lld %lld %ld\n", t->count, (long long)t->wall_ns, (long long)t->cpu_ns, t->heap_kb);
  }
  for (size_t i = 0; stacks != NULL && i < STACK_SLOTS; i++) {
    const struct stack *s = &stacks[i];
    if (s->ids == NULL) continue;
    fprintf(f, "sample ");
    for (uint32_t k = 0; k + 1 < s->depth; k++) {
      fprintf(f, "%s%s", k == 0 ? "" : ";", texts[s->ids[k]].text);
    }
    if (s->depth == 1) fprintf(f, "-");
    fprintf(f, " %s %lu\n", texts[s->ids[s->depth - 1]].text, s->us);
  }
  fclose(f);
}

/* Starts the timer `timer_which`, which sends `timer_signal`. */
static void start_timer (void) {
  long period_us = 1000000L / hz;
  if (period_us < 1) period_us = 1;
  struct itimerval every = {{period_us / 1000000, period_us % 1000000},
    {period_us / 1000000, period_us % 1000000}};
  if (setitimer(timer_which, &every, NULL) != 0) {
    signal(timer_signal, SIG_DFL);
    timer_signal = 0;
  }
}

void cosmic_profile_install (lua_State *L) {
  if (out_fd < 0 || stacks != NULL) return;
  texts = cosmic_calloc(TEXT_SLOTS, sizeof *texts);
  stacks = cosmic_calloc(STACK_SLOTS, sizeof *stacks);
  names = cosmic_calloc(NAME_SLOTS, sizeof *names);
  span_totals = cosmic_calloc(SPAN_SLOTS, sizeof *span_totals);
  if (texts == NULL || stacks == NULL || names == NULL || span_totals == NULL) {
    cosmic_free(texts);
    cosmic_free(stacks);
    cosmic_free(names);
    cosmic_free(span_totals);
    texts = NULL;
    stacks = NULL;
    names = NULL;
    span_totals = NULL;
    return;
  }
  main_state = L;
  owner = pthread_self();
  int which = strcmp(clock_name, "wall") == 0 ? ITIMER_REAL : ITIMER_PROF;
  tick_clock = which == ITIMER_REAL ? CLOCK_MONOTONIC : CLOCK_PROCESS_CPUTIME_ID;
  last_tick_ns = now_ns(tick_clock);
  int signal_number = which == ITIMER_REAL ? SIGALRM : SIGPROF;
  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_handler = on_tick;
  action.sa_flags = SA_RESTART;
  sigemptyset(&action.sa_mask);
  if (sigaction(signal_number, &action, NULL) != 0) return;
  timer_which = which;
  timer_signal = signal_number;
  start_timer();
}

void cosmic_profile_forked (pid_t pid) {
  if (pid != 0 || stacks == NULL || profile_dir == NULL || profiled == getpid()) return;
  /* The parent's file and totals are the parent's: this process writes
   * a file of its own, of what it does from here. */
  if (out_fd >= 0) close(out_fd);
  out_fd = open_profile(profile_dir);
  if (out_fd < 0) {
    /* Nothing to write to: no sampling, and no children told to. */
    stop_timer();
    profiled = getpid();
    return;
  }
  /* Fresh tables, not cleared ones: clearing would copy every page of
   * the parent's. The texts and names stay, as their indexes do. */
  struct stack *fresh = cosmic_calloc(STACK_SLOTS, sizeof *stacks);
  struct span_total *fresh_spans = cosmic_calloc(SPAN_SLOTS, sizeof *span_totals);
  if (fresh == NULL || fresh_spans == NULL) {
    cosmic_free(fresh);
    cosmic_free(fresh_spans);
    close(out_fd);
    out_fd = -1;
    return;
  }
  stacks = fresh;
  span_totals = fresh_spans;
  stacks_used = 0;
  dropped = 0;
  other_total = 0;
  ticks_lua = 0;
  ticks_c = 0;
  ticks_other = 0;
  ticked_c = NULL;
  profiled = getpid();
  started_wall_ns = now_ns(CLOCK_MONOTONIC);
  started_cpu_ns = now_ns(CLOCK_PROCESS_CPUTIME_ID);
  int64_t cpu_now = now_ns(CLOCK_THREAD_CPUTIME_ID);
  inherited_depth = open_depth;
  for (int i = 0; i < open_depth && i < SPAN_DEPTH; i++) {
    open_spans[i].wall_ns = started_wall_ns;
    open_spans[i].cpu_ns = cpu_now;
  }
  last_tick_ns = now_ns(tick_clock);
  /* A fork starts with no timer of its own. */
  if (timer_signal != 0) start_timer();
}
