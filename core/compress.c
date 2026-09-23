#include "compress.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bzlib.h"
#include "lauxlib.h"
#include "lzma.h"
#include "miniz.h"

/* bzlib built with BZ_NO_STDIO asks its embedder to supply this: it is
 * called only for an assertion inside the library itself (a bug in
 * bzlib, never a shape corrupt input can reach -- that comes back as an
 * ordinary BZ_* status code instead), so there is nothing a caller can
 * do but stop. */
void bz_internal_error(int errcode) {
  fprintf(stderr, "cosmic: internal bzip2 library error %d\n", errcode);
  abort();
}

#define STREAM_TYPE "cosmic.compress.stream"

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

/* The gzip header/trailer is parsed by hand, byte by byte across
 * `update` calls; the compressed body between them is handed to tinfl a
 * chunk at a time. */
typedef enum {
  GZ_ID1,
  GZ_ID2,
  GZ_CM,
  GZ_FLG,
  GZ_MTIME,
  GZ_XFL,
  GZ_OS,
  GZ_XLEN,
  GZ_EXTRA,
  GZ_NAME,
  GZ_COMMENT,
  GZ_HCRC,
  GZ_BODY,
  GZ_CRC,
  GZ_ISIZE,
} gzip_state;

struct stream {
  stream_op op;
  stream_format format;
  int finished; /* finish() has run: every method past that point errors */
  int done;     /* decoder: the logical end of the compressed data has been
                   reached; further input is only ever appended to `rest` */
  int errored;  /* a previous call already reported corrupt data */

  /* Decoder state. */
  tinfl_decompressor tinfl;
  unsigned char dict[TINFL_LZ_DICT_SIZE];
  size_t dict_ofs;
  int member_index; /* gzip: how many members have finished so far */
  gzip_state gstate;
  unsigned char field[4];
  int field_have;
  int field_need;
  unsigned flg;
  unsigned extra_remaining;
  mz_uint32 crc;   /* running CRC-32 of the current gzip member's output */
  mz_uint32 isize; /* running byte count of the current gzip member's output,
                       mod 2^32 */
  char *rest;
  size_t rest_len;
  size_t rest_cap;

  /* bzip2 decoder state. `member_index` above doubles as its count of
   * finished streams; `bz_open` says whether `bz` currently holds a
   * live decompressor (false between concatenated streams, and before
   * the first one starts). */
  bz_stream bz;
  int bz_open;

  /* xz decoder state. lzma_stream_decoder is initialized with
   * LZMA_CONCATENATED, so liblzma itself decodes every stream in a
   * multi-stream file and skips stream padding between them; it only
   * ever reports the true end via LZMA_FINISH, which is why `done`
   * here becomes true at `finish` rather than partway through
   * `update` the way gzip and bzip2's do. */
  lzma_stream lzma;
  int lzma_open;

  /* Encoder state. */
  tdefl_compressor *tdefl;
  int wrote_header;
  mz_uint32 enc_crc;
  mz_uint32 enc_isize;
};

static struct stream *checked_stream(lua_State *L) {
  struct stream *s = luaL_checkudata(L, 1, STREAM_TYPE);
  if (s->finished) {
    luaL_error(L, "the stream is finished");
  }
  return s;
}

static int rest_append(struct stream *s, const unsigned char *data,
                       size_t len) {
  if (len == 0) return 0;
  if (s->rest_len + len > s->rest_cap) {
    size_t room = s->rest_cap == 0 ? 256 : s->rest_cap * 2;
    while (room < s->rest_len + len) room *= 2;
    char *grown = realloc(s->rest, room);
    if (grown == NULL) return -1;
    s->rest = grown;
    s->rest_cap = room;
  }
  memcpy(s->rest + s->rest_len, data, len);
  s->rest_len += len;
  return 0;
}

/* Runs tinfl over `data[0..len)`, appending decompressed output to
 * `out` and returning how many input bytes it consumed. `more` says
 * whether more input may follow beyond what is offered here. Sets
 * `*done` when tinfl reaches the end of the deflate stream (and, for
 * zlib, the adler32 has checked out). On corrupt data returns -1 with
 * an error pushed via `errmsg`. */
