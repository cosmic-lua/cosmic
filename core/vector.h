#ifndef COSMIC_VECTOR_H
#define COSMIC_VECTOR_H

#include "lua.h"
#include "sqlite3.h"

/* Registers the vector functions on db, under pgvector's names: a
 * vector is a blob of little-endian 32-bit floats, or a text `[1,2,3]`
 * wherever one is read. Answers SQLite's status. */
int cosmic_vector_functions (sqlite3 *db);

/* Opens the table that backs the [`cosmic.vector`] wrapper, registered
 * under the raw [`cosmic.internal.vector`] name: packing, and a corpus
 * of vectors searched in memory with the same kernels as the SQL
 * functions. */
int cosmic_open_vector (lua_State *L);

#endif
