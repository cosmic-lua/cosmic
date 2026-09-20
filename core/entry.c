#include "startup.h"

#include <string.h>

int main(int argc, char **argv) {
  struct cosmic_startup startup;
  int artifact_argument = argc >= 2 && strcmp(argv[1], "--artifact") == 0;
  if (artifact_argument || cosmic_startup_has_private_environment()) {
    const char *path = artifact_argument && argc >= 3 ? argv[2] : NULL;
    cosmic_startup_portable(&startup, path);
    if (artifact_argument && argc >= 3)
      return cosmic_runtime_entry(&startup, argc - 2, argv + 2);
    return cosmic_runtime_entry(&startup, argc, argv);
  }
  cosmic_startup_native(&startup);
  return cosmic_runtime_entry(&startup, argc, argv);
}
