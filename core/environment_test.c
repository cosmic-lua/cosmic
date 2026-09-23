#define _POSIX_C_SOURCE 200809L

#include "environment.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main (void) {
  static const char *const keep[] = {
    "COSMIC_PORTABLE_STARTUP_TEST_READY",
    "COSMIC_PORTABLE_STARTUP_TEST_GO",
    NULL,
  };
  if (setenv("COSMIC_PORTABLE_CACHE", "/tmp/cache", 1) != 0) return 2;
  if (setenv("COSMIC_PORTABLE_ADJACENT_A", "a", 1) != 0) return 2;
  if (setenv("COSMIC_PORTABLE_ADJACENT_B", "b", 1) != 0) return 2;
  if (setenv(keep[0], "ready", 1) != 0 || setenv(keep[1], "go", 1) != 0)
    return 2;
  char name[96];
  for (unsigned i = 0; i < 40; i++) {
    if (snprintf(name, sizeof name, "COSMIC_PORTABLE_MANY_%02u", i) < 0 ||
        setenv(name, "many", 1) != 0)
      return 2;
  }
  memset(name, 'L', sizeof name);
  memcpy(name, "COSMIC_PORTABLE_", 16);
  name[sizeof name - 1] = '\0';
  if (setenv(name, "long", 1) != 0) return 2;

  if (!cosmic_environment_clear_reserved(keep)) return 2;
  if (getenv("COSMIC_PORTABLE_CACHE") == NULL ||
      getenv(keep[0]) == NULL || getenv(keep[1]) == NULL)
    return 1;
  if (getenv("COSMIC_PORTABLE_ADJACENT_A") != NULL ||
      getenv("COSMIC_PORTABLE_ADJACENT_B") != NULL || getenv(name) != NULL)
    return 1;
  for (unsigned i = 0; i < 40; i++) {
    if (snprintf(name, sizeof name, "COSMIC_PORTABLE_MANY_%02u", i) < 0 ||
        getenv(name) != NULL)
      return 1;
  }
  puts("environment: PASS (adjacent, forty, long, cache, and hook names)");
  return 0;
}
