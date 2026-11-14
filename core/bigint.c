/* mbedtls declares its bignum only to a file that asks for the library's
 * private identifiers: TF-PSA-Crypto's public surface is the PSA API,
 * which has no arithmetic. The functions are those the library's own RSA
 * and ECC call, compiled into every core.
 *
 * Two layers of it are used. The functions that take a time depending on
 * their operands' values, and the exponentiation, work on mbedtls_mpi.
 * The ones that are constant in time work on arrays of limbs with the
 * library's core functions (bignum_core.h, a header of its sources that
 * build.zig puts on the core's include path), and call only those the
 * header documents as constant in time in the values of their operands:
 * mbedtls_mpi_core_mla, mbedtls_mpi_core_sub, mbedtls_mpi_core_montmul
 * and mbedtls_mpi_core_cond_assign. Reading and writing a number there
 * (mbedtls_mpi_core_read_be, mbedtls_mpi_core_write_be) copies bytes by
 * their count. No branch, index or loop bound in that half of this file
 * reads an operand's limb: each is fixed by a length or by the modulus,
 * which is public. */
#define MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS

#include "bigint.h"

#include <string.h>

/* The header is one of the library's sources, held to the library's
 * warnings and not the core's: it trips these two. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wundef"
#pragma GCC diagnostic ignored "-Wsign-conversion"
#include "bignum_core.h"
#pragma GCC diagnostic pop

#include "fail.h"
#include "guard.h"
#include "lauxlib.h"
#include "mbedtls/platform_util.h"
#include "mbedtls/private/bignum.h"
#include "memory.h"

/* The most bytes of a modulus or an exponent: what mbedtls's modular
 * exponentiation accepts of either. */
#define MODULUS_MAX MBEDTLS_MPI_MAX_SIZE

/* The most bytes of any other operand: a product of two numbers below a
 * modulus still fits, so it can be reduced. */
#define OPERAND_MAX (2 * MODULUS_MAX)

enum { numbers_held = 4 };

/* Every number one call works with. An operand of argument `n` is
 * `value[n - 1]`, and the result is the last. */
struct numbers {
  mbedtls_mpi value[numbers_held];
};

/* Frees the numbers; mbedtls zeroes each one's limbs first. */
static void release_numbers (void *resource) {
  struct numbers *numbers = resource;
  for (int i = 0; i < numbers_held; i++) mbedtls_mpi_free(&numbers->value[i]);
  cosmic_free(numbers);
}

/* Pushes a guard holding a call's numbers, each initialized and empty:
 * they are released when the call returns or raises. */
static struct numbers *push_numbers (lua_State *L) {
  struct cosmic_guard *guard = cosmic_guard_push(L, release_numbers);
  struct numbers *numbers = cosmic_malloc(sizeof *numbers);
  if (numbers == NULL) luaL_error(L, "not enough memory");
  for (int i = 0; i < numbers_held; i++) mbedtls_mpi_init(&numbers->value[i]);
  guard->resource = numbers;
  return numbers;
}

/* Raises unless `status`, mbedtls's, is success. The arguments are
 * checked before the library sees them, so what is left is memory. */
static void succeed (lua_State *L, int status) {
  if (status == MBEDTLS_ERR_MPI_ALLOC_FAILED) {
    luaL_error(L, "not enough memory");
  }
  if (status != 0) {
    luaL_error(L, "bigint: the library failed with status %d", status);
  }
}

/* The bytes of argument `arg`, a string of at most `most` bytes, and
 * their count in `len`. A Lua number is refused rather than read as its
 * decimal digits. The bytes are the argument's own: it stays on the
 * stack for the call. */
static const unsigned char *check_number (lua_State *L, int arg, size_t most,
                                          size_t *len) {
  luaL_checktype(L, arg, LUA_TSTRING);
  const unsigned char *bytes = (const unsigned char *)lua_tolstring(L, arg, len);
  if (*len > most) {
    luaL_argerror(L, arg, lua_pushfstring(L, "the number is longer than %d bytes",
                                          (int)most));
  }
  return bytes;
}

