#include "protobuf.h"

#include <inttypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "lauxlib.h"
#include "pb_decode.h"

#define MESSAGE_TYPE "cosmic.protobuf.message"
#define WRITER_TYPE "cosmic.protobuf.writer"

enum { wire_varint = 0, wire_fixed64 = 1, wire_len = 2, wire_fixed32 = 5 };
enum { no_entry = -1, max_number = 536870911, why_size = 160 };

/* One field of a message. */
struct entry {
  /* The integer of a field that is one. For a length-delimited field,
   * the offset of its first byte in the message's bytes. */
  uint64_t value;
  /* The bytes of a length-delimited field. */
  size_t length;
  uint32_t number;
  /* The field before this one of the same number, or no_entry. */
  int32_t prev;
  uint8_t wire;
};

/* A message that was read: its fields in the order of the bytes, then
 * a table from a number to the last field of it, both after the struct
 * in the userdata. The userdata's user value is the bytes `data`
 * points into, which keeps them. */
struct message {
  const char *data;
  size_t count;
  /* The slots of the table, a power of two, or 0 for no field. */
  size_t buckets;
  /* 32 less the bits of `buckets`. */
  unsigned shift;
  lua_Integer depth;
  lua_Integer max_depth;
  lua_Integer max_fields;
};

static struct entry *entries_of (struct message *m) {
  return (struct entry *)(m + 1);
}

static int32_t *slots_of (struct message *m) {
  return (int32_t *)(entries_of(m) + m->count);
}

/* The slot a number's probe starts at: the high bits of the product,
 * which every bit of the number reaches, so numbers that agree in
 * their low bits do not share a slot. */
static size_t slot_of (const struct message *m, uint32_t number) {
  return (size_t)((uint32_t)(number * 2654435761u) >> m->shift);
}

/* The last field of `number`, or no_entry. */
static int32_t last_of (struct message *m, lua_Integer number) {
  if (m->buckets == 0 || number < 1 || number > max_number) {
    return no_entry;
  }
  struct entry *entries = entries_of(m);
  int32_t *slots = slots_of(m);
  for (size_t at = slot_of(m, (uint32_t)number);;
       at = (at + 1) & (m->buckets - 1)) {
    int32_t index = slots[at];
    if (index == no_entry || entries[index].number == (uint32_t)number) {
      return index;
    }
  }
}

/* The first field of the number whose last is `last`. */
static int32_t first_of (struct message *m, int32_t last) {
  struct entry *entries = entries_of(m);
  while (entries[last].prev != no_entry) {
    last = entries[last].prev;
  }
  return last;
}

/* `n` things, as cosmic.string's `counted` writes a count. */
static void counted (char *into, size_t size, lua_Integer n, const char *noun) {
  snprintf(into, size, "%" PRId64 " %s%s", (int64_t)n, noun, n == 1 ? "" : "s");
}

/* Why a varint nanopb refused could not be read: `long_one` where it
 * holds more bits than it may. */
static const char *varint_trouble (pb_istream_t *stream, const char *long_one) {
  return strcmp(PB_GET_ERROR(stream), "varint overflow") == 0
           ? long_one
           : "the bytes end inside a varint";
}

static const char long_varint[] = "a varint holds more than 64 bits";

/* Reads the fields in `size` bytes at `offset` of `data`. With `m`,
 * they go into it from entry `*at`, each chained to the field before
 * it of its number; without, they are only counted. `*at` moves past
 * them, and may not pass `max_fields`. False and `why`, the module's
 * own words, where the bytes are no message. */
