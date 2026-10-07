/* The sandbox's native endpoint connector. The Teal relay never receives
 * an unconnected host socket: this child connects it, constrained by an
 * immutable sockaddr table and a filter that cannot remap or rewrite it.
 * A connector started in public mode also connects to an address no table
 * holds, which the filter cannot judge (it compares only the sockaddr's
 * pointer and length): the child classifies the address against deny lists
 * its caller passed as data, copies an allowed one into a scratch slot the
 * filter does accept, and connects through that. The scratch page is
 * writable only because the filter has no call that could change it, and
 * the child is single-threaded and not dumpable, so nothing else writes it.
 * No Lua, allocation or loader operation occurs in the forked child.
 * Fork retains a copy of the launcher's memory and environment: this
 * helper confines network authority, not secrets already in that memory.
 * A boundary against those secrets requires a clean exec trampoline. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#if defined(__linux__)
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#endif
#include "check.h"
#include "fail.h"
#include "fault.h"
#include "lauxlib.h"
#include "process.h"

#define CONNECTOR_ENDPOINTS 128
#define CONNECTOR_SLOTS 262144
#define CONNECTOR_STRIDE 128
#define CONNECTOR_INSNS 4096
#define CONNECTOR_ALLOW 0x7fff0000u
#define CONNECTOR_KILL 0x80000000u
#define CONNECTOR_REFUSE (0x00050000u | EPERM)
#define CONNECTOR_DENY 128
#define CONNECTOR_OWN 256
#define CONNECTOR_SCRATCH 2
/* The index of a public request: a table's indexes are small, and 0 is
 * refused (EPERM) in eight bytes by every connector. */
#define CONNECTOR_PUBLIC 0xffffffffu
/* A public refusal's reply: past any errno, so a kernel's EACCES or EPERM
 * from connect is never taken for the deny list. */
#define CONNECTOR_DENIED 0x10000

struct connector_insn { uint16_t code; uint8_t jt, jf; uint32_t k; };
struct connector_range { uintptr_t base; uint32_t slots, length; };
struct connector_endpoint { struct sockaddr_storage address; uint32_t slots, length; };
struct connector_code { struct connector_insn insns[CONNECTOR_INSNS]; size_t used; };

/* An address prefix of `length` bytes (4 or 16) of which `bits` are held. */
struct connector_prefix { uint8_t bytes[16]; uint8_t length, bits; };
/* What a public connector refuses: the caller's data, and no policy of
 * this file's but the IPv6 allow root of connector_public_allowed. */
struct connector_public {
  struct connector_prefix deny[CONNECTOR_DENY], own[CONNECTOR_OWN];
  size_t denies, owns;
  bool enabled;
};
/* A public request: index CONNECTOR_PUBLIC, a port (0 asks only for the decision), the
 * family (4 or 6) and the address, an IPv4 one followed by zeros. */
struct connector_request { uint32_t index, port, family; uint8_t address[16]; };

/* Explicit Linux numbers let the same builder be checked for both
 * architectures on every host, independently of its own libc headers. */
struct connector_numbers {
  uint32_t audit, read, write, close, poll, ppoll, clock, exit, exit_group;
  uint32_t socket, connect, getsockopt, sendmsg;
};
static const struct connector_numbers connector_x86 = {
  0xc000003eu, 0, 1, 3, 7, 271, 228, 60, 231, 41, 42, 55, 46,
};
static const struct connector_numbers connector_arm = {
  0xc00000b7u, 63, 64, 57, UINT32_MAX, 73, 113, 93, 94, 198, 203, 209, 211,
};

static void connector_emit (struct connector_code *code, uint16_t op,
                            uint8_t jt, uint8_t jf, uint32_t k) {
  if (code->used < CONNECTOR_INSNS)
    code->insns[code->used] = (struct connector_insn){op, jt, jf, k};
  code->used++;
}

static void connector_load (struct connector_code *code, unsigned argument, bool high) {
  connector_emit(code, 0x20, 0, 0, 16 + 8 * argument + (high ? 4u : 0u));
}

static void connector_equal (struct connector_code *code, unsigned argument, uint32_t value) {
  connector_load(code, argument, true);
  connector_emit(code, 0x15, 1, 0, 0);
  connector_emit(code, 0x06, 0, 0, CONNECTOR_REFUSE);
  connector_load(code, argument, false);
  connector_emit(code, 0x15, 1, 0, value);
  connector_emit(code, 0x06, 0, 0, CONNECTOR_REFUSE);
}

static void connector_return (struct connector_code *code, uint32_t value) {
  connector_emit(code, 0x06, 0, 0, value);
}

/* A three-instruction dispatch has a 32-bit forward jump rather than
 * classic BPF's eight-bit conditional offset; 128 ranges still fit. */
static size_t connector_dispatch (struct connector_code *code, uint32_t number) {
  connector_emit(code, 0x15, 0, 1, number);
  size_t jump = code->used;
  connector_emit(code, 0x05, 0, 0, 0);
  return jump;
}

static void connector_target (struct connector_code *code, size_t jump) {
  if (jump < CONNECTOR_INSNS) code->insns[jump].k = (uint32_t)(code->used - jump - 1);
}

static void connector_fd (struct connector_code *code, int fd) {
  connector_equal(code, 0, (uint32_t)fd);
  connector_return(code, CONNECTOR_ALLOW);
}

/* sockaddr memory is private and read-only before this program is
 * installed. The allow list has no VM mutation, filesystem, exec, fork,
 * descriptor replacement or descriptor receive calls. In particular,
 * the private sendmsg fd may never be closed and reused for MSG_FASTOPEN
 * on a host socket. Closing it kills the process instead. */