/* Reads argument `arg`, a string of at most `most` bytes, as a number. */
static mbedtls_mpi *read_number (lua_State *L, struct numbers *numbers,
                                 int arg, size_t most) {
  size_t len;
  const unsigned char *bytes = check_number(L, arg, most, &len);
  mbedtls_mpi *number = &numbers->value[arg - 1];
  succeed(L, mbedtls_mpi_read_binary(number, bytes, len));
  return number;
}

/* Pushes `number` as its shortest big-endian bytes, one zero byte for
 * zero. */
static int push_number (lua_State *L, const mbedtls_mpi *number) {
  size_t size = mbedtls_mpi_size(number);
  if (size == 0) size = 1;
  luaL_Buffer buffer;
  unsigned char *out = (unsigned char *)luaL_buffinitsize(L, &buffer, size);
  int status = mbedtls_mpi_write_binary(number, out, size);
  luaL_pushresultsize(&buffer, size);
  succeed(L, status);
  return 1;
}

/* powmod(base, exponent, modulus): base^exponent mod modulus, for an odd
 * modulus. mbedtls_mpi_exp_mod is the library's exponentiation for a
 * secret exponent, constant in time in the exponent's value;
 * mbedtls_mpi_exp_mod_unsafe is the one for a public exponent. Neither
 * takes a random source, so there is no blinding to ask for. It is
 * Montgomery's and refuses an even modulus, and answers 1 for an
 * exponent of no limbs whatever the modulus, so a modulus of 1 is
 * answered here. */
static int bigint_powmod (lua_State *L) {
  lua_settop(L, 3);
  struct numbers *numbers = push_numbers(L);
  mbedtls_mpi *base = read_number(L, numbers, 1, OPERAND_MAX);
  mbedtls_mpi *exponent = read_number(L, numbers, 2, MODULUS_MAX);
  mbedtls_mpi *modulus = read_number(L, numbers, 3, MODULUS_MAX);
  mbedtls_mpi *result = &numbers->value[numbers_held - 1];
  luaL_argcheck(L, mbedtls_mpi_cmp_int(modulus, 0) != 0, 3,
                "the modulus is zero");
  luaL_argcheck(L, mbedtls_mpi_get_bit(modulus, 0) == 1, 3,
                "the modulus is even");
  if (mbedtls_mpi_cmp_int(modulus, 1) == 0) {
    succeed(L, mbedtls_mpi_lset(result, 0));
  } else {
    succeed(L, mbedtls_mpi_exp_mod(result, base, exponent, modulus, NULL));
  }
  return push_number(L, result);
}

static int bigint_mul (lua_State *L) {
  lua_settop(L, 2);
  struct numbers *numbers = push_numbers(L);
  mbedtls_mpi *a = read_number(L, numbers, 1, OPERAND_MAX);
  mbedtls_mpi *b = read_number(L, numbers, 2, OPERAND_MAX);
  mbedtls_mpi *result = &numbers->value[numbers_held - 1];
  succeed(L, mbedtls_mpi_mul_mpi(result, a, b));
  return push_number(L, result);
}

static int bigint_add (lua_State *L) {
  lua_settop(L, 2);
  struct numbers *numbers = push_numbers(L);
  mbedtls_mpi *a = read_number(L, numbers, 1, OPERAND_MAX);
  mbedtls_mpi *b = read_number(L, numbers, 2, OPERAND_MAX);
  mbedtls_mpi *result = &numbers->value[numbers_held - 1];
  succeed(L, mbedtls_mpi_add_mpi(result, a, b));
  return push_number(L, result);
}

/* sub(a, b): a - b and "", or nil and a message when b is the larger:
 * no byte string here is a negative number. */
