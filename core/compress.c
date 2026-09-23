#include "compress.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bzlib.h"
#include "lauxlib.h"
#include "lzma.h"
#include "memory.h"
#include "miniz.h"

/* bzlib built with BZ_NO_STDIO asks its embedder to supply this: it is
 * called only for an assertion inside the library itself (a bug in
 * bzlib, never a shape corrupt input can reach -- that comes back as an
 * ordinary BZ_* status code instead), so there is nothing a caller can
 * do but stop. */
_Noreturn void bz_internal_error (int errcode);
_Noreturn void bz_internal_error (int errcode) {
  fprintf(stderr, "cosmic: internal bzip2 library error %d\n", errcode);
  abort();
}

#define STREAM_TYPE "cosmic.compress.stream"

/* How many bytes of output one decoder `update` returns when the caller
 * names no limit of its own. */
#define DEFAULT_MAX_OUT ((lua_Integer)1 << 20)

/* The xz decoder's memory ceiling when the caller names none: enough
 * for any preset xz itself writes (-9e needs 65 MiB to decode) with
 * room to spare, and far short of what a hostile header could ask. */
#define DEFAULT_XZ_MEMLIMIT ((lua_Integer)256 << 20)

typedef enum {
  OP_INFLATE,
  OP_DEFLATE,
  OP_BZ2,
  OP_XZ,
} stream_op;

typedef enum {
  FMT_RAW,
  FMT_ZLIB,
  FMT_GZIP,
} stream_format;

/* Where a decoder is, member by member. gzip, bzip2 and xz all allow
 * one member (stream) after another; raw deflate and zlib are exactly
 * one member. */
typedef enum {
  PH_BETWEEN,  /* looking for the next member's magic */
  PH_MEMBER,   /* inside a member */
  PH_TRAILING, /* past the end: every further byte belongs to `rest` */
} phase;

/* The gzip framing around a member's deflate body, parsed by hand
 * across `update` calls. */
typedef enum {
  GZ_FIXED,   /* the ten fixed header bytes */
  GZ_XLEN,    /* FEXTRA's two-byte length */
  GZ_EXTRA,   /* FEXTRA's body */
  GZ_NAME,    /* FNAME, through its NUL */
  GZ_COMMENT, /* FCOMMENT, through its NUL */
  GZ_HCRC,    /* FHCRC's two bytes */
  GZ_BODY,    /* the deflate body */
  GZ_TRAILER, /* CRC-32 and ISIZE */
} gzip_state;

#define GZ_FHCRC 0x02u
#define GZ_FEXTRA 0x04u
#define GZ_FNAME 0x08u
#define GZ_FCOMMENT 0x10u

/* What one step of a member's decoder ended on. */
enum {
  STEP_ERROR = -1,
  STEP_INPUT, /* consumed everything offered; needs more input */
  STEP_FULL,  /* stopped at the output limit; may have more to give */
  STEP_END,   /* the member ended; unconsumed input follows it */
};

struct bytes {
  unsigned char *p;
  size_t len;
  size_t cap;
};

/* tinfl's state and its 32 KiB window, allocated only by an inflater.
 * `held` is output tinfl has already written into the window but the
 * caller has not been given yet, because it would have gone past the
 * output limit; tinfl is not run again until it has all gone out. */
struct inflate_state {
  tinfl_decompressor tinfl;
  unsigned char dict[TINFL_LZ_DICT_SIZE];
  size_t dict_ofs;
  size_t held_ofs;
  size_t held_len;
  int body_done;

  gzip_state gstate;
  unsigned char field[10];
  size_t field_have;
  unsigned flg;
  size_t extra_remaining;
  uint32_t crc;   /* the current gzip member's output CRC-32 */
  uint32_t isize; /* ... and its length, mod 2^32 */
};

struct stream {
  stream_op op;
  stream_format format;
  /* finish() ran, an error did, the stream was closed or collected, or
   * an update/finish is under way (see `begin`): methods now throw. */
  int finished;
  int ended;    /* decoder: the compressed data's end has been seen */
  int more;     /* decoder: the last call stopped at its output limit */

