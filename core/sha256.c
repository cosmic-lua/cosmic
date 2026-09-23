/*
 * SHA-256, the one hash the core carries: the importer's content keys
 * and the Mach-O code signature's page hashes.
 */

#include "sha256.h"

#include <stdint.h>
#include <string.h>

struct cosmic_sha256 {
  uint32_t state[8];
  uint64_t length;
  unsigned char block[64];
  size_t held;
};

static const uint32_t round_constants[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static uint32_t rotate_right(uint32_t x, unsigned n) {
  return (x >> n) | (x << (32 - n));
}

static void compress(struct cosmic_sha256 *s, const unsigned char *block) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++) {
    w[i] = (uint32_t)block[i * 4] << 24 | (uint32_t)block[i * 4 + 1] << 16 |
           (uint32_t)block[i * 4 + 2] << 8 | (uint32_t)block[i * 4 + 3];
  }
  for (int i = 16; i < 64; i++) {
    uint32_t a = w[i - 15], b = w[i - 2];
    uint32_t s0 = rotate_right(a, 7) ^ rotate_right(a, 18) ^ (a >> 3);
    uint32_t s1 = rotate_right(b, 17) ^ rotate_right(b, 19) ^ (b >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }

  uint32_t a = s->state[0], b = s->state[1], c = s->state[2], d = s->state[3];
  uint32_t e = s->state[4], f = s->state[5], g = s->state[6], h = s->state[7];

  for (int i = 0; i < 64; i++) {
    uint32_t s1 = rotate_right(e, 6) ^ rotate_right(e, 11) ^ rotate_right(e, 25);
    uint32_t ch = (e & f) ^ (~e & g);
    uint32_t t1 = h + s1 + ch + round_constants[i] + w[i];
    uint32_t s0 = rotate_right(a, 2) ^ rotate_right(a, 13) ^ rotate_right(a, 22);
    uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
    uint32_t t2 = s0 + maj;
    h = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }

  s->state[0] += a;
  s->state[1] += b;
  s->state[2] += c;
  s->state[3] += d;
  s->state[4] += e;
  s->state[5] += f;
  s->state[6] += g;
  s->state[7] += h;
}

static void cosmic_sha256_begin(struct cosmic_sha256 *s) {
  s->state[0] = 0x6a09e667;
  s->state[1] = 0xbb67ae85;
  s->state[2] = 0x3c6ef372;
  s->state[3] = 0xa54ff53a;
  s->state[4] = 0x510e527f;
  s->state[5] = 0x9b05688c;
  s->state[6] = 0x1f83d9ab;
  s->state[7] = 0x5be0cd19;
  s->length = 0;
  s->held = 0;
}

static void cosmic_sha256_add(struct cosmic_sha256 *s, const void *data,
                              size_t len) {
  const unsigned char *at = data;
  s->length += (uint64_t)len;
  while (len > 0) {
    size_t room = 64 - s->held;
    size_t take = len < room ? len : room;
    memcpy(s->block + s->held, at, take);
    s->held += take;
    at += take;
    len -= take;
    if (s->held == 64) {
      compress(s, s->block);
      s->held = 0;
    }
  }
}

static void cosmic_sha256_end(struct cosmic_sha256 *s, unsigned char out[32]) {
  uint64_t bits = s->length * 8;
  unsigned char pad = 0x80;
  cosmic_sha256_add(s, &pad, 1);
  unsigned char zero = 0;
  while (s->held != 56) {
    cosmic_sha256_add(s, &zero, 1);
  }
  unsigned char tail[8];
  for (int i = 0; i < 8; i++) {
    tail[i] = (unsigned char)(bits >> (56 - i * 8));
  }
  cosmic_sha256_add(s, tail, 8);
  for (int i = 0; i < 8; i++) {
    out[i * 4] = (unsigned char)(s->state[i] >> 24);
    out[i * 4 + 1] = (unsigned char)(s->state[i] >> 16);
    out[i * 4 + 2] = (unsigned char)(s->state[i] >> 8);
    out[i * 4 + 3] = (unsigned char)s->state[i];
  }
}

void cosmic_sha256(const void *data, size_t len, unsigned char out[32]) {
  struct cosmic_sha256 s;
  cosmic_sha256_begin(&s);
  cosmic_sha256_add(&s, data, len);
  cosmic_sha256_end(&s, out);
}
