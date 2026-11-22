#include "tls.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>

#include "check.h"
#include "errnos.h"
#include "http.h"
#include "lauxlib.h"
#include "mbedtls/error.h"
#include "mbedtls/pk.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"

#define CONFIG_TYPE "cosmic.tls.config"
#define SESSION_TYPE "cosmic.tls.session"

/* The most protocols a configuration offers by ALPN, and the most
 * certificate and key pairs it holds. */
enum { alpn_most = 8, pairs_most = 64, name_most = 255 };

/* A certificate chain, leaf first, and the leaf's private key. */
struct pair {
  mbedtls_x509_crt chain;
  mbedtls_pk_context key;
};

/* A configuration, a server's or a client's: what every session made
 * of it shares. Its pairs and roots are each initialized when it is
 * made, so its __gc frees all of them however far filling it got. A
 * session holds its configuration as its user value, so the
 * configuration outlives every session of it. A server's pairs are
 * those it presents; a client's, at most one, the certificate it
 * presents to a server that asks for one. */
struct config {
  mbedtls_ssl_config conf;
  /* A client's, rather than a server's. */
  bool client;
  /* Whether the peer's certificate is verified against `roots`. */
  bool verify;
  /* The roots a peer's chain must lead to; empty where none are. */
  mbedtls_x509_crt roots;
  int count;
  const char *alpn[alpn_most + 1];
  char alpn_bytes[alpn_most * (name_most + 1)];
  struct pair pair[];
};

/* A session over one accepted socket, whose descriptor it does not
 * own: the connection that holds it closes the socket, after `free`. */
struct session {
  mbedtls_ssl_context ssl;
  struct config *config;
  int fd;
  /* The errno a send or a receive last failed with, 0 for none. */
  int failure;
  bool live;
  /* The name the client asked for (SNI), as it sent it; on a client's
   * session, the name it asked for. */
  size_t name_size;
  char name[name_most];
  /* On a client's session to an IP address: the address, which the
   * server's certificate must name among its IP Subject Alternative
   * Names, as no name is sent; ip_size 0 otherwise. */
  size_t ip_size;
  unsigned char ip[16];
  /* What the trust store's distrust dates and OneCRL refused. */
  struct cosmic_distrust_note note;
};

/* Pushes `code`'s description, as "tls: <words> (-0xNNNN)". */
static void push_code (lua_State *L, const char *what, int code) {
  char words[160];
  mbedtls_strerror(code, words, sizeof words);
  lua_pushfstring(L, "tls: %s: %s (-0x%04X)", what, words,
                  (unsigned)(code < 0 ? -code : code));
}

/* nil and why, for a configuration whose pair `index` (a client's
 * identity, where `client`) cannot be read. */
static int config_failed (lua_State *L, bool client, const char *what,
                          int index, int code) {
  char where[96];
  if (client) {
    snprintf(where, sizeof where, "the identity's %s", what);
  } else {
    snprintf(where, sizeof where, "pair %d's %s", index, what);
  }
  lua_pushnil(L);
  push_code(L, where, code);
  return 2;
}

static void config_free (struct config *c, int capacity) {
  mbedtls_x509_crt_free(&c->roots);
  for (int i = 0; i < capacity; i++) {
    mbedtls_x509_crt_free(&c->pair[i].chain);
    mbedtls_pk_free(&c->pair[i].key);
  }
  mbedtls_ssl_config_free(&c->conf);
}

/* __gc. A configuration is freed only by the collector: a session
 * holds it for as long as it lives. */
static int config_gc (lua_State *L) {
  struct config *c = luaL_checkudata(L, 1, CONFIG_TYPE);
  int capacity = c->count;
  c->count = 0;
  config_free(c, capacity);
  return 0;
}

/* Whether the DNS name `pattern`, from a certificate, covers `host`,
 * ignoring case: the same name, or `*.rest` for a host of one label
 * more than `rest` (RFC 6125 6.4.3, a wildcard only as the whole left
 * label). */
static bool covers (const unsigned char *pattern, size_t pattern_size,
                    const unsigned char *host, size_t host_size) {
  if (pattern_size >= 2 && pattern[0] == '*' && pattern[1] == '.') {
    const unsigned char *dot = memchr(host, '.', host_size);
    if (dot == NULL || dot == host) return false;
    size_t rest = host_size - (size_t)(dot - host);
    if (rest != pattern_size - 1) return false;
    host = dot;
    host_size = rest;
    pattern++;
    pattern_size--;
  }
  if (pattern_size != host_size) return false;
  for (size_t i = 0; i < host_size; i++) {
    unsigned char a = pattern[i];
    unsigned char b = host[i];
    if (a >= 'A' && a <= 'Z') a = (unsigned char)(a - 'A' + 'a');
    if (b >= 'A' && b <= 'Z') b = (unsigned char)(b - 'A' + 'a');
    if (a != b) return false;
  }
  return true;
}