  /* Decoder state. */
  phase ph;
  int members;        /* how many members have ended */
  size_t padding;     /* xz: NUL bytes seen since the last stream ended */
  uint64_t memlimit;  /* xz: the decoder's memory ceiling */
  struct bytes in;    /* input not consumed yet */
  size_t in_pos;
  struct bytes rest;  /* input after the end of the compressed data */
  struct inflate_state *inf;
  int codec_open; /* bz or lzma below is live */
  union {
    bz_stream bz;
    lzma_stream lzma;
  } u;

  /* Encoder state. */
  tdefl_compressor *tdefl;
  int wrote_header;
  uint32_t enc_crc;
  uint32_t enc_isize;
};

/* Where decoded output goes, and how much more of it may go there. */
struct sink {
  luaL_Buffer *b;
  size_t budget;
};

static void sink_add (struct sink *out, const void *p, size_t n) {
  if (n == 0) return;
  luaL_addlstring(out->b, (const char *)p, n);
  out->budget -= n;
}

static int bytes_append (struct bytes *b, const void *data, size_t len) {
  if (len == 0) return 0;
  if (len > SIZE_MAX - b->len) return -1;
  if (b->len + len > b->cap) {
    size_t room = b->cap == 0 ? 256 : b->cap;
    while (room < b->len + len) {
      room = room > SIZE_MAX / 2 ? b->len + len : room * 2;
    }
    unsigned char *grown = cosmic_realloc(b->p, room);
    if (grown == NULL) return -1;
    b->p = grown;
    b->cap = room;
  }
  memcpy(b->p + b->len, data, len);
  b->len += len;
  return 0;
}

