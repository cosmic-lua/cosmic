#include "startup.h"

bool cosmic_startup_test_pause (const struct cosmic_startup *startup,
                                const char **error) {
  (void)startup;
  (void)error;
  return true;
}

void cosmic_startup_test_phase (const struct cosmic_startup *startup,
                                enum cosmic_startup_test_phase phase) {
  (void)startup;
  (void)phase;
}

const char *const *cosmic_startup_test_environment (void) {
  static const char *const none[] = {NULL};
  return none;
}
