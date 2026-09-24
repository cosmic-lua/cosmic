#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

int main (int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: launcher-socket-fd DESCRIPTOR LAUNCHER\n");
    return 2;
  }
  int descriptor = atoi(argv[1]);
  int pair[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
    perror("socketpair");
    return 3;
  }
  if (dup2(pair[0], descriptor) < 0) {
    perror("dup2");
    return 4;
  }
  if (pair[0] != descriptor) close(pair[0]);
  close(pair[1]);
  execl(argv[2], argv[2], (char *)NULL);
  perror("exec launcher");
  return errno == 0 ? 5 : errno;
}
