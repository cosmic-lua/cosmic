#include "vector.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"
#include "memory.h"

/* A vector as the functions below read one: its floats, aligned, and
 * whether they were copied (and so are freed with sqlite3_free). Every
 * target cosmic ships is little-endian, so a blob's bytes are the floats
 * themselves. */
struct vector {
  const float *values;
  size_t dims;
  float *owned;
};

/* The most dimensions a vector may have, pgvector's limit: enough for any
 * embedding a model writes, and a bound on what a text may make us
 * allocate. */
#define MAX_DIMS 16000

static void release (struct vector *v) {
  sqlite3_free(v->owned);
  v->owned = NULL;
}

/* Reads `[1, 2.5, -3e-2]`: a JSON array of numbers, nothing else. Each
 * number is read by strtod, which reads no locale, since cosmic never
 * sets one. */
static const char *parse_text (const char *text, struct vector *v) {
  const char *p = text;
  while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
  if (*p != '[') return "a vector's text starts with [";
  p++;
  size_t capacity = 16;
  float *out = sqlite3_malloc64(capacity * sizeof *out);
  if (out == NULL) return "out of memory";
  size_t n = 0;
  for (;;) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p == ']' && n == 0) {
      p++;
      break;
    }
    char *end = NULL;
    double x = strtod(p, &end);
    if (end == p || !isfinite(x)) {
      sqlite3_free(out);
      return "a vector's text holds finite numbers";
    }
    if (n == MAX_DIMS) {
      sqlite3_free(out);
      return "a vector has at most 16000 dimensions";
    }
    if (n == capacity) {
      capacity *= 2;
      float *grown = sqlite3_realloc64(out, capacity * sizeof *out);
      if (grown == NULL) {
        sqlite3_free(out);
        return "out of memory";
      }
      out = grown;
    }
    out[n++] = (float)x;
    p = end;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p == ',') {
      p++;
      continue;
    }
    if (*p == ']') {
      p++;
      break;
    }
    sqlite3_free(out);
    return "a vector's numbers are separated by commas and end with ]";
  }
  while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
  if (*p != '\0') {
    sqlite3_free(out);
    return "nothing may follow a vector's ]";
  }
  v->values = out;
  v->owned = out;
  v->dims = n;
  return NULL;
}

/* Reads argument `value` as a vector, a blob of floats or its text. An
 * error is already the context's result when this answers false. */
static int read_vector (sqlite3_context *ctx, sqlite3_value *value,
                        struct vector *v) {
  v->values = NULL;
  v->owned = NULL;
  v->dims = 0;
  const char *why = NULL;
  switch (sqlite3_value_type(value)) {
    case SQLITE_BLOB: {
      const void *data = sqlite3_value_blob(value);
      size_t len = (size_t)sqlite3_value_bytes(value);
      if (len % sizeof(float) != 0) {
        why = "a vector's blob is a whole number of 4-byte floats";
        break;
      }
      v->dims = len / sizeof(float);
      if (v->dims > MAX_DIMS) {
        why = "a vector has at most 16000 dimensions";
        break;
      }
      if (v->dims == 0) {
        v->values = NULL;
      }
      else if ((uintptr_t)data % _Alignof(float) == 0) {
        v->values = data;
      }
      else {
        v->owned = sqlite3_malloc64(len);
        if (v->owned == NULL) {
          sqlite3_result_error_nomem(ctx);
          return 0;
        }
        memcpy(v->owned, data, len);
        v->values = v->owned;
      }
      break;
    }
    case SQLITE_TEXT: {
      const char *text = (const char *)sqlite3_value_text(value);
      if (text == NULL) {
        sqlite3_result_error_nomem(ctx);
        return 0;
      }
      why = parse_text(text, v);
      break;
    }
    default:
    why = "a vector is a blob of floats or a text like [1,2,3]";
    break;
  }
  if (why != NULL) {
    sqlite3_result_error(ctx, why, -1);
    return 0;
  }
  return 1;
}

/* Reads two vectors of the same dimensions; on false an error is the
 * result and nothing is held. */