static size_t connector_program (struct connector_code *code,
    const struct connector_numbers *numbers, const struct connector_range *ranges,
    size_t count, int control, int status) {
  code->used = 0;
  connector_emit(code, 0x20, 0, 0, 4);
  connector_emit(code, 0x15, 1, 0, numbers->audit);
  connector_return(code, CONNECTOR_KILL);
  connector_emit(code, 0x20, 0, 0, 0);
  const uint32_t simple[] = {numbers->poll, numbers->ppoll, numbers->clock,
    numbers->exit, numbers->exit_group};
  for (size_t i = 0; i < sizeof simple / sizeof simple[0]; i++) {
    if (simple[i] == UINT32_MAX) continue;
    connector_emit(code, 0x15, 0, 1, simple[i]);
    connector_return(code, CONNECTOR_ALLOW);
  }
  size_t reading = connector_dispatch(code, numbers->read);
  size_t writing = connector_dispatch(code, numbers->write);
  size_t closing = connector_dispatch(code, numbers->close);
  size_t creating = connector_dispatch(code, numbers->socket);
  size_t connecting = connector_dispatch(code, numbers->connect);
  size_t checking = connector_dispatch(code, numbers->getsockopt);
  size_t sending = connector_dispatch(code, numbers->sendmsg);
  connector_return(code, CONNECTOR_REFUSE);
  connector_target(code, reading);
  connector_fd(code, control);
  connector_target(code, writing);
  connector_load(code, 0, true);
  connector_emit(code, 0x15, 1, 0, 0);
  connector_return(code, CONNECTOR_REFUSE);
  connector_load(code, 0, false);
  connector_emit(code, 0x15, 2, 0, (uint32_t)control);
  connector_emit(code, 0x15, 1, 0, (uint32_t)status);
  connector_return(code, CONNECTOR_REFUSE);
  connector_return(code, CONNECTOR_ALLOW);
  connector_target(code, closing);
  connector_load(code, 0, false);
  connector_emit(code, 0x15, 0, 1, (uint32_t)control);
  connector_return(code, CONNECTOR_KILL);
  connector_return(code, CONNECTOR_ALLOW);
  connector_target(code, creating);
  connector_load(code, 0, true);
  connector_emit(code, 0x15, 1, 0, 0);
  connector_return(code, CONNECTOR_REFUSE);
  connector_load(code, 0, false);
  connector_emit(code, 0x15, 2, 0, 2); /* Linux AF_INET */
  connector_emit(code, 0x15, 1, 0, 10); /* Linux AF_INET6 */
  connector_return(code, CONNECTOR_REFUSE);
  connector_equal(code, 1, 1u | 0x800u | 0x80000u); /* STREAM, NONBLOCK, CLOEXEC */
  connector_equal(code, 2, 6); /* IPPROTO_TCP */
  connector_return(code, CONNECTOR_ALLOW);
  connector_target(code, checking);
  connector_equal(code, 1, 1); /* SOL_SOCKET */
  connector_equal(code, 2, 4); /* SO_ERROR */
  connector_return(code, CONNECTOR_ALLOW);
  connector_target(code, sending);
  connector_equal(code, 2, 0x4000); /* MSG_NOSIGNAL */
  connector_fd(code, control);
  connector_target(code, connecting);
  for (size_t i = 0; i < count; i++) {
    uintptr_t base = ranges[i].base;
    uintptr_t end = base + (uintptr_t)ranges[i].slots * CONNECTOR_STRIDE;
    connector_load(code, 1, true);
    connector_emit(code, 0x15, 0, 10, (uint32_t)(base >> 32));
    connector_load(code, 1, false);
    connector_emit(code, 0x35, 0, 8, (uint32_t)base);
    connector_emit(code, 0x35, 7, 0, (uint32_t)end);
    connector_emit(code, 0x54, 0, 0, CONNECTOR_STRIDE - 1);
    connector_emit(code, 0x15, 0, 5, 0);
    connector_load(code, 2, true);
    connector_emit(code, 0x15, 0, 3, 0);
    connector_load(code, 2, false);
    connector_emit(code, 0x15, 0, 1, ranges[i].length);
    connector_return(code, CONNECTOR_ALLOW);
    /* Every failed condition jumps to the next range. */
  }
  connector_return(code, CONNECTOR_REFUSE);
  return code->used <= CONNECTOR_INSNS ? code->used : 0;
}

static size_t connector_endpoints (lua_State *L, int argument,
                                  struct connector_endpoint *endpoints, bool list, bool empty) {
  luaL_checktype(L, argument, LUA_TTABLE);
  size_t count = list ? lua_rawlen(L, argument) : 1;
  if ((count == 0 && !empty) || count > CONNECTOR_ENDPOINTS)
    luaL_argerror(L, argument, "endpoints must hold 1 through 128 numeric TCP endpoints");
  uint32_t slots = 0;
  for (size_t i = 0; i < count; i++) {
    if (list) lua_rawgeti(L, argument, (lua_Integer)i + 1);
    else lua_pushvalue(L, argument);
    int item = lua_gettop(L);
    luaL_checktype(L, item, LUA_TTABLE);
    lua_getfield(L, item, "host");
    size_t size = 0;
    const char *host = luaL_checklstring(L, -1, &size);
    struct connector_endpoint *endpoint = &endpoints[i];
    memset(endpoint, 0, sizeof *endpoint);
    struct sockaddr_in *v4 = (struct sockaddr_in *)&endpoint->address;
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&endpoint->address;
    if (strlen(host) != size) luaL_argerror(L, argument, "an endpoint host has a NUL");
    if (!cosmic_numeric_host(host, size)) {
      luaL_argerror(L, argument, "an endpoint host must be a numeric IPv4 or IPv6 address");
    } else if (strchr(host, ':') == NULL && inet_pton(AF_INET, host, &v4->sin_addr) == 1) {
      v4->sin_family = AF_INET;
      endpoint->length = sizeof *v4;
    } else if (inet_pton(AF_INET6, host, &v6->sin6_addr) == 1) {
      v6->sin6_family = AF_INET6;
      endpoint->length = sizeof *v6;
    } else luaL_argerror(L, argument, "an endpoint host must be a numeric IPv4 or IPv6 address");
    lua_pop(L, 1);
    lua_getfield(L, item, "port");
    int port = cosmic_checkint(L, -1);
    if (port < 0 || port > 65535) luaL_argerror(L, argument, "an endpoint port must be 0 through 65535");
    if (v4->sin_family == AF_INET) v4->sin_port = htons((uint16_t)port);
    else v6->sin6_port = htons((uint16_t)port);
    endpoint->slots = port == 0 ? 65535 : 1;
    slots += endpoint->slots;
    if (slots > CONNECTOR_SLOTS) luaL_argerror(L, argument, "endpoint port tables exceed 32 MiB");
    lua_pop(L, 2);
  }
  return count;
}

