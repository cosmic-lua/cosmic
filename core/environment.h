/* Process-environment policy applied before the runtime creates Lua. */
#ifndef COSMIC_ENVIRONMENT_H
#define COSMIC_ENVIRONMENT_H

/* Remove every COSMIC_PORTABLE_* name except COSMIC_PORTABLE_CACHE and the
 * NULL-terminated test-hook seam in keep. Returns zero on allocation or
 * unsetenv failure; it never silently leaves a matching name behind. */
int cosmic_environment_clear_reserved(const char *const *keep);

#endif
