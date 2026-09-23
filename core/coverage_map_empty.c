/* The block-to-line table a core's first link carries, before
 * core/coverage_map.zig has read that link and written the real one: no
 * blocks. The first link is only ever read, never run. A real definition
 * rather than a weak reference, which Mach-O cannot leave undefined. */
#include <stdint.h>

const uint32_t cosmic_native_coverage_blocks = 0;
const char *const cosmic_native_coverage_paths[] = {""};
const uint16_t cosmic_native_coverage_path[] = {UINT16_MAX};
const uint32_t cosmic_native_coverage_line[] = {0};
const uint8_t cosmic_native_coverage_entry[] = {0};