/* Whether a DNS name of `crt`'s Subject Alternative Names covers
 * `host`. */
static bool names (const mbedtls_x509_crt *crt, const unsigned char *host,
                   size_t size) {
  for (const mbedtls_x509_sequence *san = &crt->subject_alt_names;
       san != NULL && san->buf.p != NULL; san = san->next) {
    if (san->buf.tag ==
            (MBEDTLS_ASN1_CONTEXT_SPECIFIC | MBEDTLS_X509_SAN_DNS_NAME) &&
        covers(san->buf.p, san->buf.len, host, size)) {
      return true;
    }
  }
  return false;
}

/* Whether `name` is made of the letters, digits, `-`, `_`, `.` and `*`
 * a host name or a pattern of one is. */
static bool plausible (const unsigned char *name, size_t size) {
  for (size_t i = 0; i < size; i++) {
    unsigned char c = name[i];
    bool fits = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' ||
                c == '*';
    if (!fits) return false;
  }
  return true;
}

/* mbedtls's certificate callback, after the ClientHello: keeps the name
 * the client asked for, and offers the pairs whose leaves name it, in
 * their order, so a name with an ECDSA and an RSA pair is served the
 * one the client takes. A client that asks for none, or for a name no
 * pair has, is offered every pair. mbedtls serves the first offered
 * whose key signs by an algorithm the client lists. */
static int chosen (mbedtls_ssl_context *ssl) {
  struct session *s = mbedtls_ssl_get_user_data_p(ssl);
  size_t size = 0;
  const unsigned char *host = mbedtls_ssl_get_hs_sni(ssl, &size);
  if (host == NULL || size == 0) return 0;
  /* Kept only where it could be a host name, so what a handler reads
   * of it holds no byte a client chose to mislead a log with. */
  if (size <= sizeof s->name && plausible(host, size)) {
    s->name_size = size;
    memcpy(s->name, host, size);
  }
  struct config *c = s->config;
  for (int i = 0; i < c->count; i++) {
    if (names(&c->pair[i].chain, host, size)) {
      int code = mbedtls_ssl_set_hs_own_cert(ssl, &c->pair[i].chain,
                                             &c->pair[i].key);
      if (code != 0) return code;
    }
  }
  return 0;
}

/* Reads pair `index` of the table at argument `arg` into `p`: its `cert`,
 * a PEM chain with the leaf first, and its `key`, the leaf's private
 * key, PEM. 0, or the library's failure, with `*what` naming which. */
static int pair_read (lua_State *L, int arg, int index, struct pair *p,
                      const char **what) {
  if (lua_geti(L, arg, index) != LUA_TTABLE) {
    return luaL_error(L, "tls: pair %d is not a table", index);
  }
  lua_getfield(L, -1, "cert");
  lua_getfield(L, -2, "key");
  size_t cert_size;
  size_t key_size;
  const char *cert = lua_tolstring(L, -2, &cert_size);
  const char *key = lua_tolstring(L, -1, &key_size);
  if (cert == NULL || key == NULL || lua_type(L, -2) != LUA_TSTRING ||
      lua_type(L, -1) != LUA_TSTRING) {
    return luaL_error(L, "tls: pair %d needs a cert and a key, each a string",
                      index);
  }
  /* PEM is parsed with its terminating NUL, which a Lua string has. */
  *what = "certificate";
  int code = mbedtls_x509_crt_parse(&p->chain, (const unsigned char *)cert,
                                    cert_size + 1);
  if (code > 0) code = MBEDTLS_ERR_X509_INVALID_FORMAT;
  if (code == 0) {
    *what = "key";
    code = mbedtls_pk_parse_key(&p->key, (const unsigned char *)key,
                                key_size + 1, NULL, 0);
  }
  if (code == 0) {
    *what = "key, which is not the certificate's";
    code = mbedtls_pk_check_pair(&p->chain.pk, &p->key);
  }
  lua_pop(L, 3);
  return code;
}

/* The number of ALPN protocols the table at `arg` lists, at most 8;
 * 0 where it is nil. Raises on more. */
static int alpn_counted (lua_State *L, int arg) {
  if (lua_isnoneornil(L, arg)) return 0;
  luaL_checktype(L, arg, LUA_TTABLE);
  lua_Integer listed = luaL_len(L, arg);
  luaL_argcheck(L, listed >= 0 && listed <= alpn_most, arg,
                "at most 8 protocols");
  return (int)listed;
}

