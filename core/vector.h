#ifndef COSMIC_VECTOR_H
#define COSMIC_VECTOR_H

#include "sqlite3.h"

/* Registers the vector functions on db, under pgvector's names: a
 * vector is a blob of little-endian 32-bit floats, or a text `[1,2,3]`
 * wherever one is read. Answers SQLite's status. */
int cosmic_vector_functions (sqlite3 *db);

#endif
