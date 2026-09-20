#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/mman.h>
#endif

extern char **environ;
static void fail(const char *s) { perror(s); exit(1); }
static void put(int fd, const void *p, size_t n) {
  while (n) {
    ssize_t k = write(fd, p, n);
    if (k <= 0) fail("write");
    p = (const char *)p + k;
    n -= (size_t)k;
  }
}
static int run(const char *label, const char *path, int fd, int want) {
  fflush(stdout);
  pid_t pid = fork();
  if (pid < 0) fail("fork");
  if (!pid) {
    char *args[] = {(char *)path, NULL};
#ifdef __linux__
    if (fd >= 0) fexecve(fd, args, environ);
    else
#else
    (void)fd;
#endif
      execve(path, args, environ);
    int error = errno;
    fprintf(stderr, "%s: exec error %d (%s)\n", label, error, strerror(error));
    _exit(111);
  }
  int status;
  if (waitpid(pid, &status, 0) < 0) fail("waitpid");
  int result = WIFEXITED(status) ? WEXITSTATUS(status) : -WTERMSIG(status);
  printf("%s: status=%d (%s)\n", label, result,
         result == 42 ? "native payload ran" : "payload did not run");
  if (result < 0 || (want == 42 && result != 42) || (want == 111 && result != 111)) {
    fprintf(stderr, "unexpected result for %s\n", label);
    return 1;
  }
  return 0;
}
static void be32(unsigned char *p, uint32_t v) {
  p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
}
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  int source = open(argv[1], O_RDONLY);
  if (source < 0) fail("payload");
  struct stat st;
  if (fstat(source, &st)) fail("stat payload");
  size_t n = (size_t)st.st_size;
  unsigned char *bytes = malloc(n);
  if (!bytes) fail("malloc");
  size_t have = 0;
  while (have < n) {
    ssize_t k = read(source, bytes + have, n - have);
    if (k <= 0) fail("read payload");
    have += (size_t)k;
  }
  close(source);
  int bad = run("native file", argv[1], -1, 42);
  char path[4096];
  snprintf(path, sizeof path, "%s/prefixed", argv[2]);
  int out = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0700);
  if (out < 0) fail("prefixed");
  unsigned char header[16384] = {0};
  memcpy(header, "not an executable header\n", 25);
  put(out, header, sizeof header); put(out, bytes, n); close(out);
  bad |= run("native image at offset 16384", path, -1, 111);
  int fd = open(path, O_RDONLY);
  if (fd < 0 || lseek(fd, sizeof header, SEEK_SET) < 0) fail("seek prefix");
  char descriptor[64];
  snprintf(descriptor, sizeof descriptor, "/dev/fd/%d", fd);
  bad |= run("seeked descriptor of prefixed image", descriptor, fd, 111);
  close(fd);
  fd = open(argv[1], O_RDONLY);
  if (fd < 0 || lseek(fd, 64, SEEK_SET) < 0) fail("seek native");
  snprintf(descriptor, sizeof descriptor, "/dev/fd/%d", fd);
  /* Linux fexecve ignores the seek position. The macOS runner rejects
   * /dev/fd execution, even when the underlying file is native. */
#ifdef __linux__
  bad |= run("seeked descriptor of native image", descriptor, fd, 42);
#else
  bad |= run("seeked descriptor of native image", descriptor, fd, 111);
#endif
  close(fd);
  int pipefd[2];
  if (pipe(pipefd)) fail("pipe");
  snprintf(descriptor, sizeof descriptor, "/dev/fd/%d", pipefd[0]);
  /* No bytes are needed: the loader rejects a pipe as an executable file. */
  close(pipefd[1]);
  bad |= run("pipe descriptor", descriptor, pipefd[0], 111);
  close(pipefd[0]);
#ifdef __linux__
  fd = memfd_create("cosmic-probe", 0);
  if (fd < 0) fail("memfd_create");
  put(fd, bytes, n);
  if (fchmod(fd, 0700)) fail("chmod memfd");
  bad |= run("memfd with copied native bytes", "memfd", fd, 42);
  close(fd);
#endif
  /* Mach-O's kernel-recognized fat envelope really DOES support slices.
   * Use a single native slice here to isolate the offset-loading behavior. */
  memset(header, 0, sizeof header);
  be32(header, 0xcafebabe); be32(header + 4, 1);
#if defined(__aarch64__) || defined(__arm64__)
  be32(header + 8, 0x0100000c); be32(header + 12, 0);
#else
  be32(header + 8, 0x01000007); be32(header + 12, 3);
#endif
  be32(header + 16, sizeof header); be32(header + 20, (uint32_t)n);
  be32(header + 24, 14);
  snprintf(path, sizeof path, "%s/fat-native", argv[2]);
  out = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0700);
  if (out < 0) fail("fat file");
  put(out, header, sizeof header); put(out, bytes, n); close(out);
#ifdef __APPLE__
  bad |= run("Mach-O fat envelope, native slice at 16384", path, -1, 42);
#else
  bad |= run("Mach-O fat envelope, native slice at 16384", path, -1, 111);
#endif
  free(bytes);
  return bad;
}
