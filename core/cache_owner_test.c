#define _POSIX_C_SOURCE 200809L

#include "cache_owner.h"

#include <stdio.h>

static int failed;

static void expect (bool got, bool want, const char *what) {
  if (got == want) return;
  fprintf(stderr, "cache_owner: %s: got %d, want %d\n", what, got, want);
  failed = 1;
}

int main (void) {
  enum { ROOT = 0, USER = 1000, NOBODY = 65534 };

  /* What the map says. */
  expect(cosmic_userns_of_map("         0          0 4294967295") == COSMIC_USERNS_NO, true, "the first namespace");
  expect(cosmic_userns_of_map("      1000       1000          1") == COSMIC_USERNS_YES, true, "a namespace of one id");
  expect(cosmic_userns_of_map("         0       1000          1") == COSMIC_USERNS_YES, true, "a mapped root");
  expect(cosmic_userns_of_map("0 0 1 2") == COSMIC_USERNS_YES, true, "a line not of three numbers");
  expect(cosmic_userns_of_map(NULL) == COSMIC_USERNS_UNKNOWN, true, "an unreadable map");

  /* Root's copy in root's leaf: the shared cores of a root caller. */
  expect(cosmic_cache_roots_entry(ROOT, ROOT, USER, NOBODY, COSMIC_USERNS_NO), true, "root's in root's leaf");
  expect(cosmic_cache_roots_entry(ROOT, USER, USER, NOBODY, COSMIC_USERNS_NO), false, "root's in a user's leaf, in no namespace");
  expect(cosmic_cache_roots_entry(ROOT, 2000, USER, NOBODY, COSMIC_USERNS_NO), false, "root's in another user's leaf");

  /* A root it cannot name, in the user's own leaf (isolate "file"): whether
   * or not the namespace can be seen, as an MCP server's sandbox hides /proc
   * (this was refused as "not mode 0500 (mode 555)" under the "system"
   * profile, as root). */
  expect(cosmic_cache_roots_entry(NOBODY, USER, USER, NOBODY, COSMIC_USERNS_YES), true, "an overflow owner in a namespace");
  expect(cosmic_cache_roots_entry(NOBODY, USER, USER, NOBODY, COSMIC_USERNS_UNKNOWN), true, "an overflow owner, namespace not visible");

  /* What stays refused. */
  expect(cosmic_cache_roots_entry(NOBODY, USER, USER, NOBODY, COSMIC_USERNS_NO), false, "an overflow owner in no namespace");
  expect(cosmic_cache_roots_entry(NOBODY, NOBODY, USER, NOBODY, COSMIC_USERNS_YES), false, "an overflow owner in a leaf not the user's");
  expect(cosmic_cache_roots_entry(2000, USER, USER, NOBODY, COSMIC_USERNS_YES), false, "another user's entry in a namespace");
  expect(cosmic_cache_roots_entry(2000, USER, USER, NOBODY, COSMIC_USERNS_UNKNOWN), false, "another user's entry, namespace not visible");
  expect(cosmic_cache_roots_entry(USER, USER, USER, NOBODY, COSMIC_USERNS_YES), false, "the user's own 0555 entry");
  expect(cosmic_cache_roots_entry(NOBODY, USER, NOBODY, NOBODY, COSMIC_USERNS_UNKNOWN), false, "a user that is the overflow id");
  if (failed) return 1;
  puts("cache_owner: PASS (the map, root's copy, an unnamed root, the refusals)");
  return 0;
}