/* The numeric address in `text` (NUL-terminated, `size` long) as a prefix of
 * all its bits, an IPv4-mapped IPv6 address reduced to the IPv4 address it
 * carries when `reduce`; false for anything else. */
static bool connector_address (const char *text, size_t size, bool reduce, struct connector_prefix *out) {
  memset(out, 0, sizeof *out);
  if (!cosmic_numeric_host(text, size)) return false;
  if (strchr(text, ':') == NULL) {
    if (inet_pton(AF_INET, text, out->bytes) != 1) return false;
    out->length = 4;
  } else {
    if (inet_pton(AF_INET6, text, out->bytes) != 1) return false;
    out->length = 16;
    static const uint8_t mapped[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff};
    if (reduce && memcmp(out->bytes, mapped, sizeof mapped) == 0) {
      memmove(out->bytes, out->bytes + 12, 4);
      memset(out->bytes + 4, 0, 12);
      out->length = 4;
    }
  }
  out->bits = (uint8_t)(out->length * 8);
  return true;
}

/* `text` as "address/bits" when `cidr`, else as an address alone. */
static bool connector_prefix (char *text, size_t size, bool cidr, struct connector_prefix *out) {
  unsigned bits = 0;
  if (cidr) {
    char *slash = strchr(text, '/');
    if (slash == NULL || slash[1] == '\0' || strlen(slash + 1) > 3) return false;
    if (slash[1] == '0' && slash[2] != '\0') return false;
    for (const char *digit = slash + 1; *digit != '\0'; digit++) {
      if (*digit < '0' || *digit > '9') return false;
      bits = bits * 10 + (unsigned)(*digit - '0');
    }
    size = (size_t)(slash - text);
    *slash = '\0';
  }
  if (!connector_address(text, size, !cidr, out)) return false;
  if (!cidr) return true;
  if (bits > (unsigned)out->length * 8) return false;
  out->bits = (uint8_t)bits;
  return true;
}

static size_t connector_prefixes (lua_State *L, int argument, int list, bool cidr,
                                  struct connector_prefix *out, size_t limit) {
  if (!lua_istable(L, list))
    luaL_argerror(L, argument, cidr ? "public needs a deny list" : "public's own must be a list");
  size_t count = lua_rawlen(L, list);
  if (count > limit) luaL_argerror(L, argument, "a public list holds too many entries");
  for (size_t i = 0; i < count; i++) {
    lua_rawgeti(L, list, (lua_Integer)i + 1);
    size_t size = 0;
    const char *text = luaL_checklstring(L, -1, &size);
    char copy[64];
    if (size >= sizeof copy || strlen(text) != size) luaL_argerror(L, argument, "a public entry is not an address");
    memcpy(copy, text, size + 1);
    lua_pop(L, 1);
    if (!connector_prefix(copy, size, cidr, &out[i]))
      luaL_argerror(L, argument, cidr ? "a deny entry must be a numeric address and prefix length, as 10.0.0.0/8"
                                      : "an own entry must be a numeric address");
  }
  return count;
}

/* Reads `{ deny = {cidr...}, own = {address...} }` from `argument`. */
static void connector_public_read (lua_State *L, int argument, struct connector_public *pub) {
  luaL_checktype(L, argument, LUA_TTABLE);
  memset(pub, 0, sizeof *pub);
  lua_getfield(L, argument, "deny");
  pub->denies = connector_prefixes(L, argument, lua_gettop(L), true, pub->deny, CONNECTOR_DENY);
  lua_getfield(L, argument, "own");
  if (!lua_isnil(L, -1))
    pub->owns = connector_prefixes(L, argument, lua_gettop(L), false, pub->own, CONNECTOR_OWN);
  lua_pop(L, 2);
  pub->enabled = true;
}

COSMIC_SYSCALL(connector_pair, 0) {
  lua_createtable(L, 2, 0);
  int pair[2];
#if defined(__linux__)
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) != 0) return cosmic_fail(L, errno);
#else
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) return cosmic_fail(L, errno);
  if (fcntl(pair[0], F_SETFD, FD_CLOEXEC) != 0 || fcntl(pair[1], F_SETFD, FD_CLOEXEC) != 0) {
    int failure = errno;
    close(pair[0]); close(pair[1]);
    return cosmic_fail(L, failure);
  }
#endif
  lua_pushinteger(L, pair[0]); lua_rawseti(L, -2, 1);
  lua_pushinteger(L, pair[1]); lua_rawseti(L, -2, 2);
  return 1;
}

