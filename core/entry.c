#include "startup.h"

#include <string.h>
#include <unistd.h>

#include "executable.h"
#include "portable.h"

int main (int argc, char **argv) {
  struct cosmic_startup startup;
  int artifact_argument = argc >= 2 && strcmp(argv[1], "--artifact") == 0;
  if (artifact_argument || cosmic_startup_has_private_environment()) {
    const char *path = artifact_argument && argc >= 3 ? argv[2] : NULL;
    cosmic_startup_portable(&startup, path);
    if (artifact_argument && argc >= 3)
      return cosmic_runtime_entry(&startup, argc - 2, argv + 2);
    return cosmic_runtime_entry(&startup, argc, argv);
  }
  /* A host program is this core with its database appended: the running
   * executable itself says so, in its trailer. */
  static char self[COSMIC_ARTIFACT_PATH_CAPACITY];
  int fd = cosmic_executable_fd();
  if (fd >= 0 && cosmic_host_trailer(fd) &&
      cosmic_executable_path(self, sizeof self)) {
    cosmic_startup_host(&startup, fd, self);
    return cosmic_runtime_entry(&startup, argc, argv);
  }
  if (fd >= 0) close(fd);
  cosmic_startup_native(&startup);
  return cosmic_runtime_entry(&startup, argc, argv);
}