static long inflate_chunk(struct stream *s, const unsigned char *data,
                          size_t len, int more, luaL_Buffer *out, int *done,
                          const char **errmsg, mz_uint32 *crc,
                          mz_uint32 *isize) {
  size_t in_pos = 0;
  for (;;) {
    size_t in_size = len - in_pos;
    size_t out_avail = TINFL_LZ_DICT_SIZE - s->dict_ofs;
    /* Raw deflate inside a gzip body is fed here too (format is FMT_RAW
     * or FMT_ZLIB at the top level; the gzip body always calls this
     * with the decompressor already reset to a plain deflate stream,
     * so the zlib header flag is never wanted there). */
    unsigned flags =
        (more ? TINFL_FLAG_HAS_MORE_INPUT : 0) |
        (crc == NULL && s->format == FMT_ZLIB ? TINFL_FLAG_PARSE_ZLIB_HEADER
                                              : 0);
    tinfl_status status =
        tinfl_decompress(&s->tinfl, data + in_pos, &in_size, s->dict,
                         s->dict + s->dict_ofs, &out_avail, flags);
    in_pos += in_size;
    if (out_avail > 0) {
      luaL_addlstring(out, (const char *)(s->dict + s->dict_ofs), out_avail);
      if (crc != NULL) {
        *crc = (mz_uint32)mz_crc32(*crc, s->dict + s->dict_ofs, out_avail);
        *isize += (mz_uint32)out_avail;
      }
      s->dict_ofs = (s->dict_ofs + out_avail) & (TINFL_LZ_DICT_SIZE - 1);
    }
    if (status == TINFL_STATUS_DONE) {
      *done = 1;
      return (long)in_pos;
    }
    if (status == TINFL_STATUS_HAS_MORE_OUTPUT) {
      continue; /* the dictionary filled; drain and keep going */
    }
    if (status == TINFL_STATUS_NEEDS_MORE_INPUT) {
      return (long)in_pos; /* caller supplies the rest later */
    }
    *errmsg = "corrupt compressed data";
    return -1;
  }
}

/* Feeds gzip-formatted bytes through the header/body/trailer state
 * machine, decoding all concatenated members. */
