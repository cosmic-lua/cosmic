/* Experimental entry only: normal builds still compile core/main.c.
 * Reuse the real entry and VFS, changing only where main finds its database.
 * Proc.executable still truthfully names the native core. */
#define _XOPEN_SOURCE 700
#define main cosmic_native_main
#define cosmic_executable_path cosmic_artifact_path
#include "../../core/main.c"
#undef cosmic_executable_path
#undef main

extern int cosmic_executable_path(char *, size_t);
static const char *artifact;

int cosmic_artifact_path(char *into, size_t room) {
  if (artifact == NULL) return cosmic_executable_path(into, room);
  size_t n = strlen(artifact);
  if (n >= room) return 0;
  memcpy(into, artifact, n + 1);
  return 1;
}

int main(int argc, char **argv) {
  char resolved[4096];
  if (argc >= 3 && strcmp(argv[1], "--artifact") == 0) {
    if (realpath(argv[2], resolved) == NULL)
      return complain("cannot resolve artifact", argv[2]);
    artifact = resolved;
    argc -= 2;
    argv += 2;
  }
  return cosmic_native_main(argc, argv);
}
