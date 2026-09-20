/* Experimental entry only: normal builds use core/entry.c. The runtime entry
 * receives the same explicit startup record in both modes. */
#define _XOPEN_SOURCE 700

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "startup.h"

int main(int argc, char **argv) {
  struct cosmic_startup startup;
  if (argc < 2 || strcmp(argv[1], "--artifact") != 0) {
    cosmic_startup_native(&startup);
    return cosmic_runtime_entry(&startup, argc, argv);
  }
  if (argc < 3) {
    fprintf(stderr, "cosmic: portable startup names no artifact\n");
    return 2;
  }

  char artifact[4096];
  if (realpath(argv[2], artifact) == NULL) {
    fprintf(stderr, "cosmic: cannot resolve artifact: %s\n", argv[2]);
    return 2;
  }

  cosmic_startup_portable(&startup, artifact);
  return cosmic_runtime_entry(&startup, argc - 2, argv + 2);
}