static int gzip_feed(struct stream *s, const unsigned char *data, size_t len,
                     int more, luaL_Buffer *out, const char **errmsg) {
  size_t i = 0;
  while (i < len) {
    switch (s->gstate) {
      case GZ_ID1:
        if ((unsigned char)data[i] != 0x1f) {
          if (s->member_index > 0) {
            /* Trailing bytes after at least one full member: not
             * another member, so they are the caller's to keep. */
            if (rest_append(s, data + i, len - i) != 0) {
              *errmsg = "out of memory";
              return -1;
            }
            s->done = 1;
            return 0;
          }
          *errmsg = "not a gzip stream";
          return -1;
        }
        i++;
        s->gstate = GZ_ID2;
        break;
      case GZ_ID2:
        if ((unsigned char)data[i] != 0x8b) {
          *errmsg = "not a gzip stream";
          return -1;
        }
        i++;
        s->gstate = GZ_CM;
        break;
      case GZ_CM:
        if ((unsigned char)data[i] != 8) {
          *errmsg = "unsupported gzip compression method";
          return -1;
        }
        i++;
        s->gstate = GZ_FLG;
        break;
      case GZ_FLG:
        s->flg = (unsigned char)data[i];
        i++;
        s->field_have = 0;
        s->field_need = 4;
        s->gstate = GZ_MTIME;
        break;
      case GZ_MTIME:
        while (i < len && s->field_have < s->field_need) {
          s->field[s->field_have++] = (unsigned char)data[i++];
        }
        if (s->field_have < s->field_need) return 0;
        s->gstate = GZ_XFL;
        break;
      case GZ_XFL:
        i++;
        s->gstate = GZ_OS;
        break;
      case GZ_OS:
        i++;
        if (s->flg & 0x04) { /* FEXTRA */
          s->field_have = 0;
          s->field_need = 2;
          s->gstate = GZ_XLEN;
        } else if (s->flg & 0x08) { /* FNAME */
          s->gstate = GZ_NAME;
        } else if (s->flg & 0x10) { /* FCOMMENT */
          s->gstate = GZ_COMMENT;
        } else if (s->flg & 0x02) { /* FHCRC */
          s->field_have = 0;
          s->field_need = 2;
          s->gstate = GZ_HCRC;
        } else {
          s->gstate = GZ_BODY;
          tinfl_init(&s->tinfl);
          s->crc = MZ_CRC32_INIT;
          s->isize = 0;
        }
        break;
      case GZ_XLEN:
        while (i < len && s->field_have < s->field_need) {
          s->field[s->field_have++] = (unsigned char)data[i++];
        }
        if (s->field_have < s->field_need) return 0;
        s->extra_remaining =
            (unsigned)s->field[0] | ((unsigned)s->field[1] << 8);
        s->gstate = GZ_EXTRA;
        break;
      case GZ_EXTRA: {
        size_t take = len - i;
        if (take > s->extra_remaining) take = s->extra_remaining;
        i += take;
        s->extra_remaining -= (unsigned)take;
        if (s->extra_remaining > 0) return 0;
        if (s->flg & 0x08) {
          s->gstate = GZ_NAME;
        } else if (s->flg & 0x10) {
          s->gstate = GZ_COMMENT;
        } else if (s->flg & 0x02) {
          s->field_have = 0;
          s->field_need = 2;
          s->gstate = GZ_HCRC;
        } else {
          s->gstate = GZ_BODY;
          tinfl_init(&s->tinfl);
          s->crc = MZ_CRC32_INIT;
          s->isize = 0;
        }
        break;
      }
      case GZ_NAME:
        while (i < len && data[i] != 0) i++;
        if (i >= len) return 0; /* the terminator has not arrived yet */
        i++;
        if (s->flg & 0x10) {
          s->gstate = GZ_COMMENT;
        } else if (s->flg & 0x02) {
          s->field_have = 0;
          s->field_need = 2;
          s->gstate = GZ_HCRC;
        } else {
          s->gstate = GZ_BODY;
          tinfl_init(&s->tinfl);
          s->crc = MZ_CRC32_INIT;
          s->isize = 0;
        }
        break;
      case GZ_COMMENT:
        while (i < len && data[i] != 0) i++;
        if (i >= len) return 0;
        i++;
        if (s->flg & 0x02) {
          s->field_have = 0;
          s->field_need = 2;
          s->gstate = GZ_HCRC;
        } else {
          s->gstate = GZ_BODY;
          tinfl_init(&s->tinfl);
          s->crc = MZ_CRC32_INIT;
          s->isize = 0;
        }
        break;
      case GZ_HCRC:
        while (i < len && s->field_have < s->field_need) {
          s->field[s->field_have++] = (unsigned char)data[i++];
        }
        if (s->field_have < s->field_need) return 0;
        s->gstate = GZ_BODY;
        tinfl_init(&s->tinfl);
        s->crc = MZ_CRC32_INIT;
        s->isize = 0;
        break;
      case GZ_BODY: {
        int body_done = 0;
        long used = inflate_chunk(s, data + i, len - i, more, out,
                                  &body_done, errmsg, &s->crc, &s->isize);
        if (used < 0) return -1;
        i += (size_t)used;
        if (body_done) {
          s->field_have = 0;
          s->field_need = 4;
          s->gstate = GZ_CRC;
        } else {
          return 0; /* needs more input for the body */
        }
        break;
      }
      case GZ_CRC:
        while (i < len && s->field_have < s->field_need) {
          s->field[s->field_have++] = (unsigned char)data[i++];
        }
        if (s->field_have < s->field_need) return 0;
        {
          mz_uint32 want = (mz_uint32)s->field[0] |
                           ((mz_uint32)s->field[1] << 8) |
                           ((mz_uint32)s->field[2] << 16) |
                           ((mz_uint32)s->field[3] << 24);
          if (want != s->crc) {
            *errmsg = "gzip CRC-32 mismatch";
            return -1;
          }
        }
        s->field_have = 0;
        s->field_need = 4;
        s->gstate = GZ_ISIZE;
        break;
      case GZ_ISIZE:
        while (i < len && s->field_have < s->field_need) {
          s->field[s->field_have++] = (unsigned char)data[i++];
        }
        if (s->field_have < s->field_need) return 0;
        {
          mz_uint32 want = (mz_uint32)s->field[0] |
                           ((mz_uint32)s->field[1] << 8) |
                           ((mz_uint32)s->field[2] << 16) |
                           ((mz_uint32)s->field[3] << 24);
          if (want != s->isize) {
            *errmsg = "gzip size mismatch";
            return -1;
          }
        }
        s->member_index++;
        s->gstate = GZ_ID1;
        break;
    }
  }
  return 0;
}

