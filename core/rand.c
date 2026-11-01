#include "rand.h"

#include <math.h>
#include <stdint.h>

/* cosmic/rand.tl's samplers run in Lua, which rounds every operation to a
 * double on its own; a fused a*b+c would round once and differ in the last
 * bit. Each expression below is written as the Teal one is, and none may
 * be contracted. */
#pragma STDC FP_CONTRACT OFF

static uint64_t rotl (uint64_t x, int k) {
  return (x << k) | (x >> (64 - k));
}

/* The next 64 bits of xoshiro256**, as rand.tl's `next64`. */
static uint64_t next64 (struct cosmic_rand *g) {
  uint64_t *s = g->s;
  uint64_t result = rotl(s[1] * 5, 7) * 9;
  uint64_t t = s[1] << 17;
  s[2] ^= s[0];
  s[3] ^= s[1];
  s[1] ^= s[2];
  s[0] ^= s[3];
  s[2] ^= t;
  s[3] = rotl(s[3], 45);
  return result;
}

/* A float on [0, 1), a multiple of 2^-53, as rand.tl's `unit`. */
static double unit (struct cosmic_rand *g) {
  return (double)(next64(g) >> 11) * (1.0 / 9007199254740992.0);
}

/* As rand.tl's [`standard_normal`]: the polar method, the second value of
 * each pair dropped. */
static double standard_normal (struct cosmic_rand *g) {
  for (;;) {
    double u = 2.0 * unit(g) - 1.0;
    double v = 2.0 * unit(g) - 1.0;
    double s = u * u + v * v;
    if (s < 1.0 && s > 0.0) return u * sqrt(-2.0 * log(s) / s);
  }
}

/* Lua's `a ^ b` (luai_numpow): a square is a product, not a pow call. */
static double lua_pow (double a, double b) {
  return b == 2 ? a * a : pow(a, b);
}

/* As rand.tl's [`standard_gamma`]: Marsaglia and Tsang, a shape below 1
 * boosted by u^(1/shape) with u drawn before the shape + 1 variate. */
static double standard_gamma (struct cosmic_rand *g, double shape) {
  if (shape < 1.0) {
    double u = 1.0 - unit(g);
    double base = standard_gamma(g, shape + 1.0);
    return base * lua_pow(u, 1.0 / shape);
  }
  double d = shape - 1.0 / 3.0;
  double c = 1.0 / sqrt(9.0 * d);
  for (;;) {
    double x = standard_normal(g);
    double t = 1.0 + c * x;
    if (t > 0.0) {
      double v = t * t * t;
      double u = 1.0 - unit(g);
      double x2 = x * x;
      if (u < 1.0 - 0.0331 * x2 * x2 || log(u) < 0.5 * x2 + d * (1.0 - v + log(v)))
        return d * v;
    }
  }
}

double cosmic_rand_next (struct cosmic_rand *g, enum cosmic_rand_kind kind,
                         double first, double second) {
  switch (kind) {
    case COSMIC_RAND_NORMAL: return first + second * standard_normal(g);
    case COSMIC_RAND_GAMMA: return standard_gamma(g, first) * second;
    case COSMIC_RAND_FLOAT: break;
  }
  return unit(g);
}