COSMIC_SYSCALL(connector_filter, 4) {
  const char *architecture = luaL_checkstring(L, 1);
  const struct connector_numbers *numbers;
  if (strcmp(architecture, "x86_64") == 0) numbers = &connector_x86;
  else if (strcmp(architecture, "aarch64") == 0) numbers = &connector_arm;
  else return luaL_argerror(L, 1, "architecture must be x86_64 or aarch64");
  luaL_checktype(L, 2, LUA_TTABLE);
  size_t count = lua_rawlen(L, 2);
  if (count == 0 || count > CONNECTOR_ENDPOINTS) return luaL_argerror(L, 2, "ranges must hold 1 through 128 entries");
  struct connector_range ranges[CONNECTOR_ENDPOINTS];
  uint32_t slots = 0;
  for (size_t i = 0; i < count; i++) {
    lua_rawgeti(L, 2, (lua_Integer)i + 1);
    luaL_checktype(L, -1, LUA_TTABLE);
    lua_getfield(L, -1, "base");
    lua_Integer base = luaL_checkinteger(L, -1);
    lua_getfield(L, -2, "slots");
    int each = cosmic_checkint(L, -1);
    lua_getfield(L, -3, "length");
    int length = cosmic_checkint(L, -1);
    if (base <= 0 || (base & (CONNECTOR_STRIDE - 1)) != 0 || each < 1 || each > 65535 ||
        (length != 16 && length != 28)) return luaL_argerror(L, 2, "a range is invalid");
    uint64_t end = (uint64_t)base + (uint64_t)each * CONNECTOR_STRIDE;
    if (((uint64_t)base >> 32) != (end >> 32)) return luaL_argerror(L, 2, "a range crosses a 32-bit boundary");
    ranges[i] = (struct connector_range){(uintptr_t)base, (uint32_t)each, (uint32_t)length};
    slots += (uint32_t)each;
    if (slots > CONNECTOR_SLOTS) return luaL_argerror(L, 2, "ranges exceed 32 MiB");
    lua_pop(L, 4);
  }
  int control = cosmic_checkfd(L, 3), status = cosmic_checkfd(L, 4);
  struct connector_code code;
  size_t length = connector_program(&code, numbers, ranges, count, control, status);
  if (length == 0) return luaL_error(L, "connector filter exceeds the kernel limit");
  lua_pushlstring(L, (const char *)code.insns, length * sizeof code.insns[0]);
  return 1;
}

#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
_Static_assert(sizeof(struct connector_insn) == sizeof(struct sock_filter), "BPF layout");
_Static_assert(sizeof(struct sockaddr_storage) == CONNECTOR_STRIDE, "address slot size");

struct connector_plan {
  struct connector_range ranges[CONNECTOR_ENDPOINTS + CONNECTOR_SCRATCH];
  struct connector_code code;
  struct connector_public pub;
  /* `count` table ranges, then the scratch slots of a public connector;
   * `filtered` is how many of `ranges` the filter accepts. */
  size_t count, filtered, bytes, scratch_bytes;
  void *memory, *scratch;
  int control, status, timeout;
  bool close_refused, filter_refused;
};

/* Maps the table's `bytes` where no 4 GiB boundary falls inside it: the
 * filter compares the low 32 bits of an address with a range's, so a range
 * that crossed one could not be expressed. Of twice `bytes` mapped, one
 * boundary at most falls inside (the table is at most 32 MiB), and the
 * table is placed on the side of it where it fits; the rest is unmapped.
 * NULL, with errno, where it cannot be mapped.
 * The fault point moves that span to start a page below a boundary, so a
 * test meets the placement a mapping of the kernel's meets only now and
 * then. */
