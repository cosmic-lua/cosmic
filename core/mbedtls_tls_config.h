/*
 * mbedtls's TLS/X.509 layer also insists on a configuration header (see
 * crypto_config.h for the same pattern on the crypto side). The
 * configuration itself is the flags in build.zig, which are part of the
 * compile's cache key where a header is not reliably; this file exists
 * to be named.
 */
