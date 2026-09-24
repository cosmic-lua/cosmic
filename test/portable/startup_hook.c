#define _POSIX_C_SOURCE 200809L

#include "startup.h"

#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *const hook_environment[] = {
  "COSMIC_PORTABLE_STARTUP_TEST_READY",
  "COSMIC_PORTABLE_STARTUP_TEST_GO",
  NULL,
};

/* The hook's own names survive startup's sweep of the reserved prefix so
 * a process this one starts -- the rebuilt tool a self-rebuild re-enters
 * -- pauses at the same FIFOs. */
const char *const *cosmic_startup_test_environment (void) {
  return hook_environment;
}

bool cosmic_startup_test_pause (const struct cosmic_startup *startup,
                                const char **error) {
  if (startup->kind != COSMIC_STARTUP_PORTABLE) return true;
  const char *ready = getenv(hook_environment[0]);
  const char *go = getenv(hook_environment[1]);
  if (ready == NULL && go == NULL) return true;
  if (ready == NULL || go == NULL) {
    if (error != NULL) *error = "startup test hook is incomplete";
    return false;
  }
  int ready_fd = open(ready, O_WRONLY);
  if (ready_fd < 0 || write(ready_fd, "ready\n", 6) != 6) {
    if (ready_fd >= 0) close(ready_fd);
    if (error != NULL) *error = "startup test hook cannot signal readiness";
    return false;
  }
  close(ready_fd);
  int go_fd = open(go, O_RDONLY);
  char byte;
  ssize_t got = go_fd < 0 ? -1 : read(go_fd, &byte, 1);
  if (go_fd >= 0) close(go_fd);
  if (got != 1) {
    if (error != NULL) *error = "startup test hook was not released";
    return false;
  }
  return true;
}

void cosmic_startup_test_phase (const struct cosmic_startup *startup,
                                enum cosmic_startup_test_phase phase) {
  if (startup->kind != COSMIC_STARTUP_PORTABLE) return;
  static const char *const names[] = {
    [COSMIC_STARTUP_TEST_ARTIFACT_ADOPTED] = "artifact adopted",
    [COSMIC_STARTUP_TEST_STARTUP_RELEASED] = "startup released",
    [COSMIC_STARTUP_TEST_DATABASE_OPENED] = "database opened",
    [COSMIC_STARTUP_TEST_STORE_INSTALLED] = "store installed",
    [COSMIC_STARTUP_TEST_MAIN_ENTERING] = "main entering",
    [COSMIC_STARTUP_TEST_MAIN_RETURNED] = "main returned",
    [COSMIC_STARTUP_TEST_LUA_CLOSED] = "lua closed",
    [COSMIC_STARTUP_TEST_DATABASE_CLOSED] = "database closed",
    [COSMIC_STARTUP_TEST_ARTIFACT_CLOSED] = "artifact closed",
  };
  const char *name = names[phase];
  static const char prefix[] = "cosmic portable test phase: ";
  (void)write(STDERR_FILENO, prefix, sizeof prefix - 1);
  (void)write(STDERR_FILENO, name, strlen(name));
  (void)write(STDERR_FILENO, "\n", 1);
}