static void *connector_map (size_t bytes, size_t page) {
  size_t span = 2 * bytes;
  void *mapped = mmap(NULL, span, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (mapped == MAP_FAILED) return NULL;
  uintptr_t start = (uintptr_t)mapped;
  if (COSMIC_FAULT("connector_straddle")) {
    uintptr_t below = start & ~(uintptr_t)UINT32_MAX;
    munmap(mapped, span);
    if (below <= page) { errno = EINVAL; return NULL; }
    mapped = mmap((void *)(below - page), span, PROT_READ | PROT_WRITE,
        MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (mapped == MAP_FAILED) return NULL;
    start = (uintptr_t)mapped;
  }
  uintptr_t boundary = (start | (uintptr_t)UINT32_MAX) + 1;
  /* Only a span in the last 4 GiB of the address space, which no user
   * mapping reaches, has no boundary above it. */
  if (boundary == 0) { munmap(mapped, span); errno = EOVERFLOW; return NULL; }
  uintptr_t base = start + bytes < boundary ? start : boundary;
  if (base > start) munmap((void *)start, base - start);
  if (start + span > base + bytes) munmap((void *)(base + bytes), start + span - (base + bytes));
  return (char *)mapped + (base - start);
}

static int connector_table (const struct connector_endpoint *endpoints, size_t count,
                            struct connector_plan *plan) {
  size_t slots = 0;
  for (size_t i = 0; i < count; i++) slots += endpoints[i].slots;
  plan->count = plan->filtered = 0;
  if (slots == 0) return 0;
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) return EINVAL;
  size_t used = slots * CONNECTOR_STRIDE;
  plan->bytes = (used + (size_t)page - 1) / (size_t)page * (size_t)page;
  if (COSMIC_FAULT("connector_mmap")) return ENOMEM;
  plan->memory = connector_map(plan->bytes, (size_t)page);
  if (plan->memory == NULL) return errno;
  size_t offset = 0;
  for (size_t i = 0; i < count; i++) {
    uintptr_t base = (uintptr_t)plan->memory + offset;
    uintptr_t end = base + (uintptr_t)endpoints[i].slots * CONNECTOR_STRIDE;
    if ((base >> 32) != (end >> 32)) return EOVERFLOW;
    plan->ranges[i] = (struct connector_range){base, endpoints[i].slots, endpoints[i].length};
    for (uint32_t j = 0; j < endpoints[i].slots; j++) {
      struct sockaddr_storage *address = (struct sockaddr_storage *)(base + (uintptr_t)j * CONNECTOR_STRIDE);
      *address = endpoints[i].address;
      if (endpoints[i].slots > 1) {
        uint16_t port = htons((uint16_t)(j + 1));
        if (address->ss_family == AF_INET) ((struct sockaddr_in *)address)->sin_port = port;
        else ((struct sockaddr_in6 *)address)->sin6_port = port;
      }
    }
    offset += (size_t)endpoints[i].slots * CONNECTOR_STRIDE;
  }
  if (COSMIC_FAULT("connector_mprotect")) return EACCES;
  if (mprotect(plan->memory, plan->bytes, PROT_READ) != 0) return errno;
  plan->count = plan->filtered = count;
  return 0;
}

/* The one writable page of a public connector: an IPv4 slot, then an IPv6
 * slot. Only these slots, at these lengths, are connectable besides the
 * table, and no allowed call remaps or reprotects the page. */
static int connector_scratch (struct connector_plan *plan) {
  long page = sysconf(_SC_PAGESIZE);
  if (page < 2 * CONNECTOR_STRIDE) return EINVAL;
  if (COSMIC_FAULT("connector_scratch")) return ENOMEM;
  plan->scratch = mmap(NULL, (size_t)page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (plan->scratch == MAP_FAILED) { plan->scratch = NULL; return errno; }
  plan->scratch_bytes = (size_t)page;
  uintptr_t base = (uintptr_t)plan->scratch;
  plan->ranges[plan->count] = (struct connector_range){base, 1, sizeof(struct sockaddr_in)};
  plan->ranges[plan->count + 1] = (struct connector_range){base + CONNECTOR_STRIDE, 1, sizeof(struct sockaddr_in6)};
  plan->filtered = plan->count + CONNECTOR_SCRATCH;
  return 0;
}

static void connector_release (struct connector_plan *plan) {
  if (plan->memory != NULL) munmap(plan->memory, plan->bytes);
  if (plan->scratch != NULL) munmap(plan->scratch, plan->scratch_bytes);
  plan->memory = plan->scratch = NULL;
}

/* Whether `prefix` holds `address` of `length` bytes. */
static bool connector_within (const struct connector_prefix *prefix, const uint8_t *address, size_t length) {
  if (prefix->length != length) return false;
  size_t whole = prefix->bits / 8u, rest = prefix->bits % 8u;
  if (memcmp(prefix->bytes, address, whole) != 0) return false;
  if (rest == 0) return true;
  uint8_t mask = (uint8_t)(0xffu << (8u - rest));
  return ((prefix->bytes[whole] ^ address[whole]) & mask) == 0;
}

/* Whether a public connector may connect to `address`, 4 or 16 bytes. An
 * IPv6 address must be in 2000::/3 (global unicast), which leaves out the
 * IPv4-mapped and NAT64 forms undecoded, and then in no deny prefix and no
 * own address. A fixed number of table entries is walked: no allocation. */
static bool connector_public_allowed (const struct connector_public *pub, const uint8_t *address,
                                      size_t length) {
  if (length == 16 && (address[0] & 0xe0u) != 0x20u) return false;
  for (size_t i = 0; i < pub->denies; i++)
    if (connector_within(&pub->deny[i], address, length)) return false;
  for (size_t i = 0; i < pub->owns; i++)
    if (connector_within(&pub->own[i], address, length)) return false;
  return true;
}

static int connector_whole (int fd, void *buffer, size_t size, bool writing) {
  char *at = buffer;
  while (size > 0) {
    ssize_t got = writing ? write(fd, at, size) : read(fd, at, size);
    if (got < 0 && errno == EINTR) continue;
    if (got <= 0) return got == 0 ? EPIPE : errno;
    at += (size_t)got; size -= (size_t)got;
  }
  return 0;
}

static int64_t connector_now (void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return -1;
  return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

/* Connects a new nonblocking socket to `address`, a table or scratch slot
 * the filter accepts at `size`, within the plan's timeout. */
static int connector_establish (const struct connector_plan *plan, const struct sockaddr *address,
                                socklen_t size, int *connected) {
  int fd = socket(address->sa_family, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, IPPROTO_TCP);
  if (fd < 0) return errno;
  int failure = 0;
  if (connect(fd, address, size) != 0) {
    failure = errno;
    if (failure == EINPROGRESS) {
      int64_t now = connector_now();
      int64_t deadline = now + plan->timeout;
      while (now >= 0 && now < deadline) {
        struct pollfd wait[2] = {{fd, POLLOUT, 0}, {plan->control, POLLHUP, 0}};
        struct timespec remaining = {(time_t)((deadline - now) / 1000),
          (long)((deadline - now) % 1000) * 1000000L};
        int ready = ppoll(wait, 2, &remaining, NULL);
        if (ready < 0 && errno != EINTR) { failure = errno; break; }
        if (wait[1].revents & (POLLHUP | POLLERR | POLLNVAL)) { failure = EPIPE; break; }
        if (wait[0].revents != 0) {
          socklen_t length = sizeof failure;
          if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length) != 0) failure = errno;
          break;
        }
        now = connector_now();
      }
      if (failure == EINPROGRESS) failure = now < 0 ? EIO : ETIMEDOUT;
    }
  }
  if (failure) close(fd);
  else *connected = fd;
  return failure;
}

static int connector_connect (const struct connector_plan *plan, uint32_t index, uint32_t port,
                              int *connected) {
  *connected = -1;
  if (index < 1 || index > plan->count || port < 1 || port > 65535) return EPERM;
  const struct connector_range *range = &plan->ranges[index - 1];
  const struct sockaddr *address = (const struct sockaddr *)(range->base +
      (range->slots > 1 ? (uintptr_t)(port - 1) * CONNECTOR_STRIDE : 0));
  uint16_t held = address->sa_family == AF_INET ?
    ((const struct sockaddr_in *)address)->sin_port : ((const struct sockaddr_in6 *)address)->sin6_port;
  if (ntohs(held) != port) return EPERM;
  return connector_establish(plan, address, range->length, connected);
}

/* A public request, answered EPERM where the connector is not public,
 * EINVAL where it is malformed and CONNECTOR_DENIED where the address is refused.
 * Port 0 asks only for the decision: 0 for an allowed address, with no
 * socket made and no descriptor passed. */
static int connector_public_connect (const struct connector_plan *plan,
                                     const struct connector_request *request, int *connected) {
  *connected = -1;
  if (!plan->pub.enabled) return EPERM;
  size_t length = request->family == 4 ? 4 : request->family == 6 ? 16 : 0;
  if (length == 0 || request->port > 65535) return EINVAL;
  for (size_t i = length; i < sizeof request->address; i++)
    if (request->address[i] != 0) return EINVAL;
  if (!connector_public_allowed(&plan->pub, request->address, length)) return CONNECTOR_DENIED;
  if (request->port == 0) return 0;
  unsigned char *slot = (unsigned char *)plan->scratch;
  if (length == 16) slot += CONNECTOR_STRIDE;
  memset(slot, 0, CONNECTOR_STRIDE);
  socklen_t size;
  if (length == 4) {
    struct sockaddr_in *v4 = (struct sockaddr_in *)slot;
    v4->sin_family = AF_INET;
    v4->sin_port = htons((uint16_t)request->port);
    memcpy(&v4->sin_addr, request->address, 4);
    size = sizeof *v4;
  } else {
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)slot;
    v6->sin6_family = AF_INET6;
    v6->sin6_port = htons((uint16_t)request->port);
    memcpy(&v6->sin6_addr, request->address, 16);
    size = sizeof *v6;
  }
  return connector_establish(plan, (const struct sockaddr *)slot, size, connected);
}