static int read_pair (sqlite3_context *ctx, sqlite3_value **argv,
                      struct vector *a, struct vector *b) {
  if (!read_vector(ctx, argv[0], a)) return 0;
  if (!read_vector(ctx, argv[1], b)) {
    release(a);
    return 0;
  }
  if (a->dims != b->dims) {
    release(a);
    release(b);
    sqlite3_result_error(ctx, "the vectors have different dimensions", -1);
    return 0;
  }
  return 1;
}

static int any_null (int argc, sqlite3_value **argv) {
  for (int i = 0; i < argc; i++) {
    if (sqlite3_value_type(argv[i]) == SQLITE_NULL) return 1;
  }
  return 0;
}

/* The kernels keep eight running sums, so the compiler can hold them in
 * vector registers without being allowed to reorder a float sum itself. */
#define LANES 8

static float sum_lanes (const float *s) {
  return ((s[0] + s[1]) + (s[2] + s[3])) + ((s[4] + s[5]) + (s[6] + s[7]));
}

static float dot (const float *a, const float *b, size_t n) {
  float s[LANES] = {0};
  size_t i = 0;
  for (; i + LANES <= n; i += LANES) {
    for (size_t k = 0; k < LANES; k++) s[k] += a[i + k] * b[i + k];
  }
  float total = sum_lanes(s);
  for (; i < n; i++) total += a[i] * b[i];
  return total;
}

static float squared_l2 (const float *a, const float *b, size_t n) {
  float s[LANES] = {0};
  size_t i = 0;
  for (; i + LANES <= n; i += LANES) {
    for (size_t k = 0; k < LANES; k++) {
      float d = a[i + k] - b[i + k];
      s[k] += d * d;
    }
  }
  float total = sum_lanes(s);
  for (; i < n; i++) {
    float d = a[i] - b[i];
    total += d * d;
  }
  return total;
}

static float l1 (const float *a, const float *b, size_t n) {
  float s[LANES] = {0};
  size_t i = 0;
  for (; i + LANES <= n; i += LANES) {
    for (size_t k = 0; k < LANES; k++) s[k] += fabsf(a[i + k] - b[i + k]);
  }
  float total = sum_lanes(s);
  for (; i < n; i++) total += fabsf(a[i] - b[i]);
  return total;
}

static void cosine_parts (const float *a, const float *b, size_t n,
                          float *ab, float *aa, float *bb) {
  float sab[LANES] = {0}, saa[LANES] = {0}, sbb[LANES] = {0};
  size_t i = 0;
  for (; i + LANES <= n; i += LANES) {
    for (size_t k = 0; k < LANES; k++) {
      sab[k] += a[i + k] * b[i + k];
      saa[k] += a[i + k] * a[i + k];
      sbb[k] += b[i + k] * b[i + k];
    }
  }
  *ab = sum_lanes(sab);
  *aa = sum_lanes(saa);
  *bb = sum_lanes(sbb);
  for (; i < n; i++) {
    *ab += a[i] * b[i];
    *aa += a[i] * a[i];
    *bb += b[i] * b[i];
  }
}

static void l2_distance_function (sqlite3_context *ctx, int argc,
                                  sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector a, b;
  if (!read_pair(ctx, argv, &a, &b)) return;
  sqlite3_result_double(ctx, sqrt((double)squared_l2(a.values, b.values,
                                                     a.dims)));
  release(&a);
  release(&b);
}

static void inner_product_function (sqlite3_context *ctx, int argc,
                                    sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector a, b;
  if (!read_pair(ctx, argv, &a, &b)) return;
  sqlite3_result_double(ctx, (double)dot(a.values, b.values, a.dims));
  release(&a);
  release(&b);
}

/* One minus the cosine of the angle between the vectors, from 0 (same
 * direction) to 2 (opposite); NULL where either is all zeros, which has
 * no direction. */
static void cosine_distance_function (sqlite3_context *ctx, int argc,
                                      sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector a, b;
  if (!read_pair(ctx, argv, &a, &b)) return;
  float ab, aa, bb;
  cosine_parts(a.values, b.values, a.dims, &ab, &aa, &bb);
  release(&a);
  release(&b);
  double norms = sqrt((double)aa * (double)bb);
  if (norms == 0.0) {
    sqlite3_result_null(ctx);
    return;
  }
  double similarity = (double)ab / norms;
  /* Rounding can carry the cosine just past 1 or -1. */
  if (similarity > 1.0) similarity = 1.0;
  if (similarity < -1.0) similarity = -1.0;
  sqlite3_result_double(ctx, 1.0 - similarity);
}

