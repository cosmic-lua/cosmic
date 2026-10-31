/*
 * Hand-written configuration for the vendored expat, in place of the
 * expat_config.h its configure or CMake step would generate, for the
 * three targets this tree cross-compiles for: x86_64/aarch64 Linux
 * (musl) and aarch64 macOS, all little-endian.
 *
 * General entities and the DTD are on, as in expat's default build, so
 * a document that declares an entity reads; expat's own amplification
 * limits refuse one that expands past them. No external entity is ever
 * read: that takes a handler, and core/xml.c sets none. Namespaces are
 * compiled in, and a parser asks for them by name.
 *
 * The hash salt comes from getentropy(3), which both libcs have; where
 * it fails, expat falls back to a weaker salt of the time and pid.
 * expat reads the EXPAT_ENTROPY_DEBUG, EXPAT_ACCOUNTING_DEBUG and
 * EXPAT_MALLOC_DEBUG environment variables, and when one is set writes
 * what it traces to stderr.
 */
#ifndef COSMIC_EXPAT_CONFIG_H
#define COSMIC_EXPAT_CONFIG_H

#if !defined(__BYTE_ORDER__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "expat_config.h is written for little-endian targets"
#endif
#define BYTEORDER 1234

#define HAVE_GETENTROPY 1

#define XML_GE 1
#define XML_DTD 1
#define XML_NS 1
#define XML_CONTEXT_BYTES 1024

#endif