static int connector_reply (int control, int failure, int fd) {
  uint32_t number = htonl((uint32_t)failure);
  int trouble = connector_whole(control, &number, sizeof number, true);
  if (trouble || failure || fd < 0) return trouble;
  char marker = '\0';
  struct iovec payload = {&marker, 1};
  union { struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))]; } ancillary;
  memset(&ancillary, 0, sizeof ancillary);
  struct msghdr message = {0};
  message.msg_iov = &payload; message.msg_iovlen = 1;
  message.msg_control = ancillary.bytes; message.msg_controllen = sizeof ancillary.bytes;
  struct cmsghdr *rights = CMSG_FIRSTHDR(&message);
  rights->cmsg_level = SOL_SOCKET; rights->cmsg_type = SCM_RIGHTS;
  rights->cmsg_len = CMSG_LEN(sizeof fd);
  memcpy(CMSG_DATA(rights), &fd, sizeof fd);
  ssize_t sent;
  do { sent = sendmsg(control, &message, MSG_NOSIGNAL); } while (sent < 0 && errno == EINTR);
  return sent == 1 ? 0 : sent < 0 ? errno : EIO;
}

/* A public request carries its family and address after the eight
 * bytes every request begins with. */
static int connector_receive (int control, struct connector_request *request) {
  uint32_t head[2];
  int trouble = connector_whole(control, head, sizeof head, false);
  if (trouble) return trouble;
  *request = (struct connector_request){ntohl(head[0]), ntohl(head[1]), 0, {0}};
  if (request->index != CONNECTOR_PUBLIC) return 0;
  uint32_t family;
  trouble = connector_whole(control, &family, sizeof family, false);
  if (trouble) return trouble;
  request->family = ntohl(family);
  return connector_whole(control, request->address, sizeof request->address, false);
}

static _Noreturn void connector_loop (const struct connector_plan *plan) {
  for (;;) {
    struct connector_request request;
    if (connector_receive(plan->control, &request) != 0) _exit(0);
    int fd = -1;
    int failure = request.index == CONNECTOR_PUBLIC ? connector_public_connect(plan, &request, &fd) :
      connector_connect(plan, request.index, request.port, &fd);
    int sent = connector_reply(plan->control, failure, fd);
    if (fd >= 0) close(fd);
    if (sent || failure == EPIPE) _exit(0);
  }
}

/* This child has no runtime startup: it does not exec, call Lua, open a
 * database, allocate, or ask a loader to resolve another symbol. */
static int connector_hold (const struct connector_plan *plan) {
  if (plan->close_refused) return EPERM;
  unsigned first = (unsigned)(plan->control < plan->status ? plan->control : plan->status);
  unsigned second = (unsigned)(plan->control > plan->status ? plan->control : plan->status);
  /* A descriptor opened before the hard limit was lowered can be above
   * that limit. A loop bounded by RLIMIT_NOFILE would leave it behind:
   * close_range must succeed, or this start is refused. */
  if (first > 0 && syscall(SYS_close_range, 0u, first - 1, 0u) != 0) return errno;
  if (second > first + 1 && syscall(SYS_close_range, first + 1, second - 1, 0u) != 0) return errno;
  if (syscall(SYS_close_range, second + 1, UINT_MAX, 0u) != 0) return errno;
  struct sigaction action;
  memset(&action, 0, sizeof action);
  sigemptyset(&action.sa_mask);
  action.sa_handler = SIG_DFL;
  for (int signal = 1; signal < NSIG; signal++) {
    if (signal != SIGKILL && signal != SIGSTOP && sigaction(signal, &action, NULL) != 0) {
      if (errno != EINVAL) return errno;
    }
  }
  action.sa_handler = SIG_IGN;
  if (sigaction(SIGPIPE, &action, NULL) != 0) return errno;
  sigset_t empty;
  sigemptyset(&empty);
  if (sigprocmask(SIG_SETMASK, &empty, NULL) != 0) return errno;
  /* Not dumpable: a same-user process can neither ptrace this one nor
   * write its memory (process_vm_writev, /proc/<pid>/mem), which would
   * rewrite the scratch slot after its address was classified. */
  if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0 || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return errno;
  struct rlimit files = {256, 256};
  struct rlimit core = {0, 0};
  struct rlimit held;
  if (getrlimit(RLIMIT_NOFILE, &held) != 0) return errno;
  if (held.rlim_max < files.rlim_max) files.rlim_cur = files.rlim_max = held.rlim_max;
  if (setrlimit(RLIMIT_NOFILE, &files) != 0 || setrlimit(RLIMIT_CORE, &core) != 0) return errno;
  if (plan->filter_refused) return EPERM;
  struct sock_fprog filter = {(unsigned short)plan->code.used, (struct sock_filter *)plan->code.insns};
  if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &filter) != 0) return errno;
  return 0;
}

static int connector_control (int fd) {
  if (fd < 0) return EBADF;
  struct sockaddr_storage peer = {0};
  socklen_t size = sizeof peer;
  if (getpeername(fd, (struct sockaddr *)&peer, &size) != 0) return errno;
  if (peer.ss_family != AF_UNIX) return EINVAL;
  int kind = 0;
  size = sizeof kind;
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &size) != 0) return errno;
  if (kind != SOCK_STREAM) return EINVAL;
  int flags = fcntl(fd, F_GETFL);
  if (flags < 0) return errno;
  return flags & O_NONBLOCK ? EINVAL : 0;
}