static void l1_distance_function (sqlite3_context *ctx, int argc,
                                  sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector a, b;
  if (!read_pair(ctx, argv, &a, &b)) return;
  sqlite3_result_double(ctx, (double)l1(a.values, b.values, a.dims));
  release(&a);
  release(&b);
}

static void result_floats (sqlite3_context *ctx, const float *values,
                           size_t dims) {
  sqlite3_result_blob64(ctx, dims == 0 ? "" : (const void *)values,
                        dims * sizeof(float), SQLITE_TRANSIENT);
}

/* `vector(X)`: X as a blob of floats, so a text is parsed once, where it
 * is stored, rather than in every comparison. */
static void vector_function (sqlite3_context *ctx, int argc,
                             sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector v;
  if (!read_vector(ctx, argv[0], &v)) return;
  result_floats(ctx, v.values, v.dims);
  release(&v);
}

/* `vector_text(X)`: X as `[1,2.5,-3]`, each float written with nine
 * significant digits, which is enough to read back the same float. */
static void vector_text_function (sqlite3_context *ctx, int argc,
                                  sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector v;
  if (!read_vector(ctx, argv[0], &v)) return;
  sqlite3_str *out = sqlite3_str_new(sqlite3_context_db_handle(ctx));
  sqlite3_str_appendchar(out, 1, '[');
  for (size_t i = 0; i < v.dims; i++) {
    if (i > 0) sqlite3_str_appendchar(out, 1, ',');
    sqlite3_str_appendf(out, "%.9g", (double)v.values[i]);
  }
  sqlite3_str_appendchar(out, 1, ']');
  release(&v);
  int rc = sqlite3_str_errcode(out);
  char *text = sqlite3_str_finish(out);
  if (rc != SQLITE_OK || text == NULL) {
    sqlite3_free(text);
    sqlite3_result_error_nomem(ctx);
    return;
  }
  sqlite3_result_text(ctx, text, -1, sqlite3_free);
}

static void vector_dims_function (sqlite3_context *ctx, int argc,
                                  sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector v;
  if (!read_vector(ctx, argv[0], &v)) return;
  sqlite3_result_int64(ctx, (sqlite3_int64)v.dims);
  release(&v);
}

/* `l2_normalize(X)`: X scaled to length 1, so the inner product of two
 * normalized vectors is their cosine; all zeros stays all zeros. */
static void l2_normalize_function (sqlite3_context *ctx, int argc,
                                   sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector v;
  if (!read_vector(ctx, argv[0], &v)) return;
  float *out = sqlite3_malloc64(v.dims * sizeof *out + 1);
  if (out == NULL) {
    release(&v);
    sqlite3_result_error_nomem(ctx);
    return;
  }
  double norm = sqrt((double)dot(v.values, v.values, v.dims));
  for (size_t i = 0; i < v.dims; i++) {
    out[i] = norm == 0.0 ? 0.0f : (float)((double)v.values[i] / norm);
  }
  release(&v);
  sqlite3_result_blob64(ctx, out, v.dims * sizeof *out, sqlite3_free);
}

/* `subvector(X, start, count)`: count of X's dimensions from start,
 * counted from 1, as pgvector's: the head of a Matryoshka embedding is
 * `subvector(X, 1, 256)`. */
static void subvector_function (sqlite3_context *ctx, int argc,
                                sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector v;
  if (!read_vector(ctx, argv[0], &v)) return;
  sqlite3_int64 start = sqlite3_value_int64(argv[1]);
  sqlite3_int64 count = sqlite3_value_int64(argv[2]);
  if (start < 1 || count < 1 || (sqlite3_uint64)start > v.dims
      || (sqlite3_uint64)count > v.dims - (size_t)(start - 1)) {
    release(&v);
    sqlite3_result_error(ctx, "subvector's range is outside the vector", -1);
    return;
  }
  result_floats(ctx, v.values + (start - 1), (size_t)count);
  release(&v);
}

/* `binary_quantize(X)`: one bit per dimension, set where it is above
 * zero, first dimension in the high bit of the first byte, as pgvector's
 * bit type orders them; the last byte is padded with zeros. */
