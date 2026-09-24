#define _POSIX_C_SOURCE 200809L

#include "environment.h"

#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <crt_externs.h>
#define COSMIC_ENVIRON (*_NSGetEnviron())
#else
extern char **environ;
#define COSMIC_ENVIRON environ
#endif

#define COSMIC_PORTABLE_ENV_PREFIX "COSMIC_PORTABLE_"
#define COSMIC_PORTABLE_ENV_CACHE "COSMIC_PORTABLE_CACHE"

bool cosmic_environment_clear_reserved (const char *const *keep) {
  const size_t prefix_length = strlen(COSMIC_PORTABLE_ENV_PREFIX);
  for (;;) {
    const char *found = NULL;
    size_t found_length = 0;
    for (char **at = COSMIC_ENVIRON; at != NULL && *at != NULL; at++) {
      const char *entry = *at;
      if (strncmp(entry, COSMIC_PORTABLE_ENV_PREFIX, prefix_length) != 0)
        continue;
      const char *equals = strchr(entry, '=');
      if (equals == NULL) continue;
      const size_t name_length = (size_t)(equals - entry);
      if (name_length == strlen(COSMIC_PORTABLE_ENV_CACHE) &&
          strncmp(entry, COSMIC_PORTABLE_ENV_CACHE, name_length) == 0)
        continue;
      int kept = 0;
      for (const char *const *name = keep; name != NULL && *name != NULL;
           name++) {
        if (name_length == strlen(*name) &&
            strncmp(entry, *name, name_length) == 0) {
          kept = 1;
          break;
        }
      }
      if (kept) continue;
      found = entry;
      found_length = name_length;
      break;
    }
    if (found == NULL) return true;
    char *name = malloc(found_length + 1);
    if (name == NULL) return false;
    memcpy(name, found, found_length);
    name[found_length] = '\0';
    const int cleared = unsetenv(name) == 0;
    free(name);
    if (!cleared) return false;
  }
}