static bool read_fields (const char *data, size_t offset, size_t size,
                         struct message *m, size_t *at, lua_Integer max_fields,
                         char why[why_size]) {
  const pb_byte_t *base = (const pb_byte_t *)data;
  pb_istream_t stream = pb_istream_from_buffer(base + offset, size);
  /* An entry is named by an int32_t, and a message has two slots for each. */
  if (max_fields > INT32_MAX / 2) {
    max_fields = INT32_MAX / 2;
  }
  for (;;) {
    int64_t byte = (int64_t)((const pb_byte_t *)stream.state - base) + 1;
    if (stream.bytes_left == 0) {
      return true;
    }
    /* The key is read whole, not through pb_decode_tag, which takes one
     * of more than 32 bits where they repeat its 32nd. */
    uint64_t key = 0;
    if (!pb_decode_varint(&stream, &key)) {
      snprintf(why, why_size, "protobuf: byte %" PRId64 ": %s", byte,
               varint_trouble(&stream, long_varint));
      return false;
    }
    if (key >> 3 > (uint64_t)max_number) {
      snprintf(why, why_size,
               "protobuf: byte %" PRId64 ": a field number above %d", byte,
               (int)max_number);
      return false;
    }
    pb_wire_type_t wire = (pb_wire_type_t)(key & 7);
    uint32_t number = (uint32_t)(key >> 3);
    if (number == 0) {
      snprintf(why, why_size, "protobuf: byte %" PRId64 ": a field number of 0",
               byte);
      return false;
    }
    if ((lua_Integer)*at >= max_fields) {
      char fields[40];
      counted(fields, sizeof fields, max_fields, "field");
      snprintf(why, why_size, "protobuf: the message holds more than %s", fields);
      return false;
    }
    uint64_t value = 0;
    size_t length = 0;
    if (wire == PB_WT_VARINT) {
      if (!pb_decode_varint(&stream, &value)) {
        snprintf(why, why_size, "protobuf: byte %" PRId64 ": field %" PRIu32 ": %s",
                 byte, number, varint_trouble(&stream, long_varint));
        return false;
      }
    } else if (wire == PB_WT_64BIT || wire == PB_WT_32BIT) {
      size_t width = wire == PB_WT_64BIT ? 8 : 4;
      if (stream.bytes_left < width) {
        snprintf(why, why_size,
                 "protobuf: byte %" PRId64
                 ": the bytes end inside the %d bytes of field %" PRIu32,
                 byte, (int)width, number);
        return false;
      }
      uint32_t four = 0;
      bool read = width == 8 ? pb_decode_fixed64(&stream, &value)
                             : pb_decode_fixed32(&stream, &four);
      (void)read; /* The bytes are there. */
      if (width == 4) {
        value = four;
      }
    } else if (wire == PB_WT_STRING) {
      uint32_t declared = 0;
      if (!pb_decode_varint32(&stream, &declared)) {
        /* A length of more than 32 bits passes the end as any other too long. */
        if (strcmp(PB_GET_ERROR(&stream), "varint overflow") == 0) {
          snprintf(why, why_size,
                   "protobuf: byte %" PRId64 ": the length of field %" PRIu32
                   " passes the end of the bytes",
                   byte, number);
        } else {
          snprintf(why, why_size,
                   "protobuf: byte %" PRId64 ": field %" PRIu32 ": %s", byte,
                   number, "the bytes end inside a varint");
        }
        return false;
      }
      if (declared > stream.bytes_left) {
        snprintf(why, why_size,
                 "protobuf: byte %" PRId64 ": the length of field %" PRIu32
                 " passes the end of the bytes",
                 byte, number);
        return false;
      }
      value = (uint64_t)((const pb_byte_t *)stream.state - base);
      length = declared;
      bool skipped = pb_read(&stream, NULL, length);
      (void)skipped; /* The bytes are there. */
    } else if ((int)wire == 3 || (int)wire == 4) {
      snprintf(why, why_size,
               "protobuf: byte %" PRId64 ": field %" PRIu32
               " is a group (wire type %d), which is not read",
               byte, number, (int)wire);
      return false;
    } else {
      snprintf(why, why_size,
               "protobuf: byte %" PRId64 ": field %" PRIu32
               " has wire type %d, which the format does not have",
               byte, number, (int)wire);
      return false;
    }
    if (m != NULL) {
      struct entry *entries = entries_of(m);
      int32_t *slots = slots_of(m);
      struct entry *e = &entries[*at];
      e->value = value;
      e->length = length;
      e->number = number;
      e->wire = (uint8_t)wire;
      size_t slot = slot_of(m, number);
      while (slots[slot] != no_entry && entries[slots[slot]].number != number) {
        slot = (slot + 1) & (m->buckets - 1);
      }
      e->prev = slots[slot];
      slots[slot] = (int32_t)*at;
    }
    *at += 1;
  }
}

/* Pushes a message of `count` fields, none read yet, over the bytes at
 * stack index `bytes`. */
static struct message *push_message (lua_State *L, int bytes, size_t count,
                                     lua_Integer depth, lua_Integer max_depth,
                                     lua_Integer max_fields) {
  size_t buckets = 0;
  unsigned shift = 32;
  if (count > 0) {
    buckets = 4;
    shift = 30;
    while (buckets < count * 2) {
      buckets *= 2;
      shift -= 1;
    }
  }
  bytes = lua_absindex(L, bytes);
  struct message *m = lua_newuserdatauv(
    L, sizeof *m + count * sizeof(struct entry) + buckets * sizeof(int32_t), 1);
  m->data = lua_tostring(L, bytes);
  m->count = count;
  m->buckets = buckets;
  m->shift = shift;
  m->depth = depth;
  m->max_depth = max_depth;
  m->max_fields = max_fields;
  int32_t *slots = slots_of(m);
  for (size_t i = 0; i < buckets; i++) {
    slots[i] = no_entry;
  }
  lua_pushvalue(L, bytes);
  lua_setiuservalue(L, -2, 1);
  luaL_setmetatable(L, MESSAGE_TYPE);
  return m;
}

/* A value's failure: nil and why. */
static int refuse (lua_State *L, const char *why) {
  lua_pushnil(L);
  lua_pushstring(L, why);
  return 2;
}

/* A value and the "" that says it is one. */
static int answer (lua_State *L) {
  lua_pushliteral(L, "");
  return 2;
}

/* decode(data, max_depth, max_fields): the message and "", or nil and
 * why the bytes are none. */
static int protobuf_decode (lua_State *L) {
  size_t size;
  const char *data = luaL_checklstring(L, 1, &size);
  lua_Integer max_depth = luaL_checkinteger(L, 2);
  lua_Integer max_fields = luaL_checkinteger(L, 3);
  char why[why_size];
  size_t count = 0;
  if (!read_fields(data, 0, size, NULL, &count, max_fields, why)) {
    return refuse(L, why);
  }
  struct message *m = push_message(L, 1, count, 1, max_depth, max_fields);
  size_t at = 0;
  read_fields(data, 0, size, m, &at, max_fields, why);
  return answer(L);
}

/* read_varint(data, at): a table of the varint at byte `at` and the
 * position after it, and "", or nil and why there is none. */
static int protobuf_read_varint (lua_State *L) {
  size_t size;
  const char *data = luaL_checklstring(L, 1, &size);
  lua_Integer start = luaL_checkinteger(L, 2);
  luaL_argcheck(L, start >= 1, 2, "no position");
  size_t offset = (lua_Unsigned)start - 1 > size ? size : (size_t)start - 1;
  pb_istream_t stream =
    pb_istream_from_buffer((const pb_byte_t *)data + offset, size - offset);
  uint64_t value = 0;
  if (!pb_decode_varint(&stream, &value)) {
    lua_pushnil(L);
    lua_pushfstring(L, "protobuf: %s", varint_trouble(&stream, long_varint));
    return 2;
  }
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, (lua_Integer)value);
  lua_setfield(L, -2, "value");
  lua_pushinteger(L, (lua_Integer)(size - stream.bytes_left) + 1);
  lua_setfield(L, -2, "next");
  return answer(L);
}

