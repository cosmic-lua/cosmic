/*
 * The syscall table's log of what its calls were asked and answered,
 * which build.filesystem_observations drains into the reads of the test
 * running (core/observed.c). Each observed binding checks
 * `cosmic_observing` itself and, when it is off, is its call and
 * nothing more; every other binding is untouched. The check lives in
 * the binding, so a reference to it taken before logging began is
 * logged too.
 *
 * Three shapes of record, by what the call does:
 *   - a query, which changes nothing and answers `value|nil, error,
 *     errno` (`getcwd`, `executable`, `lstat`, `readlink`, `realpath`,
 *     `stat`, `readdir`, `getenv`, `environ`): kept after it answers,
 *     with what it answered; one whose record cannot be kept fails as
 *     memory does (`cosmic_observed_call`). `chdir` keeps a stat's of
 *     where it goes before it goes (`cosmic_observed_ask`).
 *   - a call that reaches past the process (`open`, the process table's
 *     `spawn`, cosmic.http's `open`): kept before it acts, with what it
 *     was given alone; one whose record cannot be kept fails, having
 *     done nothing (`cosmic_observed_note`).
 *   - a call that makes a directory (`mkdir`, `mkdtemp`): kept after it
 *     made it, with its path; one whose record cannot be kept removes
 *     what it made and fails.
 *
 * A path is kept whole, from the working directory the call was made in
 * when it is relative, and, where `resolving` asks for it, with what it
 * resolved to as the call was made (see core/observed.c's
 * `resolution`).
 */

#ifndef COSMIC_OBSERVED_H
#define COSMIC_OBSERVED_H

#include <stdbool.h>
#include <stddef.h>

#include "lua.h"

/* Which call a record is of: its index in core/observed.c's
 * `observed_calls`. */
enum cosmic_observed_call {
  COSMIC_OBSERVED_GETCWD,
  COSMIC_OBSERVED_EXECUTABLE,
  COSMIC_OBSERVED_LSTAT,
  COSMIC_OBSERVED_READLINK,
  COSMIC_OBSERVED_REALPATH,
  COSMIC_OBSERVED_OPEN,
  COSMIC_OBSERVED_STAT,
  COSMIC_OBSERVED_READDIR,
  COSMIC_OBSERVED_GETENV,
  COSMIC_OBSERVED_ENVIRON,
  COSMIC_OBSERVED_MKDIR,
  COSMIC_OBSERVED_MKDTEMP,
  COSMIC_OBSERVED_SPAWN,
  COSMIC_OBSERVED_HTTP,
};

/* Whether the log is on: `observe` sets it. */
extern bool cosmic_observing;

/* Calls `query` and keeps the record of what it was asked, its first
 * argument, and answered as `call`. Answers the count the query
 * answers, or, when its record cannot be kept, a failure's as memory's:
 * `nil, error, ENOMEM`. */
int cosmic_observed_call (lua_State *L, enum cosmic_observed_call call,
                          lua_CFunction query);

/* Calls `query` and keeps the record of what it was asked and answered
 * as `call`, as `cosmic_observed_call` does, but answers nothing: the
 * stack is left as it was. False when the record cannot be kept. */
bool cosmic_observed_ask (lua_State *L, enum cosmic_observed_call call,
                          lua_CFunction query);

/* Keeps the record of `call` given `text` (`length` bytes; NULL for
 * what is no string), with no answer. False when it cannot be kept. */
bool cosmic_observed_note (enum cosmic_observed_call call, const char *text,
                           size_t length);

/* The calls themselves, past the log: each binding's work. */
int cosmic_query_getcwd (lua_State *L);
int cosmic_query_executable (lua_State *L);
int cosmic_query_lstat (lua_State *L);
int cosmic_query_readlink (lua_State *L);
int cosmic_query_realpath (lua_State *L);
int cosmic_query_stat (lua_State *L);
int cosmic_query_readdir (lua_State *L);
int cosmic_query_getenv (lua_State *L);
int cosmic_query_environ (lua_State *L);
int cosmic_spawn_unobserved (lua_State *L);

/* Opens the table build.filesystem_observations reads the log through:
 * `observe` turns it on or off, `observed` drains it, `resolving` says
 * which paths a record resolves, `resolve` answers what a path resolves
 * to as a record's resolution is told, and the calls it makes for
 * itself are there as themselves, logging nothing. */
int cosmic_open_observed (lua_State *L);

#endif
