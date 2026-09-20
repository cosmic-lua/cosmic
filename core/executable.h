/* The physical executable identity and logical process path. */

#ifndef COSMIC_EXECUTABLE_H
#define COSMIC_EXECUTABLE_H

#include <stddef.h>

int cosmic_executable_path(char *into, size_t room);
int cosmic_executable_fd(void);

#endif