static void binary_quantize_function (sqlite3_context *ctx, int argc,
                                      sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector v;
  if (!read_vector(ctx, argv[0], &v)) return;
  size_t len = (v.dims + 7) / 8;
  unsigned char *bits = sqlite3_malloc64(len + 1);
  if (bits == NULL) {
    release(&v);
    sqlite3_result_error_nomem(ctx);
    return;
  }
  memset(bits, 0, len);
  for (size_t i = 0; i < v.dims; i++) {
    if (v.values[i] > 0.0f) bits[i / 8] |= (unsigned char)(0x80u >> (i % 8));
  }
  release(&v);
  sqlite3_result_blob64(ctx, bits, len, sqlite3_free);
}

/* Reads two bit vectors, blobs of the same length. */
static int read_bits (sqlite3_context *ctx, sqlite3_value **argv,
                      const unsigned char **a, const unsigned char **b,
                      size_t *len) {
  if (sqlite3_value_type(argv[0]) != SQLITE_BLOB
      || sqlite3_value_type(argv[1]) != SQLITE_BLOB) {
    sqlite3_result_error(ctx, "a bit vector is a blob", -1);
    return 0;
  }
  *len = (size_t)sqlite3_value_bytes(argv[0]);
  if ((size_t)sqlite3_value_bytes(argv[1]) != *len) {
    sqlite3_result_error(ctx, "the bit vectors have different lengths", -1);
    return 0;
  }
  *a = sqlite3_value_blob(argv[0]);
  *b = sqlite3_value_blob(argv[1]);
  return 1;
}

static int popcount64 (uint64_t x) {
  return __builtin_popcountll(x);
}

/* Counts the bits set in a & b, a | b and a ^ b, a word at a time. */
static void bit_counts (const unsigned char *a, const unsigned char *b,
                        size_t len, sqlite3_int64 *both, sqlite3_int64 *either,
                        sqlite3_int64 *differ) {
  *both = *either = *differ = 0;
  size_t i = 0;
  for (; i + 8 <= len; i += 8) {
    uint64_t x, y;
    memcpy(&x, a + i, 8);
    memcpy(&y, b + i, 8);
    *both += popcount64(x & y);
    *either += popcount64(x | y);
    *differ += popcount64(x ^ y);
  }
  for (; i < len; i++) {
    *both += popcount64((uint64_t)(a[i] & b[i]));
    *either += popcount64((uint64_t)(a[i] | b[i]));
    *differ += popcount64((uint64_t)(a[i] ^ b[i]));
  }
}

static void hamming_distance_function (sqlite3_context *ctx, int argc,
                                       sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  const unsigned char *a, *b;
  size_t len;
  if (!read_bits(ctx, argv, &a, &b, &len)) return;
  sqlite3_int64 both, either, differ;
  bit_counts(a, b, len, &both, &either, &differ);
  sqlite3_result_int64(ctx, differ);
}

/* One minus the share of set bits the two have in common; 0 for two
 * vectors with no bit set. */
static void jaccard_distance_function (sqlite3_context *ctx, int argc,
                                       sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  const unsigned char *a, *b;
  size_t len;
  if (!read_bits(ctx, argv, &a, &b, &len)) return;
  sqlite3_int64 both, either, differ;
  bit_counts(a, b, len, &both, &either, &differ);
  sqlite3_result_double(ctx, either == 0 ? 0.0
                                         : 1.0 - (double)both / (double)either);
}

struct function {
  const char *name;
  int arity;
  void (*call)(sqlite3_context *, int, sqlite3_value **);
};

/* TODO: pgvector's avg(vector) and sum(vector) aggregates, a centroid in
 * SQL; they wait on a caller that needs one. */
static const struct function functions[] = {
  {"vector", 1, vector_function},
  {"vector_text", 1, vector_text_function},
  {"vector_dims", 1, vector_dims_function},
  {"l2_distance", 2, l2_distance_function},
  {"inner_product", 2, inner_product_function},
  {"cosine_distance", 2, cosine_distance_function},
  {"l1_distance", 2, l1_distance_function},
  {"l2_normalize", 1, l2_normalize_function},
  {"subvector", 3, subvector_function},
  {"binary_quantize", 1, binary_quantize_function},
  {"hamming_distance", 2, hamming_distance_function},
  {"jaccard_distance", 2, jaccard_distance_function},
};

