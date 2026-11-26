/* Lua's one hook slot, shared: see core/hook.h. */

#define _POSIX_C_SOURCE 200809L

#include "hook.h"

#include <pthread.h>
#include <signal.h>
#include <stddef.h>

#include "lstate.h"

/* What coverage and the budget want, for every thread: one process holds
 * one Lua state. */
static int want_lines;
static int want_budget;

/* Set while the hook runs: a timer signal then leaves the arm alone. */
static volatile sig_atomic_t running;

/* The thread a sample is armed on, and the mask, count and count left it
 * had before, to give back when the sample is taken. */
static lua_State *volatile armed;
static int armed_mask;
static int armed_base;
static int armed_left;
/* Counts each [`cosmic_hook_set`]: an arm made before one gives back what
 * coverage and the budget want now, not what it saved. */
static unsigned generation;
static unsigned armed_generation;

static void dispatch (lua_State *L, lua_Debug *ar);

/* The mask coverage and the budget want. */
static int wanted_mask (void) {
  return (want_lines ? LUA_MASKLINE : 0) | (want_budget > 0 ? LUA_MASKCOUNT : 0);
}

/* Sets `L`'s hook to `mask` and `base`, with `left` of the count to go
 * where it is above 0 (a countdown a sample interrupted). */
static void install (lua_State *L, int mask, int base, int left) {
  lua_sethook(L, mask ? dispatch : NULL, mask, base);
  if ((mask & LUA_MASKCOUNT) && left > 0 && left <= base) L->hookcount = left;
}

static void dispatch (lua_State *L, lua_Debug *ar) {
  running = 1;
  if (ar->event != LUA_HOOKCOUNT) {
    cosmic_coverage_line(L, ar);
    running = 0;
    return;
  }
  if (L == armed) {
    armed = NULL;
    if (armed_generation == generation) {
      install(L, armed_mask, armed_base, armed_left);
    } else {
      install(L, wanted_mask(), want_budget, 0);
    }
    /* Cleared first: a sample can raise (out of memory), and the
     * profiler must not stay silenced after. A tick that lands while it
     * runs arms the next instruction after the hook returns. */
    running = 0;
    cosmic_profile_sample(L);
    return;
  }
  if (L->basehookcount == 1 && want_budget != 1) {
    /* An arm this thread inherited, or one a later arm on another thread
     * took over: give it what coverage and the budget want. */
    install(L, wanted_mask(), want_budget, 0);
    running = 0;
    return;
  }
  running = 0;
  /* Last: a spent budget raises. */
  cosmic_coverage_count(L);
}

void cosmic_hook_set (lua_State *L, int lines, int budget) {
  int signal_number = cosmic_profile_signal();
  sigset_t held, was;
  if (signal_number) {
    sigemptyset(&held);
    sigaddset(&held, signal_number);
    pthread_sigmask(SIG_BLOCK, &held, &was);
  }
  want_lines = lines;
  want_budget = budget > 0 ? budget : 0;
  generation++;
  if (armed == L) {
    /* Given back when the armed sample is taken. */
    armed_mask = wanted_mask();
    armed_base = want_budget;
    armed_left = 0;
    armed_generation = generation;
    lua_sethook(L, dispatch, armed_mask | LUA_MASKCOUNT, 1);
  } else {
    install(L, wanted_mask(), want_budget, 0);
  }
  if (signal_number) pthread_sigmask(SIG_SETMASK, &was, NULL);
}

void cosmic_hook_arm (lua_State *L) {
  if (running || armed == L) return;
  armed_mask = L->hookmask;
  armed_base = L->basehookcount;
  armed_left = L->hookcount;
  armed_generation = generation;
  armed = L;
  lua_sethook(L, dispatch, armed_mask | LUA_MASKCOUNT, 1);
}