/* The field number at argument 2, or 0, which no field has, where it is
 * no integer: a read by number raises for nothing. */
static lua_Integer number_of (lua_State *L) {
  int is_integer = 0;
  lua_Integer number =
    lua_type(L, 2) == LUA_TNUMBER ? lua_tointegerx(L, 2, &is_integer) : 0;
  return is_integer ? number : 0;
}

static struct message *self_of (lua_State *L) {
  return luaL_checkudata(L, 1, MESSAGE_TYPE);
}

/* The last field of the number at argument 2 with wire type `wire`. */
static struct entry *find (lua_State *L, struct message *m, uint8_t wire) {
  struct entry *entries = entries_of(m);
  for (int32_t at = last_of(m, number_of(L)); at != no_entry;
       at = entries[at].prev) {
    if (entries[at].wire == wire) {
      return &entries[at];
    }
  }
  return NULL;
}

static int message_has (lua_State *L) {
  struct message *m = self_of(L);
  lua_pushboolean(L, last_of(m, number_of(L)) != no_entry);
  return 1;
}

static int message_wires (lua_State *L) {
  struct message *m = self_of(L);
  struct entry *entries = entries_of(m);
  lua_Integer mask = 0;
  for (int32_t at = last_of(m, number_of(L)); at != no_entry;
       at = entries[at].prev) {
    mask |= (lua_Integer)1 << entries[at].wire;
  }
  lua_pushinteger(L, mask);
  return 1;
}

static lua_Integer unzigzag (uint64_t v) {
  return (lua_Integer)((v >> 1) ^ (~(v & 1) + 1));
}

static lua_Integer signed32 (uint64_t v) {
  return (lua_Integer)(int32_t)(uint32_t)v;
}

static double double_of (uint64_t bits) {
  double value;
  memcpy(&value, &bits, sizeof value);
  return value;
}

static double float_of (uint64_t bits) {
  uint32_t four = (uint32_t)bits;
  float value;
  memcpy(&value, &four, sizeof value);
  return (double)value;
}

static int message_int (lua_State *L) {
  struct entry *e = find(L, self_of(L), wire_varint);
  if (e == NULL) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushinteger(L, (lua_Integer)e->value);
  return 1;
}

static int message_sint (lua_State *L) {
  struct entry *e = find(L, self_of(L), wire_varint);
  if (e == NULL) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushinteger(L, unzigzag(e->value));
  return 1;
}

static int message_bool (lua_State *L) {
  struct entry *e = find(L, self_of(L), wire_varint);
  if (e == NULL) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushboolean(L, e->value != 0);
  return 1;
}

static int message_fixed32 (lua_State *L) {
  struct entry *e = find(L, self_of(L), wire_fixed32);
  if (e == NULL) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushinteger(L, (lua_Integer)e->value);
  return 1;
}

static int message_sfixed32 (lua_State *L) {
  struct entry *e = find(L, self_of(L), wire_fixed32);
  if (e == NULL) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushinteger(L, signed32(e->value));
  return 1;
}

static int message_fixed64 (lua_State *L) {
  struct entry *e = find(L, self_of(L), wire_fixed64);
  if (e == NULL) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushinteger(L, (lua_Integer)e->value);
  return 1;
}

static int message_float (lua_State *L) {
  struct entry *e = find(L, self_of(L), wire_fixed32);
  if (e == NULL) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushnumber(L, float_of(e->value));
  return 1;
}

static int message_double (lua_State *L) {
  struct entry *e = find(L, self_of(L), wire_fixed64);
  if (e == NULL) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushnumber(L, double_of(e->value));
  return 1;
}

static int message_bytes (lua_State *L) {
  struct message *m = self_of(L);
  struct entry *e = find(L, m, wire_len);
  if (e == NULL) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushlstring(L, m->data + e->value, e->length);
  return 1;
}

/* Whether `size` bytes at `text` are UTF-8 as Lua's `utf8.len` takes
 * it: no byte that begins nothing, no sequence cut short or longer than
 * its character needs, no surrogate and nothing past U+10FFFF. */
static bool is_utf8 (const unsigned char *text, size_t size) {
  size_t at = 0;
  while (at < size) {
    unsigned char lead = text[at];
    size_t more;
    uint32_t least;
    uint32_t code;
    if (lead < 0x80) {
      at += 1;
      continue;
    } else if (lead >= 0xc2 && lead <= 0xdf) {
      more = 1;
      least = 0x80;
      code = lead & 0x1fu;
    } else if (lead >= 0xe0 && lead <= 0xef) {
      more = 2;
      least = 0x800;
      code = lead & 0x0fu;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      more = 3;
      least = 0x10000;
      code = lead & 0x07u;
    } else {
      return false;
    }
    if (size - at <= more) {
      return false;
    }
    for (size_t i = 1; i <= more; i++) {
      unsigned char next = text[at + i];
      if ((next & 0xc0) != 0x80) {
        return false;
      }
      code = (code << 6) | (next & 0x3fu);
    }
    if (code < least || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) {
      return false;
    }
    at += more + 1;
  }
  return true;
}

static int message_string (lua_State *L) {
  struct message *m = self_of(L);
  struct entry *e = find(L, m, wire_len);
  if (e == NULL ||
      !is_utf8((const unsigned char *)m->data + e->value, e->length)) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushlstring(L, m->data + e->value, e->length);
  return 1;
}

