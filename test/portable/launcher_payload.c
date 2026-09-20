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

static void fail(const char *message) {
  fprintf(stderr, "payload: %s\n", message);
  exit(97);
}

static const char *need(const char *name) {
  const char *value = getenv(name);
  if (value == NULL || value[0] == '\0') fail(name);
  return value;
}

static void check_descriptor(const char *name, int expected) {
  char *end = NULL;
  long value = strtol(need(name), &end, 10);
  if (end == NULL || *end != '\0' || value != expected) fail(name);
  struct stat st;
  if (fstat(expected, &st) != 0 || !S_ISREG(st.st_mode)) fail(name);
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
  check_descriptor("COSMIC_PORTABLE_ARTIFACT_FD", 8);
  check_descriptor("COSMIC_PORTABLE_CORE_FD", 9);
  need("COSMIC_PORTABLE_TARGET_ID");
  need("COSMIC_PORTABLE_CONFIGURATION_ID");
  need("COSMIC_PORTABLE_CORE_OFFSET");
  need("COSMIC_PORTABLE_CORE_LENGTH");
  need("COSMIC_PORTABLE_CORE_SHA256");
  if (argc < 3 || strcmp(argv[1], "--artifact") != 0 || argv[2][0] != '/')
    fail("artifact arguments");

  char header[10];
  if (pread(8, header, sizeof header, 0) != (ssize_t)sizeof header ||
      memcmp(header, "#!/bin/sh\n", sizeof header) != 0)
    fail("artifact descriptor bytes");
  if (strcmp(need("PORTABLE_ORDINARY_ENV"), "preserved") != 0)
    fail("ordinary environment");
  if (strcmp(need("PORTABLE_CALLER_LOCALE"), "preserved") != 0)
    fail("caller locale environment");

  const char *expected_cwd = getenv("PORTABLE_EXPECT_CWD");
  if (expected_cwd != NULL) {
    char cwd[4096];
    if (getcwd(cwd, sizeof cwd) == NULL || strcmp(cwd, expected_cwd) != 0)
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
