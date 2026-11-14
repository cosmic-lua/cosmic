/* mbedtls declares its bignum only to a file that asks for the library's
 * private identifiers: TF-PSA-Crypto's public surface is the PSA API,
 * which has no arithmetic. The functions are those the library's own RSA
 * and ECC call, compiled into every core. */
#define MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS

#include "bigint.h"

#include "fail.h"
#include "guard.h"
#include "lauxlib.h"
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

/* Reads argument `arg`, a string of at most `most` bytes, as a number.
 * A Lua number is refused rather than read as its decimal digits. */
static mbedtls_mpi *read_number (lua_State *L, struct numbers *numbers,
                                 int arg, size_t most) {
  luaL_checktype(L, arg, LUA_TSTRING);
  size_t len;
  const unsigned char *bytes = (const unsigned char *)lua_tolstring(L, arg, &len);
  if (len > most) {
    luaL_argerror(L, arg, lua_pushfstring(L, "the number is longer than %d bytes",
                                          (int)most));
  }
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
 * modulus. mbedtls's exponentiation is Montgomery's and refuses an even
 * one, and answers 1 for an exponent of no limbs whatever the modulus,
 * so a modulus of 1 is answered here. */
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

static const luaL_Reg module[] = {
  {"powmod", bigint_powmod},
  {"mul", bigint_mul},
  {"add", bigint_add},
  {"sub", bigint_sub},
  {"mod", bigint_mod},
  {"compare", bigint_compare},
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
