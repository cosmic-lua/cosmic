/*
 * The syscall table's log of what its queries answered, which
 * build.filesystem_observations drains into the reads of the test
 * running (core/syscalls.c). Five bindings keep a record: `getcwd`,
 * `executable`, `lstat`, `readlink` and `realpath`, each a query that
 * changes nothing and answers `value|nil, error, errno`. Each checks
 * `cosmic_observing` first and, when it is off, is its query and
 * nothing more; every other binding is untouched. The check lives in
 * the binding itself, so a reference to it taken before logging began
 * is logged too.
 */

#ifndef COSMIC_OBSERVED_H
#define COSMIC_OBSERVED_H

#include <stdbool.h>

#include "lua.h"

/* Which query a record is of: its index in core/syscalls.c's
 * `observed_calls`. */
enum cosmic_observed_call {
  COSMIC_OBSERVED_GETCWD,
  COSMIC_OBSERVED_EXECUTABLE,
  COSMIC_OBSERVED_LSTAT,
  COSMIC_OBSERVED_READLINK,
  COSMIC_OBSERVED_REALPATH,
};

/* Whether the log is on: `observe` sets it. */
extern bool cosmic_observing;

/* Calls `query` and keeps the record of what it was asked and answered
 * as `call`. Answers the count the query answers, or, when its record
 * cannot be kept, a failure's as memory's: `nil, error, ENOMEM`. */
int cosmic_observed_call (lua_State *L, enum cosmic_observed_call call,
                          lua_CFunction query);

/* The queries themselves, past the log: each binding's work. */
int cosmic_query_getcwd (lua_State *L);
int cosmic_query_lstat (lua_State *L);
int cosmic_query_readlink (lua_State *L);
int cosmic_query_realpath (lua_State *L);

/* Opens the table build.filesystem_observations reads the log through:
 * `observe` turns it on or off, `observed` drains it, and the queries
 * it asks for itself are there as themselves, logging nothing. */
int cosmic_open_observed (lua_State *L);

#endif