int cosmic_vector_functions (sqlite3 *db) {
  /* Pure arithmetic on their arguments, so innocuous: a database file's
   * own views, generated columns and expression indexes may use them,
   * which is how a stored `binary_quantize(embedding)` is indexed. */
  int rc = SQLITE_OK;
  for (size_t i = 0; rc == SQLITE_OK && i < sizeof functions / sizeof *functions;
       i++) {
    rc = sqlite3_create_function(
        db, functions[i].name, functions[i].arity,
        SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, NULL,
        functions[i].call, NULL, NULL);
  }
  return rc;
}

/* The Lua side: [`cosmic.internal.vector`]. A corpus is a userdata
 * holding its vectors in one buffer, with the id of each and, once a
 * search asks for a binary first pass, a bit vector of each. */

#define CORPUS_TYPE "cosmic.vector.corpus"

struct corpus {
  size_t dims;
  size_t count;
  size_t capacity;
  float *data;         /* count * dims floats */
  float *inverse;      /* 1 / length of each vector, 0 for a zero vector */
  int64_t *ids;
  unsigned char *bits; /* bits_built rows of bytes each, as binary_quantize */
  size_t bits_built;
  size_t bytes;
};

enum metric { INNER_PRODUCT, COSINE, L2 };

static struct corpus *check_corpus (lua_State *L, int arg) {
  return luaL_checkudata(L, arg, CORPUS_TYPE);
}

static int corpus_gc (lua_State *L) {
  struct corpus *c = lua_touserdata(L, 1);
  cosmic_free(c->data);
  cosmic_free(c->inverse);
  cosmic_free(c->ids);
  cosmic_free(c->bits);
  c->data = NULL;
  c->inverse = NULL;
  c->ids = NULL;
  c->bits = NULL;
  return 0;
}

/* Reads argument `arg` as a vector of `dims` floats into a freshly
 * pushed, aligned userdata; raises on another length or a number that
 * is not finite. */
static float *check_floats (lua_State *L, int arg, size_t dims) {
  size_t len;
  const char *s = luaL_checklstring(L, arg, &len);
  luaL_argcheck(L, len == dims * sizeof(float), arg,
                "the vector's length is not the corpus's dimensions");
  float *out = lua_newuserdatauv(L, len + sizeof(float), 0);
  memcpy(out, s, len);
  for (size_t i = 0; i < dims; i++) {
    luaL_argcheck(L, isfinite(out[i]), arg, "a vector holds finite numbers");
  }
  return out;
}

static int vector_corpus (lua_State *L) {
  lua_Integer dims = luaL_checkinteger(L, 1);
  luaL_argcheck(L, dims >= 1 && dims <= MAX_DIMS, 1,
                "dimensions are from 1 to 16000");
  struct corpus *c = lua_newuserdatauv(L, sizeof *c, 0);
  memset(c, 0, sizeof *c);
  c->dims = (size_t)dims;
  c->bytes = ((size_t)dims + 7) / 8;
  luaL_setmetatable(L, CORPUS_TYPE);
  return 1;
}

/* TODO: account the corpus's buffers to the garbage collector, which
 * sees only the userdata header; once the core has a way to charge a
 * block to the collector that is not Lua's own allocator. */
static int corpus_add (lua_State *L) {
  struct corpus *c = check_corpus(L, 1);
  lua_Integer id = luaL_checkinteger(L, 2);
  float *v = check_floats(L, 3, c->dims);
  if (c->count == c->capacity) {
    size_t grown = c->capacity == 0 ? 64 : c->capacity * 2;
    float *data = cosmic_realloc(c->data, grown * c->dims * sizeof *data);
    if (data != NULL) c->data = data;
    float *inverse = cosmic_realloc(c->inverse, grown * sizeof *inverse);
    if (inverse != NULL) c->inverse = inverse;
    int64_t *ids = cosmic_realloc(c->ids, grown * sizeof *ids);
    if (ids != NULL) c->ids = ids;
    if (data == NULL || inverse == NULL || ids == NULL) {
      return luaL_error(L, "out of memory");
    }
    c->capacity = grown;
  }
  memcpy(c->data + c->count * c->dims, v, c->dims * sizeof *v);
  double length = sqrt((double)dot(v, v, c->dims));
  c->inverse[c->count] = length == 0.0 ? 0.0f : (float)(1.0 / length);
  c->ids[c->count] = id;
  c->count++;
  return 0;
}

