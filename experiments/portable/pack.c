/* Remove redundant compressed cores from a COPY of the boot database.
 * Target-specific builder metadata is deliberately removed: this experiment
 * exercises runtime reads, not cross-target builds or self-rebuild yet. */
#include <stdio.h>
#include "sqlite3.h"
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  sqlite3 *db = NULL;
  int rc = sqlite3_open(argv[1], &db);
  char *error = NULL;
  if (rc == SQLITE_OK)
    rc = sqlite3_exec(db, "DELETE FROM images; DELETE FROM meta WHERE key IN "
      "('host','host_image','runtime'); VACUUM;", NULL, NULL, &error);
  if (rc != SQLITE_OK) fprintf(stderr, "project database: %s\n",
      error ? error : sqlite3_errmsg(db));
  sqlite3_free(error);
  sqlite3_close(db);
  return rc == SQLITE_OK ? 0 : 1;
}