static int connector_prepare (struct connector_plan *plan,
    const struct connector_endpoint *endpoints, size_t count, const struct connector_public *pub,
    int control, int timeout) {
  memset(plan, 0, sizeof *plan);
  int trouble = connector_control(control);
  if (trouble) return trouble;
  plan->control = control;
  plan->timeout = timeout;
  plan->pub = *pub;
  trouble = connector_table(endpoints, count, plan);
  if (!trouble && pub->enabled) trouble = connector_scratch(plan);
  return trouble;
}

static int connector_start_native (struct connector_plan *plan, const char *probe, pid_t *child);

/* The scratch page's own probes, with a valid loopback address written to
 * its IPv4 slot, so that only the filter can refuse what each attempts. */
static int connector_attack_scratch (const struct connector_plan *plan, const char *operation) {
  struct sockaddr_in *slot = (struct sockaddr_in *)plan->scratch;
  memset(slot, 0, sizeof *slot);
  slot->sin_family = AF_INET;
  slot->sin_port = htons(9);
  slot->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, IPPROTO_TCP);
  if (fd < 0) return errno;
  unsigned char *base = (unsigned char *)slot;
  int result = 0;
  if (strcmp(operation, "mprotect") == 0) {
    if (mprotect(plan->scratch, plan->scratch_bytes, PROT_READ) != 0) result = errno;
  } else if (strcmp(operation, "remap") == 0) {
    if (mmap(plan->scratch, plan->scratch_bytes, PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == MAP_FAILED) result = errno;
  } else if (strcmp(operation, "pointer") == 0) {
    struct sockaddr_in copy = *slot;
    if (connect(fd, (struct sockaddr *)&copy, sizeof copy) != 0) result = errno;
  } else if (strcmp(operation, "length") == 0) {
    if (connect(fd, (struct sockaddr *)slot, sizeof(struct sockaddr_in6)) != 0) result = errno;
  } else if (strcmp(operation, "offset") == 0) {
    if (connect(fd, (struct sockaddr *)(base + 1), sizeof *slot) != 0) result = errno;
  } else if (strcmp(operation, "past") == 0) {
    /* The slot after the IPv6 one, still inside the page. */
    if (connect(fd, (struct sockaddr *)(base + 2 * CONNECTOR_STRIDE), sizeof *slot) != 0) result = errno;
  } else if (strcmp(operation, "swapped") == 0) {
    /* The IPv6 slot, asked for at the IPv4 length. */
    if (connect(fd, (struct sockaddr *)(base + CONNECTOR_STRIDE), sizeof *slot) != 0) result = errno;
  } else if (strcmp(operation, "unscratched") == 0) {
    /* The IPv4 slot of a page a table-only filter does not list. */
    if (connect(fd, (struct sockaddr *)slot, sizeof *slot) != 0) result = errno;
  }
  close(fd);
  return result;
}

static int connector_attack (const struct connector_plan *plan, const char *operation) {
  const struct connector_range *range = &plan->ranges[0];
  const struct sockaddr *address = (const struct sockaddr *)range->base;
  int fd = socket(address->sa_family, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, IPPROTO_TCP);
  if (fd < 0) return errno;
  if (strcmp(operation, "pointer") == 0) {
    struct sockaddr_storage copy;
    memcpy(&copy, address, sizeof copy);
    if (connect(fd, (struct sockaddr *)&copy, range->length) != 0) return errno;
  } else if (strcmp(operation, "length") == 0) {
    if (connect(fd, address, range->length + 1) != 0) return errno;
  } else if (strcmp(operation, "mutation") == 0) {
    volatile unsigned char *bytes = (volatile unsigned char *)range->base;
    bytes[0] = 0;
  } else if (strcmp(operation, "mprotect") == 0) {
    if (mprotect(plan->memory, plan->bytes, PROT_READ | PROT_WRITE) != 0) return errno;
  } else if (strcmp(operation, "remap") == 0) {
    if (mmap(plan->memory, plan->bytes, PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == MAP_FAILED) return errno;
  } else if (strcmp(operation, "dup") == 0) {
    if (dup2(fd, plan->control) < 0) return errno;
  } else if (strcmp(operation, "recvmsg") == 0) {
    struct msghdr message = {0};
    if (recvmsg(plan->control, &message, MSG_DONTWAIT) < 0) return errno;
  } else if (strcmp(operation, "sendto") == 0) {
    if (sendto(fd, "x", 1, MSG_NOSIGNAL, address, range->length) < 0) return errno;
  } else if (strcmp(operation, "sendmsg") == 0) {
    struct msghdr message = {0};
    message.msg_name = (void *)address; message.msg_namelen = range->length;
    if (sendmsg(fd, &message, MSG_NOSIGNAL | MSG_FASTOPEN) < 0) return errno;
  } else if (strcmp(operation, "close_control") == 0) {
    if (close(plan->control) != 0) return errno;
  } else if (strcmp(operation, "udp") == 0) {
    if (socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, IPPROTO_UDP) < 0) return errno;
  } else if (strcmp(operation, "open") == 0) {
    if (open("/proc/self/mem", O_RDWR) < 0) return errno;
  } else if (strcmp(operation, "exec") == 0) {
    char *argv[] = {NULL};
    execve("/proc/self/exe", argv, argv);
    return errno;
  } else if (strcmp(operation, "fork") == 0) {
    if (fork() < 0) return errno;
  } else if (strncmp(operation, "scratch_", 8) == 0) {
    return connector_attack_scratch(plan, operation + 8);
  } else if (strcmp(operation, "unscratched") == 0) {
    return connector_attack_scratch(plan, operation);
  }
  return 0;
}