static int bz2_open(struct stream *s, const char **errmsg) {
  memset(&s->bz, 0, sizeof s->bz);
  if (BZ2_bzDecompressInit(&s->bz, 0, 0) != BZ_OK) {
    *errmsg = "cannot start the bzip2 decoder";
    return -1;
  }
  s->bz_open = 1;
  return 0;
}

/* Feeds bzip2-compressed bytes through BZ2_bzDecompress, a true
 * push-streaming API, decoding every concatenated stream. Trailing
 * bytes that fail to open as a further stream, once at least one has
 * finished, are treated as the caller's trailer rather than an error --
 * this is only recognized when the whole of a bad magic arrives within
 * one `update` call, since bzlib gives no way to rewind what a fresh
 * decompressor has already consumed. */
static int bz2_feed(struct stream *s, const unsigned char *data, size_t len,
                    luaL_Buffer *out, const char **errmsg) {
  if (!s->bz_open) {
    if (len == 0) return 0;
    /* A fresh attempt right after at least one stream has already
     * finished: a bad magic here is the caller's trailer, not
     * corruption, since bzlib has not consumed anything of this
     * stream's own that would need rewinding. */
    int fresh = s->member_index > 0;
    if (bz2_open(s, errmsg) != 0) return -1;
    s->bz.next_in = (char *)(const void *)data;
    s->bz.avail_in = (unsigned)len;
    unsigned char probe[64];
    s->bz.next_out = (char *)probe;
    s->bz.avail_out = sizeof probe;
    int rc = BZ2_bzDecompress(&s->bz);
    if (rc == BZ_DATA_ERROR_MAGIC && fresh) {
      BZ2_bzDecompressEnd(&s->bz);
      s->bz_open = 0;
      if (rest_append(s, data, len) != 0) {
        *errmsg = "out of memory";
        return -1;
      }
      s->done = 1;
      return 0;
    }
    if (rc != BZ_OK && rc != BZ_STREAM_END) {
      *errmsg = "corrupt bzip2 data";
      return -1;
    }
    if (sizeof probe - s->bz.avail_out > 0) {
      luaL_addlstring(out, (const char *)probe, sizeof probe - s->bz.avail_out);
    }
    if (rc == BZ_STREAM_END) {
      BZ2_bzDecompressEnd(&s->bz);
      s->bz_open = 0;
      s->member_index++;
    }
  } else {
    /* The stream is already under way: hand it this chunk's bytes,
     * carrying forward whatever it left buffered internally. */
    s->bz.next_in = (char *)(const void *)data;
    s->bz.avail_in = (unsigned)len;
  }

  for (;;) {
    if (!s->bz_open) {
      if (s->bz.avail_in == 0) return 0; /* a clean boundary */
      /* Bytes remain from the member just finished: try another one. */
      const char *carry_in = s->bz.next_in;
      unsigned carry_avail = s->bz.avail_in;
      if (bz2_open(s, errmsg) != 0) return -1;
      s->bz.next_in = (char *)carry_in;
      s->bz.avail_in = carry_avail;
    }
    unsigned char buffer[8192];
    s->bz.next_out = (char *)buffer;
    s->bz.avail_out = sizeof buffer;
    int rc = BZ2_bzDecompress(&s->bz);
    size_t produced = sizeof buffer - s->bz.avail_out;
    if (produced > 0) luaL_addlstring(out, (const char *)buffer, produced);
    if (rc == BZ_STREAM_END) {
      BZ2_bzDecompressEnd(&s->bz);
      s->bz_open = 0;
      s->member_index++;
      if (s->bz.avail_in == 0) return 0;
      continue; /* more bytes carry into a further member */
    }
    if (rc == BZ_OK) {
      if (s->bz.avail_in == 0 && produced < sizeof buffer) return 0;
      continue;
    }
    *errmsg = "corrupt bzip2 data";
    return -1;
  }
}