static int bigint_sub (lua_State *L) {
  lua_settop(L, 2);
  struct numbers *numbers = push_numbers(L);
  mbedtls_mpi *a = read_number(L, numbers, 1, OPERAND_MAX);
  mbedtls_mpi *b = read_number(L, numbers, 2, OPERAND_MAX);
  mbedtls_mpi *result = &numbers->value[numbers_held - 1];
  if (mbedtls_mpi_cmp_mpi(a, b) < 0) {
    lua_pushnil(L);
    lua_pushliteral(L, "bigint: the difference is negative");
    return 2;
  }
  succeed(L, mbedtls_mpi_sub_mpi(result, a, b));
  push_number(L, result);
  return cosmic_succeeded(L);
}

static int bigint_mod (lua_State *L) {
  lua_settop(L, 2);
  struct numbers *numbers = push_numbers(L);
  mbedtls_mpi *a = read_number(L, numbers, 1, OPERAND_MAX);
  mbedtls_mpi *modulus = read_number(L, numbers, 2, MODULUS_MAX);
  mbedtls_mpi *result = &numbers->value[numbers_held - 1];
  luaL_argcheck(L, mbedtls_mpi_cmp_int(modulus, 0) != 0, 2,
                "the modulus is zero");
  succeed(L, mbedtls_mpi_mod_mpi(result, a, modulus));
  return push_number(L, result);
}

static int bigint_compare (lua_State *L) {
  lua_settop(L, 2);
  struct numbers *numbers = push_numbers(L);
  mbedtls_mpi *a = read_number(L, numbers, 1, OPERAND_MAX);
  mbedtls_mpi *b = read_number(L, numbers, 2, OPERAND_MAX);
  lua_pushinteger(L, mbedtls_mpi_cmp_mpi(a, b));
  return 1;
}

/* A call's limbs, for the functions that are constant in time: one
 * block, wiped when it is released, since a limb may hold a secret. */
struct limbs {
  size_t size;
  mbedtls_mpi_uint limb[];
};

static void release_limbs (void *resource) {
  struct limbs *limbs = resource;
  mbedtls_platform_zeroize(limbs, limbs->size);
  cosmic_free(limbs);
}

/* Pushes a guard holding `count` limbs, all zero, and answers the
 * first: they are wiped and freed when the call returns or raises. */
static mbedtls_mpi_uint *push_limbs (lua_State *L, size_t count) {
  struct cosmic_guard *guard = cosmic_guard_push(L, release_limbs);
  size_t size = sizeof(struct limbs) + count * ciL;
  struct limbs *limbs = cosmic_calloc(1, size);
  if (limbs == NULL) {
    luaL_error(L, "not enough memory");
    abort(); /* luaL_error never returns */
  }
  limbs->size = size;
  guard->resource = limbs;
  return limbs->limb;
}

/* How many limbs hold a number of `len` bytes: at least one, since the
 * core functions leave a size of 0 undefined. */
static size_t limbs_of (size_t len) {
  return len == 0 ? 1 : CHARS_TO_LIMBS(len);
}

/* A public modulus: its bytes past the leading zero ones, how many
 * there are, how many limbs hold them, and the width an answer modulo
 * it is written at, which is the argument's own length. */
struct modulus {
  const unsigned char *bytes;
  size_t len;
  size_t limbs;
  size_t width;
};

/* Reads argument `arg` as a modulus. Raises on zero. Its leading zero
 * bytes are skipped by their value: a modulus is public. */
static struct modulus check_modulus (lua_State *L, int arg) {
  struct modulus modulus;
  modulus.bytes = check_number(L, arg, MODULUS_MAX, &modulus.width);
  modulus.len = modulus.width;
  while (modulus.len > 0 && modulus.bytes[0] == 0) {
    modulus.bytes++;
    modulus.len--;
  }
  luaL_argcheck(L, modulus.len > 0, arg, "the modulus is zero");
  modulus.limbs = CHARS_TO_LIMBS(modulus.len);
  return modulus;
}

