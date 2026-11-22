#ifndef COSMIC_HTTP_H
#define COSMIC_HTTP_H

#include <stdint.h>

#include <curl/curl.h>
#include <mbedtls/x509_crt.h>

#include "lauxlib.h"

/* Opens the raw [`cosmic.internal.http`] module: `open`, returning a
 * userdata `Handle` with `status`, `url`, `headers`, `read`, `sent` and
 * `close` methods, and `check_certificate`.
 * It is a raw module registered under cosmic.internal.*, as core/sqlite.c
 * is, and listed in core/store.c's `raw_modules` the same way. See
 * cosmic/http/init.tl for the typed wrapper this backs. */
int cosmic_open_http (lua_State *L);

/* Asked by curl's mbedtls verify callback (patch/curl/05-distrust-after.txt)
 * of each certificate of a chain it verifies: the flags Mozilla's distrust
 * dates add to `crt`'s. Defined in core/http.c. */
uint32_t cosmic_tls_distrust (CURL *easy, const mbedtls_x509_crt *crt, int depth);

/* What [`cosmic_roots_distrust`] refused, for a failure's words: each
 * "" until it refuses so. */
struct cosmic_distrust_note {
  /* The subject of the first certificate OneCRL revokes. */
  char revoked[160];
  /* Which distrusted root refused the server's certificate, and why. */
  char distrusted[256];
};

/* The same flags as [`cosmic_tls_distrust`], for a handshake of
 * core/tls.c's, which no curl transfer holds: what it refused goes to
 * `note`. Meaningful once the trust store is loaded (`roots` of
 * cosmic.internal.http); before, it adds none. Defined in core/http.c. */
uint32_t cosmic_roots_distrust (const mbedtls_x509_crt *crt, int depth,
                                struct cosmic_distrust_note *note);

#ifdef COSMIC_CHECKED
/* The checked core's count of transfers holding curl state: made by
 * `open`, and not yet released by a close, a failure or the collector.
 * [`testing.live_transfers`] reads it. */
extern lua_Integer cosmic_http_live_transfers;
#endif

#endif /* COSMIC_HTTP_H */