static int corpus_count (lua_State *L) {
  lua_pushinteger(L, (lua_Integer)check_corpus(L, 1)->count);
  return 1;
}

static void quantize (const float *v, size_t dims, unsigned char *bits) {
  memset(bits, 0, (dims + 7) / 8);
  for (size_t i = 0; i < dims; i++) {
    if (v[i] > 0.0f) bits[i / 8] |= (unsigned char)(0x80u >> (i % 8));
  }
}

/* Brings the bit vectors up to every vector added so far. */
static void ensure_bits (lua_State *L, struct corpus *c) {
  if (c->bits_built == c->count) return;
  unsigned char *grown = cosmic_realloc(c->bits, c->count * c->bytes);
  if (grown == NULL) luaL_error(L, "out of memory");
  c->bits = grown;
  for (size_t i = c->bits_built; i < c->count; i++) {
    quantize(c->data + i * c->dims, c->dims, c->bits + i * c->bytes);
  }
  c->bits_built = c->count;
}

static unsigned hamming (const unsigned char *a, const unsigned char *b,
                         size_t len) {
  unsigned differ = 0;
  size_t i = 0;
  for (; i + 8 <= len; i += 8) {
    uint64_t x, y;
    memcpy(&x, a + i, 8);
    memcpy(&y, b + i, 8);
    differ += (unsigned)popcount64(x ^ y);
  }
  for (; i < len; i++) differ += (unsigned)popcount64((uint64_t)(a[i] ^ b[i]));
  return differ;
}

/* A hit as the heap holds it: higher key is better, and between equal
 * keys the lower id. */
struct hit {
  float key;
  size_t row;
};

struct heap {
  struct hit *items;
  size_t size;
  size_t limit;
  const int64_t *ids;
};

static int better (const struct heap *h, struct hit a, struct hit b) {
  if (a.key != b.key) return a.key > b.key;
  return h->ids[a.row] < h->ids[b.row];
}

/* The heap's root is its worst hit, the one to replace. */
static void sift_down (struct heap *h, size_t at) {
  for (;;) {
    size_t worst = at, l = 2 * at + 1, r = l + 1;
    if (l < h->size && better(h, h->items[worst], h->items[l])) worst = l;
    if (r < h->size && better(h, h->items[worst], h->items[r])) worst = r;
    if (worst == at) return;
    struct hit t = h->items[at];
    h->items[at] = h->items[worst];
    h->items[worst] = t;
    at = worst;
  }
}

static void offer (struct heap *h, struct hit hit) {
  if (h->size < h->limit) {
    size_t at = h->size++;
    h->items[at] = hit;
    while (at > 0) {
      size_t parent = (at - 1) / 2;
      if (!better(h, h->items[parent], h->items[at])) break;
      struct hit t = h->items[at];
      h->items[at] = h->items[parent];
      h->items[parent] = t;
      at = parent;
    }
  }
  else if (h->limit > 0 && better(h, hit, h->items[0])) {
    h->items[0] = hit;
    sift_down(h, 0);
  }
}

static size_t slot_of (int64_t id, size_t slots) {
  return (size_t)(((uint64_t)id * UINT64_C(0x9E3779B97F4A7C15)) >> 20)
         & (slots - 1);
}

/* The table at `index` of ids as a mask over the corpus's rows, in a
 * pushed userdata. Sets `*eligible` to the rows it keeps. */