/* Pushes the `limbs` limbs at `number` as exactly `width` big-endian
 * bytes. The number fits: mbedtls_mpi_core_write_be then copies `width`
 * bytes, and reads each one above them once to see that it is zero. */
static int push_fixed (lua_State *L, const mbedtls_mpi_uint *number,
                       size_t limbs, size_t width) {
  luaL_Buffer buffer;
  unsigned char *out = (unsigned char *)luaL_buffinitsize(L, &buffer, width);
  int status = mbedtls_mpi_core_write_be(number, limbs, out, width);
  luaL_pushresultsize(&buffer, width);
  succeed(L, status);
  return 1;
}

/* X = V mod N, where V is S plus `carry` times 2 to the bits of `limbs`
 * limbs and is below 2N: V itself when it is below N, and V - N when it
 * is not, chosen as mbedtls_mpi_core_montmul chooses its own answer.
 * The difference is always computed. It is the answer unless exactly
 * one of the carry and the borrow is set: with neither, S is from N up;
 * with both, V is from 2 to those bits up and the difference wrapped
 * back to V - N. */
static void settle (mbedtls_mpi_uint *X, const mbedtls_mpi_uint *S,
                    mbedtls_mpi_uint carry, const mbedtls_mpi_uint *N,
                    size_t limbs) {
  mbedtls_mpi_uint borrow = mbedtls_mpi_core_sub(X, S, N, limbs);
  mbedtls_mpi_core_cond_assign(X, S, limbs, mbedtls_ct_bool(carry ^ borrow));
}

/* X = (2X + bit) mod N, for X below N and `bit` 0 or 1. S is `limbs`
 * limbs of scratch. */
static void double_and_add (mbedtls_mpi_uint *X, mbedtls_mpi_uint bit,
                            const mbedtls_mpi_uint *N, size_t limbs,
                            mbedtls_mpi_uint *S) {
  memset(S, 0, limbs * ciL);
  S[0] = bit;
  mbedtls_mpi_uint carry = mbedtls_mpi_core_mla(S, limbs, X, limbs, 2);
  settle(X, S, carry, N, limbs);
}

/* X = (argument `arg` times 2 to the `shift`) mod N: the library has no
 * reduction that is constant in time (mbedtls_mpi_mod_mpi divides), so
 * this is Horner's rule over the argument's bits, the highest first,
 * and then `shift` doublings. Every bit of the argument's limbs takes
 * one step, a leading zero one too, so the work is fixed by the
 * argument's length, the modulus's and `shift`. W is scratch of
 * [`limbs_of`] the argument's length, and S of `limbs` limbs. */
static void reduce (lua_State *L, int arg, size_t shift, mbedtls_mpi_uint *X,
                    const mbedtls_mpi_uint *N, size_t limbs,
                    mbedtls_mpi_uint *W, mbedtls_mpi_uint *S) {
  size_t len;
  const unsigned char *bytes = check_number(L, arg, OPERAND_MAX, &len);
  size_t wide = limbs_of(len);
  succeed(L, mbedtls_mpi_core_read_be(W, wide, bytes, len));
  memset(X, 0, limbs * ciL);
  for (size_t i = wide * biL; i-- > 0;) {
    double_and_add(X, (W[i / biL] >> (i % biL)) & 1, N, limbs, S);
  }
  for (size_t i = 0; i < shift; i++) double_and_add(X, 0, N, limbs, S);
}

/* The limbs of a call that works modulo its last argument. */
struct modular {
  struct modulus modulus;
  /* The modulus, and each of its `modulus.limbs` limbs long: two
   * operands reduced, the answer and scratch. */
  mbedtls_mpi_uint *N, *A, *B, *X, *S;
  /* Scratch as wide as the widest operand. */
  mbedtls_mpi_uint *W;
  /* `extra` limbs more of scratch. */
  mbedtls_mpi_uint *T;
};

