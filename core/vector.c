#include "vector.h"

#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* The functions are DETERMINISTIC and may back an expression index, so a
 * result must not depend on whether the compiler fused a*b+c into one
 * rounding. */
#pragma STDC FP_CONTRACT OFF

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

/* Reads `[1, 2.5, -3e-2]`: a bracketed, comma-separated list of numbers.
 * Each number is read by strtod, which reads no locale, since cosmic
 * never sets one, and so is more lenient than JSON: it also takes a
 * leading `+`, `.5`, `1.` and hexadecimal floats. A number must be finite
 * as a float, and there must be at least one. */
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
      sqlite3_free(out);
      return "a vector has at least 1 dimension";
    }
    char *end = NULL;
    double x = strtod(p, &end);
    if (end == p || !isfinite(x) || !isfinite((float)x)) {
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
      /* The length first: for a zeroblob it is reported without
       * expanding the blob, and the expansion is what can fail. */
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
        why = "a vector has at least 1 dimension";
        break;
      }
      const void *data = sqlite3_value_blob(value);
      if (data == NULL) {
        /* A zeroblob that could not be expanded; the length said it
         * is not empty. */
        v->dims = 0;
        sqlite3_result_error_nomem(ctx);
        return 0;
      }
      if ((uintptr_t)data % _Alignof(float) == 0) {
        v->values = data;
      }
      else {
        /* SQLite's own values are malloc'd, so aligned: a table column is
         * copied out of its page (OP_Column), and a bound or computed
         * blob is held in a block of its own. This is for a virtual
         * table that answers a static blob at an odd offset, which no
         * SQL in the tree reaches (cosmic/vector_sql_test.tl says so). */
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
 * is stored, rather than in every comparison. It is also where a blob is
 * checked for NaN and infinity: the distance functions do not look, to
 * keep a scan fast, and give NaN for a vector that holds one. */
static void vector_function (sqlite3_context *ctx, int argc,
                             sqlite3_value **argv) {
  if (any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector v;
  if (!read_vector(ctx, argv[0], &v)) return;
  for (size_t i = 0; i < v.dims; i++) {
    if (!isfinite(v.values[i])) {
      release(&v);
      sqlite3_result_error(ctx, "a vector holds finite numbers", -1);
      return;
    }
  }
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
    if (rc != SQLITE_OK) sqlite3_result_error_code(ctx, rc);
    else sqlite3_result_error_nomem(ctx);
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
  /* Summed in double: the squares of small floats underflow, and of
   * large ones overflow, in float. */
  double squares = 0.0;
  for (size_t i = 0; i < v.dims; i++) {
    squares += (double)v.values[i] * (double)v.values[i];
  }
  double norm = sqrt(squares);
  for (size_t i = 0; i < v.dims; i++) {
    out[i] = norm == 0.0 ? 0.0f : (float)((double)v.values[i] / norm);
  }
  release(&v);
  sqlite3_result_blob64(ctx, out, v.dims * sizeof *out, sqlite3_free);
}

/* `subvector(X, start, count)`: count of X's dimensions from start,
 * counted from 1, as pgvector's: the head of a Matryoshka embedding is
 * `subvector(X, 1, 256)`. The range is clipped to X as SQL's substring
 * clips it: a start below 1 counts from 1 but still uses up count for
 * the dimensions before it, and a count past the end stops at the end.
 * Only a range that leaves no dimension is an error. */
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
  /* The half-open range [first, last) of 1-based dimensions, clipped to
   * [1, dims + 1) without overflowing start + count. */
  sqlite3_int64 first = start, last;
  if (count < 1) last = first;
  else if (start > INT64_MAX - count) last = INT64_MAX;
  else last = start + count;
  if (first < 1) first = 1;
  if (last > (sqlite3_int64)v.dims + 1) last = (sqlite3_int64)v.dims + 1;
  if (last <= first) {
    release(&v);
    sqlite3_result_error(ctx, "a vector has at least 1 dimension", -1);
    return;
  }
  result_floats(ctx, v.values + (first - 1), (size_t)(last - first));
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

/* Reads two bit vectors, blobs of the same length. They are compared by
 * their bytes alone, so a vector of 9 bits and one of 16 are the same
 * length. */
static int read_bits (sqlite3_context *ctx, sqlite3_value **argv,
                      const unsigned char **a, const unsigned char **b,
                      size_t *len) {
  if (sqlite3_value_type(argv[0]) != SQLITE_BLOB
      || sqlite3_value_type(argv[1]) != SQLITE_BLOB) {
    sqlite3_result_error(ctx, "a bit vector is a blob", -1);
    return 0;
  }
  /* The blob first, then its length: fetching a zeroblob expands it,
   * which can fail, leaving NULL beside a length above zero. */
  *a = sqlite3_value_blob(argv[0]);
  size_t len_a = (size_t)sqlite3_value_bytes(argv[0]);
  *b = sqlite3_value_blob(argv[1]);
  size_t len_b = (size_t)sqlite3_value_bytes(argv[1]);
  if ((*a == NULL && len_a > 0) || (*b == NULL && len_b > 0)) {
    sqlite3_result_error_nomem(ctx);
    return 0;
  }
  if (len_a != len_b) {
    sqlite3_result_error(ctx, "the bit vectors have different lengths", -1);
    return 0;
  }
  *len = len_a;
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
  for (size_t i = 0; i < sizeof functions / sizeof *functions; i++) {
    int rc = sqlite3_create_function(
        db, functions[i].name, functions[i].arity,
        SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, NULL,
        functions[i].call, NULL, NULL);
    if (rc != SQLITE_OK) return rc;
  }
  return SQLITE_OK;
}
