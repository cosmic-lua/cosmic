#include "startup.h"

int main(int argc, char **argv) {
  struct cosmic_startup startup;
  cosmic_startup_native(&startup);
  return cosmic_runtime_entry(&startup, argc, argv);
}