/* A new configuration, on the stack, for `endpoint` (a client's or a
 * server's), with room for `count` pairs, read from the table at
 * `pairs_arg`, and the `alpn_count` protocols of the table at
 * `alpn_arg`. Nil and why on the stack in its place where the library
 * refuses it, or a pair cannot be read: 2 then, 1 otherwise. Raises on
 * arguments of the wrong shape. */
static int config_new (lua_State *L, int endpoint, int pairs_arg, int count,
                       int alpn_arg, int alpn_count, struct config **made) {
  struct config *c = lua_newuserdatauv(
      L, sizeof *c + (size_t)count * sizeof c->pair[0], 0);
  c->count = 0;
  c->client = endpoint == MBEDTLS_SSL_IS_CLIENT;
  c->verify = false;
  mbedtls_ssl_config_init(&c->conf);
  mbedtls_x509_crt_init(&c->roots);
  for (int i = 0; i < count; i++) {
    mbedtls_x509_crt_init(&c->pair[i].chain);
    mbedtls_pk_init(&c->pair[i].key);
  }
  c->count = count;
  luaL_setmetatable(L, CONFIG_TYPE);
  *made = c;
  char *bytes = c->alpn_bytes;
  for (int i = 0; i < alpn_count; i++) {
    lua_geti(L, alpn_arg, i + 1);
    size_t size;
    const char *name = lua_tolstring(L, -1, &size);
    if (name == NULL || lua_type(L, -1) != LUA_TSTRING || size == 0 ||
        size > name_most || memchr(name, '\0', size) != NULL) {
      return luaL_error(L,
                        "tls: ALPN protocol %d must be 1 to 255 bytes, no NUL",
                        i + 1);
    }
    memcpy(bytes, name, size);
    bytes[size] = '\0';
    c->alpn[i] = bytes;
    bytes += size + 1;
    lua_pop(L, 1);
  }
  c->alpn[alpn_count] = NULL;
  int code = mbedtls_ssl_config_defaults(&c->conf, endpoint,
                                         MBEDTLS_SSL_TRANSPORT_STREAM,
                                         MBEDTLS_SSL_PRESET_DEFAULT);
  if (code != 0) {
    lua_pushnil(L);
    push_code(L, "configuring", code);
    return 2;
  }
  mbedtls_ssl_conf_min_tls_version(&c->conf, MBEDTLS_SSL_VERSION_TLS1_2);
  mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_NONE);
  if (alpn_count > 0) {
    code = mbedtls_ssl_conf_alpn_protocols(&c->conf, c->alpn);
    if (code != 0) {
      lua_pushnil(L);
      push_code(L, "ALPN", code);
      return 2;
    }
  }
  for (int i = 0; i < c->count; i++) {
    const char *what = "";
    code = pair_read(L, pairs_arg, i + 1, &c->pair[i], &what);
    if (code != 0) return config_failed(L, c->client, what, i + 1, code);
    code = mbedtls_ssl_conf_own_cert(&c->conf, &c->pair[i].chain,
                                     &c->pair[i].key);
    if (code != 0) return config_failed(L, c->client, "certificate", i + 1, code);
  }
  return 1;
}

/* config(pairs, alpn?): a server configuration of `pairs`, each a table
 * of `cert` and `key`, PEM, offering the protocols of `alpn` by ALPN;
 * or nil and why, where a pair cannot be read or its key is not its
 * certificate's. TLS 1.2 and 1.3. */
static int tls_config (lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_Integer count = luaL_len(L, 1);
  luaL_argcheck(L, count >= 1 && count <= pairs_most, 1,
                "one pair or more, and at most 64");
  int alpn_count = alpn_counted(L, 2);
  struct config *c = NULL;
  int pushed = config_new(L, MBEDTLS_SSL_IS_SERVER, 1, (int)count, 2,
                          alpn_count, &c);
  if (pushed != 1) return pushed;
  mbedtls_ssl_conf_cert_cb(&c->conf, chosen);
  return 1;
}

/* client(roots, alpn?, identity?): a client configuration that verifies
 * a server's chain against the PEM certificates of `roots`, or, where
 * `roots` is false, verifies nothing; that offers the protocols of
 * `alpn` by ALPN; and that presents `identity`, a table of `cert` and
 * `key` as a server's pairs are, to a server that asks for a
 * certificate. Nil and why where `roots` holds no certificate mbedtls
 * reads, or the identity cannot be read or its key is not its
 * certificate's. TLS 1.2 and 1.3. */
