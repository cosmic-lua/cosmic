#define _XOPEN_SOURCE 700

#include "executable.h"

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <limits.h>
#include <mach-o/dyld.h>
#endif

int cosmic_executable_path (char *into, size_t room) {
#if defined(__APPLE__)
  char raw[PATH_MAX];
  uint32_t size = sizeof raw;
  if (_NSGetExecutablePath(raw, &size) != 0) return 0;
  char resolved[PATH_MAX];
  if (realpath(raw, resolved) == NULL) return 0;
  size_t len = strlen(resolved);
  if (len + 1 > room) return 0;
  memcpy(into, resolved, len + 1);
  return 1;
#else
  ssize_t len = readlink("/proc/self/exe", into, room - 1);
  if (len < 0) return 0;
  into[len] = '\0';
  return 1;
#endif
}

int cosmic_executable_fd (void) {
#if defined(__APPLE__)
  char raw[PATH_MAX];
  uint32_t size = sizeof raw;
  if (_NSGetExecutablePath(raw, &size) != 0) return -1;
  return open(raw, O_RDONLY | O_CLOEXEC);
#else
  return open("/proc/self/exe", O_RDONLY | O_CLOEXEC);
#endif
}
