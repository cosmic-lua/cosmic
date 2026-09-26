/* Process-environment policy applied before the runtime creates Lua. */
#ifndef COSMIC_ENVIRONMENT_H
#define COSMIC_ENVIRONMENT_H

#include <stdbool.h>

/* The process's environment, `environ`, which macOS hands out only
 * through a call. */
#if defined(__APPLE__)
#include <crt_externs.h>
#define COSMIC_ENVIRON (*_NSGetEnviron())
#else
extern char **environ;
#define COSMIC_ENVIRON environ
#endif

/* Remove every COSMIC_PORTABLE_* name except COSMIC_PORTABLE_CACHE and the
 * NULL-terminated test-hook seam in keep. Returns false on allocation or
 * unsetenv failure; it never silently leaves a matching name behind. */
bool cosmic_environment_clear_reserved (const char *const *keep);

#endif
