/* The physical executable identity: where the running executable is.
 * The logical process path is COSMIC_LOGICAL_EXECUTABLE's, in
 * core/syscalls.h. */

#ifndef COSMIC_EXECUTABLE_H
#define COSMIC_EXECUTABLE_H

#include <stdbool.h>
#include <stddef.h>

/* Writes the running executable's path into `into`, NUL-terminated:
 * false when it cannot be found or does not fit in `room` bytes, NUL
 * included (so always false for a `room` of 0). */
bool cosmic_executable_path (char *into, size_t room);
int cosmic_executable_fd (void);

#endif
