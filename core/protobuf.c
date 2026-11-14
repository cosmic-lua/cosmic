#include "protobuf.h"

#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "lauxlib.h"
#include "pb_decode.h"

#define MESSAGE_TYPE "cosmic.protobuf.message"

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
    lua_rawseti(L, 3, ++found);
  }
  return 1;
}

static const luaL_Reg methods[] = {
  {"fields", message_fields},
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

static const luaL_Reg module[] = {
  {"decode", protobuf_decode},
  {"read_varint", protobuf_read_varint},
  {NULL, NULL},
};

int cosmic_open_protobuf (lua_State *L) {
  luaL_newmetatable(L, MESSAGE_TYPE);
  luaL_newlib(L, methods);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, module);
  return 1;
}