static int tls_client (lua_State *L) {
  size_t roots_size = 0;
  const char *roots = NULL;
  if (lua_type(L, 1) == LUA_TBOOLEAN) {
    luaL_argcheck(L, !lua_toboolean(L, 1), 1, "PEM roots, or false");
  } else {
    roots = luaL_checklstring(L, 1, &roots_size);
  }
  int alpn_count = alpn_counted(L, 2);
  int count = 0;
  if (!lua_isnoneornil(L, 3)) {
    luaL_checktype(L, 3, LUA_TTABLE);
    /* The identity is read as the only pair of a list of one. */
    lua_createtable(L, 1, 0);
    lua_pushvalue(L, 3);
    lua_rawseti(L, -2, 1);
    lua_replace(L, 3);
    count = 1;
  }
  struct config *c = NULL;
  int pushed = config_new(L, MBEDTLS_SSL_IS_CLIENT, 3, count, 2, alpn_count,
                          &c);
  if (pushed != 1) return pushed;
  if (roots != NULL) {
    /* PEM is parsed with its terminating NUL, which a Lua string has. A
     * positive answer counts certificates it could not read, which are
     * left out, trusted no more than missing ones. */
    int code = mbedtls_x509_crt_parse(&c->roots, (const unsigned char *)roots,
                                      roots_size + 1);
    if (code < 0 || c->roots.raw.len == 0) {
      lua_pushnil(L);
      push_code(L, "the roots", code < 0 ? code : MBEDTLS_ERR_X509_INVALID_FORMAT);
      return 2;
    }
    c->verify = true;
    mbedtls_ssl_conf_ca_chain(&c->conf, &c->roots, NULL);
    mbedtls_ssl_conf_authmode(&c->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
  }
  return 1;
}

/* The days from 1970-01-01 to the proleptic Gregorian `year`-`mon`-`day`
 * (Howard Hinnant's days_from_civil). */
static int64_t days_from_civil (int64_t year, int64_t mon, int64_t day) {
  year -= mon <= 2;
  int64_t era = (year >= 0 ? year : year - 399) / 400;
  int64_t yoe = year - era * 400;
  int64_t doy = (153 * (mon + (mon > 2 ? -3 : 9)) + 2) / 5 + day - 1;
  int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
  return era * 146097 + doe - 719468;
}

static lua_Integer unix_seconds (const mbedtls_x509_time *t) {
  return (lua_Integer)(days_from_civil(t->year, t->mon, t->day) * 86400 +
                       t->hour * 3600 + t->min * 60 + t->sec);
}

/* leaf(pem): what the first certificate of the PEM chain `pem` says of
 * itself: `names`, the DNS names of its Subject Alternative Names, and
 * `not_before` and `not_after`, seconds since the epoch; or nil and why,
 * where it cannot be read. */
static int tls_leaf (lua_State *L) {
  size_t size;
  const char *pem = luaL_checklstring(L, 1, &size);
  lua_createtable(L, 0, 3);
  lua_createtable(L, 4, 0);
  /* Parsed after the pushes, which can raise; freed before any other. */
  mbedtls_x509_crt crt;
  mbedtls_x509_crt_init(&crt);
  int code = mbedtls_x509_crt_parse(&crt, (const unsigned char *)pem,
                                    size + 1);
  if (code > 0) code = MBEDTLS_ERR_X509_INVALID_FORMAT;
  if (code != 0) {
    mbedtls_x509_crt_free(&crt);
    lua_pushnil(L);
    push_code(L, "the certificate", code);
    return 2;
  }
  lua_Integer before = unix_seconds(&crt.valid_from);
  lua_Integer after = unix_seconds(&crt.valid_to);
  /* The names are copied out before any push: each push can raise. */
  enum { listed_most = 100 };
  char listed[listed_most][name_most + 1];
  int count = 0;
  for (const mbedtls_x509_sequence *san = &crt.subject_alt_names;
       san != NULL && san->buf.p != NULL && count < listed_most;
       san = san->next) {
    if (san->buf.tag ==
            (MBEDTLS_ASN1_CONTEXT_SPECIFIC | MBEDTLS_X509_SAN_DNS_NAME) &&
        san->buf.len > 0 && san->buf.len <= name_most) {
      memcpy(listed[count], san->buf.p, san->buf.len);
      listed[count][san->buf.len] = '\0';
      count++;
    }
  }
  mbedtls_x509_crt_free(&crt);
  for (int i = 0; i < count; i++) {
    lua_pushstring(L, listed[i]);
    lua_rawseti(L, -2, i + 1);
  }
  lua_setfield(L, -2, "names");
  lua_pushinteger(L, before);
  lua_setfield(L, -2, "not_before");
  lua_pushinteger(L, after);
  lua_setfield(L, -2, "not_after");
  return 1;
}

/* mbedtls's send, over the session's nonblocking socket. */
static int bio_send (void *context, const unsigned char *data,
                     size_t size) {
  struct session *s = context;
#if defined(MSG_NOSIGNAL)
  const int flags = MSG_NOSIGNAL;
#else
  /* Every socket of core/socket.c's has SO_NOSIGPIPE where there is no
   * MSG_NOSIGNAL. */
  const int flags = 0;
#endif
  ssize_t sent;
  do {
    sent = send(s->fd, data, size, flags);
  } while (sent < 0 && errno == EINTR);
  if (sent >= 0) return (int)sent;
  if (errno == EAGAIN || errno == EWOULDBLOCK) {
    return MBEDTLS_ERR_SSL_WANT_WRITE;
  }
  s->failure = errno;
  return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

/* mbedtls's receive, over the session's nonblocking socket: 0 at the
 * peer's end, which mbedtls reads as the connection's end. */
static int bio_recv (void *context, unsigned char *data, size_t size) {
  struct session *s = context;
  ssize_t got;
  do {
    got = recv(s->fd, data, size, 0);
  } while (got < 0 && errno == EINTR);
  if (got >= 0) return (int)got;
  if (errno == EAGAIN || errno == EWOULDBLOCK) {
    return MBEDTLS_ERR_SSL_WANT_READ;
  }
  s->failure = errno;
  return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

/* The session at argument 1, its last call's errno forgotten, so a
 * failure is described by what failed in this call. */
static struct session *checked_session (lua_State *L) {
  struct session *s = luaL_checkudata(L, 1, SESSION_TYPE);
  if (!s->live) {
    luaL_error(L, "tls: the session is freed"); /* throws: a use after free
                                                   is a bug, not a runtime
                                                   failure */
  }
  s->failure = 0;
  return s;
}

/* Pushes why the peer's chain was refused: each reason mbedtls gives,
 * and what the trust store's distrust dates or OneCRL said. */
static void push_unverified (lua_State *L, struct session *s) {
  uint32_t flags = mbedtls_ssl_get_verify_result(&s->ssl);
  /* Room for every reason mbedtls words, each under 80 bytes. */
  char info[2048];
  int size = mbedtls_x509_crt_verify_info(info, sizeof info, "", flags);
  if (size < 0) size = 0;
  /* One line a reason, the last ended too: joined with "; ". */
  while (size > 0 && info[size - 1] == '\n') info[--size] = '\0';
  for (int i = 0; i < size; i++) {
    if (info[i] == '\n') info[i] = ';';
  }
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  luaL_addstring(&b, "tls: the peer's certificate is not trusted: ");
  for (int i = 0; i < size; i++) {
    luaL_addchar(&b, info[i]);
    if (info[i] == ';') luaL_addchar(&b, ' ');
  }
  if (size == 0) luaL_addstring(&b, "its chain does not verify");
  if (s->note.revoked[0] != '\0') {
    luaL_addstring(&b, "; the certificate ");
    luaL_addstring(&b, s->note.revoked);
    luaL_addstring(&b, " is revoked by Mozilla's OneCRL");
  }
  if (s->note.distrusted[0] != '\0') {
    luaL_addstring(&b, "; ");
    luaL_addstring(&b, s->note.distrusted);
  }
  luaL_pushresult(&b);
}

/* Whether an IP Subject Alternative Name of `crt` is the `size` bytes
 * of `ip`. */
static bool names_ip (const mbedtls_x509_crt *crt, const unsigned char *ip,
                      size_t size) {
  for (const mbedtls_x509_sequence *san = &crt->subject_alt_names;
       san != NULL && san->buf.p != NULL; san = san->next) {
    if (san->buf.tag ==
            (MBEDTLS_ASN1_CONTEXT_SPECIFIC | MBEDTLS_X509_SAN_IP_ADDRESS) &&
        san->buf.len == size && memcmp(san->buf.p, ip, size) == 0) {
      return true;
    }
  }
  return false;
}

/* mbedtls's verify callback, for each certificate of a chain it
 * verifies, the root first: adds what the trust store's distrust dates
 * and OneCRL refuse, and, on a client's session to an IP address, that
 * the server's own certificate does not name it. */
static int verified (void *context, mbedtls_x509_crt *crt, int depth,
                     uint32_t *flags) {
  struct session *s = context;
  *flags |= cosmic_roots_distrust(crt, depth, &s->note);
  if (depth == 0 && s->ip_size > 0 && !names_ip(crt, s->ip, s->ip_size)) {
    *flags |= MBEDTLS_X509_BADCERT_CN_MISMATCH;
  }
  return 0;
}

/* What a call that did not finish answers in its third value. */
enum { stop_failed = 0, stop_read = 1, stop_write = 2, stop_ended = 3 };

/* `first` (nil or false), why, and what stopped the call, of the
 * session's `code`: stop_read or stop_write where it waits for the
 * socket, why "", stop_ended at the peer's end, why "", or stop_failed
 * and why. */
static int unfinished (lua_State *L, struct session *s, int code,
                       bool effect) {
  if (effect) {
    lua_pushboolean(L, 0);
  } else {
    lua_pushnil(L);
  }
  int stop = stop_failed;
  switch (code) {
    case MBEDTLS_ERR_SSL_WANT_READ:
    stop = stop_read;
    break;
    case MBEDTLS_ERR_SSL_WANT_WRITE:
    stop = stop_write;
    break;
    case MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY:
    case MBEDTLS_ERR_SSL_CONN_EOF:
    stop = stop_ended;
    break;
    default:
    break;
  }
  if (stop != stop_failed) {
    lua_pushliteral(L, "");
  } else if (code == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED) {
    push_unverified(L, s);
  } else if (s->failure != 0) {
    int failure = s->failure;
    s->failure = 0;
    lua_pushfstring(L, "tls: %s", cosmic_errno_describe(failure, NULL));
  } else {
    push_code(L, "the session", code);
  }
  lua_pushinteger(L, stop);
  return 3;
}

/* session(config, fd, server_name?): a session of `config` over the
 * socket `fd`, which it does not own: a server's over an accepted
 * socket, or a client's over a connected one. A client's asks for
 * `server_name` (SNI) and verifies that the server's certificate names
 * it, where its configuration verifies; an IP address is asked for by
 * no name, and must be among the certificate's IP Subject Alternative
 * Names. Nil and why where the library cannot set one up. Raises on a
 * client's verifying session with no `server_name`, or a name of a NUL
 * or more than 255 bytes. */
static int tls_session (lua_State *L) {
  struct config *c = luaL_checkudata(L, 1, CONFIG_TYPE);
  int fd = cosmic_checkfd(L, 2);
  size_t name_size = 0;
  const char *name = luaL_optlstring(L, 3, NULL, &name_size);
  if (c->client) {
    luaL_argcheck(L, name != NULL || !c->verify, 3,
                  "a server name, which a client that verifies needs");
    luaL_argcheck(L, name == NULL || (name_size >= 1 && name_size <= name_most &&
                                      memchr(name, '\0', name_size) == NULL),
                  3, "1 to 255 bytes, no NUL");
  } else {
    luaL_argcheck(L, name == NULL, 3, "none, on a server's session");
  }
  struct session *s = lua_newuserdatauv(L, sizeof *s, 1);
  mbedtls_ssl_init(&s->ssl);
  s->config = c;
  s->fd = fd;
  s->failure = 0;
  s->live = true;
  s->name_size = 0;
  s->ip_size = 0;
  s->note.revoked[0] = '\0';
  s->note.distrusted[0] = '\0';
  luaL_setmetatable(L, SESSION_TYPE);
  lua_pushvalue(L, 1);
  lua_setiuservalue(L, -2, 1);
  int code = mbedtls_ssl_setup(&s->ssl, &c->conf);
  if (code != 0) {
    lua_pushnil(L);
    push_code(L, "setting up a session", code);
    return 2;
  }
  mbedtls_ssl_set_user_data_p(&s->ssl, s);
  mbedtls_ssl_set_bio(&s->ssl, s, bio_send, bio_recv, NULL);
  mbedtls_ssl_set_verify(&s->ssl, verified, s);
  if (c->client) {
    const char *asked = name;
    if (name != NULL) {
      memcpy(s->name, name, name_size);
      s->name_size = name_size;
      /* An address is sent as no name (RFC 6066 3), and checked by
       * `verified`: mbedtls would send it, and match it as a DNS name. */
      if (strchr(name, ':') == NULL && inet_pton(AF_INET, name, s->ip) == 1) {
        s->ip_size = 4;
        asked = NULL;
      } else if (inet_pton(AF_INET6, name, s->ip) == 1) {
        s->ip_size = 16;
        asked = NULL;
      }
    }
    /* Called with NULL too: mbedtls then checks no name, rather than
     * refusing to verify without one. */
    code = mbedtls_ssl_set_hostname(&s->ssl, asked);
    if (code != 0) {
      lua_pushnil(L);
      push_code(L, "the server name", code);
      return 2;
    }
  }
  return 1;
}

/* handshake(): true once the handshake is done; false, why and what
 * stopped it otherwise, as `unfinished` says. */
static int session_handshake (lua_State *L) {
  struct session *s = checked_session(L);
  int code = mbedtls_ssl_handshake(&s->ssl);
  if (code != 0) return unfinished(L, s, code, true);
  /* Checked again here: mbedtls trusts a self-issued certificate found
   * among the roots without calling `verified`, so an address it does
   * not name would pass. */
  const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(&s->ssl);
  if (s->config->client && s->config->verify && s->ip_size > 0 &&
      (peer == NULL || !names_ip(peer, s->ip, s->ip_size))) {
    lua_pushboolean(L, 0);
    lua_pushliteral(L, "tls: the peer's certificate is not trusted: "
                    "it names not the address connected to among its IP addresses");
    lua_pushinteger(L, stop_failed);
    return 3;
  }
  lua_pushboolean(L, 1);
  return 1;
}

/* read(max): at most `max` bytes of what the peer sent, at most a
 * record's 16 KiB, handshaking first where that is not done; nil and
 * what `handshake` says otherwise. */
static int session_read (lua_State *L) {
  struct session *s = checked_session(L);
  lua_Integer max = luaL_checkinteger(L, 2);
  luaL_argcheck(L, max >= 1, 2, "must be positive");
  unsigned char data[16384];
  size_t want = max < (lua_Integer)sizeof data ? (size_t)max : sizeof data;
  int got = mbedtls_ssl_read(&s->ssl, data, want);
  if (got <= 0) return unfinished(L, s, got, false);
  lua_pushlstring(L, (const char *)data, (size_t)got);
  return 1;
}

/* write(data, from): how many bytes of `data` from `from` the session
 * took, handshaking first where that is not done; nil and what
 * `handshake` says otherwise. One that waited must be called again
 * with the same bytes. */
static int session_write (lua_State *L) {
  struct session *s = checked_session(L);
  size_t size;
  const char *data = luaL_checklstring(L, 2, &size);
  lua_Integer from = luaL_checkinteger(L, 3);
  luaL_argcheck(L, from >= 1 && (lua_Unsigned)from - 1 < size, 3,
                "out of range");
  int took = mbedtls_ssl_write(&s->ssl,
                               (const unsigned char *)data + (from - 1),
                               size - (size_t)(from - 1));
  if (took < 0) return unfinished(L, s, took, false);
  lua_pushinteger(L, took);
  return 1;
}

/* close_notify(): true once the alert that ends the session is sent;
 * false and what `handshake` says otherwise. */
static int session_close_notify (lua_State *L) {
  struct session *s = checked_session(L);
  int code = mbedtls_ssl_close_notify(&s->ssl);
  if (code != 0) return unfinished(L, s, code, true);
  lua_pushboolean(L, 1);
  return 1;
}

/* Pushes the Subject Alternative Names of `crt` whose tag is `tag`,
 * as a list: each as the certificate holds it, an IP address in its
 * text form. */
static void push_sans (lua_State *L, const mbedtls_x509_crt *crt, int tag) {
  lua_newtable(L);
  int count = 0;
  for (const mbedtls_x509_sequence *san = &crt->subject_alt_names;
       san != NULL && san->buf.p != NULL; san = san->next) {
    if (san->buf.tag != (MBEDTLS_ASN1_CONTEXT_SPECIFIC | tag)) continue;
    if (tag == MBEDTLS_X509_SAN_IP_ADDRESS) {
      char text[64];
      int family = san->buf.len == 4 ? AF_INET : AF_INET6;
      if ((san->buf.len != 4 && san->buf.len != 16) ||
          inet_ntop(family, san->buf.p, text, sizeof text) == NULL) {
        continue;
      }
      lua_pushstring(L, text);
    } else {
      lua_pushlstring(L, (const char *)san->buf.p, san->buf.len);
    }
    lua_rawseti(L, -2, ++count);
  }
}

/* Pushes the distinguished name `dn` as mbedtls words it
 * ("CN=example.com, O=Example"), or "" where it cannot. */
static void push_dn (lua_State *L, const mbedtls_x509_name *dn) {
  char words[1024];
  if (mbedtls_x509_dn_gets(words, sizeof words, dn) < 0) words[0] = '\0';
  lua_pushstring(L, words);
}

/* Pushes what the peer's certificate `crt` says of itself, as
 * cosmic/internal/tls.d.tl's Peer. */
static void push_peer (lua_State *L, struct session *s,
                       const mbedtls_x509_crt *crt) {
  lua_createtable(L, 0, 12);
  lua_pushlstring(L, (const char *)crt->raw.p, crt->raw.len);
  lua_setfield(L, -2, "der");
  lua_pushlstring(L, (const char *)crt->pk_raw.p, crt->pk_raw.len);
  lua_setfield(L, -2, "public_key");
  push_dn(L, &crt->subject);
  lua_setfield(L, -2, "subject");
  push_dn(L, &crt->issuer);
  lua_setfield(L, -2, "issuer");
  char serial[128];
  if (mbedtls_x509_serial_gets(serial, sizeof serial, &crt->serial) < 0) {
    serial[0] = '\0';
  }
  lua_pushstring(L, serial);
  lua_setfield(L, -2, "serial");
  push_sans(L, crt, MBEDTLS_X509_SAN_DNS_NAME);
  lua_setfield(L, -2, "names");
  push_sans(L, crt, MBEDTLS_X509_SAN_IP_ADDRESS);
  lua_setfield(L, -2, "addresses");
  push_sans(L, crt, MBEDTLS_X509_SAN_UNIFORM_RESOURCE_IDENTIFIER);
  lua_setfield(L, -2, "uris");
  push_sans(L, crt, MBEDTLS_X509_SAN_RFC822_NAME);
  lua_setfield(L, -2, "emails");
  lua_pushinteger(L, unix_seconds(&crt->valid_from));
  lua_setfield(L, -2, "not_before");
  lua_pushinteger(L, unix_seconds(&crt->valid_to));
  lua_setfield(L, -2, "not_after");
  /* Verified only where the configuration asked, and the chain passed:
   * a configuration that verifies nothing reports a peer unverified. */
  bool checked = s->config->verify &&
                 mbedtls_ssl_get_verify_result(&s->ssl) == 0;
  lua_pushboolean(L, checked);
  lua_setfield(L, -2, "verified");
}

/* info(): the version the handshake settled on ("TLSv1.3"), the
 * protocol ALPN chose, the name the client asked for, and what the
 * peer's certificate says, the last three nil where there is none. */
static int session_info (lua_State *L) {
  struct session *s = checked_session(L);
  lua_createtable(L, 0, 4);
  lua_pushstring(L, mbedtls_ssl_get_version(&s->ssl));
  lua_setfield(L, -2, "version");
  const char *alpn = mbedtls_ssl_get_alpn_protocol(&s->ssl);
  if (alpn != NULL) {
    lua_pushstring(L, alpn);
    lua_setfield(L, -2, "alpn");
  }
  if (s->name_size > 0) {
    lua_pushlstring(L, s->name, s->name_size);
    lua_setfield(L, -2, "server_name");
  }
  const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(&s->ssl);
  if (peer != NULL && peer->raw.len > 0) {
    push_peer(L, s, peer);
    lua_setfield(L, -2, "peer");
  }
  return 1;
}

static void session_release (struct session *s) {
  if (s->live) {
    s->live = false;
    mbedtls_ssl_free(&s->ssl);
  }
}

/* free(), __close and __gc: frees the session, once. Its socket is the
 * caller's. */
static int session_free (lua_State *L) {
  session_release(luaL_checkudata(L, 1, SESSION_TYPE));
  return 0;
}

static const luaL_Reg session_methods[] = {
  {"handshake", session_handshake},
  {"read", session_read},
  {"write", session_write},
  {"close_notify", session_close_notify},
  {"info", session_info},
  {"free", session_free},
  {NULL, NULL},
};

static const luaL_Reg module[] = {
  {"config", tls_config},
  {"client", tls_client},
  {"session", tls_session},
  {"leaf", tls_leaf},
  {NULL, NULL},
};

int cosmic_open_tls (lua_State *L) {
  luaL_newmetatable(L, CONFIG_TYPE);
  lua_pushcfunction(L, config_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
  luaL_newmetatable(L, SESSION_TYPE);
  lua_pushcfunction(L, session_free);
  lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, session_free);
  lua_setfield(L, -2, "__close");
  lua_newtable(L);
  luaL_setfuncs(L, session_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);
  luaL_newlib(L, module);
  lua_pushinteger(L, stop_failed);
  lua_setfield(L, -2, "FAILED");
  lua_pushinteger(L, stop_read);
  lua_setfield(L, -2, "READ");
  lua_pushinteger(L, stop_write);
  lua_setfield(L, -2, "WRITE");
  lua_pushinteger(L, stop_ended);
  lua_setfield(L, -2, "ENDED");
  return 1;
}