/* Checks the modulus and the lengths of the `operands` arguments before
 * it, pushes the call's limbs and reads the modulus into them. */
static struct modular push_modular (lua_State *L, int operands, size_t extra) {
  struct modular modular;
  modular.modulus = check_modulus(L, operands + 1);
  size_t limbs = modular.modulus.limbs;
  size_t wide = 1;
  for (int arg = 1; arg <= operands; arg++) {
    size_t len;
    check_number(L, arg, OPERAND_MAX, &len);
    if (limbs_of(len) > wide) wide = limbs_of(len);
  }
  mbedtls_mpi_uint *block = push_limbs(L, 5 * limbs + wide + extra);
  modular.N = block;
  modular.A = block + limbs;
  modular.B = block + 2 * limbs;
  modular.X = block + 3 * limbs;
  modular.S = block + 4 * limbs;
  modular.W = block + 5 * limbs;
  modular.T = modular.W + wide;
  succeed(L, mbedtls_mpi_core_read_be(modular.N, limbs, modular.modulus.bytes,
                                      modular.modulus.len));
  return modular;
}

/* Pushes the answer of a call that works modulo `modular`'s modulus. */
static int push_modular_answer (lua_State *L, const struct modular *modular) {
  return push_fixed(L, modular->X, modular->modulus.limbs,
                    modular->modulus.width);
}

/* reduce(a, modulus): a mod modulus, as wide as the modulus. */
static int bigint_reduce (lua_State *L) {
  lua_settop(L, 2);
  struct modular m = push_modular(L, 1, 0);
  reduce(L, 1, 0, m.X, m.N, m.modulus.limbs, m.W, m.S);
  return push_modular_answer(L, &m);
}

/* addmod(a, b, modulus): (a + b) mod modulus, as wide as the modulus.
 * The sum of the two reduced operands is below twice the modulus:
 * mbedtls_mpi_core_mla with a factor of 1 is the addition the library
 * documents as constant in time. */
static int bigint_addmod (lua_State *L) {
  lua_settop(L, 3);
  struct modular m = push_modular(L, 2, 0);
  size_t limbs = m.modulus.limbs;
  reduce(L, 1, 0, m.A, m.N, limbs, m.W, m.S);
  reduce(L, 2, 0, m.B, m.N, limbs, m.W, m.S);
  memcpy(m.S, m.A, limbs * ciL);
  mbedtls_mpi_uint carry = mbedtls_mpi_core_mla(m.S, limbs, m.B, limbs, 1);
  settle(m.X, m.S, carry, m.N, limbs);
  return push_modular_answer(L, &m);
}

/* submod(a, b, modulus): (a - b) mod modulus, as wide as the modulus.
 * The difference of the two reduced operands and that difference plus
 * the modulus are both computed, and the borrow chooses. */
static int bigint_submod (lua_State *L) {
  lua_settop(L, 3);
  struct modular m = push_modular(L, 2, 0);
  size_t limbs = m.modulus.limbs;
  reduce(L, 1, 0, m.A, m.N, limbs, m.W, m.S);
  reduce(L, 2, 0, m.B, m.N, limbs, m.W, m.S);
  mbedtls_mpi_uint borrow = mbedtls_mpi_core_sub(m.X, m.A, m.B, limbs);
  memcpy(m.S, m.X, limbs * ciL);
  (void)mbedtls_mpi_core_mla(m.S, limbs, m.N, limbs, 1);
  mbedtls_mpi_core_cond_assign(m.X, m.S, limbs, mbedtls_ct_bool(borrow));
  return push_modular_answer(L, &m);
}

/* mulmod(a, b, modulus): (a * b) mod modulus, for an odd modulus, as
 * wide as the modulus. With R 2 to the bits of the modulus's limbs,
 * mbedtls_mpi_core_montmul answers its two factors' product over R, so
 * the first is reduced as a times R, by that many doublings more. */