/* Feeds .xz bytes through lzma_code with LZMA_RUN, opening the decoder
 * on the first call. Draining is bounded the same way inflate_chunk and
 * bz2_feed's are: loop until input is exhausted and the output buffer
 * did not fill, so a large chunk still returns in bounded memory. */
static int xz_feed(struct stream *s, const unsigned char *data, size_t len,
                   luaL_Buffer *out, const char **errmsg) {
  if (!s->lzma_open) {
    s->lzma = (lzma_stream)LZMA_STREAM_INIT;
    if (lzma_stream_decoder(&s->lzma, UINT64_MAX, LZMA_CONCATENATED) !=
        LZMA_OK) {
      *errmsg = "cannot start the xz decoder";
      return -1;
    }
    s->lzma_open = 1;
  }
  s->lzma.next_in = data;
  s->lzma.avail_in = len;
  for (;;) {
    unsigned char buffer[8192];
    s->lzma.next_out = buffer;
    s->lzma.avail_out = sizeof buffer;
    lzma_ret rc = lzma_code(&s->lzma, LZMA_RUN);
    size_t produced = sizeof buffer - s->lzma.avail_out;
    if (produced > 0) luaL_addlstring(out, (const char *)buffer, produced);
    if (rc == LZMA_STREAM_END) return 0; /* finish() confirms this cleanly */
    if (rc != LZMA_OK) {
      *errmsg = "corrupt xz data";
      return -1;
    }
    if (s->lzma.avail_in == 0 && produced < sizeof buffer) return 0;
  }
}

static int inflater(lua_State *L) {
  const char *format = luaL_checkstring(L, 1);
  stream_format fmt;
  if (strcmp(format, "raw") == 0) {
    fmt = FMT_RAW;
  } else if (strcmp(format, "zlib") == 0) {
    fmt = FMT_ZLIB;
  } else if (strcmp(format, "gzip") == 0) {
    fmt = FMT_GZIP;
  } else {
    lua_pushnil(L);
    lua_pushstring(L, "unknown format");
    return 2;
  }
  struct stream *s = lua_newuserdatauv(L, sizeof *s, 0);
  memset(s, 0, sizeof *s);
  luaL_setmetatable(L, STREAM_TYPE);
  s->op = OP_INFLATE;
  s->format = fmt;
  tinfl_init(&s->tinfl);
  s->gstate = GZ_ID1;
  return 1;
}

