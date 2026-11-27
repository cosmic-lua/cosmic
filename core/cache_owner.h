/* Whose a 0555 cache entry may be: the judgement startup makes of the
 * owner of the core it runs from, apart from the system calls that tell it
 * the facts (core/startup.c), so a test holds it with no root, no user
 * namespace and no /proc (core/cache_owner_test.c). */
#ifndef COSMIC_CACHE_OWNER_H
#define COSMIC_CACHE_OWNER_H

#include <stdbool.h>
#include <sys/types.h>

/* Whether this process is in a user namespace other than the first. */
enum cosmic_userns {
  COSMIC_USERNS_NO,
  COSMIC_USERNS_YES,
  /* Its uid_map could not be read: a sandbox that holds /proc from the
   * program (the "system" profile an MCP server runs under) leaves no way
   * to tell. */
  COSMIC_USERNS_UNKNOWN,
};

/* The state `map` says, the first line of /proc/self/uid_map, or NULL
 * where it could not be read. */
enum cosmic_userns cosmic_userns_of_map (const char *map);

/* Whether a 0555 entry owned by `owner` in a leaf owned by `leaf_owner` is
 * root's copy, as `user` sees it: root's, in root's leaf; or, where this
 * user's leaf holds an entry of a root it cannot name (the user's own mount
 * of root's shared directory, or its namespace's, which shows what it does
 * not map as `overflow`), that overflow uid, which is never this user.
 * Only root can put an entry owned by another user in a leaf only its
 * owner and root can write, and root is trusted; and a 0555 entry is hashed
 * on every start, as no stamp is left beside it. So a namespace this
 * process cannot see (COSMIC_USERNS_UNKNOWN) does not refuse it, and a
 * process that can see it is in none does. */
bool cosmic_cache_roots_entry (uid_t owner, uid_t leaf_owner, uid_t user,
                               uid_t overflow, enum cosmic_userns state);

#endif