static int bigint_mulmod (lua_State *L) {
  lua_settop(L, 3);
  struct modular m = push_modular(L, 2, 2 * MODULUS_MAX / ciL + 1);
  size_t limbs = m.modulus.limbs;
  luaL_argcheck(L, (m.N[0] & 1) == 1, 3, "the modulus is even");
  reduce(L, 1, limbs * biL, m.A, m.N, limbs, m.W, m.S);
  reduce(L, 2, 0, m.B, m.N, limbs, m.W, m.S);
  mbedtls_mpi_core_montmul(m.X, m.A, m.B, limbs, m.N, limbs,
                           mbedtls_mpi_core_montmul_init(m.N), m.T);
  return push_modular_answer(L, &m);
}

/* product(a, b): a * b in exactly as many bytes as a and b have
 * together. It is mbedtls_mpi_core_mul's own loop, one
 * mbedtls_mpi_core_mla for each limb of b, written out because only the
 * inner function is documented as constant in time. */
static int bigint_product (lua_State *L) {
  lua_settop(L, 2);
  size_t a_len, b_len;
  const unsigned char *a = check_number(L, 1, OPERAND_MAX, &a_len);
  const unsigned char *b = check_number(L, 2, OPERAND_MAX, &b_len);
  size_t a_limbs = limbs_of(a_len), b_limbs = limbs_of(b_len);
  mbedtls_mpi_uint *A = push_limbs(L, 2 * (a_limbs + b_limbs));
  mbedtls_mpi_uint *B = A + a_limbs;
  mbedtls_mpi_uint *X = B + b_limbs;
  succeed(L, mbedtls_mpi_core_read_be(A, a_limbs, a, a_len));
  succeed(L, mbedtls_mpi_core_read_be(B, b_limbs, b, b_len));
  for (size_t i = 0; i < b_limbs; i++) {
    (void)mbedtls_mpi_core_mla(X + i, a_limbs + 1, A, a_limbs, B[i]);
  }
  return push_fixed(L, X, a_limbs + b_limbs, a_len + b_len);
}

/* sum(a, b): a + b in exactly one byte more than the longer of a and b
 * has, which no carry leaves. */
static int bigint_sum (lua_State *L) {
  lua_settop(L, 2);
  size_t a_len, b_len;
  const unsigned char *a = check_number(L, 1, OPERAND_MAX, &a_len);
  const unsigned char *b = check_number(L, 2, OPERAND_MAX, &b_len);
  size_t width = (a_len > b_len ? a_len : b_len) + 1;
  size_t limbs = CHARS_TO_LIMBS(width), b_limbs = limbs_of(b_len);
  mbedtls_mpi_uint *X = push_limbs(L, limbs + b_limbs);
  mbedtls_mpi_uint *B = X + limbs;
  succeed(L, mbedtls_mpi_core_read_be(X, limbs, a, a_len));
  succeed(L, mbedtls_mpi_core_read_be(B, b_limbs, b, b_len));
  (void)mbedtls_mpi_core_mla(X, limbs, B, b_limbs, 1);
  return push_fixed(L, X, limbs, width);
}

static const luaL_Reg module[] = {
  {"powmod", bigint_powmod},
  {"mul", bigint_mul},
  {"add", bigint_add},
  {"sub", bigint_sub},
  {"mod", bigint_mod},
  {"compare", bigint_compare},
  {"reduce", bigint_reduce},
  {"addmod", bigint_addmod},
  {"submod", bigint_submod},
  {"mulmod", bigint_mulmod},
  {"product", bigint_product},
  {"sum", bigint_sum},
  {NULL, NULL},
};

int cosmic_open_bigint (lua_State *L) {
  luaL_newlib(L, module);
  lua_pushinteger(L, OPERAND_MAX);
  lua_setfield(L, -2, "operand_max");
  lua_pushinteger(L, MODULUS_MAX);
  lua_setfield(L, -2, "modulus_max");
  return 1;
}