static int deflater(lua_State *L) {
  const char *format = luaL_checkstring(L, 1);
  lua_Integer level = luaL_optinteger(L, 2, MZ_DEFAULT_LEVEL);
  stream_format fmt;
  if (strcmp(format, "raw") == 0) {
    fmt = FMT_RAW;
  } else if (strcmp(format, "zlib") == 0) {
    fmt = FMT_ZLIB;
  } else if (strcmp(format, "gzip") == 0) {
    fmt = FMT_GZIP;
  } else {
    lua_pushnil(L);
    lua_pushstring(L, "unknown format");
    return 2;
  }
  if (level < 0) level = 0;
  if (level > 10) level = 10;
  struct stream *s = lua_newuserdatauv(L, sizeof *s, 0);
  memset(s, 0, sizeof *s);
  luaL_setmetatable(L, STREAM_TYPE);
  s->op = OP_DEFLATE;
  s->format = fmt;
  s->tdefl = malloc(sizeof(tdefl_compressor));
  if (s->tdefl == NULL) {
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  /* Raw deflate for gzip too: its header and trailer are written by
   * hand, around a plain deflate body. */
  int window_bits = fmt == FMT_ZLIB ? 15 : -15;
  mz_uint flags =
      tdefl_create_comp_flags_from_zip_params((int)level, window_bits,
                                              MZ_DEFAULT_STRATEGY);
  tdefl_init(s->tdefl, NULL, NULL, (int)flags);
  s->enc_crc = MZ_CRC32_INIT;
  s->enc_isize = 0;
  return 1;
}

/* Compresses `data` (which may be empty, to flush) with `flush`,
 * appending to `out`. */
static void deflate_chunk(struct stream *s, const unsigned char *data,
                          size_t len, tdefl_flush flush, luaL_Buffer *out) {
  unsigned char buffer[8192];
  size_t in_pos = 0;
  for (;;) {
    size_t in_size = len - in_pos;
    size_t out_size = sizeof buffer;
    tdefl_status status = tdefl_compress(s->tdefl, data + in_pos, &in_size,
                                         buffer, &out_size, flush);
    in_pos += in_size;
    if (out_size > 0) {
      luaL_addlstring(out, (const char *)buffer, out_size);
    }
    if (status != TDEFL_STATUS_OKAY) break; /* done, or a bad parameter */
    if (in_pos >= len && out_size < sizeof buffer) {
      break; /* every input byte consumed, nothing more pending */
    }
  }
}

static void gzip_write_header(luaL_Buffer *out) {
  static const unsigned char header[10] = {
      0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255,
  };
  luaL_addlstring(out, (const char *)header, sizeof header);
}

static void push_u32le(luaL_Buffer *out, mz_uint32 v) {
  unsigned char b[4] = {(unsigned char)(v), (unsigned char)(v >> 8),
                        (unsigned char)(v >> 16), (unsigned char)(v >> 24)};
  luaL_addlstring(out, (const char *)b, 4);
}

static int stream_update(lua_State *L) {
  struct stream *s = checked_stream(L);
  size_t len;
  const char *data = luaL_checklstring(L, 2, &len);
  luaL_Buffer out;
  luaL_buffinit(L, &out);

  if (s->op == OP_DEFLATE) {
    if (s->format == FMT_GZIP && !s->wrote_header) {
      gzip_write_header(&out);
      s->wrote_header = 1;
    }
    if (len > 0) {
      s->enc_crc = mz_crc32(s->enc_crc, (const unsigned char *)data, len);
      s->enc_isize += (mz_uint32)len;
    }
    deflate_chunk(s, (const unsigned char *)data, len, TDEFL_NO_FLUSH, &out);
    luaL_pushresult(&out);
    return 1;
  }

  if (s->done) {
    if (rest_append(s, (const unsigned char *)data, len) != 0) {
      return luaL_error(L, "out of memory");
    }
    luaL_pushresult(&out);
    return 1;
  }

  if (s->op == OP_BZ2) {
    const char *err = NULL;
    int rc = bz2_feed(s, (const unsigned char *)data, len, &out, &err);
    if (rc != 0) {
      luaL_pushresult(&out);
      lua_pop(L, 1);
      s->errored = 1;
      s->finished = 1;
      lua_pushnil(L);
      lua_pushstring(L, err != NULL ? err : "corrupt bzip2 data");
      return 2;
    }
    luaL_pushresult(&out);
    return 1;
  }

  if (s->op == OP_XZ) {
    const char *err = NULL;
    int rc = xz_feed(s, (const unsigned char *)data, len, &out, &err);
    if (rc != 0) {
      luaL_pushresult(&out);
      lua_pop(L, 1);
      s->errored = 1;
      s->finished = 1;
      lua_pushnil(L);
      lua_pushstring(L, err != NULL ? err : "corrupt xz data");
      return 2;
    }
    luaL_pushresult(&out);
    return 1;
  }

  const char *errmsg = NULL;
  if (s->format == FMT_GZIP) {
    /* The gzip body's CRC-32 and byte count are accumulated inside
     * inflate_chunk as it produces output (see its crc/isize
     * parameters), since luaL_Buffer gives no way to read back what
     * was just appended. */
    const char *err = NULL;
    int rc = gzip_feed(s, (const unsigned char *)data, len, 1, &out, &err);
    if (rc != 0) {
      luaL_pushresult(&out);
      lua_pop(L, 1);
      s->errored = 1;
      s->finished = 1;
      lua_pushnil(L);
      lua_pushstring(L, err != NULL ? err : "corrupt compressed data");
      return 2;
    }
    luaL_pushresult(&out);
    return 1;
  }

  int done = 0;
  long used = inflate_chunk(s, (const unsigned char *)data, len, 1, &out,
                            &done, &errmsg, NULL, NULL);
  if (used < 0) {
    luaL_pushresult(&out);
    lua_pop(L, 1);
    s->errored = 1;
    s->finished = 1;
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  if (done) {
    s->done = 1;
    if ((size_t)used < len) {
      if (rest_append(s, (const unsigned char *)data + used, len - used) !=
          0) {
        luaL_pushresult(&out);
        lua_pop(L, 1);
        return luaL_error(L, "out of memory");
      }
    }
  }
  luaL_pushresult(&out);
  return 1;
}

static int stream_finish(lua_State *L) {
  struct stream *s = checked_stream(L);
  luaL_Buffer out;
  luaL_buffinit(L, &out);

  if (s->op == OP_DEFLATE) {
    if (s->format == FMT_GZIP && !s->wrote_header) {
      gzip_write_header(&out);
      s->wrote_header = 1;
    }
    deflate_chunk(s, NULL, 0, TDEFL_FINISH, &out);
    if (s->format == FMT_GZIP) {
      push_u32le(&out, s->enc_crc);
      push_u32le(&out, s->enc_isize);
    }
    free(s->tdefl);
    s->tdefl = NULL;
    s->finished = 1;
    luaL_pushresult(&out);
    return 1;
  }

  if (s->done) {
    s->finished = 1;
    luaL_pushresult(&out);
    return 1;
  }

  if (s->op == OP_BZ2) {
    s->finished = 1;
    /* A clean finish is a closed decompressor with no carried-over
     * bytes waiting on a further member. */
    if (s->bz_open || s->member_index == 0) {
      if (s->bz_open) BZ2_bzDecompressEnd(&s->bz);
      s->bz_open = 0;
      luaL_pushresult(&out);
      lua_pop(L, 1);
      lua_pushnil(L);
      lua_pushstring(L, "truncated bzip2 stream");
      return 2;
    }
    s->done = 1;
    luaL_pushresult(&out);
    return 1;
  }

  if (s->op == OP_XZ) {
    s->finished = 1;
    if (!s->lzma_open) {
      luaL_pushresult(&out);
      lua_pop(L, 1);
      lua_pushnil(L);
      lua_pushstring(L, "truncated xz stream");
      return 2;
    }
    s->lzma.next_in = NULL;
    s->lzma.avail_in = 0;
    for (;;) {
      unsigned char buffer[8192];
      s->lzma.next_out = buffer;
      s->lzma.avail_out = sizeof buffer;
      lzma_ret rc = lzma_code(&s->lzma, LZMA_FINISH);
      size_t produced = sizeof buffer - s->lzma.avail_out;
      if (produced > 0) luaL_addlstring(&out, (const char *)buffer, produced);
      if (rc == LZMA_STREAM_END) {
        lzma_end(&s->lzma);
        s->lzma_open = 0;
        s->done = 1;
        luaL_pushresult(&out);
        return 1;
      }
      if (rc != LZMA_OK) {
        lzma_end(&s->lzma);
        s->lzma_open = 0;
        luaL_pushresult(&out);
        lua_pop(L, 1);
        lua_pushnil(L);
        lua_pushstring(L, "truncated xz stream");
        return 2;
      }
    }
  }

  const char *errmsg = NULL;
  if (s->format == FMT_GZIP) {
    int rc = gzip_feed(s, (const unsigned char *)"", 0, 0, &out, &errmsg);
    (void)rc;
    /* A clean finish sits exactly at the start of a would-be next
     * member, with no bytes committed toward it. Anything else is a
     * stream that stopped mid-way through. */
    if (s->gstate != GZ_ID1 || s->member_index == 0) {
      luaL_pushresult(&out);
      lua_pop(L, 1);
      s->finished = 1;
      lua_pushnil(L);
      lua_pushstring(L, "truncated gzip stream");
      return 2;
    }
    s->done = 1;
    s->finished = 1;
    luaL_pushresult(&out);
    return 1;
  }

  int done = 0;
  long used = inflate_chunk(s, (const unsigned char *)"", 0, 0, &out, &done,
                            &errmsg, NULL, NULL);
  s->finished = 1;
  if (used < 0) {
    luaL_pushresult(&out);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, errmsg);
    return 2;
  }
  if (!done) {
    luaL_pushresult(&out);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, "truncated compressed stream");
    return 2;
  }
  s->done = 1;
  luaL_pushresult(&out);
  return 1;
}

