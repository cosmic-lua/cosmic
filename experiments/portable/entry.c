/* Experimental entry only: normal builds use core/entry.c. The runtime entry
 * receives the same explicit startup record in both modes. */
#define _XOPEN_SOURCE 700

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "startup.h"

int main(int argc, char **argv) {
  struct cosmic_startup startup;
  int private_environment = cosmic_startup_has_private_environment();
  if (argc < 2 || strcmp(argv[1], "--artifact") != 0) {
    if (private_environment) {
      cosmic_startup_portable(&startup, NULL);
      return cosmic_runtime_entry(&startup, argc, argv);
    }
    cosmic_startup_native(&startup);
    return cosmic_runtime_entry(&startup, argc, argv);
  }
  if (argc < 3) {
    fprintf(stderr, "cosmic: portable startup names no artifact\n");
    return 2;
  }

  /* The old packed prototype intentionally has no descriptor contract.
   * New-format launchers set at least one private field and therefore take
   * the strict retained-descriptor path; malformed partial contracts cannot
   * silently fall back to this compatibility route. */
  if (private_environment) {
    cosmic_startup_portable(&startup, argv[2]);
  } else {
    char artifact[4096];
    if (realpath(argv[2], artifact) == NULL) {
      fprintf(stderr, "cosmic: cannot resolve artifact: %s\n", argv[2]);
      return 2;
    }
    cosmic_startup_legacy_artifact(&startup, artifact);
    return cosmic_runtime_entry(&startup, argc - 2, argv + 2);
  }
  return cosmic_runtime_entry(&startup, argc - 2, argv + 2);
}
