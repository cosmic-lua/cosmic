#define _POSIX_C_SOURCE 200809L

#include "cache_owner.h"

#include <stdio.h>

enum cosmic_userns cosmic_userns_of_map (const char *map) {
  if (map == NULL) return COSMIC_USERNS_UNKNOWN;
  unsigned long inside, outside, count;
  char extra;
  if (sscanf(map, " %lu %lu %lu %c", &inside, &outside, &count, &extra) != 3)
    return COSMIC_USERNS_YES;
  return (inside == 0 && outside == 0)
             ? COSMIC_USERNS_NO
             : COSMIC_USERNS_YES;
}

bool cosmic_cache_roots_entry (uid_t owner, uid_t leaf_owner, uid_t user,
                               uid_t overflow, enum cosmic_userns state) {
  if (owner == 0) return leaf_owner == 0;
  return leaf_owner == user && owner != user && owner == overflow &&
         state != COSMIC_USERNS_NO;
}
