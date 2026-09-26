/*
 * The heap the core's own C allocates from. In every core but the
 * checked one these are libc's own functions, by name: nothing is added
 * to a call, and a release core is the same machine code it would be
 * with malloc written out. The checked core (COSMIC_CHECKED, see
 * core/testing_checked.c) counts the bytes and blocks live on it, and
 * draws every growth from the same countdown as the failing Lua
 * allocator, so `testing.fail_allocations` refuses a C allocation where
 * it would refuse a Lua one: the call returns NULL, and the refusal is
 * counted.
 *
 * Only memory this C both allocates and frees goes through here. A
 * block a library frees, or one allocated by a library and freed here,
 * stays libc's: the two heaps are not interchangeable in the checked
 * core, whose blocks carry a header libc knows nothing of.
 *
 * One block this C allocates and frees is libc's all the same: the
 * syscall table's log (core/observed.c), the observer's rather than
 * the test's, which a test holding the core to `testing.c_heap` is not
 * held to; its growth fails only at its own fault point.
 */

#ifndef COSMIC_MEMORY_H
#define COSMIC_MEMORY_H

#include <stdlib.h>

#ifdef COSMIC_CHECKED

void *cosmic_malloc (size_t size);
void *cosmic_calloc (size_t count, size_t size);
void *cosmic_realloc (void *block, size_t size);
void cosmic_free (void *block);

#else

#define cosmic_malloc malloc
#define cosmic_calloc calloc
#define cosmic_realloc realloc
#define cosmic_free free

#endif

#endif
