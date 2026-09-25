/*
 * What an errno is called and what it says, the same on every OS the
 * core runs on. The numbers are the platform's own -- EAGAIN is 11 on
 * Linux and 35 on macOS -- but a failure's message (core/fail.h) and a
 * number's name come from one table (core/errnos.c), where libc's
 * strerror would answer musl's words on Linux and libSystem's on macOS.
 */

#ifndef COSMIC_ERRNOS_H
#define COSMIC_ERRNOS_H

/* The message for errno `number`: musl's wording, on every OS, and
 * "No error information" for a number the table does not hold. Never
 * NULL; static storage. When `name` is not NULL, `*name` is set to the
 * number's symbolic name ("ENOENT"), or NULL for a number the table
 * does not hold; where two names share a number on this OS (EOPNOTSUPP
 * and ENOTSUP on Linux) the first in the table answers. */
const char *cosmic_errno_describe (int number, const char **name);

#endif