/* Pushes the message that the length-delimited fields of `number`
 * hold, merged, and "", or nil and why they hold none. With `only`,
 * the message of that one field. */
static int push_embedded (lua_State *L, struct message *m, lua_Integer number,
                          int32_t only) {
  char why[why_size];
  if (m->depth >= m->max_depth) {
    char messages[40];
    counted(messages, sizeof messages, m->max_depth, "message");
    snprintf(why, why_size, "protobuf: field %" PRId64 " nests deeper than %s",
             (int64_t)number, messages);
    return refuse(L, why);
  }
  struct entry *entries = entries_of(m);
  int32_t last = only != no_entry ? only : last_of(m, number);
  int32_t first = only != no_entry ? only : last;
  if (only == no_entry && last != no_entry) {
    first = first_of(m, last);
  }
  for (int pass = 0; pass < 2; pass++) {
    size_t at = 0;
    struct message *child = NULL;
    if (pass == 1) {
      size_t count = (size_t)lua_tointeger(L, -1);
      lua_pop(L, 1);
      lua_getiuservalue(L, 1, 1);
      child = push_message(L, -1, count, m->depth + 1, m->max_depth,
                           m->max_fields);
      lua_remove(L, -2);
    }
    for (int32_t i = first; last != no_entry && i <= last; i++) {
      struct entry *e = &entries[i];
      if ((lua_Integer)e->number != number || e->wire != wire_len) {
        continue;
      }
      if (!read_fields(m->data, (size_t)e->value, e->length, child, &at,
                       m->max_fields, why)) {
        lua_pushnil(L);
        lua_pushfstring(L, "%s (in field %I)", why, number);
        return 2;
      }
    }
    if (pass == 0) {
      lua_pushinteger(L, (lua_Integer)at);
    }
  }
  return answer(L);
}

static int message_message (lua_State *L) {
  struct message *m = self_of(L);
  return push_embedded(L, m, number_of(L), no_entry);
}

static int message_repeated_message (lua_State *L) {
  struct message *m = self_of(L);
  lua_Integer number = number_of(L);
  struct entry *entries = entries_of(m);
  int32_t last = last_of(m, number);
  lua_newtable(L);
  lua_Integer found = 0;
  for (int32_t i = last == no_entry ? 0 : first_of(m, last);
       last != no_entry && i <= last; i++) {
    if ((lua_Integer)entries[i].number != number || entries[i].wire != wire_len) {
      continue;
    }
    if (push_embedded(L, m, number, i) != 2 || lua_isnil(L, -2)) {
      return 2;
    }
    lua_pop(L, 1);
    found += 1;
    lua_rawseti(L, -2, found);
  }
  if (found == 0 && m->depth >= m->max_depth) {
    /* No field is there to refuse the depth, which `message` refuses
     * with no field too. */
    return push_embedded(L, m, number, no_entry);
  }
  return answer(L);
}

/* What a repeated read makes of each number it finds. */
enum kind {
  kind_int,
  kind_sint,
  kind_fixed32,
  kind_sfixed32,
  kind_fixed64,
  kind_float,
  kind_double,
};

static void push_one (lua_State *L, enum kind kind, uint64_t bits) {
  switch (kind) {
    case kind_int:
    case kind_fixed32:
    case kind_fixed64:
    lua_pushinteger(L, (lua_Integer)bits);
    break;
    case kind_sint:
    lua_pushinteger(L, unzigzag(bits));
    break;
    case kind_sfixed32:
    lua_pushinteger(L, signed32(bits));
    break;
    case kind_float:
    lua_pushnumber(L, float_of(bits));
    break;
    case kind_double:
    lua_pushnumber(L, double_of(bits));
    break;
  }
}

/* Every number of the field at argument 2, in order, packed or not, and
 * "", or nil and why a packed field holds none: `wire` is the wire type
 * of one by itself, and `width` its bytes, 0 for a varint. */
static int repeated (lua_State *L, enum kind kind, uint8_t wire, size_t width) {
  struct message *m = self_of(L);
  lua_Integer number = number_of(L);
  struct entry *entries = entries_of(m);
  int32_t last = last_of(m, number);
  char why[why_size];
  lua_newtable(L);
  lua_Integer found = 0;
  for (int32_t i = last == no_entry ? 0 : first_of(m, last);
       last != no_entry && i <= last; i++) {
    struct entry *e = &entries[i];
    if ((lua_Integer)e->number != number) {
      continue;
    }
    if (e->wire == wire) {
      push_one(L, kind, e->value);
      lua_rawseti(L, -2, ++found);
    } else if (e->wire == wire_len && width == 0) {
      pb_istream_t stream = pb_istream_from_buffer(
        (const pb_byte_t *)m->data + e->value, e->length);
      while (stream.bytes_left > 0) {
        uint64_t value = 0;
        if (!pb_decode_varint(&stream, &value)) {
          snprintf(why, why_size, "protobuf: packed field %" PRId64 ": %s",
                   (int64_t)number, varint_trouble(&stream, long_varint));
          return refuse(L, why);
        }
        push_one(L, kind, value);
        lua_rawseti(L, -2, ++found);
      }
    } else if (e->wire == wire_len) {
      if (e->length % width != 0) {
        char bytes[40];
        counted(bytes, sizeof bytes, (lua_Integer)e->length, "byte");
        snprintf(why, why_size,
                 "protobuf: packed field %" PRId64 " is %s, no multiple of %d",
                 (int64_t)number, bytes, (int)width);
        return refuse(L, why);
      }
      pb_istream_t stream = pb_istream_from_buffer(
        (const pb_byte_t *)m->data + e->value, e->length);
      while (stream.bytes_left > 0) {
        uint64_t value = 0;
        uint32_t four = 0;
        bool read = width == 8 ? pb_decode_fixed64(&stream, &value)
                               : pb_decode_fixed32(&stream, &four);
        (void)read; /* The bytes are there. */
        push_one(L, kind, width == 8 ? value : four);
        lua_rawseti(L, -2, ++found);
      }
    }
  }
  return answer(L);
}