static int connector_start_native (struct connector_plan *plan, const char *probe, pid_t *child) {
  int status[2] = {-1, -1};
  if (COSMIC_FAULT("connector_pipe")) return EMFILE;
  if (pipe2(status, O_CLOEXEC) != 0) return errno;
  if (status[0] < 0 || status[1] < 0) {
    if (status[0] >= 0) close(status[0]);
    if (status[1] >= 0) close(status[1]);
    return EIO;
  }
  plan->status = status[1];
  plan->close_refused = COSMIC_FAULT("connector_close_range");
  plan->filter_refused = COSMIC_FAULT("connector_filter");
#if defined(__x86_64__)
  const struct connector_numbers *numbers = &connector_x86;
#else
  const struct connector_numbers *numbers = &connector_arm;
#endif
  if (connector_program(&plan->code, numbers, plan->ranges, plan->filtered,
      plan->control, plan->status) == 0) { close(status[0]); close(status[1]); return E2BIG; }
  sigset_t every, before;
  sigfillset(&every);
  if (sigprocmask(SIG_SETMASK, &every, &before) != 0) {
    int trouble = errno; close(status[0]); close(status[1]); return trouble;
  }
  bool refused = COSMIC_FAULT("connector_fork");
  pid_t pid = refused ? -1 : fork();
  int failure = refused ? EAGAIN : errno;
  if (pid == 0) {
    int held = connector_hold(plan);
    if (connector_whole(plan->status, &held, sizeof held, true) != 0) _exit(1);
    close(plan->status);
    if (held) _exit(1);
    if (probe != NULL) {
      int result = connector_attack(plan, probe);
      if (connector_whole(plan->control, &result, sizeof result, true) != 0) _exit(1);
      _exit(0);
    }
    connector_loop(plan);
  }
  int restore_error = sigprocmask(SIG_SETMASK, &before, NULL) == 0 ? 0 : errno;
  close(status[1]);
  if (pid < 0) { close(status[0]); return failure; }
  if (restore_error) {
    close(status[0]);
    kill(pid, SIGKILL);
    int ignored; while (waitpid(pid, &ignored, 0) < 0 && errno == EINTR) {}
    return restore_error;
  }
  int held = 0;
  failure = connector_whole(status[0], &held, sizeof held, false);
  close(status[0]);
  if (failure || held) {
    kill(pid, SIGKILL);
    int ignored; while (waitpid(pid, &ignored, 0) < 0 && errno == EINTR) {}
    return failure ? failure : held;
  }
  *child = pid;
  return 0;
}
#endif

COSMIC_SYSCALL(connector_start, 4) {
  struct connector_endpoint endpoints[CONNECTOR_ENDPOINTS];
  struct connector_public pub;
  memset(&pub, 0, sizeof pub);
  if (!lua_isnoneornil(L, 4)) connector_public_read(L, 4, &pub);
  size_t count = connector_endpoints(L, 1, endpoints, true, pub.enabled);
  int control = cosmic_checkfd(L, 2), timeout = cosmic_checkint(L, 3);
  if (timeout < 1 || timeout > 60000) return luaL_argerror(L, 3, "timeout must be 1 through 60000 milliseconds");
#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
  struct connector_plan plan;
  int failure = connector_prepare(&plan, endpoints, count, &pub, control, timeout);
  pid_t child = -1;
  if (!failure) failure = connector_start_native(&plan, NULL, &child);
  connector_release(&plan);
  if (failure) return cosmic_fail(L, failure);
  lua_pushinteger(L, child);
  return 1;
#else
  /* TODO: use Seatbelt's exact numeric remote rules once the macOS
   * profile application and native connector confinement land. */
  (void)count; (void)control; (void)pub;
  return cosmic_fail(L, ENOSYS);
#endif
}

COSMIC_SYSCALL(connector_probe, 2) {
  struct connector_endpoint endpoint;
  connector_endpoints(L, 1, &endpoint, false, false);
  const char *operation = luaL_checkstring(L, 2);
  static const char *const operations[] = {"pointer", "length", "mutation", "mprotect", "remap", "dup",
    "recvmsg", "sendto", "sendmsg", "close_control", "udp", "open", "exec", "fork"};
  static const char *const scratch[] = {"scratch_mprotect", "scratch_remap", "scratch_pointer",
    "scratch_length", "scratch_offset", "scratch_past", "scratch_swapped"};
  bool known = false;
  for (size_t i = 0; i < sizeof operations / sizeof operations[0]; i++)
    if (strcmp(operation, operations[i]) == 0) known = true;
  struct connector_public pub;
  memset(&pub, 0, sizeof pub);
  for (size_t i = 0; i < sizeof scratch / sizeof scratch[0]; i++)
    if (strcmp(operation, scratch[i]) == 0) { known = true; pub.enabled = true; }
  bool unscratched = strcmp(operation, "unscratched") == 0;
  if (unscratched) known = true;
  if (!known) return luaL_argerror(L, 2, "unknown connector probe");
#if defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
  int pair[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair) != 0) return cosmic_fail(L, errno);
  struct connector_plan plan;
  int failure = connector_prepare(&plan, &endpoint, 1, &pub, pair[1], 100);
  pid_t child = -1;
  if (!failure && unscratched) {
    /* A page the filter was not told of, as a table-only connector has none. */
    plan.scratch_bytes = (size_t)sysconf(_SC_PAGESIZE);
    plan.scratch = mmap(NULL, plan.scratch_bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (plan.scratch == MAP_FAILED) { plan.scratch = NULL; failure = errno; }
  }
  if (!failure) failure = connector_start_native(&plan, operation, &child);
  close(pair[1]);
  connector_release(&plan);
  int result = 0, ended = 0;
  if (!failure) {
    int read_error = connector_whole(pair[0], &result, sizeof result, false);
    pid_t reaped; do { reaped = waitpid(child, &ended, 0); } while (reaped < 0 && errno == EINTR);
    if (reaped < 0) failure = errno;
    else if (WIFSIGNALED(ended)) result = -WTERMSIG(ended);
    else if (read_error) failure = read_error;
  }
  close(pair[0]);
  if (failure) return cosmic_fail(L, failure);
  lua_pushinteger(L, result);
  return 1;
#else
  return cosmic_fail(L, ENOSYS);
#endif
}
