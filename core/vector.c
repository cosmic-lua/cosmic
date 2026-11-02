#include "vector.h"

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "guard.h"
#include "memory.h"
#include "lauxlib.h"
#include "process.h"
#include "sqlite.h"

#if defined(__x86_64__)
#include <cpuid.h>
#include <immintrin.h>
#define INT8_VNNI 1
#endif

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

/* What [`read_value`] answers for memory the allocator refused, in place of
 * a message. */
static const char out_of_memory[] = "out of memory";

/* Reads `value` as a vector, a blob of floats or its text. Answers NULL,
 * or why it is not one: `out_of_memory`, or a message. Nothing is held
 * on an answer. */
static const char *read_value (sqlite3_value *value, struct vector *v) {
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
        return out_of_memory;
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
        if (v->owned == NULL) return out_of_memory;
        memcpy(v->owned, data, len);
        v->values = v->owned;
      }
      break;
    }
    case SQLITE_TEXT: {
      const char *text = (const char *)sqlite3_value_text(value);
      if (text == NULL) return out_of_memory;
      /* The parser reads to the first NUL, so a text with one would be
       * read as only its head: `[1]` NUL junk is not the vector `[1]`. */
      if (strlen(text) != (size_t)sqlite3_value_bytes(value)) {
        why = "a vector's text holds no NUL";
        break;
      }
      why = parse_text(text, v);
      break;
    }
    default:
    why = "a vector is a blob of floats or a text like [1,2,3]";
    break;
  }
  return why;
}

/* Reads argument `value` as a vector, a blob of floats or its text. An
 * error is already the context's result when this answers false. */