static uint32_t le32 (const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static struct stream *checked_stream (lua_State *L) {
  struct stream *s = luaL_checkudata(L, 1, STREAM_TYPE);
  if (s->finished) {
    luaL_error(L, "the stream is finished"); /* throws: a use after the
                                                end is a bug, not a
                                                runtime failure */
  }
  return s;
}

/* The second result of every success: "" in the error slot. */
static int succeeded (lua_State *L) {
  lua_pushliteral(L, "");
  return 2;
}

/* Marks the stream finished for the length of an update or finish. The
 * codec may already have consumed input when a buffer's growth raises
 * on memory, and nothing can say where it stopped, so a raise leaves
 * the stream finished; only a normal return from `update` clears the
 * mark again. */
static void begin (struct stream *s) { s->finished = 1; }

/* Frees the codec's own state; `rest` stays for the caller to read. */
static void release (struct stream *s) {
  cosmic_free(s->tdefl);
  s->tdefl = NULL;
  cosmic_free(s->inf);
  s->inf = NULL;
  cosmic_free(s->in.p);
  memset(&s->in, 0, sizeof s->in);
  s->in_pos = 0;
  s->more = 0;
  if (s->codec_open) {
    if (s->op == OP_BZ2) BZ2_bzDecompressEnd(&s->u.bz);
    if (s->op == OP_XZ) lzma_end(&s->u.lzma);
    s->codec_open = 0;
  }
}

/* Drops the partial output in `out`, finishes the stream, and returns
 * nil, `msg` -- the shape of every decoder failure. Never inlined, so
 * the tests that reach a failure enter this one copy. */
__attribute__((noinline)) static int fail (lua_State *L, struct stream *s, luaL_Buffer *out,
                 const char *msg) {
  luaL_pushresult(out);
  lua_pop(L, 1);
  s->finished = 1;
  s->more = 0;
  release(s);
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

/* ---- tinfl: raw deflate, zlib, and the gzip body ---- */

static int inflate_step (struct stream *s, const unsigned char *p, size_t n,
                         size_t *used, struct sink *out, const char **err) {
  struct inflate_state *f = s->inf;
  /* The gzip body is plain deflate: its framing is parsed here. */
  mz_uint32 flags = TINFL_FLAG_HAS_MORE_INPUT |
                    (s->format == FMT_ZLIB ? TINFL_FLAG_PARSE_ZLIB_HEADER : 0);
  size_t i = 0;
  int starved = 0;
  for (;;) {
    if (f->held_len > 0) {
      size_t k = f->held_len < out->budget ? f->held_len : out->budget;
      sink_add(out, f->dict + f->held_ofs, k);
      f->held_ofs += k;
      f->held_len -= k;
      if (f->held_len > 0) {
        *used = i;
        return STEP_FULL;
      }
    }
    if (f->body_done) {
      *used = i;
      return STEP_END;
    }
    if (starved) {
      *used = i;
      return STEP_INPUT;
    }
    size_t in_size = n - i;
    size_t out_avail = TINFL_LZ_DICT_SIZE - f->dict_ofs;
    tinfl_status status =
        tinfl_decompress(&f->tinfl, p + i, &in_size, f->dict,
                         f->dict + f->dict_ofs, &out_avail, flags);
    i += in_size;
    if (out_avail > 0) {
      if (s->format == FMT_GZIP) {
        f->crc = lzma_crc32(f->dict + f->dict_ofs, out_avail, f->crc);
        f->isize += (uint32_t)out_avail;
      }
      f->held_ofs = f->dict_ofs;
      f->held_len = out_avail;
      f->dict_ofs = (f->dict_ofs + out_avail) & (TINFL_LZ_DICT_SIZE - 1);
    }
    if (status == TINFL_STATUS_DONE) {
      f->body_done = 1;
    } else if (status == TINFL_STATUS_NEEDS_MORE_INPUT) {
      starved = 1; /* tinfl takes every byte offered before asking */
    } else if (status != TINFL_STATUS_HAS_MORE_OUTPUT) {
      *err = "corrupt compressed data";
      return STEP_ERROR;
    }
  }
}

static void inflate_start_body (struct inflate_state *f) {
  tinfl_init(&f->tinfl);
  f->body_done = 0;
  f->crc = 0;
  f->isize = 0;
}

/* Copies bytes toward a fixed-size header field; true once it holds
 * `need` of them. */
static int gzip_collect (struct inflate_state *f, const unsigned char *p,
                         size_t n, size_t *i, size_t need) {
  while (*i < n && f->field_have < need) f->field[f->field_have++] = p[(*i)++];
  return f->field_have == need;
}

/* Moves to whichever optional header part the flags still name, or to
 * the body once none is left. Each part clears its flag when done. */
static void gzip_next (struct inflate_state *f) {
  f->field_have = 0;
  if (f->flg & GZ_FEXTRA) {
    f->gstate = GZ_XLEN;
  } else if (f->flg & GZ_FNAME) {
    f->gstate = GZ_NAME;
  } else if (f->flg & GZ_FCOMMENT) {
    f->gstate = GZ_COMMENT;
  } else if (f->flg & GZ_FHCRC) {
    f->gstate = GZ_HCRC;
  } else {
    f->gstate = GZ_BODY;
    inflate_start_body(f);
  }
}

static int gzip_step (struct stream *s, const unsigned char *p, size_t n,
                      size_t *used, struct sink *out, const char **err) {
  struct inflate_state *f = s->inf;
  size_t i = 0;
  for (;;) {
    switch (f->gstate) {
      case GZ_FIXED:
      if (!gzip_collect(f, p, n, &i, 10)) goto starved;
      if (f->field[2] != 8) {
        *err = "unsupported gzip compression method";
        return STEP_ERROR;
      }
      f->flg = f->field[3];
      gzip_next(f);
      break;
      case GZ_XLEN:
      if (!gzip_collect(f, p, n, &i, 2)) goto starved;
      f->extra_remaining = (size_t)f->field[0] | ((size_t)f->field[1] << 8);
      f->gstate = GZ_EXTRA;
      break;
      case GZ_EXTRA: {
        size_t take = n - i < f->extra_remaining ? n - i : f->extra_remaining;
        i += take;
        f->extra_remaining -= take;
        if (f->extra_remaining > 0) goto starved;
        f->flg &= ~GZ_FEXTRA;
        gzip_next(f);
        break;
      }
      case GZ_NAME:
      case GZ_COMMENT: {
        const unsigned char *nul = i < n ? memchr(p + i, 0, n - i) : NULL;
        if (nul == NULL) {
          i = n;
          goto starved;
        }
        i = (size_t)(nul - p) + 1;
        f->flg &= f->gstate == GZ_NAME ? ~GZ_FNAME : ~GZ_FCOMMENT;
        gzip_next(f);
        break;
      }
      case GZ_HCRC:
      if (!gzip_collect(f, p, n, &i, 2)) goto starved;
      f->flg &= ~GZ_FHCRC;
      gzip_next(f);
      break;
      case GZ_BODY: {
        size_t u = 0;
        int rc = inflate_step(s, p + i, n - i, &u, out, err);
        i += u;
        if (rc != STEP_END) {
          *used = i;
          return rc;
        }
        f->field_have = 0;
        f->gstate = GZ_TRAILER;
        break;
      }
      case GZ_TRAILER:
      if (!gzip_collect(f, p, n, &i, 8)) goto starved;
      if (le32(f->field) != f->crc) {
        *err = "gzip CRC-32 mismatch";
        return STEP_ERROR;
      }
      if (le32(f->field + 4) != f->isize) {
        *err = "gzip size mismatch";
        return STEP_ERROR;
      }
      *used = i;
      return STEP_END;
    }
  }
  starved:
  *used = i;
  return STEP_INPUT;
}

/* ---- bzip2 and xz ---- */

/* The most output one library call is offered at a time. */
#define CODEC_SLICE ((size_t)1 << 16)

static int bz2_step (struct stream *s, const unsigned char *p, size_t n,
                     size_t *used, struct sink *out, const char **err) {
  bz_stream *bz = &s->u.bz;
  size_t i = 0;
  for (;;) {
    if (out->budget == 0) {
      *used = i;
      return STEP_FULL;
    }
    /* bzlib counts in unsigned int: offer a larger chunk in pieces. */
    size_t in_take = n - i < UINT_MAX ? n - i : UINT_MAX;
    size_t out_take = out->budget < CODEC_SLICE ? out->budget : CODEC_SLICE;
    char *dst = luaL_prepbuffsize(out->b, out_take);
    bz->next_in = (char *)(p + i);
    bz->avail_in = (unsigned)in_take;
    bz->next_out = dst;
    bz->avail_out = (unsigned)out_take;
    int rc = BZ2_bzDecompress(bz);
    size_t produced = out_take - bz->avail_out;
    i += in_take - bz->avail_in;
    luaL_addsize(out->b, produced);
    out->budget -= produced;
    if (rc == BZ_STREAM_END) {
      BZ2_bzDecompressEnd(bz);
      s->codec_open = 0;
      *used = i;
      return STEP_END;
    }
    if (rc != BZ_OK) {
      *err = "corrupt bzip2 data";
      return STEP_ERROR;
    }
    if (i == n && produced < out_take) {
      *used = i;
      return STEP_INPUT;
    }
  }
}

static int xz_step (struct stream *s, const unsigned char *p, size_t n,
                    size_t *used, struct sink *out, const char **err) {
  lzma_stream *z = &s->u.lzma;
  size_t i = 0;
  for (;;) {
    if (out->budget == 0) {
      *used = i;
      return STEP_FULL;
    }
    size_t out_take = out->budget < CODEC_SLICE ? out->budget : CODEC_SLICE;
    unsigned char *dst = (unsigned char *)luaL_prepbuffsize(out->b, out_take);
    z->next_in = p + i;
    z->avail_in = n - i;
    z->next_out = dst;
    z->avail_out = out_take;
    lzma_ret rc = lzma_code(z, LZMA_RUN);
    size_t produced = out_take - z->avail_out;
    i = n - z->avail_in;
    luaL_addsize(out->b, produced);
    out->budget -= produced;
    if (rc == LZMA_STREAM_END) {
      *used = i;
      return STEP_END;
    }
    /* LZMA_BUF_ERROR is liblzma saying a call made no progress: with no
     * input left that is just a decoder waiting for more. */
    if (rc == LZMA_BUF_ERROR && i == n) {
      *used = i;
      return STEP_INPUT;
    }
    if (rc != LZMA_OK) {
      *err = rc == LZMA_MEMLIMIT_ERROR ? "xz memory limit exceeded"
             : rc == LZMA_MEM_ERROR    ? "out of memory"
                                       : "corrupt xz data";
      return STEP_ERROR;
    }
    if (i == n && produced < out_take) {
      *used = i;
      return STEP_INPUT;
    }
  }
}

/* ---- members ---- */

/* Whether `p[0..n)` begins the next member: 1 when it does, 0 when it
 * cannot, -1 when too few bytes have arrived to tell. */
static int magic_match (const struct stream *s, const unsigned char *p,
                        size_t n) {
  static const unsigned char gz[] = {0x1f, 0x8b};
  static const unsigned char bz[] = {'B', 'Z', 'h', 0};
  static const unsigned char xz[] = {0xfd, '7', 'z', 'X', 'Z', 0};
  const unsigned char *magic =
      s->op == OP_BZ2 ? bz : s->op == OP_XZ ? xz : gz;
  size_t need = s->op == OP_BZ2 ? 4 : s->op == OP_XZ ? 6 : 2;
  for (size_t k = 0; k < need; k++) {
    if (k == n) return -1;
    if (s->op == OP_BZ2 && k == 3) {
      if (p[k] < '1' || p[k] > '9') return 0;
    } else if (p[k] != magic[k]) {
      return 0;
    }
  }
  return 1;
}

static int start_member (struct stream *s, const char **err) {
  if (s->op == OP_INFLATE) {
    s->inf->gstate = GZ_FIXED;
    s->inf->field_have = 0;
    return 0;
  }
  if (s->op == OP_BZ2) {
    memset(&s->u.bz, 0, sizeof s->u.bz);
    if (BZ2_bzDecompressInit(&s->u.bz, 0, 0) != BZ_OK) {
      *err = "cannot start the bzip2 decoder";
      return -1;
    }
    s->codec_open = 1;
    return 0;
  }
  /* One stream at a time, without LZMA_CONCATENATED: stream padding and
   * what follows the last stream are this file's to judge, the same
   * way gzip and bzip2 members are. Re-initializing a live decoder
   * reuses its memory. */
  if (!s->codec_open) s->u.lzma = (lzma_stream)LZMA_STREAM_INIT;
  lzma_ret rc = lzma_stream_decoder(&s->u.lzma, s->memlimit, 0);
  if (rc != LZMA_OK) {
    *err = rc == LZMA_MEM_ERROR ? "out of memory"
                                : "cannot start the xz decoder";
    return -1;
  }
  s->codec_open = 1;
  return 0;
}

static int member_step (struct stream *s, const unsigned char *p, size_t n,
                        size_t *used, struct sink *out, const char **err) {
  switch (s->op) {
    case OP_BZ2:
    return bz2_step(s, p, n, used, out, err);
    case OP_XZ:
    return xz_step(s, p, n, used, out, err);
    default:
    return s->format == FMT_GZIP ? gzip_step(s, p, n, used, out, err)
                                 : inflate_step(s, p, n, used, out, err);
  }
}

static const char *not_a_stream (const struct stream *s) {
  return s->op == OP_BZ2  ? "not a bzip2 stream"
         : s->op == OP_XZ ? "not an xz stream"
                          : "not a gzip stream";
}

static const char *truncated (const struct stream *s) {
  if (s->op == OP_BZ2) return "truncated bzip2 stream";
  if (s->op == OP_XZ) return "truncated xz stream";
  if (s->format == FMT_GZIP) return "truncated gzip stream";
  return "truncated compressed stream";
}

/* Past the last member: the NUL bytes of an xz stream padding that is
 * not a whole number of four-byte words are not padding, so they are
 * the first bytes of `rest`. */
static int enter_trailing (struct stream *s) {
  static const unsigned char zeros[4] = {0};
  if (s->padding % 4 != 0) {
    for (size_t k = 0; k < s->padding; k += 4) {
      size_t take = s->padding - k < 4 ? s->padding - k : 4;
      if (bytes_append(&s->rest, zeros, take) != 0) return -1;
    }
  }
  s->padding = 0;
  s->ph = PH_TRAILING;
  s->ended = 1;
  return 0;
}

/* Decodes `p[0..n)`, sets `*used` to how much of it was taken, and
 * leaves the rest for the caller to offer again. Stops early, setting
 * `s->more`, when the sink's budget runs out. `at_end` says no input
 * follows, so bytes that might yet have begun a further member are
 * judged now as trailing bytes. Returns -1 with `*err` on failure. */
static int decode (struct stream *s, const unsigned char *p, size_t n,
                   int at_end, struct sink *out, size_t *used,
                   const char **err) {
  size_t i = 0;
  s->more = 0;
  for (;;) {
    if (s->ph == PH_TRAILING) {
      if (bytes_append(&s->rest, p + i, n - i) != 0) goto oom;
      *used = n;
      return 0;
    }
    if (s->ph == PH_MEMBER) {
      size_t u = 0;
      int rc = member_step(s, p + i, n - i, &u, out, err);
      i += u;
      if (rc == STEP_ERROR) return -1;
      if (rc == STEP_END) {
        s->members++;
        if (s->op == OP_INFLATE && s->format != FMT_GZIP) {
          if (enter_trailing(s) != 0) goto oom;
        } else {
          s->ph = PH_BETWEEN;
        }
        continue;
      }
      if (rc == STEP_FULL) s->more = 1;
      *used = i;
      return 0;
    }
    /* PH_BETWEEN */
    if (i == n) {
      *used = i;
      return 0;
    }
    if (s->op == OP_XZ && s->members > 0 && p[i] == 0) {
      s->padding++;
      i++;
      continue;
    }
    int m = magic_match(s, p + i, n - i);
    if (m < 0 && !at_end) {
      *used = i; /* kept, and judged again once more has arrived */
      return 0;
    }
    if (m <= 0) {
      if (s->members == 0) {
        *err = m < 0 ? truncated(s) : not_a_stream(s);
        return -1;
      }
      if (enter_trailing(s) != 0) goto oom;
      continue;
    }
    if (s->padding % 4 != 0) {
      *err = "corrupt xz stream padding";
      return -1;
    }
    s->padding = 0;
    if (start_member(s, err) != 0) return -1;
    s->ph = PH_MEMBER;
  }
  oom:
  *err = "out of memory";
  return -1;
}

/* ---- constructors ---- */

static const char *const format_names[] = {"raw", "zlib", "gzip", NULL};

static struct stream *new_stream (lua_State *L, stream_op op) {
  struct stream *s = lua_newuserdatauv(L, sizeof *s, 0);
  memset(s, 0, sizeof *s);
  luaL_setmetatable(L, STREAM_TYPE);
  s->op = op;
  return s;
}

static int inflater (lua_State *L) {
  stream_format fmt =
      (stream_format)luaL_checkoption(L, 1, NULL, format_names);
  struct stream *s = new_stream(L, OP_INFLATE);
  s->format = fmt;
  s->inf = cosmic_malloc(sizeof *s->inf);
  if (s->inf == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(s->inf, 0, sizeof *s->inf);
  if (fmt == FMT_GZIP) {
    s->ph = PH_BETWEEN;
  } else {
    s->ph = PH_MEMBER;
    inflate_start_body(s->inf);
  }
  return succeeded(L);
}

static int deflater (lua_State *L) {
  stream_format fmt =
      (stream_format)luaL_checkoption(L, 1, NULL, format_names);
  lua_Integer level = luaL_optinteger(L, 2, MZ_DEFAULT_LEVEL);
  luaL_argcheck(L, level >= 0 && level <= 10, 2, "level must be 0 to 10");
  struct stream *s = new_stream(L, OP_DEFLATE);
  s->format = fmt;
  s->tdefl = cosmic_malloc(sizeof(tdefl_compressor));
  if (s->tdefl == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  /* Raw deflate for gzip too: its header and trailer are written by
   * hand, around a plain deflate body. */
  int window_bits = fmt == FMT_ZLIB ? 15 : -15;
  mz_uint flags = tdefl_create_comp_flags_from_zip_params(
      (int)level, window_bits, MZ_DEFAULT_STRATEGY);
  tdefl_init(s->tdefl, NULL, NULL, (int)flags);
  return succeeded(L);
}

static int xz_decoder (lua_State *L) {
  lua_Integer memlimit = luaL_optinteger(L, 1, DEFAULT_XZ_MEMLIMIT);
  luaL_argcheck(L, memlimit > 0, 1, "the memory limit must be positive");
  struct stream *s = new_stream(L, OP_XZ);
  s->memlimit = (uint64_t)memlimit;
  s->ph = PH_BETWEEN;
  return succeeded(L);
}

static int bz2_decoder (lua_State *L) {
  struct stream *s = new_stream(L, OP_BZ2);
  s->ph = PH_BETWEEN;
  return succeeded(L);
}

/* ---- encoder ---- */

/* Compresses `data` (which may be empty, to flush) with `flush`,
 * appending to `out`. */
static void deflate_chunk (struct stream *s, const unsigned char *data,
                           size_t len, tdefl_flush flush, luaL_Buffer *out) {
  unsigned char buffer[8192];
  size_t in_pos = 0;
  for (;;) {
    size_t in_size = len - in_pos;
    size_t out_size = sizeof buffer;
    tdefl_status status = tdefl_compress(s->tdefl, data + in_pos, &in_size,
                                         buffer, &out_size, flush);
    in_pos += in_size;
    luaL_addlstring(out, (const char *)buffer, out_size);
    if (status != TDEFL_STATUS_OKAY) break; /* done, or a bad parameter */
    if (in_pos >= len && out_size < sizeof buffer) break;
  }
}

static void gzip_write_header (struct stream *s, luaL_Buffer *out) {
  static const unsigned char header[10] = {
    0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255,
  };
  if (s->format != FMT_GZIP || s->wrote_header) return;
  luaL_addlstring(out, (const char *)header, sizeof header);
  s->wrote_header = 1;
}

static void push_u32le (luaL_Buffer *out, uint32_t v) {
  unsigned char b[4] = {(unsigned char)(v), (unsigned char)(v >> 8),
    (unsigned char)(v >> 16), (unsigned char)(v >> 24)};
  luaL_addlstring(out, (const char *)b, 4);
}

/* ---- methods ---- */

static int stream_update (lua_State *L) {
  struct stream *s = checked_stream(L);
  size_t len;
  const unsigned char *data =
      (const unsigned char *)luaL_checklstring(L, 2, &len);
  lua_Integer max = luaL_optinteger(L, 3, DEFAULT_MAX_OUT);
  luaL_argcheck(L, max > 0, 3, "the output limit must be positive");
  begin(s);
  luaL_Buffer out;
  luaL_buffinit(L, &out);

  if (s->op == OP_DEFLATE) {
    gzip_write_header(s, &out);
    s->enc_crc = lzma_crc32(data, len, s->enc_crc);
    s->enc_isize += (uint32_t)len;
    deflate_chunk(s, data, len, TDEFL_NO_FLUSH, &out);
    luaL_pushresult(&out);
    lua_pushliteral(L, "");
    s->finished = 0;
    return 2;
  }

  /* With input already waiting, the new chunk joins it; otherwise the
   * chunk is decoded in place and only what is left of it is kept. */
  int backlog = s->in.len > s->in_pos;
  if (backlog && bytes_append(&s->in, data, len) != 0) {
    return fail(L, s, &out, "out of memory");
  }
  const unsigned char *p = backlog ? s->in.p + s->in_pos : data;
  size_t n = backlog ? s->in.len - s->in_pos : len;
  struct sink sink = {&out, (size_t)max};
  size_t used = 0;
  const char *err = NULL;
  if (decode(s, p, n, 0, &sink, &used, &err) != 0) {
    return fail(L, s, &out, err);
  }
  if (backlog) {
    s->in_pos += used;
    if (s->in_pos == s->in.len) {
      s->in.len = s->in_pos = 0;
    } else if (s->in_pos > s->in.len / 2) {
      memmove(s->in.p, s->in.p + s->in_pos, s->in.len - s->in_pos);
      s->in.len -= s->in_pos;
      s->in_pos = 0;
    }
  } else if (used < n) {
    s->in.len = s->in_pos = 0;
    if (bytes_append(&s->in, data + used, n - used) != 0) {
      return fail(L, s, &out, "out of memory");
    }
  }
  luaL_pushresult(&out);
  lua_pushliteral(L, "");
  s->finished = 0;
  return 2;
}

/* A decoder holding output back refuses to finish rather than hand all
 * of it over at once: past the drain, what is left is at most a partial
 * magic, which goes to `rest`, so `finish` never returns a decoder's
 * bulk. */
static int stream_finish (lua_State *L) {
  struct stream *s = checked_stream(L);
  if (s->more) {
    return luaL_error(L, "the stream has pending output: drain it with "
                         "update(\"\") while pending() before finish");
  }
  begin(s);
  luaL_Buffer out;
  luaL_buffinit(L, &out);

  if (s->op == OP_DEFLATE) {
    gzip_write_header(s, &out);
    deflate_chunk(s, NULL, 0, TDEFL_FINISH, &out);
    if (s->format == FMT_GZIP) {
      push_u32le(&out, s->enc_crc);
      push_u32le(&out, s->enc_isize);
    }
    release(s);
    luaL_pushresult(&out);
    return succeeded(L);
  }

  struct sink sink = {&out, SIZE_MAX};
  size_t used = 0;
  const char *err = NULL;
  if (decode(s, s->in.p + s->in_pos, s->in.len - s->in_pos, 1, &sink, &used,
             &err) != 0) {
    return fail(L, s, &out, err);
  }
  if (s->ph == PH_MEMBER) return fail(L, s, &out, truncated(s));
  if (s->ph == PH_BETWEEN) {
    if (s->members == 0) return fail(L, s, &out, truncated(s));
    if (enter_trailing(s) != 0) return fail(L, s, &out, "out of memory");
  }
  release(s);
  luaL_pushresult(&out);
  return succeeded(L);
}

static int stream_done (lua_State *L) {
  struct stream *s = luaL_checkudata(L, 1, STREAM_TYPE);
  lua_pushboolean(L, s->ended);
  return 1;
}

static int stream_pending (lua_State *L) {
  struct stream *s = luaL_checkudata(L, 1, STREAM_TYPE);
  lua_pushboolean(L, s->more);
  return 1;
}

static int stream_rest (lua_State *L) {
  struct stream *s = luaL_checkudata(L, 1, STREAM_TYPE);
  lua_pushlstring(L, s->rest.p == NULL ? "" : (const char *)s->rest.p,
                  s->rest.len);
  return 1;
}

/* `__close`: the stream ends here, as after an error. `rest` stays. */
static int stream_close (lua_State *L) {
  struct stream *s = luaL_checkudata(L, 1, STREAM_TYPE);
  s->finished = 1;
  release(s);
  return 0;
}

/* `__gc`: as `__close`, and `rest` goes too. A finalizer elsewhere can
 * still hand the object back to Lua afterward, so it is left finished:
 * every method that would reach the freed state throws instead. */
static int stream_gc (lua_State *L) {
  struct stream *s = luaL_checkudata(L, 1, STREAM_TYPE);
  s->finished = 1;
  release(s);
  cosmic_free(s->rest.p);
  memset(&s->rest, 0, sizeof s->rest);
  return 0;
}

static int compress_crc32 (lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  lua_Integer crc = luaL_optinteger(L, 2, 0);
  luaL_argcheck(L, crc >= 0 && crc <= 0xffffffff, 2,
                "a CRC-32 is 0 to 0xffffffff");
  uint32_t result =
      lzma_crc32((const uint8_t *)data, len, (uint32_t)crc);
  lua_pushinteger(L, (lua_Integer)result);
  return 1;
}

static const luaL_Reg stream_methods[] = {
  {"update", stream_update}, {"finish", stream_finish},
  {"done", stream_done},     {"pending", stream_pending},
  {"rest", stream_rest},     {NULL, NULL},
};

static const luaL_Reg module[] = {
  {"inflater", inflater},     {"deflater", deflater},
  {"xz_decoder", xz_decoder}, {"bz2_decoder", bz2_decoder},
  {"crc32", compress_crc32},  {NULL, NULL},
};

int cosmic_open_compress (lua_State *L) {
  luaL_newmetatable(L, STREAM_TYPE);
  lua_pushcfunction(L, stream_gc);
  lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, stream_close);
  lua_setfield(L, -2, "__close");
  lua_pushstring(L, STREAM_TYPE);
  lua_setfield(L, -2, "__name");
  lua_newtable(L);
  luaL_setfuncs(L, stream_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, module);
  return 1;
}
