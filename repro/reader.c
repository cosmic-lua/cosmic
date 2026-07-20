/* Minimal static reader: open(argv[1]) read-only; exit 0 if it opens, 1 if
 * denied/missing (prints errno name to stderr). Static so a sandboxed child
 * can exec it needing only rx on this binary + r on the target — no dynamic
 * linker, no libc.so, nothing else to grant. That isolates the one variable
 * under test: does Landlock let the sandboxed process OPEN the file? */
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 2) return 2;
  int fd = open(argv[1], O_RDONLY);
  if (fd >= 0) { close(fd); return 0; }
  const char *m = strerror(errno);
  (void)!write(2, m, strlen(m));
  return 1;
}