static int message_repeated_int (lua_State *L) {
  return repeated(L, kind_int, wire_varint, 0);
}

static int message_repeated_sint (lua_State *L) {
  return repeated(L, kind_sint, wire_varint, 0);
}

static int message_repeated_fixed32 (lua_State *L) {
  return repeated(L, kind_fixed32, wire_fixed32, 4);
}

static int message_repeated_sfixed32 (lua_State *L) {
  return repeated(L, kind_sfixed32, wire_fixed32, 4);
}

static int message_repeated_fixed64 (lua_State *L) {
  return repeated(L, kind_fixed64, wire_fixed64, 8);
}

static int message_repeated_float (lua_State *L) {
  return repeated(L, kind_float, wire_fixed32, 4);
}

static int message_repeated_double (lua_State *L) {
  return repeated(L, kind_double, wire_fixed64, 8);
}

static int message_repeated_bytes (lua_State *L) {
  struct message *m = self_of(L);
  lua_Integer number = number_of(L);
  struct entry *entries = entries_of(m);
  int32_t last = last_of(m, number);
  lua_newtable(L);
  lua_Integer found = 0;
  for (int32_t i = last == no_entry ? 0 : first_of(m, last);
       last != no_entry && i <= last; i++) {
    struct entry *e = &entries[i];
    if ((lua_Integer)e->number == number && e->wire == wire_len) {
      lua_pushlstring(L, m->data + e->value, e->length);
      lua_rawseti(L, -2, ++found);
    }
  }
  return 1;
}

/* Pushes the field `e` of `m` as a table of its number, wire type and
 * value. */
static void push_field (lua_State *L, struct message *m, struct entry *e) {
  lua_createtable(L, 0, 3);
  lua_pushinteger(L, (lua_Integer)e->number);
  lua_setfield(L, -2, "number");
  lua_pushinteger(L, (lua_Integer)e->wire);
  lua_setfield(L, -2, "wire");
  if (e->wire == wire_len) {
    lua_pushlstring(L, m->data + e->value, e->length);
  } else {
    lua_pushinteger(L, (lua_Integer)e->value);
  }
  lua_setfield(L, -2, "value");
}

/* fields(keep): every field as a table of its number, wire type and
 * value, in the order of the bytes, or those `keep` answers true for
 * of a number and a wire type. */
static int message_fields (lua_State *L) {
  struct message *m = self_of(L);
  bool choosing = !lua_isnoneornil(L, 2);
  struct entry *entries = entries_of(m);
  lua_settop(L, 2);
  lua_newtable(L);
  lua_Integer found = 0;
  for (size_t i = 0; i < m->count; i++) {
    struct entry *e = &entries[i];
    if (choosing) {
      lua_pushvalue(L, 2);
      lua_pushinteger(L, (lua_Integer)e->number);
      lua_pushinteger(L, (lua_Integer)e->wire);
      lua_call(L, 2, 1);
      bool kept = lua_toboolean(L, -1);
      lua_pop(L, 1);
      if (!kept) {
        continue;
      }
    }
    push_field(L, m, e);
    lua_rawseti(L, 3, ++found);
  }
  return 1;
}

/* unfit(fits, named): the fields whose wire type is no bit of their
 * number's entry of the table `fits`, as `fields` lists them, or nil
 * where there is none. A number with no entry fits nothing, and with
 * `named` it is passed over. */
static int message_unfit (lua_State *L) {
  struct message *m = self_of(L);
  luaL_checktype(L, 2, LUA_TTABLE);
  bool named = lua_toboolean(L, 3);
  struct entry *entries = entries_of(m);
  lua_settop(L, 2);
  lua_pushnil(L);
  lua_Integer found = 0;
  for (size_t i = 0; i < m->count; i++) {
    struct entry *e = &entries[i];
    int isnum = 0;
    bool known = lua_rawgeti(L, 2, (lua_Integer)e->number) != LUA_TNIL;
    lua_Integer bits = lua_tointegerx(L, -1, &isnum);
    lua_pop(L, 1);
    if (known ? (isnum && (bits >> e->wire & 1) != 0) : named) {
      continue;
    }
    if (found == 0) {
      lua_newtable(L);
      lua_replace(L, 3);
    }
    push_field(L, m, e);
    lua_rawseti(L, 3, ++found);
  }
  return 1;
}

static const luaL_Reg methods[] = {
  {"fields", message_fields},
  {"unfit", message_unfit},
  {"has", message_has},
  {"wires", message_wires},
  {"int", message_int},
  {"sint", message_sint},
  {"bool", message_bool},
  {"fixed32", message_fixed32},
  {"sfixed32", message_sfixed32},
  {"fixed64", message_fixed64},
  {"float", message_float},
  {"double", message_double},
  {"bytes", message_bytes},
  {"string", message_string},
  {"message", message_message},
  {"repeated_int", message_repeated_int},
  {"repeated_sint", message_repeated_sint},
  {"repeated_fixed32", message_repeated_fixed32},
  {"repeated_sfixed32", message_repeated_sfixed32},
  {"repeated_fixed64", message_repeated_fixed64},
  {"repeated_float", message_repeated_float},
  {"repeated_double", message_repeated_double},
  {"repeated_bytes", message_repeated_bytes},
  {"repeated_message", message_repeated_message},
  {NULL, NULL},
};

