/* The bulk draws of cosmic.rand's seeded `Source`: the same xoshiro256**
 * generator and the same samplers as cosmic/rand.tl, operation for
 * operation, so a batch drawn here is bit for bit what that many single
 * draws there would give. */

#ifndef COSMIC_RAND_H
#define COSMIC_RAND_H

#include <stdint.h>

/* The most values one bulk draw returns. */
#define COSMIC_RAND_BULK_MAX (1 << 20)

/* What a draw yields: a float on [0, 1), a normal variate, a gamma variate. */
enum cosmic_rand_kind {
  COSMIC_RAND_FLOAT,
  COSMIC_RAND_NORMAL,
  COSMIC_RAND_GAMMA,
};

/* The generator's four state words. */
struct cosmic_rand {
  uint64_t s[4];
};

/* The next value of `kind` from `generator`. A float takes no parameter;
 * a normal takes its mean in `first` and its standard deviation in
 * `second`; a gamma takes its shape in `first` and its scale in `second`.
 * The parameters are already validated: finite, a standard deviation not
 * negative, a shape and a scale positive. */
double cosmic_rand_next (struct cosmic_rand *generator, enum cosmic_rand_kind kind,
                         double first, double second);

#endif