static unsigned char *allow_mask (lua_State *L, const struct corpus *c,
                                  int index, size_t *eligible) {
  size_t n = lua_rawlen(L, index);
  size_t slots = 16;
  while (slots < 2 * n) slots *= 2;
  size_t key_offset = (slots + 7) / 8 * 8;
  unsigned char *used = lua_newuserdatauv(
      L, key_offset + slots * sizeof(int64_t), 0);
  int64_t *keys = (int64_t *)(void *)(used + key_offset);
  memset(used, 0, slots);
  for (size_t i = 1; i <= n; i++) {
    lua_rawgeti(L, index, (lua_Integer)i);
    int ok;
    lua_Integer id = lua_tointegerx(L, -1, &ok);
    if (!ok) luaL_error(L, "allow holds integers");
    lua_pop(L, 1);
    size_t at = slot_of(id, slots);
    while (used[at] && keys[at] != id) at = (at + 1) & (slots - 1);
    used[at] = 1;
    keys[at] = id;
  }
  unsigned char *mask = lua_newuserdatauv(L, c->count + 1, 0);
  *eligible = 0;
  for (size_t row = 0; row < c->count; row++) {
    int64_t id = c->ids[row];
    size_t at = slot_of(id, slots);
    while (used[at] && keys[at] != id) at = (at + 1) & (slots - 1);
    mask[row] = used[at];
    *eligible += used[at];
  }
  lua_remove(L, -2);
  return mask;
}

/* search(corpus, query, k, metric, candidates, allow): the ids and
 * scores of the k best, best first. */
static int corpus_search (lua_State *L) {
  struct corpus *c = check_corpus(L, 1);
  float *q = check_floats(L, 2, c->dims);
  lua_Integer k = luaL_checkinteger(L, 3);
  luaL_argcheck(L, k >= 1, 3, "k is at least 1");
  const char *name = luaL_checkstring(L, 4);
  enum metric metric;
  if (strcmp(name, "inner_product") == 0) metric = INNER_PRODUCT;
  else if (strcmp(name, "cosine") == 0) metric = COSINE;
  else if (strcmp(name, "l2") == 0) metric = L2;
  else return luaL_argerror(L, 4, "a metric is inner_product, cosine or l2");
  lua_Integer candidates = 0;
  if (!lua_isnoneornil(L, 5)) {
    candidates = luaL_checkinteger(L, 5);
    luaL_argcheck(L, candidates >= 1, 5, "candidates is at least 1");
  }
  unsigned char *mask = NULL;
  size_t eligible = c->count;
  if (!lua_isnoneornil(L, 6)) {
    luaL_checktype(L, 6, LUA_TTABLE);
    mask = allow_mask(L, c, 6, &eligible);
  }

  size_t dims = c->dims;
  double qlen = sqrt((double)dot(q, q, dims));
  float qinverse = qlen == 0.0 ? 0.0f : (float)(1.0 / qlen);

  size_t limit = (size_t)k < eligible ? (size_t)k : eligible;
  struct heap heap = {0};
  heap.items = lua_newuserdatauv(L, (limit + 1) * sizeof *heap.items, 0);
  heap.limit = limit;
  heap.ids = c->ids;

  /* The rows to score: all of them, or the best `candidates` by Hamming
   * distance between the sign bits, the earliest rows among equals. */
  size_t *rows = NULL;
  size_t row_count = c->count;
  if (candidates > 0 && (size_t)candidates < eligible) {
    ensure_bits(L, c);
    unsigned char *qbits = lua_newuserdatauv(L, c->bytes + 1, 0);
    quantize(q, dims, qbits);
    unsigned *histogram = lua_newuserdatauv(
        L, (dims + 1) * sizeof *histogram, 0);
    memset(histogram, 0, (dims + 1) * sizeof *histogram);
    uint16_t *distance = lua_newuserdatauv(
        L, c->count * sizeof *distance + 1, 0);
    for (size_t row = 0; row < c->count; row++) {
      if (mask != NULL && !mask[row]) continue;
      unsigned d = hamming(c->bits + row * c->bytes, qbits, c->bytes);
      distance[row] = (uint16_t)d;
      histogram[d]++;
    }
    size_t below = 0, threshold = 0;
    while (below + histogram[threshold] < (size_t)candidates) {
      below += histogram[threshold++];
    }
    size_t tied = (size_t)candidates - below;
    rows = lua_newuserdatauv(L, (size_t)candidates * sizeof *rows, 0);
    row_count = 0;
    for (size_t row = 0; row < c->count; row++) {
      if (mask != NULL && !mask[row]) continue;
      if (distance[row] < threshold) {
        rows[row_count++] = row;
      }
      else if (distance[row] == threshold && tied > 0) {
        tied--;
        rows[row_count++] = row;
      }
    }
  }

  for (size_t at = 0; at < row_count; at++) {
    size_t row = rows != NULL ? rows[at] : at;
    if (rows == NULL && mask != NULL && !mask[row]) continue;
    const float *v = c->data + row * dims;
    float key;
    switch (metric) {
      case INNER_PRODUCT: key = dot(v, q, dims); break;
      case COSINE: key = dot(v, q, dims) * c->inverse[row] * qinverse; break;
      default: key = -squared_l2(v, q, dims); break;
    }
    struct hit hit = {key, row};
    offer(&heap, hit);
  }

  lua_createtable(L, (int)heap.size, 0);
  int ids = lua_gettop(L);
  lua_createtable(L, (int)heap.size, 0);
  int scores = lua_gettop(L);
  /* Popping the worst first fills the answer from its tail. */
  size_t n = heap.size;
  for (size_t j = 0; j < n; j++) {
    struct hit worst = heap.items[0];
    heap.items[0] = heap.items[--heap.size];
    sift_down(&heap, 0);
    lua_Integer place = (lua_Integer)(n - j);
    lua_pushinteger(L, (lua_Integer)c->ids[worst.row]);
    lua_rawseti(L, ids, place);
    lua_pushnumber(L, metric == L2 ? sqrt(-(double)worst.key)
                                   : (double)worst.key);
    lua_rawseti(L, scores, place);
  }
  return 2;
}