static int stream_done(lua_State *L) {
  struct stream *s = luaL_checkudata(L, 1, STREAM_TYPE);
  lua_pushboolean(L, s->done);
  return 1;
}

static int stream_rest(lua_State *L) {
  struct stream *s = luaL_checkudata(L, 1, STREAM_TYPE);
  lua_pushlstring(L, s->rest == NULL ? "" : s->rest, s->rest_len);
  return 1;
}

static int stream_gc(lua_State *L) {
  struct stream *s = luaL_checkudata(L, 1, STREAM_TYPE);
  free(s->tdefl);
  s->tdefl = NULL;
  free(s->rest);
  s->rest = NULL;
  if (s->bz_open) {
    BZ2_bzDecompressEnd(&s->bz);
    s->bz_open = 0;
  }
  if (s->lzma_open) {
    lzma_end(&s->lzma);
    s->lzma_open = 0;
  }
  return 0;
}

static int compress_crc32(lua_State *L) {
  size_t len;
  const char *data = luaL_checklstring(L, 1, &len);
  lua_Integer crc = luaL_optinteger(L, 2, MZ_CRC32_INIT);
  mz_ulong result =
      mz_crc32((mz_ulong)crc, (const unsigned char *)data, len);
  lua_pushinteger(L, (lua_Integer)result);
  return 1;
}