/* A message being written: the bytes of the fields so far. User value 1
 * is why the first field that could not be written could not, a string,
 * or nil while every field could; user value 2 is the userdata `data`
 * points into. */
struct writer {
  char *data;
  size_t size;
  size_t room;
  /* Where the message being written inside this one begins, or no_open:
   * the link_size bytes there hold the same of the message around it,
   * until `close` writes the length in their place. */
  size_t open;
  bool troubled;
};

enum { link_size = 8 };
static const size_t no_open = SIZE_MAX;
static const char unclosed[] = "protobuf: a message was opened and not closed";

/* Pushes a writer of no fields, with room for a few. */
static struct writer *push_writer (lua_State *L) {
  enum { first_room = 64 };
  struct writer *w = lua_newuserdatauv(L, sizeof *w, 2);
  w->size = 0;
  w->room = 0;
  w->troubled = false;
  w->open = no_open;
  w->data = NULL;
  luaL_setmetatable(L, WRITER_TYPE);
  char *data = lua_newuserdatauv(L, first_room, 0);
  lua_setiuservalue(L, -2, 2);
  w->data = data;
  w->room = first_room;
  return w;
}

static struct writer *writer_of (lua_State *L) {
  return luaL_checkudata(L, 1, WRITER_TYPE);
}

/* Room for `more` bytes after those written by the writer `w` at stack
 * index `self`, which is no index from the top. The bytes are a
 * userdata of Lua's, so the collector counts them and frees them, and a
 * refusal of memory raises as Lua's own does. The block before it is
 * let go only once this returns. */
static char *writer_room (lua_State *L, int self, struct writer *w,
                          size_t more) {
  if (w->room - w->size < more) {
    size_t room = w->room;
    while (room - w->size < more) {
      if (room > SIZE_MAX / 2) {
        luaL_error(L, "not enough memory");
      }
      room *= 2;
    }
    char *data = lua_newuserdatauv(L, room, 0);
    memcpy(data, w->data, w->size);
    lua_setiuservalue(L, self, 2);
    w->data = data;
    w->room = room;
  }
  return w->data + w->size;
}

static size_t put_varint (char *into, uint64_t value) {
  size_t at = 0;
  while (value >= 0x80) {
    into[at++] = (char)(value | 0x80);
    value >>= 7;
  }
  into[at++] = (char)value;
  return at;
}

static void put_little (char *into, uint64_t value, size_t width) {
  for (size_t i = 0; i < width; i++) {
    into[i] = (char)(value >> (8 * i));
  }
}

/* The value on the stack's top becomes the trouble of the writer at
 * index 1, and is popped. */
static void writer_fail (lua_State *L, struct writer *w) {
  lua_setiuservalue(L, 1, 1);
  w->troubled = true;
}

/* Whether the field at argument 2 can be written: false where the
 * writer is troubled already, and where the number is no field's, which
 * becomes its trouble. */
static bool writer_number (lua_State *L, struct writer *w, uint32_t *number) {
  if (w->troubled) {
    return false;
  }
  lua_Integer n = lua_isinteger(L, 2) ? lua_tointeger(L, 2) : 0;
  if (n < 1 || n > max_number) {
    lua_pushfstring(L, "protobuf: %s is no field number (1 to %d)",
                    luaL_tolstring(L, 2, NULL), (int)max_number);
    writer_fail(L, w);
    return false;
  }
  *number = (uint32_t)n;
  return true;
}

/* Writes the key of a field and its value of `width` bytes, the low
 * ones first, or as a varint where `width` is 0. */
static int write_number (lua_State *L, struct writer *w, uint8_t wire,
                         uint64_t value, size_t width) {
  uint32_t number;
  if (writer_number(L, w, &number)) {
    char *into = writer_room(L, 1, w, 5 + 10);
    size_t at = put_varint(into, (uint64_t)number << 3 | wire);
    if (width == 0) {
      at += put_varint(into + at, value);
    } else {
      put_little(into + at, value, width);
      at += width;
    }
    w->size += at;
  }
  lua_settop(L, 1);
  return 1;
}

/* Writes a length-delimited field of `size` bytes at `body`. */
static int write_bytes (lua_State *L, struct writer *w, const char *body,
                        size_t size) {
  uint32_t number;
  if (writer_number(L, w, &number)) {
    char *into = writer_room(L, 1, w, 5 + 10 + size);
    size_t at = put_varint(into, (uint64_t)number << 3 | wire_len);
    at += put_varint(into + at, size);
    if (size > 0) {
      memcpy(into + at, body, size);
    }
    w->size += at + size;
  }
  lua_settop(L, 1);
  return 1;
}

static uint64_t zigzag (lua_Integer value) {
  return ((uint64_t)value << 1) ^ (value < 0 ? UINT64_MAX : 0);
}

static int writer_int (lua_State *L) {
  struct writer *w = writer_of(L);
  return write_number(L, w, wire_varint, (uint64_t)luaL_checkinteger(L, 3), 0);
}

static int writer_sint (lua_State *L) {
  struct writer *w = writer_of(L);
  return write_number(L, w, wire_varint, zigzag(luaL_checkinteger(L, 3)), 0);
}

static int writer_bool (lua_State *L) {
  struct writer *w = writer_of(L);
  return write_number(L, w, wire_varint, lua_toboolean(L, 3) ? 1 : 0, 0);
}

/* Whether `value` fits 32 bits, signed or not; where it does not, that
 * becomes the trouble of a writer that has none. */
static bool fits32 (lua_State *L, struct writer *w, lua_Integer value) {
  if (value >= -INT64_C(0x80000000) && value <= INT64_C(0xffffffff)) {
    return true;
  }
  if (!w->troubled) {
    lua_pushfstring(L, "protobuf: field %s: %I does not fit 32 bits",
                    luaL_tolstring(L, 2, NULL), (LUAI_UACINT)value);
    writer_fail(L, w);
  }
  return false;
}

