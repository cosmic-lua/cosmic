/* The sampling profiler of Lua code: see core/profile.h. */

#define _POSIX_C_SOURCE 200809L
/* O_NOFOLLOW is outside strict POSIX on Darwin. */
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif

#include "profile.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lauxlib.h"
#include "memory.h"

/* The most frames of a stack a sample records, from the innermost. */
#define PROFILE_DEPTH 128
/* The slots of the table of frames and of stacks, powers of two. A
 * sample that finds either half full is counted in `dropped`. */
#define FRAME_SLOTS (1u << 17)
#define STACK_SLOTS (1u << 21)

/* One function a sample stood in: `name@source:line`. */
struct frame {
  char *text;
  uint64_t hash;
};

/* One stack, its frames' indexes in `frames` from the outermost. */
struct stack {
  uint32_t *ids;
  uint64_t hash;
  unsigned long count;
  uint32_t depth;
};

static struct frame *frames;
static size_t frames_used;
static struct stack *stacks;
static size_t stacks_used;
static unsigned long dropped;
static char *out_path;
/* The process the profile is of: a child that forked from it and exits
 * through the same handler writes nothing, rather than a copy of it. */
static pid_t profiled;

static uint64_t fnv (uint64_t h, const void *p, size_t n) {
  const unsigned char *s = p;
  for (size_t i = 0; i < n; i++) h = (h ^ s[i]) * 1099511628211u;
  return h;
}

/* The index of `text` in `frames`, added when new; UINT32_MAX when the
 * table is half full or memory runs out. */
static uint32_t frame_id (const char *text) {
  size_t n = strlen(text);
  uint64_t h = fnv(1469598103934665603u, text, n);
  size_t at = (size_t)h & (FRAME_SLOTS - 1);
  while (frames[at].text != NULL) {
    if (frames[at].hash == h && strcmp(frames[at].text, text) == 0) {
      return (uint32_t)at;
    }
    at = (at + 1) & (FRAME_SLOTS - 1);
  }
  if (frames_used >= FRAME_SLOTS / 2) return UINT32_MAX;
  char *copy = cosmic_malloc(n + 1);
  if (copy == NULL) return UINT32_MAX;
  memcpy(copy, text, n + 1);
  frames[at].text = copy;
  frames[at].hash = h;
  frames_used++;
  return (uint32_t)at;
}

static void count_stack (const uint32_t *ids, uint32_t depth) {
  uint64_t h = fnv(1469598103934665603u, ids, depth * sizeof *ids);
  size_t at = (size_t)h & (STACK_SLOTS - 1);
  while (stacks[at].ids != NULL) {
    if (stacks[at].hash == h && stacks[at].depth == depth &&
        memcmp(stacks[at].ids, ids, depth * sizeof *ids) == 0) {
      stacks[at].count++;
      return;
    }
    at = (at + 1) & (STACK_SLOTS - 1);
  }
  if (stacks_used >= STACK_SLOTS / 2) {
    dropped++;
    return;
  }
  uint32_t *copy = cosmic_malloc(depth * sizeof *ids);
  if (copy == NULL) {
    dropped++;
    return;
  }
  memcpy(copy, ids, depth * sizeof *ids);
  stacks[at].ids = copy;
  stacks[at].hash = h;
  stacks[at].count = 1;
  stacks[at].depth = depth;
  stacks_used++;
}

static void profile_hook (lua_State *L, lua_Debug *ar) {
  (void)ar;
  uint32_t ids[PROFILE_DEPTH];
  uint32_t depth = 0;
  lua_Debug d;
  char text[512];
  while (depth < PROFILE_DEPTH && lua_getstack(L, (int)depth, &d)) {
    if (!lua_getinfo(L, "Sn", &d)) break;
    const char *name = d.name != NULL ? d.name : "?";
    if (d.what[0] == 'C') {
      snprintf(text, sizeof text, "%s@[C]", name);
    } else {
      snprintf(text, sizeof text, "%s@%s:%d", name, d.short_src,
               d.linedefined);
    }
    /* A `;` or a space in a frame would split it in the folded form. */
    for (char *c = text; *c != '\0'; c++) {
      if (*c == ';' || *c == ' ') *c = '_';
    }
    uint32_t id = frame_id(text);
    if (id == UINT32_MAX) {
      dropped++;
      return;
    }
    ids[depth++] = id;
  }
  if (depth == 0) return;
  /* Outermost first, as the folded form writes them. */
  for (uint32_t i = 0; i < depth / 2; i++) {
    uint32_t t = ids[i];
    ids[i] = ids[depth - 1 - i];
    ids[depth - 1 - i] = t;
  }
  count_stack(ids, depth);
}

void cosmic_profile_report (void) {
  if (stacks == NULL || out_path == NULL || getpid() != profiled) return;
  /* A new file of this user's alone: never one that is there already,
   * nor a symbolic link at the path's last name, so the variable cannot
   * aim the write at a file that exists. A link earlier in the path is
   * followed, as any open follows it. The image an exec starts keeps the
   * pid, so its profile takes the next free name. */
  char path[4096];
  int fd = -1;
  for (int n = 0; n < 100 && fd < 0; n++) {
    int made = n == 0 ? snprintf(path, sizeof path, "%s.%ld", out_path, (long)getpid())
                      : snprintf(path, sizeof path, "%s.%ld.%d", out_path, (long)getpid(), n);
    if (made < 0 || made >= (int)sizeof path) return;
    fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0 && errno != EEXIST) return;
  }
  if (fd < 0) return;
  /* Written once: the atexit call after an earlier one finds nothing. */
  cosmic_free(out_path);
  out_path = NULL;
  FILE *f = fdopen(fd, "w");
  if (f == NULL) {
    close(fd);
    return;
  }
  for (size_t i = 0; i < STACK_SLOTS; i++) {
    const struct stack *s = &stacks[i];
    if (s->ids == NULL) continue;
    for (uint32_t k = 0; k < s->depth; k++) {
      fprintf(f, "%s%s", k == 0 ? "" : ";", frames[s->ids[k]].text);
    }
    fprintf(f, " %lu\n", s->count);
  }
  if (dropped > 0) fprintf(f, "(dropped) %lu\n", dropped);
  fclose(f);
}

void cosmic_profile_install (lua_State *L) {
  const char *path = getenv("COSMIC_PROFILE");
  if (path == NULL || path[0] == '\0') return;
  /* The hook slot is taken already: startup coverage
   * (COSMIC_COVERAGE_STARTUP) keeps it, and nothing is profiled. */
  if (lua_gethook(L) != NULL) return;
  if (stacks == NULL) {
    size_t n = strlen(path);
    frames = cosmic_calloc(FRAME_SLOTS, sizeof *frames);
    stacks = cosmic_calloc(STACK_SLOTS, sizeof *stacks);
    out_path = cosmic_malloc(n + 1);
    if (frames == NULL || stacks == NULL || out_path == NULL) {
      cosmic_free(frames);
      cosmic_free(stacks);
      cosmic_free(out_path);
      frames = NULL;
      stacks = NULL;
      out_path = NULL;
      return;
    }
    memcpy(out_path, path, n + 1);
    profiled = getpid();
    atexit(cosmic_profile_report);
  }
  int period = 1000;
  const char *given = getenv("COSMIC_PROFILE_PERIOD");
  if (given != NULL) {
    long n = strtol(given, NULL, 10);
    if (n > 0 && n < 1000000000) period = (int)n;
  }
  lua_sethook(L, profile_hook, LUA_MASKCOUNT, period);
}
