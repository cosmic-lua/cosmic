/* Static reader / open-hammer for the #744 fd-pressure test.
 *
 *   reader FILE            open FILE once  -> exit 0 if opened, 1 if denied
 *   reader FILE N          open+close FILE N times (mimicking teal's
 *                          open-read-close-per-module churn) -> exit 0 if all
 *                          N succeeded, 1 on the first failure, printing the
 *                          iteration and errno NAME so a Landlock deny (EACCES)
 *                          is distinguishable from a transient fd/interrupt
 *                          failure (EMFILE/ENFILE/EINTR/ENOMEM).
 *
 * Static: a sandboxed child needs only rx on this binary + r on FILE, so a
 * failure can only be the kernel refusing an otherwise-granted open. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  long loops = argc >= 3 ? strtol(argv[2], 0, 10) : 1;
  for (long i = 0; i < loops; i++) {
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
      fprintf(stderr, "open#%ld errno=%d(%s)", i, errno, strerror(errno));
      return 1;
    }
    close(fd);
  }
  return 0;
}