static int writer_fixed32 (lua_State *L) {
  struct writer *w = writer_of(L);
  lua_Integer value = luaL_checkinteger(L, 3);
  if (!fits32(L, w, value)) {
    lua_settop(L, 1);
    return 1;
  }
  return write_number(L, w, wire_fixed32, (uint64_t)value & UINT64_C(0xffffffff), 4);
}

static int writer_fixed64 (lua_State *L) {
  struct writer *w = writer_of(L);
  return write_number(L, w, wire_fixed64, (uint64_t)luaL_checkinteger(L, 3), 8);
}

/* The bits of the single nearest `value`: one quiet NaN for every NaN,
 * whose bits differ between processors, and the infinity of its sign
 * for a value that rounds past the greatest single, which C leaves
 * undefined. */
static uint32_t float_bits (double value) {
  if (value != value) {
    return UINT32_C(0x7fc00000);
  }
  /* Half way from the greatest single to the next power of two. */
  const double overflow = 3.4028235677973366e+38;
  const double greatest = 3.4028234663852886e+38;
  float single;
  if (value >= overflow) {
    single = (float)HUGE_VAL;
  } else if (value <= -overflow) {
    single = (float)-HUGE_VAL;
  } else if (value > greatest) {
    single = (float)greatest;
  } else if (value < -greatest) {
    single = (float)-greatest;
  } else {
    single = (float)value;
  }
  uint32_t bits;
  memcpy(&bits, &single, sizeof bits);
  return bits;
}

static uint64_t double_bits (double value) {
  if (value != value) {
    return UINT64_C(0x7ff8000000000000);
  }
  uint64_t bits;
  memcpy(&bits, &value, sizeof bits);
  return bits;
}

static int writer_float (lua_State *L) {
  struct writer *w = writer_of(L);
  return write_number(L, w, wire_fixed32, float_bits(luaL_checknumber(L, 3)), 4);
}

static int writer_double (lua_State *L) {
  struct writer *w = writer_of(L);
  return write_number(L, w, wire_fixed64, double_bits(luaL_checknumber(L, 3)), 8);
}

static int writer_bytes (lua_State *L) {
  struct writer *w = writer_of(L);
  size_t size;
  const char *body = luaL_checklstring(L, 3, &size);
  return write_bytes(L, w, body, size);
}

static int writer_string (lua_State *L) {
  struct writer *w = writer_of(L);
  size_t size;
  const char *body = luaL_checklstring(L, 3, &size);
  if (!is_utf8((const unsigned char *)body, size)) {
    if (!w->troubled) {
      lua_pushfstring(L, "protobuf: field %s: a string that is not UTF-8",
                      luaL_tolstring(L, 2, NULL));
      writer_fail(L, w);
    }
    lua_settop(L, 1);
    return 1;
  }
  return write_bytes(L, w, body, size);
}

/* message(number, child): the fields `child` holds now, or its trouble. */
static int writer_message (lua_State *L) {
  struct writer *w = writer_of(L);
  struct writer *child = luaL_testudata(L, 3, WRITER_TYPE);
  if (child != NULL && !child->troubled && child->open != no_open) {
    if (!w->troubled) {
      lua_pushstring(L, unclosed);
      writer_fail(L, w);
    }
    lua_settop(L, 1);
    return 1;
  }
  if (child == NULL) {
    /* A writer that is not the core's says what it holds itself. */
    lua_getfield(L, 3, "encode");
    lua_pushvalue(L, 3);
    lua_call(L, 1, 2);
    if (lua_type(L, -2) != LUA_TSTRING) {
      /* No bytes and no reason is no trouble, and no field. */
      bool reason = lua_type(L, -1) != LUA_TSTRING || lua_rawlen(L, -1) > 0;
      if (!w->troubled && reason) {
        writer_fail(L, w);
      }
      lua_settop(L, 1);
      return 1;
    }
    size_t size;
    const char *body = lua_tolstring(L, -2, &size);
    return write_bytes(L, w, body, size);
  }
  if (child->troubled) {
    if (!w->troubled) {
      lua_getiuservalue(L, 3, 1);
      writer_fail(L, w);
    }
    lua_settop(L, 1);
    return 1;
  }
  if (child == w) {
    /* Its own bytes move when room is made for them. */
    lua_pushlstring(L, w->data, w->size);
    size_t size;
    const char *body = lua_tolstring(L, -1, &size);
    return write_bytes(L, w, body, size);
  }
  return write_bytes(L, w, child->data, child->size);
}

static const char *const kinds[] = {"int",     "sint",  "fixed32",
  "fixed64", "float", "double"};

/* packed(number, kind, values): every value in one length-delimited
 * field, and no field for an empty list. */
