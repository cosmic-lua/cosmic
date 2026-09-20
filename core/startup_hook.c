#include "startup.h"

int cosmic_startup_test_pause(const struct cosmic_startup *startup,
                              const char **error) {
  (void)startup;
  (void)error;
  return 1;
}

void cosmic_startup_test_phase(const struct cosmic_startup *startup,
                               enum cosmic_startup_test_phase phase) {
  (void)startup;
  (void)phase;
}
