#include "startup.h"

#include <stdbool.h>
#include <string.h>
#include <unistd.h>

#include "executable.h"
#include "portable.h"
#include "process.h"

int main (int argc, char **argv) {
#if defined(__linux__)
  if (cosmic_sandbox_init_asked(argc, argv)) cosmic_sandbox_init();
#endif
  struct cosmic_startup startup;
  /* The artifact is named `--artifact <path>`, or `--artifact=<path>` in
   * one argument: a `#!` line hands its interpreter one argument at most,
   * so a script names the core as its interpreter only that way. The
   * joined form's slot is rewritten to the path, so the runtime's argv
   * begins with the path under either form. */
  static const char joined[] = "--artifact=";
  bool artifact_argument = argc >= 2 && strcmp(argv[1], "--artifact") == 0;
  bool artifact_joined =
      argc >= 2 && strncmp(argv[1], joined, sizeof joined - 1) == 0;
  if (artifact_argument || artifact_joined ||
      cosmic_startup_has_private_environment()) {
    if (artifact_argument && argc >= 3) {
      cosmic_startup_portable(&startup, argv[2]);
      return cosmic_runtime_entry(&startup, argc - 2, argv + 2);
    }
    if (artifact_joined && argv[1][sizeof joined - 1] != '\0') {
      argv[1] += sizeof joined - 1;
      cosmic_startup_portable(&startup, argv[1]);
      return cosmic_runtime_entry(&startup, argc - 1, argv + 1);
    }
    /* Either form naming no path is refused as naming no artifact. */
    cosmic_startup_portable(&startup, NULL);
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
