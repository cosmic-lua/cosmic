/*
 * Private process-startup contract shared by native and portable entries.
 * Artifact-format and descriptor validation are added at their later boundary;
 * this record establishes the explicit seam and binds target/configuration now.
 */

#ifndef COSMIC_STARTUP_H
#define COSMIC_STARTUP_H

#include <stdint.h>

#define COSMIC_STARTUP_VERSION 1u

enum cosmic_startup_kind {
  COSMIC_STARTUP_NATIVE = 1,
  COSMIC_STARTUP_PORTABLE = 2,
};

struct cosmic_startup {
  uint32_t version;
  enum cosmic_startup_kind kind;
  uint32_t target_id;
  uint32_t configuration_id;
  const char *target_name;
  const char *configuration_name;
  const char *artifact_path;
};

void cosmic_startup_native(struct cosmic_startup *startup);
void cosmic_startup_portable(struct cosmic_startup *startup,
                             const char *artifact_path);
const char *cosmic_startup_validate(const struct cosmic_startup *startup);
int cosmic_runtime_entry(const struct cosmic_startup *startup, int argc,
                         char **argv);

#endif
