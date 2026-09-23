#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static _Noreturn void fail(const char *message) {
  fprintf(stderr, "payload: %s\n", message);
  exit(97);
}

static const char *need(const char *name) {
  const char *value = getenv(name);
  if (value == NULL || value[0] == '\0') fail(name);
  return value;
}

static int check_descriptor(const char *name) {
  char *end = NULL;
  long value = strtol(need(name), &end, 10);
  if (end == NULL || *end != '\0' || value < 3 || value > 9) fail(name);
  struct stat st;
  if (fstat((int)value, &st) != 0 || !S_ISREG(st.st_mode)) fail(name);
  return (int)value;
}

static void append_marker(void) {
  const char *path = getenv("PORTABLE_PAYLOAD_MARKER");
  if (path == NULL) return;
  FILE *file = fopen(path, "a");
  if (file == NULL) fail("cannot append marker");
  if (fputs("ran\n", file) == EOF || fclose(file) != 0)
    fail("cannot finish marker");
}

int main(int argc, char **argv) {
  int artifact_fd = check_descriptor("COSMIC_PORTABLE_ARTIFACT_FD");
  int core_fd = check_descriptor("COSMIC_PORTABLE_CORE_FD");
  if (artifact_fd == core_fd) fail("descriptor fields are equal");
  need("COSMIC_PORTABLE_TARGET_ID");
  need("COSMIC_PORTABLE_CONFIGURATION_ID");
  need("COSMIC_PORTABLE_CORE_OFFSET");
  need("COSMIC_PORTABLE_CORE_LENGTH");
  need("COSMIC_PORTABLE_CORE_SHA256");
  if (argc < 3 || strcmp(argv[1], "--artifact") != 0 || argv[2][0] != '/')
    fail("artifact arguments");

  char header[10];
  if (pread(artifact_fd, header, sizeof header, 0) != (ssize_t)sizeof header ||
      memcmp(header, "#!/bin/sh\n", sizeof header) != 0)
    fail("artifact descriptor bytes");
  if (strcmp(need("PORTABLE_ORDINARY_ENV"), "preserved") != 0)
    fail("ordinary environment");
  if (strcmp(need("PORTABLE_CALLER_LOCALE"), "preserved") != 0)
    fail("caller locale environment");
  const char *expected_umask = getenv("PORTABLE_EXPECT_UMASK");
  if (expected_umask != NULL) {
    char *umask_end = NULL;
    long expected_mode = strtol(expected_umask, &umask_end, 8);
    mode_t actual_mode = umask(0);
    umask(actual_mode);
    if (umask_end == NULL || *umask_end != '\0' || expected_mode < 0 ||
        (mode_t)expected_mode != actual_mode)
      fail("caller umask");
  }

  const char *expected_cwd = getenv("PORTABLE_EXPECT_CWD");
  if (expected_cwd != NULL) {
    struct stat expected;
    struct stat actual;
    if (stat(expected_cwd, &expected) != 0 || stat(".", &actual) != 0 ||
        expected.st_dev != actual.st_dev || expected.st_ino != actual.st_ino)
      fail("current directory");
  }
  if (getenv("PORTABLE_CHECK_IO") != NULL) {
    if (argc != 6 || strcmp(argv[3], "a b") != 0 || argv[4][0] != '\0' ||
        strcmp(argv[5], "--literal") != 0)
      fail("user arguments");
    char input[32];
    if (fgets(input, sizeof input, stdin) == NULL ||
        strcmp(input, "input stays intact\n") != 0)
      fail("standard input");
    printf("pid=%ld\n", (long)getpid());
    printf("args=%s|%s|%s\n", argv[3], argv[4], argv[5]);
    fprintf(stderr, "payload stderr\n");
  }

  append_marker();
  if (getenv("PORTABLE_PAYLOAD_SIGNAL") != NULL) {
    raise(SIGTERM);
    fail("signal returned");
  }
  const char *exit_text = getenv("PORTABLE_PAYLOAD_EXIT");
  if (exit_text != NULL) return atoi(exit_text);
  return 0;
}
