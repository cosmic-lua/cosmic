/*
 * Private process-startup contract shared by native and portable entries.
 * Portable startup captures and clears the launcher's bounded environment
 * contract before the runtime can create a Lua state. The inherited handles
 * are then adopted into one owned artifact context.
 */

#ifndef COSMIC_STARTUP_H
#define COSMIC_STARTUP_H

#include <stdint.h>

#include "portable.h"

#define COSMIC_STARTUP_VERSION 1u

/*
 * Private portable launcher environment contract. The entire
 * COSMIC_PORTABLE_ prefix is reserved for the launcher and runtime; callers
 * configure only COSMIC_PORTABLE_CACHE. The launcher first selects two unused
 * descriptors from its bounded candidate set, then leaves the artifact and
 * verified standalone core open on them across its one exec. Startup must
 * validate and clear exactly these bounded fields before Lua can inspect or
 * propagate the environment. cosmic_startup_portable below does the validate
 * and clear; cosmic_startup_adopt does the adoption once that succeeds.
 */
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
  /* A host program: the executable carries its own database. */
  COSMIC_STARTUP_HOST = 3,
};

enum cosmic_startup_test_phase {
  COSMIC_STARTUP_TEST_ARTIFACT_ADOPTED,
  COSMIC_STARTUP_TEST_STARTUP_RELEASED,
  COSMIC_STARTUP_TEST_DATABASE_OPENED,
  COSMIC_STARTUP_TEST_STORE_INSTALLED,
  COSMIC_STARTUP_TEST_MAIN_ENTERING,
  COSMIC_STARTUP_TEST_MAIN_RETURNED,
  COSMIC_STARTUP_TEST_LUA_CLOSED,
  COSMIC_STARTUP_TEST_DATABASE_CLOSED,
  COSMIC_STARTUP_TEST_ARTIFACT_CLOSED,
};

struct cosmic_startup {
  uint32_t version;
  enum cosmic_startup_kind kind;
  uint32_t target_id;
  uint32_t configuration_id;
  const char *target_name;
  const char *configuration_name;
  const char *artifact_path;
  int artifact_fd;
  int core_fd;
  uint32_t launcher_target_id;
  uint32_t launcher_configuration_id;
  uint64_t launcher_core_offset;
  uint64_t launcher_core_length;
  unsigned char launcher_core_sha256[COSMIC_PORTABLE_SHA256_LENGTH];
  const char *contract_error;
};

void cosmic_startup_native(struct cosmic_startup *startup);
/* A native start whose own executable, held open by `fd` at `path`, ends in
 * a host program trailer. */
void cosmic_startup_host(struct cosmic_startup *startup, int fd,
                         const char *path);
/* Whether the artifact's selected core range hashes to its manifest digest,
 * checked once and remembered. */
int cosmic_artifact_core_matches(struct cosmic_artifact *artifact);
void cosmic_startup_portable(struct cosmic_startup *startup,
                             const char *artifact_path);
int cosmic_startup_has_private_environment(void);
const char *cosmic_startup_validate(const struct cosmic_startup *startup);
int cosmic_startup_adopt(const struct cosmic_startup *startup,
                         struct cosmic_artifact *artifact,
                         const char **error);
int cosmic_startup_test_pause(const struct cosmic_startup *startup,
                              const char **error);
/* The names under the reserved COSMIC_PORTABLE_ prefix the linked hook
 * reads for itself and leaves in place for the processes this one
 * starts, NULL-terminated; the product hook names none, so startup
 * clears every reserved name but COSMIC_PORTABLE_CACHE. */
const char *const *cosmic_startup_test_environment(void);
void cosmic_startup_test_phase(const struct cosmic_startup *startup,
                               enum cosmic_startup_test_phase phase);
int cosmic_runtime_entry(const struct cosmic_startup *startup, int argc,
                         char **argv);

#endif