static const luaL_Reg stream_methods[] = {
    {"update", stream_update}, {"finish", stream_finish},
    {"done", stream_done},     {"rest", stream_rest},
    {NULL, NULL},
};

static int xz_decoder(lua_State *L) {
  struct stream *s = lua_newuserdatauv(L, sizeof *s, 0);
  memset(s, 0, sizeof *s);
  luaL_setmetatable(L, STREAM_TYPE);
  s->op = OP_XZ;
  return 1;
}

static int bz2_decoder(lua_State *L) {
  struct stream *s = lua_newuserdatauv(L, sizeof *s, 0);
  memset(s, 0, sizeof *s);
  luaL_setmetatable(L, STREAM_TYPE);
  s->op = OP_BZ2;
  return 1;
}

static const luaL_Reg module[] = {
    {"inflater", inflater},
    {"deflater", deflater},
    {"xz_decoder", xz_decoder},
    {"bz2_decoder", bz2_decoder},
    {"crc32", compress_crc32},
    {NULL, NULL},
};

int cosmic_open_compress(lua_State *L) {
  luaL_newmetatable(L, STREAM_TYPE);
  lua_pushcfunction(L, stream_gc);
  lua_setfield(L, -2, "__gc");
  lua_pushstring(L, STREAM_TYPE);
  lua_setfield(L, -2, "__name");
  lua_newtable(L);
  luaL_setfuncs(L, stream_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_newlib(L, module);
  return 1;
}
