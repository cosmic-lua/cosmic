/*
 * Private process-startup contract shared by native and portable entries.
 * Artifact-format and descriptor validation are added at their later boundary;
 * this record establishes the explicit seam and binds target/configuration now.
 */

#ifndef COSMIC_STARTUP_H
#define COSMIC_STARTUP_H

#include <stdint.h>

#define COSMIC_STARTUP_VERSION 1u

/*
 * Private portable launcher environment contract. The launcher first refuses
 * inherited descriptors 8 and 9 in either access direction, then leaves the
 * artifact and verified standalone core open on them across its one exec.
 * Startup must validate and clear exactly these bounded fields before Lua can
 * inspect or propagate the environment. Adoption begins in portable step 5.
 */
#define COSMIC_PORTABLE_ARTIFACT_FD 8
#define COSMIC_PORTABLE_CORE_FD 9
#define COSMIC_PORTABLE_ENV_ARTIFACT_FD "COSMIC_PORTABLE_ARTIFACT_FD"
#define COSMIC_PORTABLE_ENV_CORE_FD "COSMIC_PORTABLE_CORE_FD"
#define COSMIC_PORTABLE_ENV_TARGET_ID "COSMIC_PORTABLE_TARGET_ID"
#define COSMIC_PORTABLE_ENV_CONFIGURATION_ID "COSMIC_PORTABLE_CONFIGURATION_ID"
#define COSMIC_PORTABLE_ENV_CORE_OFFSET "COSMIC_PORTABLE_CORE_OFFSET"
#define COSMIC_PORTABLE_ENV_CORE_LENGTH "COSMIC_PORTABLE_CORE_LENGTH"
#define COSMIC_PORTABLE_ENV_CORE_SHA256 "COSMIC_PORTABLE_CORE_SHA256"

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
