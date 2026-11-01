/*
** The settings of the zstd stream core/unzstd.c decodes that the program
** that writes the stream must also keep.
*/

#ifndef cosmic_unzstd_h
#define cosmic_unzstd_h

/* The largest window, as a power of two, a stream may declare: 8 MiB,
** which holds a core written at level 19. The decoder refuses a larger
** one before it allocates, so its memory is this window and the fixed
** state and buffers of core/unzstd.c. core/compress.c sets the
** encoder's window to it for a frame of declared size (Compress.zstd). */
#define COSMIC_UNZSTD_WINDOW_LOG 23

/* The largest decoded length the program takes: far over any release
** core. */
#define COSMIC_UNZSTD_MAX_LENGTH ((unsigned long long)1 << 28)

#endif
