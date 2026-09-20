#include "startup.h"

#include <stddef.h>
#include <string.h>

#ifndef COSMIC_TARGET_ID
#error "build.zig must define COSMIC_TARGET_ID"
#endif
#ifndef COSMIC_TARGET_NAME
#error "build.zig must define COSMIC_TARGET_NAME"
#endif
#ifndef COSMIC_CONFIGURATION_ID
#error "build.zig must define COSMIC_CONFIGURATION_ID"
#endif
#ifndef COSMIC_CONFIGURATION_NAME
#error "build.zig must define COSMIC_CONFIGURATION_NAME"
#endif

static void compiled_startup(struct cosmic_startup *startup,
                             enum cosmic_startup_kind kind,
                             const char *artifact_path) {
  *startup = (struct cosmic_startup){
      .version = COSMIC_STARTUP_VERSION,
      .kind = kind,
      .target_id = COSMIC_TARGET_ID,
      .configuration_id = COSMIC_CONFIGURATION_ID,
      .target_name = COSMIC_TARGET_NAME,
      .configuration_name = COSMIC_CONFIGURATION_NAME,
      .artifact_path = artifact_path,
  };
}

void cosmic_startup_native(struct cosmic_startup *startup) {
  compiled_startup(startup, COSMIC_STARTUP_NATIVE, NULL);
}

void cosmic_startup_portable(struct cosmic_startup *startup,
                             const char *artifact_path) {
  compiled_startup(startup, COSMIC_STARTUP_PORTABLE, artifact_path);
}

const char *cosmic_startup_validate(const struct cosmic_startup *startup) {
  if (startup == NULL) return "startup record is missing";
  if (startup->version != COSMIC_STARTUP_VERSION)
    return "startup record has an unsupported version";
  if (startup->kind != COSMIC_STARTUP_NATIVE &&
      startup->kind != COSMIC_STARTUP_PORTABLE)
    return "startup record has an unknown kind";
  if (startup->target_id != COSMIC_TARGET_ID ||
      startup->target_name == NULL ||
      strcmp(startup->target_name, COSMIC_TARGET_NAME) != 0)
    return "startup target differs from the compiled target";
  if (startup->configuration_id != COSMIC_CONFIGURATION_ID ||
      startup->configuration_name == NULL ||
      strcmp(startup->configuration_name, COSMIC_CONFIGURATION_NAME) != 0)
    return "startup configuration differs from the compiled configuration";
  if (startup->kind == COSMIC_STARTUP_NATIVE &&
      startup->artifact_path != NULL)
    return "native startup unexpectedly names an artifact";
  if (startup->kind == COSMIC_STARTUP_PORTABLE &&
      (startup->artifact_path == NULL || startup->artifact_path[0] == '\0'))
    return "portable startup names no artifact";
  return NULL;
}