static int vector_pack (lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  size_t n = lua_rawlen(L, 1);
  luaL_argcheck(L, n <= MAX_DIMS, 1, "a vector has at most 16000 dimensions");
  float *out = lua_newuserdatauv(L, n * sizeof *out + 1, 0);
  for (size_t i = 0; i < n; i++) {
    lua_rawgeti(L, 1, (lua_Integer)(i + 1));
    int ok;
    lua_Number x = lua_tonumberx(L, -1, &ok);
    luaL_argcheck(L, ok && isfinite(x), 1, "a vector holds finite numbers");
    out[i] = (float)x;
    lua_pop(L, 1);
  }
  lua_pushlstring(L, (const char *)out, n * sizeof *out);
  return 1;
}

static int vector_unpack (lua_State *L) {
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  luaL_argcheck(L, len % sizeof(float) == 0, 1,
                "a vector is a whole number of 4-byte floats");
  size_t n = len / sizeof(float);
  lua_createtable(L, (int)n, 0);
  for (size_t i = 0; i < n; i++) {
    float x;
    memcpy(&x, s + i * sizeof x, sizeof x);
    lua_pushnumber(L, (lua_Number)x);
    lua_rawseti(L, -2, (lua_Integer)(i + 1));
  }
  return 1;
}

static int vector_from_json (lua_State *L) {
  const char *text = luaL_checkstring(L, 1);
  struct vector v;
  const char *why = parse_text(text, &v);
  if (why != NULL) {
    lua_pushnil(L);
    lua_pushstring(L, why);
    return 2;
  }
  lua_pushlstring(L, (const char *)v.values, v.dims * sizeof(float));
  release(&v);
  return 1;
}

static int vector_normalize (lua_State *L) {
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  luaL_argcheck(L, len % sizeof(float) == 0, 1,
                "a vector is a whole number of 4-byte floats");
  size_t n = len / sizeof(float);
  float *in = lua_newuserdatauv(L, len + sizeof(float), 0);
  memcpy(in, s, len);
  double norm = sqrt((double)dot(in, in, n));
  for (size_t i = 0; i < n; i++) {
    in[i] = norm == 0.0 || !isfinite(norm) ? 0.0f : (float)((double)in[i] / norm);
  }
  lua_pushlstring(L, (const char *)in, len);
  return 1;
}

static const luaL_Reg corpus_methods[] = {
  {"add", corpus_add},
  {"count", corpus_count},
  {"search", corpus_search},
  {NULL, NULL},
};

static const luaL_Reg module[] = {
  {"corpus", vector_corpus},
  {"pack", vector_pack},
  {"unpack", vector_unpack},
  {"from_json", vector_from_json},
  {"normalize", vector_normalize},
  {NULL, NULL},
};

int cosmic_open_vector (lua_State *L) {
  luaL_newmetatable(L, CORPUS_TYPE);
  lua_pushcfunction(L, corpus_gc);
  lua_setfield(L, -2, "__gc");
  lua_newtable(L);
  luaL_setfuncs(L, corpus_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, module);
  return 1;
}