static int writer_packed (lua_State *L) {
  struct writer *w = writer_of(L);
  const char *name = luaL_checkstring(L, 3);
  luaL_checktype(L, 4, LUA_TTABLE);
  int kind = 2; /* As the Teal writer took a kind it did not know. */
  for (int i = 0; i < 6; i++) {
    if (strcmp(name, kinds[i]) == 0) {
      kind = i;
    }
  }
  if (luaL_len(L, 4) == 0 || w->troubled) {
    lua_settop(L, 1);
    return 1;
  }
  /* The values are written to a writer of their own, whose bytes are
   * this field's. */
  struct writer *body = push_writer(L);
  int held = lua_gettop(L);
  for (lua_Integer i = 1; lua_geti(L, 4, i) != LUA_TNIL; i++) {
    char *into = writer_room(L, held, body, 10);
    size_t wrote = 0;
    if (kind == 4 || kind == 5) {
      double value = luaL_checknumber(L, -1);
      if (kind == 4) {
        put_little(into, float_bits(value), 4);
        wrote = 4;
      } else {
        put_little(into, double_bits(value), 8);
        wrote = 8;
      }
    } else {
      int whole = 0;
      lua_Integer value = lua_tointegerx(L, -1, &whole);
      if (!whole) {
        const char *shown = luaL_tolstring(L, held + 1, NULL);
        lua_pushfstring(L, "protobuf: field %s: %s is no integer",
                        luaL_tolstring(L, 2, NULL), shown);
        writer_fail(L, w);
        lua_settop(L, 1);
        return 1;
      }
      if (kind == 0) {
        wrote = put_varint(into, (uint64_t)value);
      } else if (kind == 1) {
        wrote = put_varint(into, zigzag(value));
      } else if (kind == 3) {
        put_little(into, (uint64_t)value, 8);
        wrote = 8;
      } else {
        if (!fits32(L, w, value)) {
          lua_settop(L, 1);
          return 1;
        }
        put_little(into, (uint64_t)value & UINT64_C(0xffffffff), 4);
        wrote = 4;
      }
    }
    body->size += wrote;
    lua_settop(L, held);
  }
  lua_settop(L, held);
  uint32_t number;
  if (writer_number(L, w, &number)) {
    char *into = writer_room(L, 1, w, 5 + 10 + body->size);
    size_t at = put_varint(into, (uint64_t)number << 3 | wire_len);
    at += put_varint(into + at, body->size);
    memcpy(into + at, body->data, body->size);
    w->size += at + body->size;
  }
  lua_settop(L, 1);
  return 1;
}

/* open(number): begins an embedded message in place, whose fields are
 * those written until `close`. */
static int writer_open (lua_State *L) {
  struct writer *w = writer_of(L);
  uint32_t number;
  if (writer_number(L, w, &number)) {
    char *into = writer_room(L, 1, w, 5 + link_size);
    size_t at = put_varint(into, (uint64_t)number << 3 | wire_len);
    put_little(into + at, (uint64_t)w->open, link_size);
    w->open = w->size + at;
    w->size += at + link_size;
  }
  lua_settop(L, 1);
  return 1;
}

/* close(): ends the message the last `open` began: its length goes
 * where the link was, and its bytes move down to follow it. */
static int writer_close (lua_State *L) {
  struct writer *w = writer_of(L);
  if (!w->troubled && w->open == no_open) {
    lua_pushliteral(L, "protobuf: a message was closed that was not opened");
    writer_fail(L, w);
  }
  if (!w->troubled) {
    char *link = w->data + w->open;
    uint64_t around = 0;
    for (size_t i = 0; i < link_size; i++) {
      around |= (uint64_t)(unsigned char)link[i] << (8 * i);
    }
    size_t body = w->size - w->open - link_size;
    char length[10];
    size_t wide = put_varint(length, body);
    /* A length of more than link_size bytes is of 2^56 bytes or more. */
    if (wide <= link_size) {
      memmove(link + wide, link + link_size, body);
      memcpy(link, length, wide);
      w->size -= link_size - wide;
      w->open = (size_t)around;
    }
  }
  lua_settop(L, 1);
  return 1;
}

/* append(bytes): bytes that are fields already, as they are. */
static int writer_append (lua_State *L) {
  struct writer *w = writer_of(L);
  size_t size;
  const char *bytes = luaL_checklstring(L, 2, &size);
  if (!w->troubled && size > 0) {
    char *into = writer_room(L, 1, w, size);
    memcpy(into, bytes, size);
    w->size += size;
  }
  lua_settop(L, 1);
  return 1;
}

/* trouble(): why the first field that could not be written could not,
 * or "". */
static int writer_trouble (lua_State *L) {
  struct writer *w = writer_of(L);
  if (w->troubled) {
    lua_getiuservalue(L, 1, 1);
  } else {
    lua_pushliteral(L, "");
  }
  return 1;
}

/* encode(): the bytes and "", or nil and the writer's trouble. */
static int writer_encode (lua_State *L) {
  struct writer *w = writer_of(L);
  if (w->troubled) {
    lua_pushnil(L);
    lua_getiuservalue(L, 1, 1);
    return 2;
  }
  if (w->open != no_open) {
    lua_pushnil(L);
    lua_pushstring(L, unclosed);
    return 2;
  }
  lua_pushlstring(L, w->data, w->size);
  return answer(L);
}

/* writer(): a writer of a message with no fields yet. */
static int protobuf_writer (lua_State *L) {
  push_writer(L);
  return 1;
}

static const luaL_Reg writer_methods[] = {
  {"int", writer_int},
  {"sint", writer_sint},
  {"bool", writer_bool},
  {"fixed32", writer_fixed32},
  {"fixed64", writer_fixed64},
  {"float", writer_float},
  {"double", writer_double},
  {"bytes", writer_bytes},
  {"string", writer_string},
  {"message", writer_message},
  {"packed", writer_packed},
  {"open", writer_open},
  {"close", writer_close},
  {"append", writer_append},
  {"trouble", writer_trouble},
  {"encode", writer_encode},
  {NULL, NULL},
};

static const luaL_Reg module[] = {
  {"decode", protobuf_decode},
  {"read_varint", protobuf_read_varint},
  {"writer", protobuf_writer},
  {NULL, NULL},
};

int cosmic_open_protobuf (lua_State *L) {
  luaL_newmetatable(L, MESSAGE_TYPE);
  luaL_newlib(L, methods);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newmetatable(L, WRITER_TYPE);
  luaL_newlib(L, writer_methods);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, module);
  return 1;
}