static int read_vector (sqlite3_context *ctx, sqlite3_value *value,
                        struct vector *v) {
  const char *why = read_value(value, v);
  if (why == out_of_memory) {
    sqlite3_result_error_nomem(ctx);
    return 0;
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

/* The corpus's stored forms. A half is widened to a float in a register
 * and summed in the same eight lanes as above; the widening is exact, so
 * the sums are those of the floats the halves stand for. The lanes are
 * written as vectors: the loops above, with a half read in each, are
 * vectorized as eight scalar chains and shuffled into place. */
typedef float lanes_f __attribute__((vector_size(LANES * sizeof(float))));
typedef _Float16 lanes_h __attribute__((vector_size(LANES * sizeof(_Float16))));

static float sum_vector (lanes_f v) {
  float s[LANES];
  memcpy(s, &v, sizeof s);
  return sum_lanes(s);
}

static lanes_f load_f (const float *p) {
  lanes_f v;
  memcpy(&v, p, sizeof v);
  return v;
}

static lanes_f load_h (const _Float16 *p) {
  lanes_h h;
  memcpy(&h, p, sizeof h);
  return __builtin_convertvector(h, lanes_f);
}

static float dot_f16 (const _Float16 *a, const float *b, size_t n) {
  lanes_f s = {0};
  size_t i = 0;
  for (; i + LANES <= n; i += LANES) s += load_h(a + i) * load_f(b + i);
  float total = sum_vector(s);
  for (; i < n; i++) total += (float)a[i] * b[i];
  return total;
}

static float squared_l2_f16 (const _Float16 *a, const float *b, size_t n) {
  lanes_f s = {0};
  size_t i = 0;
  for (; i + LANES <= n; i += LANES) {
    lanes_f d = load_h(a + i) - load_f(b + i);
    s += d * d;
  }
  float total = sum_vector(s);
  for (; i < n; i++) {
    float d = (float)a[i] - b[i];
    total += d * d;
  }
  return total;
}

/* The int8 dot product of a row and the query. `biased` is the query's
 * codes plus 128, as unsigned bytes, and `sum` the sum of the row's codes:
 * VNNI multiplies an unsigned operand by a signed one, and
 * sum(row * query) = sum(row * (query + 128)) - 128 * sum(row).
 *
 * The integer sums are exact, so every kernel answers the same, whatever
 * order it sums in. They cannot overflow 32 bits: 16000 * 127 * 127 <
 * 2^31, and with the query biased by 128, below 16000 * 255 * 127. The
 * correction is unsigned arithmetic, which wraps: a `sum` that is not the
 * sum of the row's codes (a block made by hand lies about it) scores that
 * row wrongly, and by a kernel's own measure, but is not undefined. */
typedef int32_t (*dot_i8_fn) (const int8_t *row, int32_t sum, const int8_t *codes,
                              const uint8_t *biased, size_t n);

/* TODO: once a caller runs int8 corpora on x86-64 hosts without VNNI: the
 * compiler makes this loop 128-bit `vpmaddwd`s, and a 256-bit loop of
 * intrinsics measured about 20% faster at 768 dimensions in cache (130
 * against 156 ns a row). Write that loop under `__AVX2__`. */
static int32_t dot_i8_generic (const int8_t *row, int32_t sum, const int8_t *codes,
                               const uint8_t *biased, size_t n) {
  (void)sum;
  (void)biased;
  int32_t total = 0;
  for (size_t i = 0; i < n; i++) total += (int32_t)row[i] * (int32_t)codes[i];
  return total;
}

#ifdef INT8_VNNI
/* VNNI multiplies 32 unsigned bytes by 32 signed ones and adds each four
 * products into a 32-bit lane in one instruction. It comes in two
 * encodings of the same operation: AVX-512 VNNI with the 256-bit forms of
 * AVX-512 VL (Skylake-SP and Cascade Lake servers onward), and AVX-VNNI
 * (Alder Lake and Sapphire Rapids onward). The 512-bit form scans no
 * faster: the scan is bound by memory. */
__attribute__((target("avx512f,avx512vl,avx512vnni")))
static int32_t dot_i8_avx512_vnni (const int8_t *row, int32_t sum, const int8_t *codes,
                                   const uint8_t *biased, size_t n) {
  (void)codes;
  __m256i first = _mm256_setzero_si256(), second = _mm256_setzero_si256();
  size_t i = 0;
  for (; i + 64 <= n; i += 64) {
    first = _mm256_dpbusd_epi32(first,
        _mm256_loadu_si256((const __m256i *)(const void *)(biased + i)),
        _mm256_loadu_si256((const __m256i *)(const void *)(row + i)));
    second = _mm256_dpbusd_epi32(second,
        _mm256_loadu_si256((const __m256i *)(const void *)(biased + i + 32)),
        _mm256_loadu_si256((const __m256i *)(const void *)(row + i + 32)));
  }
  int32_t lanes[8];
  _mm256_storeu_si256((__m256i *)(void *)lanes, _mm256_add_epi32(first, second));
  int32_t total = ((lanes[0] + lanes[1]) + (lanes[2] + lanes[3]))
                  + ((lanes[4] + lanes[5]) + (lanes[6] + lanes[7]));
  for (; i < n; i++) total += (int32_t)row[i] * (int32_t)biased[i];
  return (int32_t)((uint32_t)total - 128u * (uint32_t)sum);
}

__attribute__((target("avx2,avxvnni")))
static int32_t dot_i8_avx_vnni (const int8_t *row, int32_t sum, const int8_t *codes,
                                const uint8_t *biased, size_t n) {
  (void)codes;
  __m256i first = _mm256_setzero_si256(), second = _mm256_setzero_si256();
  size_t i = 0;
  for (; i + 64 <= n; i += 64) {
    first = _mm256_dpbusd_avx_epi32(first,
        _mm256_loadu_si256((const __m256i *)(const void *)(biased + i)),
        _mm256_loadu_si256((const __m256i *)(const void *)(row + i)));
    second = _mm256_dpbusd_avx_epi32(second,
        _mm256_loadu_si256((const __m256i *)(const void *)(biased + i + 32)),
        _mm256_loadu_si256((const __m256i *)(const void *)(row + i + 32)));
  }
  int32_t lanes[8];
  _mm256_storeu_si256((__m256i *)(void *)lanes, _mm256_add_epi32(first, second));
  int32_t total = ((lanes[0] + lanes[1]) + (lanes[2] + lanes[3]))
                  + ((lanes[4] + lanes[5]) + (lanes[6] + lanes[7]));
  for (; i < n; i++) total += (int32_t)row[i] * (int32_t)biased[i];
  return (int32_t)((uint32_t)total - 128u * (uint32_t)sum);
}

/* The register state the operating system saves (xgetbv's XCR0), or 0
 * when it does not say. A CPU feature is usable only if its registers
 * are saved. */
static unsigned saved_state (void) {
  unsigned a, b, c, d;
  if (!__get_cpuid(1, &a, &b, &c, &d) || (c & (1u << 27)) == 0) return 0;
  unsigned low, high;
  __asm__ volatile ("xgetbv" : "=a"(low), "=d"(high) : "c"(0));
  return low;
}

/* AVX-512 F and VL (leaf 7's ebx bits 16, 31) and VNNI (ecx bit 11),
 * with the opmask and vector state saved (XCR0 bits 1, 2, 5, 6, 7). */
static bool has_avx512_vnni (void) {
  unsigned a, b, c, d;
  if ((saved_state() & 0xE6u) != 0xE6u || !__get_cpuid_count(7, 0, &a, &b, &c, &d)) return false;
  const unsigned need = (1u << 16) | (1u << 31);
  return (b & need) == need && (c & (1u << 11)) != 0;
}

/* AVX-VNNI (leaf 7 subleaf 1's eax bit 4), with the 256-bit state saved
 * (XCR0 bits 1, 2). The core is built for x86-64-v3, so it has AVX2. */
static bool has_avx_vnni (void) {
  unsigned a, b, c, d;
  return (saved_state() & 0x6u) == 0x6u && __get_cpuid_count(7, 1, &a, &b, &c, &d)
         && (a & (1u << 4)) != 0;
}
#endif

/* The int8 kernel in use, chosen once when the module opens and changed
 * only by [`vector_kernel`] (the tests'). */
static dot_i8_fn dot_i8_kernel = dot_i8_generic;
static const char *dot_i8_name = "generic";

/* The same sums in double, for the vectors whose float sums leave the
 * range of a float: the squares of numbers past 1.8e19, or the products
 * and differences of numbers near FLT_MAX, are infinity (or, with their
 * signs mixed, not a number) in float, but ordinary doubles. They are
 * tried only after the float sums fail, so a scan of ordinary vectors
 * pays nothing for them. */
static double dot_wide (const float *a, const float *b, size_t n) {
  double total = 0.0;
  for (size_t i = 0; i < n; i++) total += (double)a[i] * (double)b[i];
  return total;
}

static double squared_l2_wide (const float *a, const float *b, size_t n) {
  double total = 0.0;
  for (size_t i = 0; i < n; i++) {
    double d = (double)a[i] - (double)b[i];
    total += d * d;
  }
  return total;
}

static double l1_wide (const float *a, const float *b, size_t n) {
  double total = 0.0;
  for (size_t i = 0; i < n; i++) total += fabs((double)a[i] - (double)b[i]);
  return total;
}

static void l2_distance_function (sqlite3_context *ctx, int argc,
                                  sqlite3_value **argv) {
  if (cosmic_any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector a, b;
  if (!read_pair(ctx, argv, &a, &b)) return;
  double squares = (double)squared_l2(a.values, b.values, a.dims);
  /* A float sum that overflowed, or underflowed to zero or a subnormal
   * (differences near 1e-30 square to 1e-60), is redone in double; the
   * double sum of equal vectors is exactly zero, as it was. */
  if (!isfinite(squares) || squares < FLT_MIN) {
    squares = squared_l2_wide(a.values, b.values, a.dims);
  }
  sqlite3_result_double(ctx, sqrt(squares));
  release(&a);
  release(&b);
}

static void inner_product_function (sqlite3_context *ctx, int argc,
                                    sqlite3_value **argv) {
  if (cosmic_any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector a, b;
  if (!read_pair(ctx, argv, &a, &b)) return;
  double product = (double)dot(a.values, b.values, a.dims);
  /* Redone in double when the float sum overflowed, or when its size is
   * below a normal float's, where products like 1e-30 * 1e-30 are lost. */
  if (!isfinite(product) || fabs(product) < FLT_MIN) {
    product = dot_wide(a.values, b.values, a.dims);
  }
  sqlite3_result_double(ctx, product);
  release(&a);
  release(&b);
}

/* One minus the cosine of the angle between the vectors, from 0 (same
 * direction) to 2 (opposite); NULL where either is all zeros, which has
 * no direction. */
static void cosine_distance_function (sqlite3_context *ctx, int argc,
                                      sqlite3_value **argv) {
  if (cosmic_any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector a, b;
  if (!read_pair(ctx, argv, &a, &b)) return;
  float fab, faa, fbb;
  cosine_parts(a.values, b.values, a.dims, &fab, &faa, &fbb);
  double ab = fab, aa = faa, bb = fbb;
  /* A sum that underflowed to zero or a subnormal, or overflowed, is
   * redone in double, so a vector of 1e-30s or of 1e20s keeps its
   * direction. */
  if (aa < FLT_MIN || bb < FLT_MIN || !isfinite(ab) || !isfinite(aa) || !isfinite(bb)) {
    ab = dot_wide(a.values, b.values, a.dims);
    aa = dot_wide(a.values, a.values, a.dims);
    bb = dot_wide(b.values, b.values, b.dims);
  }
  release(&a);
  release(&b);
  double norms = sqrt(aa * bb);
  if (norms == 0.0) {
    sqlite3_result_null(ctx);
    return;
  }
  double similarity = ab / norms;
  /* Rounding can carry the cosine just past 1 or -1. */
  if (similarity > 1.0) similarity = 1.0;
  if (similarity < -1.0) similarity = -1.0;
  sqlite3_result_double(ctx, 1.0 - similarity);
}

static void l1_distance_function (sqlite3_context *ctx, int argc,
                                  sqlite3_value **argv) {
  if (cosmic_any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector a, b;
  if (!read_pair(ctx, argv, &a, &b)) return;
  double total = (double)l1(a.values, b.values, a.dims);
  if (!isfinite(total)) total = l1_wide(a.values, b.values, a.dims);
  sqlite3_result_double(ctx, total);
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
  if (cosmic_any_null(argc, argv)) {
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
  if (cosmic_any_null(argc, argv)) {
    sqlite3_result_null(ctx);
    return;
  }
  struct vector v;
  if (!read_vector(ctx, argv[0], &v)) return;
  sqlite3_str *out = sqlite3_str_new(sqlite3_context_db_handle(ctx));
  sqlite3_str_appendchar(out, 1, '[');
  for (size_t i = 0; i < v.dims; i++) {
    if (i > 0) sqlite3_str_appendchar(out, 1, ',');
    /* SQLite's printf writes the zero of -0.0 without its sign, which
     * would read back as a different blob. */
    if (v.values[i] == 0.0f && signbit(v.values[i])) {
      sqlite3_str_appendall(out, "-0");
    }
    else {
      sqlite3_str_appendf(out, "%.9g", (double)v.values[i]);
    }
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
  if (cosmic_any_null(argc, argv)) {
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
  if (cosmic_any_null(argc, argv)) {
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
  if (cosmic_any_null(argc, argv)) {
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
  if (cosmic_any_null(argc, argv)) {
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
  if (cosmic_any_null(argc, argv)) {
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
  if (cosmic_any_null(argc, argv)) {
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

static int register_blocks (sqlite3 *db);

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
  return register_blocks(db);
}

/* The Lua side: [`cosmic.internal.vector`]. A corpus is a userdata
 * holding its vectors in one buffer, with the id of each and, once a
 * search asks for a binary first pass, a bit vector of each.
 *
 * Every buffer is a userdata of its own, held in one of the corpus's
 * user values, so Lua's allocator owns each byte: the collector counts
 * them (a corpus of a million vectors is not a 100-byte object to it),
 * the checked core refuses them like any Lua allocation, and nothing is
 * left on the C heap for a __gc to release. A buffer never moves while
 * the corpus holds it, so the pointers below stay valid across a Lua
 * call that has the corpus on the stack and does not add to it. Growing allocates the bigger
 * buffer, copies, and only then swaps it in: a refusal raises with the
 * corpus as it was. */

#define CORPUS_TYPE "cosmic.vector.corpus"

/* The user value each buffer is held in. */
enum { SLOT_DATA = 1, SLOT_INVERSE, SLOT_IDS, SLOT_BITS, SLOT_CODES, SLOTS = SLOT_CODES };

/* How a corpus holds its vectors. A vector is quantized once, in `add`;
 * a query stays f32 (an int8 corpus quantizes it once per search). */
enum storage { F32, F16, INT8 };

/* What an int8 vector keeps beside its codes: the scale (the largest
 * magnitude over 127; 0 for a vector with no direction), the sum of the
 * squares of its codes, which is exact in 32 bits at 16000 dimensions
 * (16000 * 127 * 127), and the sum of the codes. */
struct code_row {
  float scale;
  uint32_t sumsq;
  int32_t sum;
};

struct corpus {
  size_t dims;
  size_t count;
  size_t capacity;
  enum storage storage;
  void *data;          /* count * dims floats, halves or int8 codes */
  float *inverse;      /* 1 / length of each stored vector, 0 for no direction */
  int64_t *ids;
  struct code_row *codes; /* int8 only: count rows */
  unsigned char *bits; /* bits_built rows of bytes each, as binary_quantize */
  size_t bits_built;
  size_t bytes;
};

enum metric { INNER_PRODUCT, COSINE, L2 };

static struct corpus *check_corpus (lua_State *L, int arg) {
  return luaL_checkudata(L, arg, CORPUS_TYPE);
}

/* Whether a guard of cosmic.signal has caught SIGINT or SIGTERM. It does
 * not take the signal: the guard's holder still sees it. The long calls
 * below ask every few hundred rows and, when it is so, stop and answer
 * `nil, "interrupted"` ([`interrupted`]) as http and socket do. What they
 * hold is Lua's own, so stopping leaves nothing to release, and the
 * corpus is left as it was: search and kmeans never change the corpus,
 * and [`ensure_bits`] publishes the bit vectors only after its loop
 * ends. */
static bool check_interrupt (void) {
  return cosmic_signal_caught();
}

/* The answer of a long call that stopped for a signal: `nil, "interrupted"`. */
static int interrupted (lua_State *L) {
  lua_pushnil(L);
  lua_pushliteral(L, "interrupted");
  return 2;
}

/* How often a row loop asks: a power of two minus one, to mask a row
 * number with: a signal is seen within that many rows' work, which is
 * milliseconds at thousands of dimensions. */
#define CHECK_EVERY 255u

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

/* The length of a vector, its squares summed in double as the SQL
 * functions do: in float the squares of small numbers underflow to a
 * length of zero and of large ones overflow. */
static double length_of (const float *v, size_t n) {
  double squares = 0.0;
  for (size_t i = 0; i < n; i++) squares += (double)v[i] * (double)v[i];
  return sqrt(squares);
}

/* Quantizes `v` to int8 codes with one scale: the largest magnitude over
 * 127, each code the value over the scale rounded to nearest (ties to
 * even). Answers the scale and sets the sum of the squares of the codes
 * and the sum of the codes.
 * A vector whose scale is below a normal float's has no direction worth
 * keeping and becomes all zero codes, as the f32 corpus treats a length
 * it cannot invert. */
static float quantize_i8 (const float *v, size_t n, int8_t *codes, uint32_t *sumsq,
                          int32_t *sum) {
  float largest = 0.0f;
  for (size_t i = 0; i < n; i++) {
    float magnitude = fabsf(v[i]);
    if (magnitude > largest) largest = magnitude;
  }
  float scale = largest / 127.0f;
  if (!(scale >= FLT_MIN)) {
    memset(codes, 0, n);
    *sumsq = 0;
    *sum = 0;
    return 0.0f;
  }
  uint32_t squares = 0;
  int32_t total = 0;
  for (size_t i = 0; i < n; i++) {
    float r = rintf(v[i] / scale);
    int code = (int)(r > 127.0f ? 127.0f : r < -127.0f ? -127.0f : r);
    codes[i] = (int8_t)code;
    squares += (uint32_t)(code * code);
    total += code;
  }
  *sumsq = squares;
  *sum = total;
  return scale;
}

static int vector_corpus (lua_State *L) {
  lua_Integer dims = luaL_checkinteger(L, 1);
  luaL_argcheck(L, dims >= 1 && dims <= MAX_DIMS, 1,
                "dimensions are from 1 to 16000");
  const char *name = luaL_optstring(L, 2, "f32");
  enum storage storage;
  if (strcmp(name, "f32") == 0) storage = F32;
  else if (strcmp(name, "f16") == 0) storage = F16;
  else if (strcmp(name, "int8") == 0) storage = INT8;
  else return luaL_argerror(L, 2, "a storage is f32, f16 or int8");
  struct corpus *c = lua_newuserdatauv(L, sizeof *c, SLOTS);
  memset(c, 0, sizeof *c);
  c->storage = storage;
  c->dims = (size_t)dims;
  c->bytes = ((size_t)dims + 7) / 8;
  luaL_setmetatable(L, CORPUS_TYPE);
  return 1;
}

/* Whether n elements of `size` bytes can be asked of the allocator at
 * all: Lua refuses a block too large itself, but the product must not
 * wrap first. */
static bool fits (size_t n, size_t size) {
  return n <= SIZE_MAX / size;
}

/* Half precision's largest magnitude is 65504; a float of 65520 or more
 * rounds to infinity. */
#define HALF_LIMIT 65520.0f

/* Binary quantization by the sign of each dimension of the f32 input,
 * the same bits for every storage. */
static void quantize (const float *v, size_t dims, unsigned char *bits) {
  memset(bits, 0, (dims + 7) / 8);
  for (size_t i = 0; i < dims; i++) {
    if (v[i] > 0.0f) bits[i / 8] |= (unsigned char)(0x80u >> (i % 8));
  }
}

/* Stores `v`, which holds finite numbers, as row `row`. Answers the length
 * of what was stored, in double, and sets an int8 row's header. */
static double store_row (struct corpus *c, size_t row, const float *v) {
  size_t dims = c->dims;
  switch (c->storage) {
    case F32: {
      float *out = (float *)c->data + row * dims;
      memcpy(out, v, dims * sizeof *out);
      return length_of(v, dims);
    }
    case F16: {
      _Float16 *out = (_Float16 *)c->data + row * dims;
      double squares = 0.0;
      for (size_t i = 0; i < dims; i++) {
        out[i] = (_Float16)v[i];
        squares += (double)(float)out[i] * (double)(float)out[i];
      }
      return sqrt(squares);
    }
    default: {
      struct code_row *header = c->codes + row;
      header->scale = quantize_i8(v, dims, (int8_t *)c->data + row * dims, &header->sumsq,
                                   &header->sum);
      return (double)header->scale * sqrt((double)header->sumsq);
    }
  }
}

/* The bytes one number takes in a corpus or a block of `storage`. */
static size_t element_size (enum storage storage) {
  return storage == F32 ? sizeof(float) : storage == F16 ? sizeof(_Float16) : 1;
}

/* 1 over a stored vector's length. A length too small to invert in a
 * float is a vector with no direction, held as 0. */
static float inverse_of (double length) {
  float inverse = length == 0.0 ? 0.0f : (float)(1.0 / length);
  return isfinite(inverse) ? inverse : 0.0f;
}

/* Makes room for `extra` more rows; the corpus is at stack index 1. The
 * buffers are allocated bigger than needed (double the old, or `extra`
 * if more), all of them first, each held on the stack and so safe from
 * the collector the next allocation may run; the corpus is changed only
 * once none can be refused. */
static void reserve (lua_State *L, struct corpus *c, size_t extra) {
  if (extra <= c->capacity - c->count) return;
  if (extra > SIZE_MAX / 2 - c->count) luaL_error(L, "not enough memory");
  size_t grown = c->capacity == 0 ? 64 : c->capacity * 2;
  if (grown < c->count + extra) grown = c->count + extra;
  if (!fits(grown, (c->dims + 2) * sizeof(int64_t))) luaL_error(L, "not enough memory");
  size_t element = element_size(c->storage);
  int slots[SLOTS], pushed = 0;
  void *data = lua_newuserdatauv(L, grown * c->dims * element, 0);
  slots[pushed++] = SLOT_DATA;
  float *inverse = lua_newuserdatauv(L, grown * sizeof *inverse, 0);
  slots[pushed++] = SLOT_INVERSE;
  int64_t *ids = lua_newuserdatauv(L, grown * sizeof *ids, 0);
  slots[pushed++] = SLOT_IDS;
  struct code_row *codes = NULL;
  if (c->storage == INT8) {
    codes = lua_newuserdatauv(L, grown * sizeof *codes, 0);
    slots[pushed++] = SLOT_CODES;
  }
  /* A quantized corpus no longer has the floats a lazy build would read,
   * so each row's bits are made as it is added. */
  unsigned char *bits = NULL;
  if (c->storage != F32) {
    bits = lua_newuserdatauv(L, grown * c->bytes, 0);
    slots[pushed++] = SLOT_BITS;
  }
  if (c->count > 0) {
    memcpy(data, c->data, c->count * c->dims * element);
    memcpy(inverse, c->inverse, c->count * sizeof *inverse);
    memcpy(ids, c->ids, c->count * sizeof *ids);
    if (codes != NULL) memcpy(codes, c->codes, c->count * sizeof *codes);
    if (bits != NULL) memcpy(bits, c->bits, c->count * c->bytes);
  }
  while (pushed > 0) lua_setiuservalue(L, 1, slots[--pushed]);
  c->data = data;
  c->inverse = inverse;
  c->ids = ids;
  c->capacity = grown;
  if (codes != NULL) c->codes = codes;
  if (bits != NULL) c->bits = bits;
}

/* Appends `v`, which holds finite numbers (under 65520 in magnitude for
 * f16), as the next row; room for it is reserved. */
static void append_row (struct corpus *c, int64_t id, const float *v) {
  double length = store_row(c, c->count, v);
  c->inverse[c->count] = inverse_of(length);
  c->ids[c->count] = id;
  if (c->storage != F32) {
    quantize(v, c->dims, c->bits + c->count * c->bytes);
    c->bits_built = c->count + 1;
  }
  c->count++;
}

static int corpus_add (lua_State *L) {
  struct corpus *c = check_corpus(L, 1);
  lua_Integer id = luaL_checkinteger(L, 2);
  float *v = check_floats(L, 3, c->dims);
  if (c->storage == F16) {
    for (size_t i = 0; i < c->dims; i++) {
      luaL_argcheck(L, fabsf(v[i]) < HALF_LIMIT, 3,
                    "a half-precision vector holds numbers under 65520 in magnitude");
    }
  }
  reserve(L, c, 1);
  append_row(c, id, v);
  return 0;
}

static int corpus_count (lua_State *L) {
  lua_pushinteger(L, (lua_Integer)check_corpus(L, 1)->count);
  return 1;
}

/* Brings the bit vectors up to every vector added so far; the corpus is
 * at stack index 1. Only an f32 corpus builds them here, from its floats:
 * a quantized one made each row's as the row was added. Answers false,
 * with the corpus as it was, when a signal interrupted it. A new buffer
 * is made each time rather than grown in place: the rows already built
 * are copied, which costs less than the scan that follows. */
static bool ensure_bits (lua_State *L, struct corpus *c) {
  if (c->bits_built == c->count) return true;
  unsigned char *bits = lua_newuserdatauv(L, c->count * c->bytes, 0);
  if (c->bits_built > 0) memcpy(bits, c->bits, c->bits_built * c->bytes);
  for (size_t i = c->bits_built; i < c->count; i++) {
    if ((i & CHECK_EVERY) == 0 && check_interrupt()) return false;
    quantize((const float *)c->data + i * c->dims, c->dims, bits + i * c->bytes);
  }
  lua_setiuservalue(L, 1, SLOT_BITS);
  c->bits = bits;
  c->bits_built = c->count;
  return true;
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
 * keys the lower id. The key is a double so that a ranking by a distance
 * can keep the distance's own ties; a float key widens exactly. */
struct hit {
  double key;
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

/* A query as the stored form of a corpus compares it: the floats always
 * (an f32 or f16 row is scored against them, and the first pass reads
 * their signs), and for an int8 corpus also the codes the query
 * quantizes to. `inverse` is 1 over the length of what the rows are
 * compared with: the floats, or the codes' dequantized length. */
struct query {
  const float *floats;
  const int8_t *codes;
  const uint8_t *biased;
  float scale;
  uint32_t sumsq;
  float inverse;
};

/* Prepares `q` to score the f32 vector `floats` against rows of `storage`.
 * An int8 corpus needs `codes`, 2 * dims + 1 bytes the query's quantized
 * form is held in; any other storage takes NULL. */
static void query_init (struct query *q, const float *floats, size_t dims,
                        enum storage storage, void *codes) {
  *q = (struct query){floats, NULL, NULL, 0.0f, 0, 0.0f};
  if (storage == INT8) {
    int8_t *held = codes;
    uint8_t *biased = (uint8_t *)held + dims;
    int32_t sum;
    q->codes = held;
    q->biased = biased;
    q->scale = quantize_i8(floats, dims, held, &q->sumsq, &sum);
    for (size_t i = 0; i < dims; i++) biased[i] = (uint8_t)(held[i] + 128);
    double qlen = (double)q->scale * sqrt((double)q->sumsq);
    q->inverse = inverse_of(qlen);
  }
  else {
    double qlen = length_of(floats, dims);
    q->inverse = qlen == 0.0 ? 0.0f : (float)(1.0 / qlen);
  }
}

/* The key a row ranks by under `metric`, higher better. An int8 row is
 * scored by an exact integer dot product of the codes, scaled by both
 * scales; its cosine uses the stored length of the codes' dequantized
 * vector, and its distance the identity
 * |a - b|^2 = |a|^2 + |b|^2 - 2 a.b over the dequantized vectors, summed
 * in double and clamped at zero. The identity is exact for a vector
 * against its own codes, which score 0. */
static float row_key (const struct corpus *c, size_t row, const struct query *q,
                      enum metric metric) {
  size_t dims = c->dims;
  switch (c->storage) {
    case F32: {
      const float *v = (const float *)c->data + row * dims;
      switch (metric) {
        case INNER_PRODUCT: return dot(v, q->floats, dims);
        case COSINE:
        /* A zero vector has no direction, and SQL's cosine_distance of
         * one is NULL: it ranks below every row that has one. */
        if (c->inverse[row] == 0.0f || q->inverse == 0.0f) return -INFINITY;
        return dot(v, q->floats, dims) * c->inverse[row] * q->inverse;
        default: return -squared_l2(v, q->floats, dims);
      }
    }
    case F16: {
      const _Float16 *v = (const _Float16 *)c->data + row * dims;
      switch (metric) {
        case INNER_PRODUCT: return dot_f16(v, q->floats, dims);
        case COSINE:
        if (c->inverse[row] == 0.0f || q->inverse == 0.0f) return -INFINITY;
        return dot_f16(v, q->floats, dims) * c->inverse[row] * q->inverse;
        default: return -squared_l2_f16(v, q->floats, dims);
      }
    }
    default: {
      const int8_t *v = (const int8_t *)c->data + row * dims;
      double scale = c->codes[row].scale;
      double both = scale * (double)q->scale;
      double product = (double)dot_i8_kernel(v, c->codes[row].sum, q->codes, q->biased, dims);
      switch (metric) {
        case INNER_PRODUCT: return (float)(product * both);
        case COSINE:
        if (c->inverse[row] == 0.0f || q->inverse == 0.0f) return -INFINITY;
        return (float)(product * both * (double)c->inverse[row] * (double)q->inverse);
        default: {
          double mine = scale * scale;
          double theirs = (double)q->scale * (double)q->scale;
          double squares = mine * (double)c->codes[row].sumsq
                           + theirs * (double)q->sumsq - 2.0 * (both * product);
          return squares > 0.0 ? -(float)squares : -0.0f;
        }
      }
    }
  }
}

/* search(corpus, query, k, metric, candidates, allow): the ids and
 * scores of the k best, best first; `nil, "interrupted"` when a signal
 * stopped it. */
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
  struct query query;
  query_init(&query, q, dims, c->storage,
             c->storage == INT8 ? lua_newuserdatauv(L, 2 * dims + 1, 0) : NULL);

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
    if (!ensure_bits(L, c)) return interrupted(L);
    unsigned char *qbits = lua_newuserdatauv(L, c->bytes + 1, 0);
    quantize(q, dims, qbits);
    unsigned *histogram = lua_newuserdatauv(
        L, (dims + 1) * sizeof *histogram, 0);
    memset(histogram, 0, (dims + 1) * sizeof *histogram);
    uint16_t *distance = lua_newuserdatauv(
        L, c->count * sizeof *distance + 1, 0);
    for (size_t row = 0; row < c->count; row++) {
      if ((row & CHECK_EVERY) == 0 && check_interrupt()) return interrupted(L);
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
    if ((at & CHECK_EVERY) == 0 && check_interrupt()) return interrupted(L);
    size_t row = rows != NULL ? rows[at] : at;
    if (rows == NULL && mask != NULL && !mask[row]) continue;
    float key = row_key(c, row, &query, metric);
    /* TODO: once the corpus kernels redo a non-finite (or underflowed)
     * sum in double, as the SQL distance functions do, behind a hot-path
     * cost check: they sum in float, so a row can score infinity or be
     * dropped as NaN here where l2_distance, inner_product and
     * cosine_distance answer a finite double. */
    /* A NaN key compares false both ways, which would leave the heap's
     * order depending on arrival; such a row is not a hit. */
    if (isnan(key)) continue;
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
  luaL_argcheck(L, n >= 1, 1, "a vector has at least 1 dimension");
  luaL_argcheck(L, n <= MAX_DIMS, 1, "a vector has at most 16000 dimensions");
  float *out = lua_newuserdatauv(L, n * sizeof *out + 1, 0);
  for (size_t i = 0; i < n; i++) {
    lua_rawgeti(L, 1, (lua_Integer)(i + 1));
    int ok;
    /* A number, not a string that reads as one. */
    lua_Number x = lua_tonumberx(L, -1, &ok);
    if (lua_type(L, -1) != LUA_TNUMBER) ok = 0;
    /* Compared as a double before the conversion: a double past
     * FLT_MAX has no float to convert to, and converting is undefined. */
    luaL_argcheck(L, ok && isfinite(x) && fabs(x) <= (double)FLT_MAX, 1,
                  "a vector holds finite numbers");
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
  size_t text_len;
  const char *text = luaL_checklstring(L, 1, &text_len);
  if (strlen(text) != text_len) {
    lua_pushnil(L);
    lua_pushliteral(L, "a vector's text holds no NUL");
    return 2;
  }
  /* The parsed block is the guard's: pushing the answer allocates, and
   * a raise there must not leak the block. */
  struct cosmic_guard *guard = cosmic_guard_push(L, sqlite3_free);
  struct vector v;
  const char *why = parse_text(text, &v);
  if (why != NULL) {
    lua_pushnil(L);
    lua_pushstring(L, why);
    return 2;
  }
  guard->resource = v.owned;
  lua_pushlstring(L, (const char *)v.values, v.dims * sizeof(float));
  cosmic_guard_release(guard);
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
  double norm = length_of(in, n);
  for (size_t i = 0; i < n; i++) {
    in[i] = norm == 0.0 || !isfinite(norm) ? 0.0f : (float)((double)in[i] / norm);
  }
  lua_pushlstring(L, (const char *)in, len);
  return 1;
}


/* k-means over a corpus, for the IVF scheme. The
 * algorithm is Lloyd's with k-means++ seeding on the unit-length
 * vectors (spherical k-means); no code is taken from pgvector. All
 * scratch lives in one Lua userdata, so nothing is held across a raise. */

static uint64_t splitmix (uint64_t *state) {
  uint64_t z = (*state += 0x9E3779B97F4A7C15ULL);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
  return z ^ (z >> 31);
}

/* Row i as floats: the row itself for f32, else the stored form widened
 * into `scratch`, which holds `dims` floats. */
static const float *row_floats (const struct corpus *c, size_t i, float *scratch) {
  size_t dims = c->dims;
  switch (c->storage) {
    case F32: return (const float *)c->data + i * dims;
    case F16: {
      const _Float16 *v = (const _Float16 *)c->data + i * dims;
      for (size_t d = 0; d < dims; d++) scratch[d] = (float)v[d];
      return scratch;
    }
    default: {
      const int8_t *v = (const int8_t *)c->data + i * dims;
      float scale = c->codes[i].scale;
      for (size_t d = 0; d < dims; d++) scratch[d] = (float)v[d] * scale;
      return scratch;
    }
  }
}

/* Writes row i scaled to length 1 into out. */
static void unit_row (const struct corpus *c, size_t i, float *out) {
  const float *x = row_floats(c, i, out);
  for (size_t d = 0; d < c->dims; d++) out[d] = x[d] * c->inverse[i];
}

static void normalize_in_place (float *v, size_t n) {
  double norm = sqrt((double)dot(v, v, n));
  if (norm == 0.0) return;
  for (size_t d = 0; d < n; d++) v[d] = (float)((double)v[d] / norm);
}

/* The inner product with a NaN (infinity minus infinity, from floats
 * that are each finite) counted as the worst score, so every ranking
 * here agrees on what a score that is not a number is. */
static float score (const float *a, const float *b, size_t n) {
  float s = dot(a, b, n);
  return isnan(s) ? -INFINITY : s;
}

/* The k-means++ weight of row i against a unit centroid: its squared
 * distance, from 0 to 4. A row without a direction has weight 0, so it
 * is never drawn. */
static float seed_weight (const struct corpus *c, size_t i, const float *cent,
                          float *scratch) {
  if (c->inverse[i] == 0.0f) return 0.0f;
  float m = 2.0f - 2.0f * c->inverse[i] * score(row_floats(c, i, scratch), cent, c->dims);
  if (!(m > 0.0f)) return 0.0f;
  return m > 4.0f ? 4.0f : m;
}

/* The index of the pick'th row that has a direction. */
static size_t nth_directed (const struct corpus *c, size_t pick) {
  for (size_t i = 0; i < c->count; i++) {
    if (c->inverse[i] == 0.0f) continue;
    if (pick == 0) return i;
    pick--;
  }
  return 0;
}

/* corpus:kmeans(k, seed, iterations): a table of k centroid strings, or
 * `nil, "interrupted"` when a signal stopped it.
 * A row of length zero (or too short to take the inverse of) has no
 * direction: it is never a seed, and counts toward no cluster. A corpus
 * of such rows alone raises. */
static int corpus_kmeans (lua_State *L) {
  struct corpus *c = check_corpus(L, 1);
  lua_Integer k = luaL_checkinteger(L, 2);
  uint64_t rng = (uint64_t)luaL_checkinteger(L, 3);
  lua_Integer iterations = luaL_checkinteger(L, 4);
  luaL_argcheck(L, k >= 1 && (size_t)k <= c->count, 2,
                "k is from 1 to the number of vectors");
  luaL_argcheck(L, iterations >= 1, 4, "iterations is at least 1");
  size_t dims = c->dims, n = c->count, kk = (size_t)k;
  luaL_argcheck(L, kk * dims <= ((size_t)1 << 30) && n <= ((size_t)1 << 30), 2,
                "too large");
  size_t directed = 0;
  for (size_t i = 0; i < n; i++) if (c->inverse[i] != 0.0f) directed++;
  if (directed == 0) return luaL_error(L, "no vector has a direction to cluster");
  size_t words = 2 * kk * dims + n + n + kk + dims;
  float *scratch = lua_newuserdatauv(L, words * sizeof(float), 0);
  float *cent = scratch;
  float *sums = cent + kk * dims;
  float *best = sums + kk * dims;
  int32_t *assign = (int32_t *)(best + n);
  uint32_t *counts = (uint32_t *)(assign + n);
  float *rowbuf = (float *)(counts + kk);

  /* k-means++: each next centroid is drawn in proportion to its
   * squared distance (2 - 2 * similarity) from the nearest chosen. */
  unit_row(c, nth_directed(c, splitmix(&rng) % directed), cent);
  for (size_t i = 0; i < n; i++) best[i] = seed_weight(c, i, cent, rowbuf);
  for (size_t j = 1; j < kk; j++) {
    if (check_interrupt()) return interrupted(L);
    double total = 0;
    size_t last = 0;
    bool any = false;
    for (size_t i = 0; i < n; i++) {
      total += best[i];
      if (best[i] > 0) { last = i; any = true; }
    }
    size_t pick = nth_directed(c, splitmix(&rng) % directed);
    if (any) {
      double r = (double)(splitmix(&rng) >> 11) * (1.0 / 9007199254740992.0) * total;
      /* Rounding can leave r unspent: the last row that has weight. */
      pick = last;
      for (size_t i = 0; i < n; i++) {
        r -= best[i];
        if (r < 0 && best[i] > 0) { pick = i; break; }
      }
    }
    float *cj = cent + j * dims;
    unit_row(c, pick, cj);
    for (size_t i = 0; i < n; i++) {
      float m = seed_weight(c, i, cj, rowbuf);
      if (m < best[i]) best[i] = m;
    }
  }

  for (size_t i = 0; i < n; i++) assign[i] = -1;
  for (lua_Integer it = 0; it < iterations; it++) {
    size_t changed = 0;
    if (check_interrupt()) return interrupted(L);
    for (size_t i = 0; i < n; i++) {
      if ((i & 63u) == 0 && check_interrupt()) return interrupted(L);
      if (c->inverse[i] == 0.0f) { best[i] = 1.0f; continue; }
      const float *x = row_floats(c, i, rowbuf);
      float top = -INFINITY;
      int32_t at = 0;
      for (size_t j = 0; j < kk; j++) {
        float sim = score(x, cent + j * dims, dims);
        if (sim > top) { top = sim; at = (int32_t)j; }
      }
      best[i] = top * c->inverse[i];
      if (assign[i] != at) { assign[i] = at; changed++; }
    }
    if (changed == 0) break;
    memset(sums, 0, kk * dims * sizeof *sums);
    memset(counts, 0, kk * sizeof *counts);
    for (size_t i = 0; i < n; i++) {
      if (assign[i] < 0) continue;
      float *sum = sums + (size_t)assign[i] * dims;
      const float *x = row_floats(c, i, rowbuf);
      for (size_t d = 0; d < dims; d++) sum[d] += x[d] * c->inverse[i];
      counts[assign[i]]++;
    }
    for (size_t j = 0; j < kk; j++) {
      float *cj = cent + j * dims;
      if (counts[j] == 0) {
        /* An empty cluster takes the vector worst served by its own. */
        size_t far = nth_directed(c, 0);
        for (size_t i = far + 1; i < n; i++) {
          if (c->inverse[i] != 0.0f && best[i] < best[far]) far = i;
        }
        unit_row(c, far, cj);
        best[far] = 1.0f;
      } else {
        float *sum = sums + j * dims;
        normalize_in_place(sum, dims);
        memcpy(cj, sum, dims * sizeof *cj);
      }
    }
  }

  lua_createtable(L, (int)kk, 0);
  for (size_t j = 0; j < kk; j++) {
    lua_pushlstring(L, (const char *)(cent + j * dims), dims * sizeof(float));
    lua_rawseti(L, -2, (lua_Integer)(j + 1));
  }
  return 1;
}

/* nearest(centroids, v, n): the 1-based indexes of the n centroids with
 * the highest inner product with v, best first, ties to the lower. The
 * query and every centroid hold finite numbers; a product that is not
 * a number (infinity minus infinity) scores worst. */
static int vector_nearest (lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  size_t vlen;
  const char *vs = luaL_checklstring(L, 2, &vlen);
  lua_Integer want = luaL_checkinteger(L, 3);
  size_t k = lua_rawlen(L, 1);
  luaL_argcheck(L, k >= 1, 1, "there are no centroids");
  luaL_argcheck(L, vlen % sizeof(float) == 0 && vlen > 0, 2,
                "a vector is a whole number of 4-byte floats");
  luaL_argcheck(L, want >= 1, 3, "n is at least 1");
  if ((size_t)want > k) want = (lua_Integer)k;
  size_t dims = vlen / sizeof(float);
  float *q = lua_newuserdatauv(L, vlen + sizeof(float), 0);
  memcpy(q, vs, vlen);
  for (size_t i = 0; i < dims; i++) {
    luaL_argcheck(L, isfinite(q[i]), 2, "a vector holds finite numbers");
  }
  /* The scores, then one byte per centroid saying it is already taken. */
  float *sims = lua_newuserdatauv(L, k * (sizeof *sims + 1), 0);
  unsigned char *taken = (unsigned char *)(sims + k);
  memset(taken, 0, k);
  float *row = lua_newuserdatauv(L, vlen + sizeof(float), 0);
  for (size_t j = 0; j < k; j++) {
    lua_rawgeti(L, 1, (lua_Integer)(j + 1));
    size_t len = 0;
    const char *s = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &len) : NULL;
    if (s == NULL || len != vlen) {
      return luaL_argerror(L, 1, "a centroid is not a vector of the query's length");
    }
    memcpy(row, s, len);
    lua_pop(L, 1);
    for (size_t i = 0; i < dims; i++) {
      luaL_argcheck(L, isfinite(row[i]), 1, "a vector holds finite numbers");
    }
    sims[j] = score(q, row, dims);
  }
  lua_createtable(L, 0, 0);
  for (lua_Integer r = 1; r <= want; r++) {
    size_t at = k;
    for (size_t j = 0; j < k; j++) {
      if (taken[j]) continue;
      if (at == k || sims[j] > sims[at]) at = j;
    }
    taken[at] = 1;
    lua_pushinteger(L, (lua_Integer)(at + 1));
    lua_rawseti(L, -2, r);
  }
  return 1;
}

/* vector_kernel(name?): the int8 dot product in use, "generic",
 * "avx512_vnni" or "avx_vnni"; given a name, switches to it and answers
 * it. Raises on a name this CPU cannot run. It is a member of
 * [`cosmic.internal.testing`], for tests that compare the kernels: a
 * corpus answers the same under each. */
static int vector_kernel (lua_State *L) {
  if (!lua_isnoneornil(L, 1)) {
    const char *name = luaL_checkstring(L, 1);
    if (strcmp(name, "generic") == 0) {
      dot_i8_kernel = dot_i8_generic;
      dot_i8_name = "generic";
    }
#ifdef INT8_VNNI
    else if (strcmp(name, "avx512_vnni") == 0 && has_avx512_vnni()) {
      dot_i8_kernel = dot_i8_avx512_vnni;
      dot_i8_name = "avx512_vnni";
    }
    else if (strcmp(name, "avx_vnni") == 0 && has_avx_vnni()) {
      dot_i8_kernel = dot_i8_avx_vnni;
      dot_i8_name = "avx_vnni";
    }
#endif
    else return luaL_argerror(L, 1, "a kernel is generic or one this CPU has");
  }
  lua_pushstring(L, dot_i8_name);
  return 1;
}

/* Packed blocks: many vectors of one dimension count and one storage in a
 * single blob, so a table of them has a row per block instead of a row
 * (and for a 3 KB vector, a page) per vector. A block is a corpus
 * serialized: the same buffers, in the same forms, so the corpus's kernels
 * score it in place and [`corpus_add_block`] copies it in.
 *
 * Layout, little-endian, every section starting at a multiple of 8:
 *   0   "VBLK"
 *   4   storage: 0 f32, 1 f16, 2 int8; then three zero bytes
 *   8   dims, u32
 *   12  count, u32
 *   16  ids: count int64
 *       inverse lengths: count float
 *       int8 only: count code_rows (scale, sum of squares, sum)
 *       the vectors back to back: count * dims numbers of the storage
 * and nothing after, so the length is a function of the header. */

_Static_assert(F32 == 0 && F16 == 1 && INT8 == 2, "a block stores the storage's number");

#define BLOCK_HEADER 16

static const unsigned char block_magic[4] = {'V', 'B', 'L', 'K'};

/* A block as the scorers read it: pointers into its blob. */
struct block {
  enum storage storage;
  size_t dims;
  size_t count;
  const int64_t *ids;
  const float *inverse;
  const struct code_row *codes;
  const void *data;
};

struct block_layout {
  uint64_t inverse;
  uint64_t codes;
  uint64_t data;
  uint64_t total;
};

static uint64_t pad8 (uint64_t n) {
  return (n + 7) & ~(uint64_t)7;
}

/* Where each section starts. `count` is at most 2^32 and `dims` 16000, so
 * nothing here overflows 64 bits. */
static struct block_layout layout_of (enum storage storage, uint64_t dims, uint64_t count) {
  struct block_layout l;
  l.inverse = BLOCK_HEADER + count * sizeof(int64_t);
  l.codes = pad8(l.inverse + count * sizeof(float));
  l.data = pad8(l.codes + (storage == INT8 ? count * sizeof(struct code_row) : 0));
  l.total = l.data + count * dims * element_size(storage);
  return l;
}

static uint32_t read_u32 (const unsigned char *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void write_u32 (unsigned char *p, uint32_t x) {
  p[0] = (unsigned char)x;
  p[1] = (unsigned char)(x >> 8);
  p[2] = (unsigned char)(x >> 16);
  p[3] = (unsigned char)(x >> 24);
}

/* Reads `len` bytes at `bytes`, which are 8-aligned, as a block. Answers
 * NULL, or why they are not one. The header and the length are held
 * exactly, and each row's own length and scale are held to be finite and
 * not negative; the vectors' numbers are not read (that is O(dims *
 * count)), so a hand-made block can hold a number a search scores as NaN,
 * which ranks nowhere. */
static const char *block_view (const unsigned char *bytes, size_t len, struct block *b) {
  if (len < BLOCK_HEADER || memcmp(bytes, block_magic, sizeof block_magic) != 0) {
    return "not a vector block";
  }
  if (bytes[4] > INT8 || (bytes[5] | bytes[6] | bytes[7]) != 0) {
    return "a vector block's header is malformed";
  }
  b->storage = (enum storage)bytes[4];
  uint32_t dims = read_u32(bytes + 8);
  uint32_t count = read_u32(bytes + 12);
  if (dims < 1 || dims > MAX_DIMS) return "a vector block has 1 to 16000 dimensions";
  struct block_layout l = layout_of(b->storage, dims, count);
  if (l.total != len) return "a vector block's length does not match its header";
  b->dims = dims;
  b->count = count;
  b->ids = (const int64_t *)(const void *)(bytes + BLOCK_HEADER);
  b->inverse = (const float *)(const void *)(bytes + l.inverse);
  b->codes = (const struct code_row *)(const void *)(bytes + l.codes);
  b->data = bytes + l.data;
  for (size_t i = 0; i < b->count; i++) {
    if (!(b->inverse[i] >= 0.0f && isfinite(b->inverse[i]))) {
      return "a vector block holds a length that is not a number";
    }
    /* A scale over FLT_MAX / 127 would make a code stand for a number that
     * is not finite. */
    if (b->storage == INT8 && !(b->codes[i].scale >= 0.0f && b->codes[i].scale <= FLT_MAX / 127.0f)) {
      return "a vector block holds a scale out of range";
    }
  }
  return NULL;
}

/* The block as the corpus it serializes, for the scorers that take one.
 * Nothing is owned, and nothing is written through it. */
static struct corpus block_corpus (const struct block *b) {
  struct corpus c;
  memset(&c, 0, sizeof c);
  c.dims = b->dims;
  c.count = b->count;
  c.capacity = b->count;
  c.storage = b->storage;
  c.data = (void *)b->data;
  c.inverse = (float *)b->inverse;
  c.ids = (int64_t *)b->ids;
  c.codes = (struct code_row *)b->codes;
  return c;
}

/* Scores every row of `b` and offers the keys to `heap`. Answers false
 * when a signal stopped it, after the first row and every few hundred
 * since. A row whose key is not a number is no hit, as in a corpus search
 * (see the TODO there on sums that overflow).
 *
 * TODO: once a caller searches more blocks than a full scan suits: give a
 * block a bit vector per row beside its vectors, so that
 * `vector_block_search` can take a `candidates` count as a corpus search
 * does. */
static bool scan_block (const struct block *b, const struct query *q, enum metric metric,
                        struct heap *heap) {
  struct corpus rows = block_corpus(b);
  heap->ids = rows.ids;
  for (size_t row = 0; row < rows.count; row++) {
    if ((row & CHECK_EVERY) == 0 && check_interrupt()) return false;
    float key = row_key(&rows, row, q, metric);
    if (isnan(key)) continue;
    /* A cosine ranks by the distance it reports, 1 less its clamped
     * similarity, negated so that higher is nearer: rows at the same
     * distance, one that rounded past 1 and one that did not, or two so
     * near 0 that 1 less them is 1, must rank by their ids. A vector
     * without a direction keeps its key of -infinity, which ranks last. */
    double rank = key;
    if (metric == COSINE && key != -INFINITY) rank = (double)fmaxf(-1.0f, fminf(1.0f, key)) - 1.0;
    struct hit hit = {rank, row};
    offer(heap, hit);
  }
  return true;
}

/* The metric `name` spells, or false. */
static bool metric_named (const char *name, enum metric *metric) {
  if (strcmp(name, "inner_product") == 0) *metric = INNER_PRODUCT;
  else if (strcmp(name, "cosine") == 0) *metric = COSINE;
  else if (strcmp(name, "l2") == 0) *metric = L2;
  else return false;
  return true;
}

/* The distance a hit's rank stands for, lower nearer, as the SQL
 * functions report it: the negative inner product (pgvector's `<#>`),
 * `cosine_distance` (NULL, as `has` false, for a vector without a
 * direction) and `l2_distance`. */
static double block_distance (enum metric metric, double rank, bool *has) {
  *has = true;
  switch (metric) {
    case INNER_PRODUCT: return 0.0 - rank;
    case COSINE: {
      if (rank == -INFINITY) {
        *has = false;
        return 0.0;
      }
      return 0.0 - rank;
    }
    default: return sqrt(-rank);
  }
}

/* vector_block(id, vector [, storage]), an aggregate: the block of its
 * rows, a blob, or NULL for none. The rows are held as they arrive in
 * the buffers of the block, converted to the storage as a corpus does,
 * and assembled once at the end. */
struct block_state {
  bool failed;
  bool started;
  enum storage storage;
  size_t dims;
  size_t count;
  size_t capacity;
  int64_t *ids;
  float *inverse;
  struct code_row *codes;
  unsigned char *data;
};

static void block_release (struct block_state *s) {
  cosmic_free(s->ids);
  cosmic_free(s->inverse);
  cosmic_free(s->codes);
  cosmic_free(s->data);
  s->ids = NULL;
  s->inverse = NULL;
  s->codes = NULL;
  s->data = NULL;
}

static void block_fail (sqlite3_context *ctx, struct block_state *s, const char *why) {
  s->failed = true;
  sqlite3_result_error(ctx, why, -1);
}

/* Resizes `*buffer` to `bytes`, keeping it as it was where the allocator
 * refuses. */
static bool resize (void **buffer, size_t bytes) {
  void *grown = cosmic_realloc(*buffer, bytes);
  if (grown == NULL) return false;
  *buffer = grown;
  return true;
}

/* Room for one more row, within SQLite's length limit on a value. */
static bool block_grow (sqlite3_context *ctx, struct block_state *s) {
  if (s->count < s->capacity) return true;
  uint64_t limit = (uint64_t)sqlite3_limit(sqlite3_context_db_handle(ctx), SQLITE_LIMIT_LENGTH, -1);
  if (layout_of(s->storage, s->dims, s->count + 1).total > limit) {
    block_fail(ctx, s, "a vector block would be longer than SQLite allows a value to be");
    return false;
  }
  size_t grown = s->capacity == 0 ? 16 : s->capacity * 2;
  if (layout_of(s->storage, s->dims, grown).total > limit) grown = s->count + 1;
  bool ok = resize((void **)&s->ids, grown * sizeof *s->ids)
            && resize((void **)&s->inverse, grown * sizeof *s->inverse)
            && (s->storage != INT8 || resize((void **)&s->codes, grown * sizeof *s->codes))
            && resize((void **)&s->data, grown * s->dims * element_size(s->storage));
  if (!ok) {
    s->failed = true;
    sqlite3_result_error_nomem(ctx);
    return false;
  }
  s->capacity = grown;
  return true;
}

static void block_step (sqlite3_context *ctx, int argc, sqlite3_value **argv) {
  struct block_state *s = sqlite3_aggregate_context(ctx, sizeof *s);
  if (s == NULL) {
    sqlite3_result_error_nomem(ctx);
    return;
  }
  if (s->failed) return;
  /* A row without a vector is left out, as an aggregate leaves a NULL. */
  if (sqlite3_value_type(argv[1]) == SQLITE_NULL) return;
  if (sqlite3_value_type(argv[0]) != SQLITE_INTEGER) {
    block_fail(ctx, s, "vector_block wants an integer id");
    return;
  }
  enum storage storage = F32;
  if (argc == 3) {
    const char *name = sqlite3_value_type(argv[2]) == SQLITE_TEXT
                           ? (const char *)sqlite3_value_text(argv[2])
                           : NULL;
    if (name == NULL) {
      block_fail(ctx, s, "a storage is f32, f16 or int8");
      return;
    }
    if (strcmp(name, "f32") == 0) storage = F32;
    else if (strcmp(name, "f16") == 0) storage = F16;
    else if (strcmp(name, "int8") == 0) storage = INT8;
    else {
      block_fail(ctx, s, "a storage is f32, f16 or int8");
      return;
    }
  }
  if (s->started && storage != s->storage) {
    block_fail(ctx, s, "a block holds one storage");
    return;
  }
  struct vector v;
  const char *why = read_value(argv[1], &v);
  if (why == out_of_memory) {
    s->failed = true;
    sqlite3_result_error_nomem(ctx);
    return;
  }
  if (why != NULL) {
    block_fail(ctx, s, why);
    return;
  }
  if (s->started && v.dims != s->dims) {
    release(&v);
    block_fail(ctx, s, "the vectors have different dimensions");
    return;
  }
  for (size_t i = 0; i < v.dims; i++) {
    if (!isfinite(v.values[i])) {
      release(&v);
      block_fail(ctx, s, "a vector holds finite numbers");
      return;
    }
    if (storage == F16 && !(fabsf(v.values[i]) < HALF_LIMIT)) {
      release(&v);
      block_fail(ctx, s, "a half-precision vector holds numbers under 65520 in magnitude");
      return;
    }
  }
  if (!s->started) {
    s->started = true;
    s->storage = storage;
    s->dims = v.dims;
  }
  if (!block_grow(ctx, s)) {
    release(&v);
    return;
  }
  struct corpus rows;
  memset(&rows, 0, sizeof rows);
  rows.dims = s->dims;
  rows.storage = s->storage;
  rows.data = s->data;
  rows.codes = s->codes;
  double length = store_row(&rows, s->count, v.values);
  s->inverse[s->count] = inverse_of(length);
  s->ids[s->count] = sqlite3_value_int64(argv[0]);
  s->count++;
  release(&v);
}

static void block_final (sqlite3_context *ctx) {
  struct block_state *s = sqlite3_aggregate_context(ctx, 0);
  if (s == NULL) {
    sqlite3_result_null(ctx);
    return;
  }
  if (s->failed || s->count == 0) {
    if (!s->failed) sqlite3_result_null(ctx);
    block_release(s);
    return;
  }
  struct block_layout l = layout_of(s->storage, s->dims, s->count);
  unsigned char *out = cosmic_calloc(1, l.total);
  if (out == NULL) {
    sqlite3_result_error_nomem(ctx);
    block_release(s);
    return;
  }
  /* Zeroed, so the header's reserved bytes and the padding between the
   * sections are, and a block is the same bytes whenever it is made. */
  memcpy(out, block_magic, sizeof block_magic);
  out[4] = (unsigned char)s->storage;
  write_u32(out + 8, (uint32_t)s->dims);
  write_u32(out + 12, (uint32_t)s->count);
  memcpy(out + BLOCK_HEADER, s->ids, s->count * sizeof *s->ids);
  memcpy(out + l.inverse, s->inverse, s->count * sizeof *s->inverse);
  if (s->storage == INT8) memcpy(out + l.codes, s->codes, s->count * sizeof *s->codes);
  memcpy(out + l.data, s->data, l.total - l.data);
  block_release(s);
  sqlite3_result_blob64(ctx, out, l.total, cosmic_free);
}

/* vector_block_search(block, query, k [, metric]), a table-valued
 * function: the (at most) k rows of `block` nearest to `query`, as
 * (id, distance) in order of distance, ties to the lower id. */
enum { HIDDEN_BLOCK, HIDDEN_QUERY, HIDDEN_K, HIDDEN_METRIC, HIDDEN_COUNT };

/* The first two columns are the answer's. */
enum { COLUMN_ID, COLUMN_DISTANCE, COLUMN_HIDDEN };

struct block_hit {
  int64_t id;
  double distance;
  bool has_distance;
};

struct block_cursor {
  sqlite3_vtab_cursor base;
  struct block_hit *hits;
  size_t count;
  size_t at;
  sqlite3_int64 k;
  const char *metric;
};

static int block_connect (sqlite3 *db, void *aux, int argc, const char *const *argv,
                          sqlite3_vtab **out, char **error) {
  (void)aux;
  (void)argc;
  (void)argv;
  (void)error;
  int rc = sqlite3_declare_vtab(
      db, "CREATE TABLE x(id INTEGER, distance REAL, block HIDDEN, query HIDDEN, k HIDDEN, "
          "metric HIDDEN)");
  if (rc != SQLITE_OK) return rc;
  /* Pure arithmetic on its arguments, like the functions: a view in a
   * database file may use it. */
  sqlite3_vtab_config(db, SQLITE_VTAB_INNOCUOUS);
  sqlite3_vtab *vtab = cosmic_malloc(sizeof *vtab);
  if (vtab == NULL) return SQLITE_NOMEM;
  memset(vtab, 0, sizeof *vtab);
  *out = vtab;
  return SQLITE_OK;
}

static int block_disconnect (sqlite3_vtab *vtab) {
  cosmic_free(vtab);
  return SQLITE_OK;
}

/* The block, query and k must be given as equalities a join can supply;
 * the metric may be. Anything else the planner tried is refused, so it
 * plans the block's table first. */
static int block_best_index (sqlite3_vtab *vtab, sqlite3_index_info *info) {
  (void)vtab;
  int found[HIDDEN_COUNT];
  for (int i = 0; i < HIDDEN_COUNT; i++) found[i] = -1;
  int unusable = 0;
  for (int i = 0; i < info->nConstraint; i++) {
    const struct sqlite3_index_constraint *k = info->aConstraint + i;
    if (k->iColumn < COLUMN_HIDDEN || k->op != SQLITE_INDEX_CONSTRAINT_EQ) continue;
    if (!k->usable) {
      unusable = 1;
      continue;
    }
    found[k->iColumn - COLUMN_HIDDEN] = i;
  }
  if (unusable || found[HIDDEN_BLOCK] < 0 || found[HIDDEN_QUERY] < 0 || found[HIDDEN_K] < 0) {
    return SQLITE_CONSTRAINT;
  }
  int argument = 0, mask = 0;
  for (int i = 0; i < HIDDEN_COUNT; i++) {
    if (found[i] < 0) continue;
    info->aConstraintUsage[found[i]].argvIndex = ++argument;
    info->aConstraintUsage[found[i]].omit = 1;
    mask |= 1 << i;
  }
  info->idxNum = mask;
  info->estimatedCost = 100.0;
  info->estimatedRows = 10;
  return SQLITE_OK;
}

static int block_open (sqlite3_vtab *vtab, sqlite3_vtab_cursor **out) {
  (void)vtab;
  struct block_cursor *cursor = cosmic_malloc(sizeof *cursor);
  if (cursor == NULL) return SQLITE_NOMEM;
  memset(cursor, 0, sizeof *cursor);
  *out = &cursor->base;
  return SQLITE_OK;
}

static void block_clear (struct block_cursor *cursor) {
  cosmic_free(cursor->hits);
  cursor->hits = NULL;
  cursor->count = 0;
  cursor->at = 0;
}

static int block_close (sqlite3_vtab_cursor *base) {
  struct block_cursor *cursor = (struct block_cursor *)base;
  block_clear(cursor);
  cosmic_free(cursor);
  return SQLITE_OK;
}

/* Makes `why` the statement's error. */
static int block_error (sqlite3_vtab_cursor *base, const char *why) {
  sqlite3_free(base->pVtab->zErrMsg);
  base->pVtab->zErrMsg = sqlite3_mprintf("%s", why);
  return base->pVtab->zErrMsg == NULL ? SQLITE_NOMEM : SQLITE_ERROR;
}

/* Reads the block, whose blob is `value`; it is copied if it is not
 * 8-aligned (SQLite's own values are, so that is for a virtual table
 * that answers a blob at an odd offset). `*owned` is what to free. */
static const char *block_of_value (sqlite3_value *value, struct block *b, void **owned) {
  *owned = NULL;
  if (sqlite3_value_type(value) != SQLITE_BLOB) return "a vector block is a blob";
  size_t len = (size_t)sqlite3_value_bytes(value);
  const void *bytes = sqlite3_value_blob(value);
  if (bytes == NULL) return len == 0 ? "not a vector block" : out_of_memory;
  if ((uintptr_t)bytes % 8 != 0) {
    *owned = cosmic_malloc(len);
    if (*owned == NULL) return out_of_memory;
    memcpy(*owned, bytes, len);
    bytes = *owned;
  }
  return block_view(bytes, len, b);
}

/* TODO: once a caller's packed scan is bound by preparing its query: keep
 * the prepared query (read, checked and, for int8, quantized) between the
 * blocks of a statement. A prototype that did gained about 5% of an int8
 * scan of 768 dimensions in 64 KB pages, within the noise of the VM it
 * was measured on. */
static int block_filter (sqlite3_vtab_cursor *base, int mask, const char *index_string, int argc,
                         sqlite3_value **argv) {
  (void)index_string;
  (void)argc;
  struct block_cursor *cursor = (struct block_cursor *)base;
  block_clear(cursor);
  sqlite3_value *given[HIDDEN_COUNT] = {0};
  for (int i = 0, next = 0; i < HIDDEN_COUNT; i++) {
    if (mask & (1 << i)) given[i] = argv[next++];
  }
  /* A NULL block, query or k answers no rows, as the functions answer NULL. */
  for (int i = 0; i < HIDDEN_K + 1; i++) {
    if (sqlite3_value_type(given[i]) == SQLITE_NULL) return SQLITE_OK;
  }
  if (sqlite3_value_type(given[HIDDEN_K]) != SQLITE_INTEGER) {
    return block_error(base, "k is an integer");
  }
  sqlite3_int64 k = sqlite3_value_int64(given[HIDDEN_K]);
  if (k < 1) return block_error(base, "k is at least 1");
  enum metric metric = INNER_PRODUCT;
  if (given[HIDDEN_METRIC] != NULL) {
    const char *name = sqlite3_value_type(given[HIDDEN_METRIC]) == SQLITE_TEXT
                           ? (const char *)sqlite3_value_text(given[HIDDEN_METRIC])
                           : NULL;
    if (name == NULL || !metric_named(name, &metric)) {
      return block_error(base, "a metric is inner_product, cosine or l2");
    }
  }
  cursor->k = k;
  cursor->metric = metric == COSINE ? "cosine" : metric == L2 ? "l2" : "inner_product";
  struct block block;
  void *owned_block;
  const char *why = block_of_value(given[HIDDEN_BLOCK], &block, &owned_block);
  if (why != NULL) {
    cosmic_free(owned_block);
    return why == out_of_memory ? SQLITE_NOMEM : block_error(base, why);
  }
  struct vector query;
  why = read_value(given[HIDDEN_QUERY], &query);
  bool read = why == NULL;
  if (read && query.dims != block.dims) why = "the query's dimensions are not the block's";
  for (size_t i = 0; why == NULL && i < query.dims; i++) {
    if (!isfinite(query.values[i])) why = "a vector holds finite numbers";
  }
  if (why != NULL) {
    if (read) release(&query);
    cosmic_free(owned_block);
    if (why == out_of_memory) return SQLITE_NOMEM;
    return block_error(base, why);
  }
  size_t limit = (uint64_t)k < block.count ? (size_t)k : block.count;
  struct query asked;
  void *codes = NULL;
  struct hit *items = NULL;
  struct block_hit *hits = NULL;
  bool fits_all = true;
  if (block.storage == INT8) {
    codes = cosmic_malloc(2 * block.dims + 1);
    fits_all = codes != NULL;
  }
  items = cosmic_malloc((limit + 1) * sizeof *items);
  hits = cosmic_malloc((limit + 1) * sizeof *hits);
  fits_all = fits_all && items != NULL && hits != NULL;
  int rc = SQLITE_OK;
  if (!fits_all) {
    rc = SQLITE_NOMEM;
  }
  else {
    query_init(&asked, query.values, block.dims, block.storage, codes);
    struct heap heap = {items, 0, limit, NULL};
    if (!scan_block(&block, &asked, metric, &heap)) {
      rc = block_error(base, "interrupted");
      if (rc == SQLITE_ERROR) rc = SQLITE_INTERRUPT;
    }
    else {
      /* Popping the worst first fills the answer from its tail. */
      size_t n = heap.size;
      for (size_t j = 0; j < n; j++) {
        struct hit worst = heap.items[0];
        heap.items[0] = heap.items[--heap.size];
        sift_down(&heap, 0);
        struct block_hit *out = hits + (n - j - 1);
        out->id = block.ids[worst.row];
        out->distance = block_distance(metric, worst.key, &out->has_distance);
      }
      cursor->hits = hits;
      cursor->count = n;
      hits = NULL;
    }
  }
  cosmic_free(hits);
  cosmic_free(items);
  cosmic_free(codes);
  release(&query);
  cosmic_free(owned_block);
  return rc;
}

static int block_next (sqlite3_vtab_cursor *base) {
  ((struct block_cursor *)base)->at++;
  return SQLITE_OK;
}

static int block_eof (sqlite3_vtab_cursor *base) {
  const struct block_cursor *cursor = (struct block_cursor *)base;
  return cursor->at >= cursor->count;
}

static int block_column (sqlite3_vtab_cursor *base, sqlite3_context *ctx, int column) {
  const struct block_cursor *cursor = (struct block_cursor *)base;
  const struct block_hit *hit = cursor->hits + cursor->at;
  if (column == COLUMN_ID) sqlite3_result_int64(ctx, hit->id);
  else if (column == COLUMN_DISTANCE && hit->has_distance) sqlite3_result_double(ctx, hit->distance);
  /* The arguments read back as they were given, for a WHERE on one that
   * the planner did not take as the argument; the block and the query
   * are too large to keep, and read NULL. */
  else if (column == COLUMN_HIDDEN + HIDDEN_K) sqlite3_result_int64(ctx, cursor->k);
  else if (column == COLUMN_HIDDEN + HIDDEN_METRIC) {
    sqlite3_result_text(ctx, cursor->metric, -1, SQLITE_STATIC);
  }
  return SQLITE_OK;
}

static int block_rowid (sqlite3_vtab_cursor *base, sqlite3_int64 *rowid) {
  *rowid = (sqlite3_int64)((struct block_cursor *)base)->at;
  return SQLITE_OK;
}

static sqlite3_module block_module = {
  .iVersion = 0,
  .xConnect = block_connect,
  .xBestIndex = block_best_index,
  .xDisconnect = block_disconnect,
  .xDestroy = block_disconnect,
  .xOpen = block_open,
  .xClose = block_close,
  .xFilter = block_filter,
  .xNext = block_next,
  .xEof = block_eof,
  .xColumn = block_column,
  .xRowid = block_rowid,
};

static int register_blocks (sqlite3 *db) {
  /* Aggregates of the same kind as the functions: pure, so innocuous. */
  const int flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS;
  int rc = sqlite3_create_function(db, "vector_block", 2, flags, NULL, NULL, block_step,
                                   block_final);
  if (rc == SQLITE_OK) {
    rc = sqlite3_create_function(db, "vector_block", 3, flags, NULL, NULL, block_step,
                                 block_final);
  }
  if (rc == SQLITE_OK) rc = sqlite3_create_module(db, "vector_block_search", &block_module, NULL);
  return rc;
}

/* The block `blob` (argument `arg`) holds, 8-aligned: copied into a
 * pushed userdata where the string is not. Answers NULL, or why it is not
 * a block. */
static const char *lua_block (lua_State *L, int arg, struct block *b) {
  size_t len;
  const char *s = luaL_checklstring(L, arg, &len);
  if ((uintptr_t)s % 8 != 0) {
    void *copy = lua_newuserdatauv(L, len + 1, 0);
    memcpy(copy, s, len);
    s = copy;
  }
  return block_view((const unsigned char *)s, len, b);
}

/* block_info(blob): the dimensions, storage name and count of a block,
 * or `nil` and why it is not one. */
static int vector_block_info (lua_State *L) {
  struct block b;
  const char *why = lua_block(L, 1, &b);
  if (why != NULL) {
    lua_pushnil(L);
    lua_pushstring(L, why);
    return 2;
  }
  lua_pushinteger(L, (lua_Integer)b.dims);
  lua_pushstring(L, b.storage == F32 ? "f32" : b.storage == F16 ? "f16" : "int8");
  lua_pushinteger(L, (lua_Integer)b.count);
  return 3;
}

/* Whether every number of the block's vectors is under `limit` in
 * magnitude (`INFINITY` asks for finite ones). An int8 block's are
 * widened a row at a time through `scratch`. */
static bool numbers_below (const struct block *b, float limit, float *scratch) {
  size_t n = b->count * b->dims;
  unsigned bad = 0;
  if (b->storage == F32) {
    const float *v = b->data;
    for (size_t i = 0; i < n; i++) bad |= !(fabsf(v[i]) < limit);
  }
  else if (b->storage == F16) {
    const _Float16 *v = b->data;
    for (size_t i = 0; i < n; i++) bad |= !(fabsf((float)v[i]) < limit);
  }
  else {
    struct corpus rows = block_corpus(b);
    for (size_t row = 0; row < b->count; row++) {
      const float *v = row_floats(&rows, row, scratch);
      for (size_t i = 0; i < b->dims; i++) bad |= !(fabsf(v[i]) < limit);
    }
  }
  return bad == 0;
}

/* Whether each row of an int8 block holds the sums its header claims, the
 * sum of its codes and of their squares, and no code of -128: the scorers'
 * bounds, and the VNNI kernels' correction, hold for codes from -127 to
 * 127 and the true sum. */
static bool codes_consistent (const struct block *b) {
  for (size_t row = 0; row < b->count; row++) {
    const int8_t *v = (const int8_t *)b->data + row * b->dims;
    int32_t sum = 0;
    uint32_t squares = 0;
    for (size_t i = 0; i < b->dims; i++) {
      if (v[i] < -127) return false;
      sum += v[i];
      squares += (uint32_t)(v[i] * v[i]);
    }
    if (sum != b->codes[row].sum || squares != b->codes[row].sumsq) return false;
  }
  return true;
}

/* The length of stored row `row`, as [`store_row`] answers it when the
 * row is added. `scratch` holds `dims` floats. */
static double stored_length (const struct corpus *c, size_t row, float *scratch) {
  switch (c->storage) {
    case F32: return length_of((const float *)c->data + row * c->dims, c->dims);
    case F16: {
      const float *v = row_floats(c, row, scratch);
      double squares = 0.0;
      for (size_t i = 0; i < c->dims; i++) squares += (double)v[i] * (double)v[i];
      return sqrt(squares);
    }
    default: return (double)c->codes[row].scale * sqrt((double)c->codes[row].sumsq);
  }
}

/* The sign bits of stored row `row` as `quantize` makes them from the f32
 * numbers, read from the stored form: a block has no f32. */
#define PACK_SIGNS(positive) \
  for (; i + 8 <= dims; i += 8) { \
    unsigned byte = 0; \
    for (size_t k = 0; k < 8; k++) byte |= (unsigned)(positive) << (7 - k); \
    bits[i / 8] = (unsigned char)byte; \
  } \
  if (i < dims) { \
    unsigned byte = 0; \
    for (size_t k = 0; i + k < dims; k++) byte |= (unsigned)(positive) << (7 - k); \
    bits[i / 8] = (unsigned char)byte; \
  }

static void quantize_stored (const struct corpus *c, size_t row, unsigned char *bits) {
  size_t dims = c->dims, i = 0;
  if (c->storage == F16) {
    const _Float16 *v = (const _Float16 *)c->data + row * dims;
    PACK_SIGNS((float)v[i + k] > 0.0f)
  }
  else {
    /* A code is positive where the number it stands for is: the scale is
     * not negative. */
    const int8_t *v = (const int8_t *)c->data + row * dims;
    PACK_SIGNS(v[i + k] > 0)
  }
}

/* corpus:add_block(blob): appends every vector of a block, converting
 * them to the corpus's storage when it differs, and computing the lengths
 * cosine reads from the numbers rather than taking the block's. Raises on a blob that is
 * not a block, one of other dimensions, a block of numbers that are not
 * finite, an int8 block whose sums are not its codes' (for an int8
 * corpus), and, for an f16 corpus, a number of 65520 or more in
 * magnitude; the corpus is as it was then. A quantized corpus makes its
 * bit vectors from the stored numbers, as a block holds no f32 to read
 * them from. */
static int corpus_add_block (lua_State *L) {
  struct corpus *c = check_corpus(L, 1);
  struct block b;
  const char *why = lua_block(L, 2, &b);
  if (why != NULL) return luaL_argerror(L, 2, why);
  luaL_argcheck(L, b.dims == c->dims, 2, "the block's dimensions are not the corpus's");
  if (b.count == 0) return 0;
  size_t dims = c->dims;
  float *scratch = lua_newuserdatauv(L, dims * sizeof *scratch + 1, 0);
  /* What a corpus would have refused, found before anything is changed.
   * int8 codes copied as they are have no number to refuse, but the sums
   * the scorers read beside them must be the codes' own. */
  if (b.storage == INT8 && c->storage == INT8) {
    luaL_argcheck(L, codes_consistent(&b), 2, "a vector block's code sums are not its codes'");
  }
  else {
    luaL_argcheck(L, numbers_below(&b, INFINITY, scratch), 2, "a vector holds finite numbers");
    luaL_argcheck(L, c->storage != F16 || b.storage == F16
                         || numbers_below(&b, HALF_LIMIT, scratch),
                  2, "a half-precision vector holds numbers under 65520 in magnitude");
  }
  reserve(L, c, b.count);
  if (b.storage == c->storage) {
    size_t at = c->count, element = element_size(b.storage);
    memcpy(c->ids + at, b.ids, b.count * sizeof *b.ids);
    if (b.storage == INT8) memcpy(c->codes + at, b.codes, b.count * sizeof *b.codes);
    memcpy((unsigned char *)c->data + at * dims * element, b.data, b.count * dims * element);
    c->count += b.count;
    /* The lengths are the corpus's own to compute, from the numbers it now
     * holds, as `add` does: a block's are read by its search alone. */
    for (size_t row = at; row < c->count; row++) {
      c->inverse[row] = inverse_of(stored_length(c, row, scratch));
    }
    if (c->storage != F32) {
      for (size_t row = at; row < c->count; row++) {
        quantize_stored(c, row, c->bits + row * c->bytes);
      }
      c->bits_built = c->count;
    }
  }
  else {
    struct corpus rows = block_corpus(&b);
    for (size_t row = 0; row < b.count; row++) {
      append_row(c, b.ids[row], row_floats(&rows, row, scratch));
    }
  }
  return 0;
}

static const luaL_Reg corpus_methods[] = {
  {"kmeans", corpus_kmeans},
  {"add", corpus_add},
  {"count", corpus_count},
  {"search", corpus_search},
  {"add_block", corpus_add_block},
  {NULL, NULL},
};

static const luaL_Reg module[] = {
  {"corpus", vector_corpus},
  {"pack", vector_pack},
  {"unpack", vector_unpack},
  {"from_json", vector_from_json},
  {"normalize", vector_normalize},
  {"nearest", vector_nearest},
  {"block_info", vector_block_info},
  {NULL, NULL},
};

void cosmic_add_vector_kernel (lua_State *L) {
  lua_pushcfunction(L, vector_kernel);
  lua_setfield(L, -2, "vector_kernel");
}

int cosmic_open_vector (lua_State *L) {
#ifdef INT8_VNNI
  /* The widest the CPU has; the integer sums are exact, so the choice
   * changes no answer. */
  if (has_avx512_vnni()) {
    dot_i8_kernel = dot_i8_avx512_vnni;
    dot_i8_name = "avx512_vnni";
  }
  else if (has_avx_vnni()) {
    dot_i8_kernel = dot_i8_avx_vnni;
    dot_i8_name = "avx_vnni";
  }
#endif
  luaL_newmetatable(L, CORPUS_TYPE);
  lua_newtable(L);
  luaL_setfuncs(L, corpus_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, module);
  return 1;
}
